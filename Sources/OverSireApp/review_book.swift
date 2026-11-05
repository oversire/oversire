import Foundation
import OverSireCore
import RuntimeDaemon

/// The groups of Work › Review, in page order.
enum ReviewGroup: String, CaseIterable {
    case plans, code, waiting, conflict

    var title: String {
        switch self {
        case .plans: return "Plans to approve"
        case .code: return "Code to review"
        case .waiting: return "Waiting for the agent"
        case .conflict: return "Conflict"
        }
    }

    var note: String {
        switch self {
        case .plans: return "Approve sets Todo, then the queue can take it"
        case .code: return "Oldest first"
        case .waiting: return ""
        case .conflict: return "The agent rebases and fixes it"
        }
    }

    /// nil: a merged review shows in no group.
    init?(_ s: ReviewSummary) {
        switch s.state {
        case .ready: self = s.kind == .plan ? .plans : .code
        case .waiting: self = .waiting
        case .conflict: self = .conflict
        case .merged: return nil
        }
    }
}

/// The read state of the reviews of one machine. A failed read keeps the old rows, so the page tells their age.
struct ReviewHealth: Equatable {
    /// The time of the last read that worked.
    var read: Date?
    /// The error of the last read. nil: the last read worked.
    var error: String?

    /// The banner text when the last read failed.
    func notice(machine: String, now: Date) -> (title: String, body: String)? {
        guard let error else { return nil }
        let age = read.map { "This data is from \(MachinesModel.ago($0, now: now))." } ?? "No read worked yet."
        return ("The reviews of \(machine) did not load: \(error.lowercasedFirst)", age + " OverSire tries again each minute.")
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// The reviews of all machines of the group (OVERSIRE-371). Each row keeps its machine, so each call goes to the right daemon.
/// A review frame of a daemon reads that machine again. A read on start, on a log gap and each 60 s catches what a frame missed.
/// A failed read keeps the last rows of the machine and sets its health. Use it on the main thread.
final class ReviewBook {
    static let changed = Notification.Name("ReviewBook.changed")

    private let sources: () -> [any ReviewSource]
    private let bus: ChangeBus
    private var pages: [String: ReviewsPage] = [:]   // machine → page
    private var desks: [String: ReviewDesk] = [:]    // ReviewSummary.id → desk
    private var healths: [String: ReviewHealth] = [:] // machine → last read
    private let sink: any LogSink
    let now: () -> Date
    private var timer: Timer?
    /// The tracker writes of the desks.
    var tracker: (any ReviewTracking)? = nil
    /// False for `--uishots`: the seeded rows stay.
    var reads = true

    init(sources: @escaping () -> [any ReviewSource] = ReviewBook.groupSources, bus: ChangeBus = .shared,
         log: any LogSink = AppLog(), now: @escaping () -> Date = Date.init) {
        self.sources = sources
        self.bus = bus
        self.sink = log
        self.now = now
    }

    /// The daemons of the active machines.
    static func groupSources() -> [any ReviewSource] {
        guard let hub = ENV.machines else { return [] }
        return hub.active.compactMap { hub.runtime($0.machine) }
    }

    // MARK: What the page shows

    /// All open reviews of all machines. A merged review does not show.
    var rows: [ReviewSummary] {
        pages.keys.sorted().flatMap { pages[$0]!.reviews }.filter { $0.state != .merged }
    }

    /// Each group with its rows, oldest first. A group with no rows is left out.
    var groups: [(group: ReviewGroup, rows: [ReviewSummary])] {
        let all = rows
        return ReviewGroup.allCases.compactMap { g in
            let list = all.filter { ReviewGroup($0) == g }.sorted { Self.since($0) < Self.since($1) }
            return list.isEmpty ? nil : (g, list)
        }
    }

    /// The rows where you act: a plan or code that waits for your review.
    var yourTurn: Int { rows.filter { $0.state == .ready }.count }

    /// The base branches with local commits, on all machines.
    var notPushed: [(machine: String, item: NotPushed)] {
        pages.keys.sorted().flatMap { m in pages[m]!.notPushed.map { (m, $0) } }
    }

    /// The open review of the key. A code review wins over a plan review of the same key.
    func review(_ key: String, kind: ReviewKind? = nil) -> ReviewSummary? {
        let list = rows.filter { $0.key == key && (kind == nil || $0.kind == kind) }
        return list.first { $0.kind == .code } ?? list.first
    }

    static func since(_ s: ReviewSummary) -> Date { s.readyAt ?? s.updatedAt }

    func health(_ machine: String) -> ReviewHealth { healths[machine] ?? ReviewHealth() }

    /// The machines whose last read failed, by name.
    var failing: [String] { healths.filter { $0.value.error != nil }.keys.sorted() }

    // MARK: Reads

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { await self?.refresh() } }
        Task { await refresh() }
    }

