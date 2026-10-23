import Cocoa
import OverSireCore

// ─── Logs ────────────────────────────────────────────────────────────────────
// One JSONL file a day in ~/.config/oversire/logs/. The logs stay on this Mac.
// Each line goes to the ProblemTracker, also a line that the log does not keep.

/// The log of the app. Tests and the CLI paths keep NoLog.
var APP_LOG: any LogSink = NoLog()

/// Writes to APP_LOG at the time of the write. Adapters get it before the log store starts.
struct AppLog: LogSink {
    func write(_ e: LogEntry) { APP_LOG.write(e) }
}

/// Lines in the area ui: what the user did. The label of a control, never typed text.
enum UILog {
    static var sink: any LogSink = AppLog()
    /// The page of the main window.
    private(set) static var page = ""
    private static var menus: NSObjectProtocol?

    static func write(_ job: String, _ message: String) {
        sink.write(LogEntry(level: .ok, area: .ui, job: job, subject: page.isEmpty ? nil : page, message: message))
    }

    static func shown(_ title: String) {
        guard title != page else { return }
        write("Page", page.isEmpty ? title : "\(page) → \(title)")
        page = title
    }

    /// Each menu action: the app menu, the status menu and the context menus.
    static func watchMenus() {
        guard menus == nil else { return }
        menus = NotificationCenter.default.addObserver(forName: NSMenu.didSendActionNotification, object: nil, queue: .main) { n in
            guard let item = n.userInfo?["MenuItem"] as? NSMenuItem else { return }
            let menu = (n.object as? NSMenu)?.title ?? ""
            write("Menu", menu.isEmpty ? item.title : "\(menu) › \(item.title)")
        }
    }
}

final class LogStore: LogSink, @unchecked Sendable {
    static let changed = Notification.Name("LogStore.changed")
    static let cap = 5000

    let dir: String
    let problems: ProblemTracker
    var cfg: () -> LogConfig = { LOGS_CFG }
    /// Values to remove from each line, for example the API key of the config.
    var secrets: [String] = []
    let now: () -> Date
    private let lock = NSLock()
    private var lines: [LogEntry] = []

    init(dir: String, problems: ProblemTracker, now: @escaping () -> Date = Date.init) {
        self.dir = dir
        self.problems = problems
        self.now = now
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        prune()
        load()
    }

    /// Newest first.
    var entries: [LogEntry] { lock.withLock { lines.reversed() } }

