import Foundation
import OverSireCore

// The counters of the Home tiles. The pure parts are static. The instance keeps the data that polls do not give:
// the session minutes of each day and the PRs merged this week. A nil counter is not known: the tile hides its line.
final class WorkStats {
    static let changed = Notification.Name("WorkStatsChanged")
    static let keepDays = 14
    static let maxGap: TimeInterval = 120
    static let mergedEvery: TimeInterval = 1800

    struct Merged: Codable, Equatable {
        let repo: String
        let number: Int
        let at: Date
    }

    private struct State: Codable {
        var minutes: [String: Double] = [:]   // "yyyy-MM-dd" → session minutes
        var merged: [Merged]?
        var mergedAt: Date?
    }

    private var state = State()
    private var lastSample: (at: Date, working: Int)?
    private var fetching = false
    private let path: String
    private let fetchMerged: (_ since: Date) -> [Merged]?
    var now: () -> Date = Date.init
    var calendar = Calendar.current

    init(path: String, fetchMerged: @escaping (Date) -> [Merged]? = WorkStats.ghMerged) {
        self.path = path
        self.fetchMerged = fetchMerged
        if let d = FileManager.default.contents(atPath: path) {
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            if let s = try? dec.decode(State.self, from: d) { state = s }
        }
    }

    // MARK: Days

