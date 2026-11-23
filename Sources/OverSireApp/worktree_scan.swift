import Foundation
import OverSireCore

// ─── Worktree scan ───────────────────────────────────────────────────────────
// The git worktrees of each active machine (OVERSIRE-588). A worktree with changes and no binding shows in
// Work › "Not linked to an item". A sure guess binds it at once.

final class WorktreeScanBook {
    static let changed = Notification.Name("WorktreeScanBook.changed")

    /// One worktree with no binding. `dir` is the folder that a link binds.
    struct Unlinked: Equatable {
        var machine: String
        var info: WorktreeInfo
        var dir: String
    }

    private let sources: () -> [any WorktreeSource]
    private let bindings: WorktreeBindingBook
    private let binder: WorktreeBinder
    private let known: (String) -> Bool
    private var pages: [String: WorktreesPage] = [:]   // machine → page
    /// The machines whose daemon has no worktree route.
    private(set) var old: Set<String> = []
    private var timer: Timer?
    private var observer: NSObjectProtocol?
    /// False for `--uishots`: the seeded rows stay.
    var reads = true

    init(sources: @escaping () -> [any WorktreeSource], bindings: WorktreeBindingBook, binder: WorktreeBinder,
         known: @escaping (String) -> Bool) {
        self.sources = sources
        self.bindings = bindings
        self.binder = binder
        self.known = known
        observer = NotificationCenter.default.addObserver(forName: WorktreeBindingBook.changed, object: bindings, queue: .main) { [weak self] _ in
            guard let self else { return }
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    static func groupSources() -> [any WorktreeSource] {
        guard let hub = ENV.machines else { return [] }
        return hub.active.compactMap { hub.runtime($0.machine) }
    }

    /// The worktrees with changes and no binding, by machine and path.
    var unlinked: [Unlinked] {
        pages.keys.sorted().flatMap { m in
            let all = pages[m]!.worktrees
            return all.filter { $0.changed && bindings.owner(of: $0.path, machine: m) == nil }
                .map { Unlinked(machine: m, info: $0, dir: Self.groupDir($0, in: all)) }
        }
    }

    /// The sums of the worktrees in the folder of the binding. Nil when the machine has no read.
    func state(of b: WorktreeBinding) -> (uncommitted: Int, ahead: Int, exists: Bool)? {
        guard let page = pages[b.machine] else { return nil }
        let dir = (b.dir as NSString).standardizingPath
        let rows = page.worktrees.filter { $0.path == dir || $0.path.hasPrefix(dir + "/") }
        return (rows.reduce(0) { $0 + $1.uncommitted }, rows.reduce(0) { $0 + $1.ahead }, !rows.isEmpty)
    }

    /// The folder to bind: the parent when a sibling worktree of another repo shares it (a group), else the worktree.
    static func groupDir(_ w: WorktreeInfo, in all: [WorktreeInfo]) -> String {
        let parent = (w.path as NSString).deletingLastPathComponent
        let group = all.contains { $0.repo != w.repo && ($0.path as NSString).deletingLastPathComponent == parent }
        return group ? parent : w.path
    }

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in Task { await self?.refresh() } }
        Task { await refresh() }
    }

    /// Reads all machines. A failed read keeps the old rows of the machine.
    func refresh() async {
        guard reads else { return }
        let list = await MainActor.run { sources() }
        var read: [String: Result<WorktreesPage, ProviderError>] = [:]
        for s in list { read[s.machine] = await Result(awaiting: { try await s.worktrees(changed: false, dir: nil) }) }
        let got = read
        await MainActor.run {
            var next = pages.filter { m, _ in list.contains { $0.machine == m } }
            var old = old
            for (m, r) in got {
                switch r {
                case .success(let p):
                    next[m] = p
                    old.remove(m)
                case .failure(.notFound):
                    old.insert(m)
                case .failure:
                    break
                }
            }
            self.old = old
            set(next)
        }
    }

    /// For `--uishots`.
    func seedOld(_ machines: Set<String>) { old = machines }

    /// For tests and `--uishots`.
    func set(_ next: [String: WorktreesPage]) {
        pages = next
        autoBind()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// Binds a worktree when the guess comes from the path or a session, the key is known and has no binding.
    /// A branch guess is never bound alone.
    private func autoBind() {
        for u in unlinked {
            guard let g = u.info.guess, g.from != .branch, known(g.key), bindings.binding(g.key) == nil, binder.mayAct() else { continue }
            _ = binder.link(key: g.key, dir: u.dir, machine: u.machine, branch: u.info.branch, source: .auto,
                            actor: EventActor(type: .system, name: "binder"))
        }
    }
}