    func write(_ entry: LogEntry) {
        var e = Self.redact(entry, secrets: secrets)
        let c = cfg()
        if !c.keepAIText {
            e.input = nil
            e.output = nil
        }
        let keep = e.verbose != true || e.level != .ok || c.debug
        if keep {
            lock.withLock {
                lines.append(e)
                if lines.count > Self.cap { lines.removeFirst(lines.count - Self.cap) }
                append(e)
            }
        }
        // A poll that the log does not keep changes nothing on screen.
        guard keep || !e.area.isRecord else { return }
        let post = { [problems] in
            if !e.area.isRecord { problems.record(e) }
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    func clear() {
        lock.withLock {
            lines = []
            for f in files() { try? FileManager.default.removeItem(atPath: dir + "/" + f) }
        }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    var bytes: Int {
        files().reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: dir + "/" + $1)[.size] as? Int) ?? 0) }
    }

    func path(of e: LogEntry) -> String { dir + "/" + Self.day(e.at) + ".jsonl" }

    // Drops the files older than the keep days. Today counts as one day.
    func prune() {
        let keep = max(1, cfg().keepDays)
        guard let oldest = Calendar.current.date(byAdding: .day, value: 1 - keep, to: now()) else { return }
        let first = Self.day(oldest)
        for f in files() where String(f.prefix(10)) < first { try? FileManager.default.removeItem(atPath: dir + "/" + f) }
    }

    private func files() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".jsonl") }.sorted()
    }

    private func load() {
        var all: [LogEntry] = []
        for f in files() {
            guard let text = try? String(contentsOfFile: dir + "/" + f, encoding: .utf8) else { continue }
            all += text.split(separator: "\n").compactMap { try? Self.decoder.decode(LogEntry.self, from: Data($0.utf8)) }
        }
        lines = Array(all.suffix(Self.cap))
    }

    private func append(_ e: LogEntry) {
        guard var data = try? Self.encoder.encode(e) else { return }
        data.append(0x0A)
        let p = path(of: e)
        if let h = FileHandle(forWritingAtPath: p) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            FileManager.default.createFile(atPath: p, contents: data, attributes: [.posixPermissions: 0o600])
        }
    }

    static func day(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Redaction

    static func redact(_ e: LogEntry, secrets: [String]) -> LogEntry {
        var e = e
        let r = { (s: String?) in s.map { redact($0, secrets: secrets) } }
        e.message = redact(e.message, secrets: secrets)
        e.input = r(e.input)
        e.output = r(e.output)
        e.outputTail = r(e.outputTail)
        e.reason = r(e.reason)
        return e
    }

    private static let rules: [(NSRegularExpression, String)] = [
        (#"(?i)\b(x-api-key|authorization|api[-_]?key|access[-_]?token|token|secret|password)(["']?\s*[:=]\s*["']?)(bearer\s+|basic\s+|token\s+)?[^\s"',}]+"#, "$1$2[removed]"),
        (#"\b(sk-[A-Za-z0-9_-]{8,}|gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{16,}|plane_api_[A-Za-z0-9]{12,}|xox[abpcs]-[A-Za-z0-9-]{10,})"#, "[removed]"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func redact(_ s: String, secrets: [String]) -> String {
        var t = s
        for sec in secrets where sec.count >= 8 { t = t.replacingOccurrences(of: sec, with: "[removed]") }
        for (re, template) in rules {
            t = re.stringByReplacingMatches(in: t, range: NSRange(t.startIndex..., in: t), withTemplate: template)
        }
        return t
    }
}

// ─── Problems ────────────────────────────────────────────────────────────────
// A problem groups the errors of one key: the area, the job and the host or account.
// The next ok line of the key clears it. 3 warnings in a row open it. Dismiss hides it until its next error.

struct Problem: Codable, Equatable {
    var key: String
    var area: LogArea
    var job: String
    var host: String?
    var subject: String?
    var message: String
    var count: Int
    var first: Date
    var last: Date
    var dismissed = false
}

final class ProblemTracker {
    static let changed = Notification.Name("ProblemTracker.changed")
    static let closeAfter: TimeInterval = 24 * 3600
    static let warnings = 3

    private(set) var all: [Problem] = []
    private var streaks: [String: Int] = [:]
    let path: String?
    let now: () -> Date
    /// Gets each problem that opens, or that opens again after Dismiss.
    var opened: ((Problem) -> Void)?

    init(path: String?, now: @escaping () -> Date = Date.init) {
        self.path = path
        self.now = now
        if let path, let data = FileManager.default.contents(atPath: path) {
            all = (try? JSONDecoder().decode([Problem].self, from: data)) ?? []
        }
        expire()
    }

    /// The problems that show, newest first.
    var open: [Problem] { all.filter { !$0.dismissed }.sorted { $0.last > $1.last } }

    func record(_ e: LogEntry) {
        let k = e.problemKey
        let i = all.firstIndex { $0.key == k }
        switch e.level {
        case .ok:
            streaks[k] = nil
            guard let i else { return }
            all.remove(at: i)
        case .warn:
            streaks[k, default: 0] += 1
            if let i {
                all[i].count += 1
                all[i].last = e.at
                all[i].message = e.message
            } else if streaks[k, default: 0] >= Self.warnings {
                start(e)
            } else {
                return
            }
        case .error:
            if let i {
                let wasHidden = all[i].dismissed
                all[i].count += 1
                all[i].last = e.at
                all[i].message = e.message
                all[i].subject = e.subject ?? all[i].subject
                all[i].dismissed = false
                if wasHidden { opened?(all[i]) }
            } else {
                start(e)
            }
        }
        changed()
    }

    func dismiss(_ key: String) {
        guard let i = all.firstIndex(where: { $0.key == key }) else { return }
        all[i].dismissed = true
        changed()
    }

    // A problem with no new error for 24 h closes: its job stopped.
    func expire() {
        let t = now()
        let n = all.count
        all.removeAll { t.timeIntervalSince($0.last) > Self.closeAfter }
        if all.count != n { changed() }
    }

    func problem(_ key: String) -> Problem? { all.first { $0.key == key && !$0.dismissed } }

    private func start(_ e: LogEntry) {
        let p = Problem(key: e.problemKey, area: e.area, job: e.job, host: e.host, subject: e.subject, message: e.message,
                        count: e.level == .warn ? streaks[e.problemKey, default: 1] : 1, first: e.at, last: e.at)
        all.append(p)
        opened?(p)
    }

    private func changed() {
        if let path, let data = try? JSONEncoder().encode(all) { try? data.write(to: URL(fileURLWithPath: path), options: .atomic) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

// ─── Work orders ─────────────────────────────────────────────────────────────
// The hub writes the work orders. Each new state of an order makes one log line.

extension WorkOrder {
    /// The item key of a start order, else the repo folder.
    var itemKey: String? {
        guard case .start(let req) = order else { return nil }
        return req.item?.key ?? URL(fileURLWithPath: req.repo).lastPathComponent
    }
}

final class WorkOrderLog {
    private var states: [String: WorkOrder.State]?
    private var observer: NSObjectProtocol?

    init(writes: StoreWrites) {
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard n.userInfo?["collection"] as? String == WorkOrder.collection else { return }
            self?.observe(writes.load(WorkOrder.self))
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    // The first load only keeps the states: it tells nothing new.
    func observe(_ orders: [WorkOrder]) {
        defer { states = Dictionary(orders.map { ($0.id, $0.state) }, uniquingKeysWith: { a, _ in a }) }
        guard let states else { return }
        for o in orders where states[o.id] != o.state {
            if let e = Self.entry(o) { APP_LOG.write(e) }
        }
    }

    static func entry(_ o: WorkOrder) -> LogEntry? {
        let level: LogLevel
        let msg: String
        switch o.state {
        case .done: (level, msg) = (.ok, "Done")
        case .failed: (level, msg) = (.error, o.result?.error ?? "The runner could not do the order.")
        case .expired: (level, msg) = (.warn, "No runner took the order before it expired.")
        case .held: (level, msg) = (.ok, "Held by the hub")
        case .sent, .acked: (level, msg) = (.ok, o.state == .sent ? "Sent to the runner" : "The runner has it")
        default: return nil
        }
        var e = LogEntry(level: level, area: .runner, job: "Work order", subject: o.itemKey, host: o.runner, message: msg)
        e.verbose = o.state == .done || o.state == .failed || o.state == .expired ? nil : true
        return e
    }
}
