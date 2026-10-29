import Foundation
import OverSireCore

/// The last runbook run of each item, on the sessions machine. A runbookRun frame of any daemon changes it at once;
/// a read on start, on a log gap and each 60 s catches what a frame missed.
/// Use it on the main thread.
final class RunbookBook {
    static let changed = Notification.Name("RunbookBook.changed")

    private let runtime: () -> (any RunbookRunning)?
    private var runs: [String: RunbookRun] = [:]   // item key → run
    private var timer: Timer?

    init(runtime: @escaping () -> (any RunbookRunning)? = { ENV.runtime as? any RunbookRunning }) {
        self.runtime = runtime
    }

    /// The last run of the item, open or not.
    func run(for key: String) -> RunbookRun? { runs[key] }

    /// The runs that can go on, oldest first.
    var open: [RunbookRun] { runs.values.filter(\.state.isOpen).sorted { $0.started < $1.started } }

    /// The runs that wait for the user: a gate or a pause.
    var waiting: [RunbookRun] { open.filter { $0.state != .running } }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { await self?.refresh() } }
        Task { await refresh() }
    }

    func refresh() async {
        guard let rt = runtime(), rt.capabilities.contains(.runbooks) else { return }
        do {
            let list = try await rt.runbookRuns(item: nil, open: false)
            await MainActor.run {
                list.forEach { _ = keep($0) }
                NotificationCenter.default.post(name: Self.changed, object: self)
            }
        } catch {
            log.info("Runbooks: the read failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A run from a frame or from an action reply.
    func apply(_ r: RunbookRun) {
        guard keep(r) else { return }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// A newer run of the item wins. An older copy of the same run does not.
    private func keep(_ r: RunbookRun) -> Bool {
        let key = r.item.key
        if let old = runs[key], old.id == r.id ? old.updated > r.updated : old.started > r.started { return false }
        if runs[key] == r { return false }
        runs[key] = r
        return true
    }

    /// For tests and `--uishots`.
    func set(_ list: [RunbookRun]) {
        runs = [:]
        list.forEach { _ = keep($0) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

let RUNBOOKS = RunbookBook()
