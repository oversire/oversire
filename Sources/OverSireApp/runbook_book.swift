import Foundation
import OverSireCore

/// The last runbook run of each item, on the sessions machine. A runbookRun frame of any daemon changes it at once;
/// a read on start, on a log gap and each 60 s catches what a frame missed.
/// Use it on the main thread.
final class RunbookBook {
    static let changed = Notification.Name("RunbookBook.changed")

    private let runtime: () -> (any RunbookRunning)?
    private let bus: ChangeBus
    private var runs: [String: RunbookRun] = [:]   // item key → run
    private var timer: Timer?
    private var notified: Set<String> = []
    /// Posts one notification for a gate or a pause that waits this long. nil: never.
    var tellAfter: () -> TimeInterval? = { AGENTS.questionNotice.delay }
    var notify: (_ key: String, _ title: String, _ body: String) -> Void = { _, _, _ in }

    init(runtime: @escaping () -> (any RunbookRunning)? = { ENV.runtime as? any RunbookRunning }, bus: ChangeBus = .shared) {
        self.runtime = runtime
        self.bus = bus
    }

    /// The last run of the item, open or not.
    func run(for key: String) -> RunbookRun? { runs[key] }

    /// The runs that can go on, oldest first.
    var open: [RunbookRun] { runs.values.filter(\.state.isOpen).sorted { $0.started < $1.started } }

    /// The runs that wait for the user: a gate or a pause.
    var waiting: [RunbookRun] { open.filter { $0.state != .running } }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.tell()
            Task { await self?.refresh() }
        }
        Task { await refresh() }
    }

    func refresh() async {
        guard let rt = runtime(), rt.capabilities.contains(.runbooks) else { return }
        do {
            let list = try await rt.runbookRuns(item: nil, open: false)
            await MainActor.run {
                let changed = list.filter { keep($0) }.map(\.item.key)
                if !changed.isEmpty { post(Set(changed)) }
            }
        } catch {
            log.info("Runbooks: the read failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A run from a frame or from an action reply.
    func apply(_ r: RunbookRun) {
        guard keep(r) else { return }
        post([r.item.key])
    }

    /// A newer run of the item wins. An older copy of the same run does not.
    private func keep(_ r: RunbookRun) -> Bool {
        let key = r.item.key
        if let old = runs[key], old.id == r.id ? old.updated > r.updated : old.started > r.started { return false }
        if runs[key] == r { return false }
        runs[key] = r
        return true
    }

    /// The run and the step of a step session: by its session, else by its key `runbook:<run>.<step>.<round>`.
    func step(session: SessionRef?, key: String? = nil) -> (run: RunbookRun, step: StepRun)? {
        if let session {
            for r in runs.values { if let s = r.steps.last(where: { $0.session == session }) { return (r, s) } }
        }
        guard let k = key.flatMap(Self.parse) else { return nil }
        guard let r = runs.values.first(where: { $0.id.rawValue == k.run }), let s = r.steps.first(where: { $0.step == k.step && $0.round == k.round }) else { return nil }
        return (r, s)
    }

    /// "Implement", or "Review Plan · round 2".
    static func label(_ r: RunbookRun, _ s: StepRun) -> String {
        let name = r.runbook.step(s.step)?.name ?? s.step
        return s.round > 1 ? "\(name) · round \(s.round)" : name
    }

    /// The parts of a step session key. The step id and the round have no dot.
    static func parse(_ key: String) -> (run: String, step: String, round: Int)? {
        guard key.hasPrefix("runbook:") else { return nil }
        let parts = key.dropFirst("runbook:".count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 3, let round = Int(parts[parts.count - 1]), !parts[parts.count - 2].isEmpty else { return nil }
        return (parts.dropLast(2).joined(separator: "."), String(parts[parts.count - 2]), round)
    }

    /// One notification for each Needs you row of a run that waits longer than the question setting.
    func tell(now: Date = Date()) {
        guard let after = tellAfter() else { return }
        for n in NeedsYou.runbooks(open) where !notified.contains(n.id) && now.timeIntervalSince(n.at) >= after {
            notified.insert(n.id)
            notify(n.key, "\(n.key) needs you", n.reason)
        }
    }

    /// For tests and `--uishots`.
    func set(_ list: [RunbookRun]) {
        runs = [:]
        list.forEach { _ = keep($0) }
        post([])
    }

    /// An empty key set: all items.
    private func post(_ keys: Set<String>) {
        bus.post(DataChange(.runbooks, items: keys, origin: .event))
        NotificationCenter.default.post(name: Self.changed, object: self)
        tell()
    }
}

let RUNBOOKS = RunbookBook()