    /// Reads all machines at once. A machine that left the group loses its rows.
    func refresh() async {
        guard reads else { return }
        let list = await MainActor.run { sources() }
        let got = await withTaskGroup(of: (String, Result<ReviewsPage, ProviderError>).self) { g in
            for s in list { g.addTask { [self] in (s.machine, await read(s)) } }
            var out: [(String, Result<ReviewsPage, ProviderError>)] = []
            for await r in g { out.append(r) }
            return out
        }
        await MainActor.run {
            let machines = Set(list.map(\.machine))
            var next = pages.filter { machines.contains($0.key) }
            var health = healths.filter { machines.contains($0.key) }
            for (m, r) in got {
                if case .success(let p) = r { next[m] = p }
                health[m] = Self.health(health[m], r, at: now())
            }
            set(next, health: health)
        }
    }

    /// Reads one machine again.
    func refresh(machine: String) async {
        guard reads, let s = await MainActor.run(body: { source(machine) }) else { return }
        let r = await read(s)
        await MainActor.run {
            var next = pages
            if case .success(let p) = r { next[machine] = p }
            var health = healths
            health[machine] = Self.health(health[machine], r, at: now())
            set(next, health: health)
        }
    }

    /// A review frame: the rows of the machine and the open desk of the key read again.
    func apply(_ e: ReviewEvent, from machine: String) async {
        let m = e.machine ?? machine
        await refresh(machine: m)
        let desk = await MainActor.run { desks["\(m)/\(e.kind.rawValue)/\(e.key)"] }
        await desk?.load()
    }

    /// One job line for each read: 3 failures in a row open a problem, a read that works clears it.
    private func read(_ s: any ReviewSource) async -> Result<ReviewsPage, ProviderError> {
        let t0 = Date()
        let r = await Result<ReviewsPage, ProviderError>(awaiting: { try await s.reviews(kind: nil) })
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        switch r {
        case .success(let p):
            var e = LogEntry(level: .ok, area: .sync, job: "Reviews read", host: s.machine, message: "\(p.reviews.count) reviews", ms: ms)
            e.verbose = true
            sink.write(e)
        case .failure(let err):
            sink.write(LogEntry(level: .warn, area: .sync, job: "Reviews read", host: s.machine, message: err.message, ms: ms))
        }
        return r
    }

    private static func health(_ old: ReviewHealth?, _ r: Result<ReviewsPage, ProviderError>, at t: Date) -> ReviewHealth {
        switch r {
        case .success: return ReviewHealth(read: t)
        case .failure(let e): return ReviewHealth(read: old?.read, error: e.message)
        }
    }

    func source(_ machine: String) -> (any ReviewSource)? { sources().first { $0.machine == machine } }

    /// The desk of a review. It stays while the app runs, so a tab keeps its place and its drafts.
    func desk(_ s: ReviewSummary) -> ReviewDesk? {
        if let d = desks[s.id] { return d }
        guard let src = source(s.machine) else { return nil }
        let d = ReviewDesk(summary: s, source: src, tracker: tracker, bus: bus)
        d.local = src is LocalMachineRuntime
        d.agent = { key in
            let rt = PROJECTS_CFG.runtime
            guard let command = try? rt.command(for: rt.agent).resolve(name: key, key: key, title: key) else { return nil }
            let l = rt.launch(rt.agent, name: key, key: key, title: key)
            return l.spec(command: command)
        }
        desks[s.id] = d
        return d
    }

    /// For tests and `--uishots`: a desk with its data, and no reads.
    func put(_ d: ReviewDesk) { desks[d.id] = d }

    /// For tests and `--uishots`.
    func set(_ next: [String: ReviewsPage], health: [String: ReviewHealth]? = nil) {
        let health = health ?? healths
        guard next != pages || health != healths else { return }
        let keys = Set(pages.values.flatMap(\.reviews).map(\.key)).union(next.values.flatMap(\.reviews).map(\.key))
        pages = next
        healths = health
        bus.post(DataChange(.reviews, items: keys, origin: .event))
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

let REVIEWS = ReviewBook()