    /// The 7 days of the calendar week of `now`, the first day of the week first.
    static func week(_ now: Date, calendar: Calendar) -> [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// The count for each day of the week of `now`.
    static func perDay(_ dates: [Date], now: Date, calendar: Calendar) -> [Int] {
        week(now, calendar: calendar).map { d in dates.filter { calendar.isDate($0, inSameDayAs: d) }.count }
    }

    static func dayKey(_ d: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Counters

    /// Success against failure of the completed runs: the rolling 7 days, then each of the 7 days, the oldest first.
    /// Nil when no run completed in that time.
    static func passRate(_ runs: [Run], now: Date, calendar: Calendar) -> (rate: Double?, daily: [Double?]) {
        let today = calendar.startOfDay(for: now)
        let days = (0..<7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
        let done = runs.compactMap { r -> (Date, Bool)? in
            guard r.status == "completed", let c = r.conclusion, c == "success" || c == "failure",
                  let at = parseISO(r.updatedAt), at <= now, at >= days[0] else { return nil }
            return (at, c == "success")
        }
        func rate(_ l: [(Date, Bool)]) -> Double? { l.isEmpty ? nil : Double(l.filter(\.1).count) / Double(l.count) }
        return (rate(done), days.map { d in rate(done.filter { calendar.isDate($0.0, inSameDayAs: d) }) })
    }

    /// The PRs that wait for the user's review, and the creation time of the oldest.
    static func reviews(_ prs: [ChangeRequest]) -> (count: Int, oldest: Date?) {
        let l = prs.filter { !$0.mine && !$0.isDraft }
        return (l.count, l.compactMap { parseISO($0.createdAt) }.min())
    }

    /// The items of the user that closed on each day of the week.
    static func closed(_ entries: [ActivityEntry], mine: (ActivityEntry) -> Bool, now: Date, calendar: Calendar) -> [Int] {
        // An item that closes, opens and closes again counts once on each day.
        var seen = Set<String>()
        let dates = entries.filter { $0.change == .closed && mine($0) }.sorted { $0.at < $1.at }.compactMap { e -> Date? in
            seen.insert("\(e.projectKey)|\(e.itemId)|\(dayKey(e.at, calendar: calendar))").inserted ? e.at : nil
        }
        return perDay(dates, now: now, calendar: calendar)
    }

    /// The reset time of a usage-limit message near the end of the screen: "3pm", "3:05 PM". Nil when there is none.
    static func usageLimit(_ lines: [String]) -> String? {
        for l in lines.suffix(12).reversed() {
            let s = l.trimmingCharacters(in: .whitespaces)
            guard s.range(of: "limit", options: .caseInsensitive) != nil,
                  let m = limitRE.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range(at: 1), in: s) else { continue }
            return String(s[r]).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    private static let limitRE = try! NSRegularExpression(
        pattern: #"(?i)(?:resets?(?: at)?|try again at)\s+(\d{1,2}(?::\d{2})?\s?(?:[ap]m)?)"#)

    /// Fixed data for the uishots.
    func seed(hours: [Double], merged: [Merged]) {
        for (d, h) in zip(WorkStats.week(now(), calendar: calendar), hours) { state.minutes[WorkStats.dayKey(d, calendar: calendar)] = h * 60 }
        state.merged = merged
        state.mergedAt = now()
    }

    // MARK: Session minutes

    /// Adds the time since the last sample for each session that worked then. A gap over 2 minutes adds nothing:
    /// the app slept or did not poll.
    func sample(working: Int, at: Date? = nil) {
        let at = at ?? now()
        defer { lastSample = (at, working) }
        guard let last = lastSample, last.working > 0 else { return }
        let gap = at.timeIntervalSince(last.at)
        guard gap > 0, gap <= WorkStats.maxGap else { return }
        state.minutes[WorkStats.dayKey(at, calendar: calendar), default: 0] += gap / 60 * Double(last.working)
        let keep = Set((0..<WorkStats.keepDays).compactMap { calendar.date(byAdding: .day, value: -$0, to: at) }
            .map { WorkStats.dayKey($0, calendar: calendar) })
        state.minutes = state.minutes.filter { keep.contains($0.key) }
        save()
    }

    /// The session hours of each day of this week.
    var sessionHours: [Double] {
        WorkStats.week(now(), calendar: calendar).map { (state.minutes[WorkStats.dayKey($0, calendar: calendar)] ?? 0) / 60 }
    }

    // MARK: Merged PRs

    /// The PRs of the user merged on each day of this week, in the tracked repos. Nil until the first fetch.
    func merged(repos: [String]) -> [Int]? {
        guard let l = state.merged else { return nil }
        let set = Set(repos.map { $0.lowercased() })
        return WorkStats.perDay(l.filter { set.contains($0.repo.lowercased()) }.map(\.at), now: now(), calendar: calendar)
    }

    /// Fetches the merged PRs off the main thread, at most each 30 minutes.
    func refreshMerged(force: Bool = false) {
        let t = now()
        guard !fetching, force || state.mergedAt.map({ t.timeIntervalSince($0) >= WorkStats.mergedEvery }) ?? true else { return }
        fetching = true
        let since = WorkStats.week(t, calendar: calendar)[0]
        let fetch = fetchMerged
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let l = fetch(since)
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                guard let l else { return }
                self.state.merged = l
                self.state.mergedAt = t
                self.save()
                NotificationCenter.default.post(name: WorkStats.changed, object: self)
            }
        }
    }

    static func ghMerged(since: Date) -> [Merged]? {
        struct Hit: Decodable {
            struct Repo: Decodable { let nameWithOwner: String }
            let number: Int
            let repository: Repo
            let closedAt: String
        }
        let day = ISO8601DateFormatter.string(from: since, timeZone: .current, formatOptions: [.withFullDate])
        guard let out = try? ghRun(["search", "prs", "--author=@me", "--merged", "--merged-at", ">=\(day)",
                                    "--json", "number,repository,closedAt", "--limit", "200"], timeout: 30),
              out.status == 0, let hits = try? JSONDecoder().decode([Hit].self, from: out.stdout) else { return nil }
        return hits.compactMap { h in parseISO(h.closedAt).map { Merged(repo: h.repository.nameWithOwner, number: h.number, at: $0) } }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let d = try? enc.encode(state) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

extension AgentIndex {
    /// The sessions that stopped at a usage limit, with the reset time from the screen.
    var limits: [(key: String, reset: String)] {
        agents.keys.sorted().compactMap { k in
            guard let st = state(k), st != .working, st != .closed, let r = watch(k)?.limit else { return nil }
            return (k, r)
        }
    }
}
