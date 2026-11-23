import Foundation
import OverSireCore
import OverSireSync

// ─── Worktree bindings ───────────────────────────────────────────────────────
// Each item gets a fixed worktree folder when it is made (OVERSIRE-584). The home store keeps it,
// and the daemon finds the review group of the item through it.

final class WorktreeBindingBook {
    static let changed = Notification.Name("WorktreeBindingBookChanged")

    private let writes: StoreWrites
    private(set) var records: [String: WorktreeBinding] = [:]   // by key
    private var observer: NSObjectProtocol?

    init(writes: StoreWrites) {
        self.writes = writes
        load()
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard let self, n.userInfo?["collection"] as? String == WorktreeBinding.collection else { return }
            self.load()
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func binding(_ key: String) -> WorktreeBinding? { records[key.uppercased()] }

    /// The bindings of the sub-items of `parent`, sorted by key.
    func children(of parent: String) -> [WorktreeBinding] {
        let p = parent.uppercased()
        return records.values.filter { $0.parent?.uppercased() == p }.sorted { $0.key < $1.key }
    }

    /// The own-mode binding on `machine` whose folder is `dir` or holds it.
    func owner(of dir: String, machine: String) -> WorktreeBinding? {
        let d = (dir as NSString).standardizingPath
        return records.values.filter { $0.mode == .own && $0.machine == machine }
            .filter { let b = ($0.dir as NSString).standardizingPath; return d == b || d.hasPrefix(b + "/") }
            .max { $0.dir.count < $1.dir.count }
    }

    func save(_ b: WorktreeBinding) {
        records[b.key] = b
        writes.put(b)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// For `--uishots`: a binding without a write.
    func seed(_ b: WorktreeBinding) { records[b.key] = b }

    private func load() {
        records = Dictionary(writes.load(WorktreeBinding.self).map { ($0.key, $0) }, uniquingKeysWith: { _, b in b })
    }
}

/// What a caller asks for. Nil fields take the defaults.
struct BindRequest {
    var worktree: String?        // a path or a template with {key}
    var machine: String?
    var branch: String?
    var shareParentGroup = false
    var root: String?            // nil: the workspace root of the project
}

enum BindError: Error, Equatable {
    case noRoot(String)
    case noMachine
    case badPath(String)
    case taken(dir: String, by: String)

    var message: String {
        switch self {
        case .noRoot(let p): return "the project \(p) has no workspace root. Set it in Settings › Projects."
        case .noMachine: return "no machine runs the sessions. Set it in Settings › Machines."
        case .badPath(let p): return "the path \(p) is empty or has a .. part."
        case .taken(let dir, let by): return "\(by) has the folder \(dir) already."
        }
    }
}

final class WorktreeBinder {
    /// Only for the auto binds. The binds that a person or an agent asks for always run.
    var mayAct: () -> Bool = { true }
    /// The write-back of the OverSire block.
    var onBound: ((WorktreeBinding) -> Void)?

    private let book: WorktreeBindingBook
    private let store: ProjectStore
    private let events: EventDesk
    private let machine: () -> String?
    private let root: (ProjectSummary) -> String?
    private let now: () -> Date

    init(book: WorktreeBindingBook, store: ProjectStore, events: EventDesk, machine: @escaping () -> String?,
         root: @escaping (ProjectSummary) -> String?, now: @escaping () -> Date = Date.init) {
        self.book = book
        self.store = store
        self.events = events
        self.machine = machine
        self.root = root
        self.now = now
    }

    func bind(key: String, title: String, parent: String?, project: ProjectSummary, _ r: BindRequest,
              source: WorktreeBinding.Source, actor: EventActor) -> Result<WorktreeBinding, BindError> {
        let key = key.uppercased()
        guard let machine = r.machine.flatMap({ $0.isEmpty ? nil : $0 }) ?? machine() else { return .failure(.noMachine) }
        let pb = parent.flatMap(book.binding)
        let mode: WorktreeBinding.Mode = r.shareParentGroup && parent != nil ? .parent : .own
        let group: String
        var branch: String
        if mode == .parent, let parent {
            group = pb?.group ?? WorktreeBinding.defaultGroup(parent)
            branch = pb?.branch ?? ""
        } else {
            let template = r.worktree.flatMap { $0.isEmpty ? nil : $0 } ?? ".wt/{key}"
            guard let g = WorktreeBinding.group(from: template, key: key) else { return .failure(.badPath(template)) }
            group = g
            branch = r.branch ?? PROJECTS_CFG.local(project.identifier).branch(key: key, title: title)
        }
        let rootPath = (mode == .parent ? pb?.root : nil) ?? r.root ?? root(project)
        guard group.hasPrefix("/") || rootPath != nil else { return .failure(.noRoot(project.identifier)) }
        if r.branch == nil, mode == .own, branch.isEmpty { branch = key.lowercased() }
        let b = WorktreeBinding(key: key, machine: machine, root: rootPath ?? "/", group: group, branch: branch,
                                parent: parent?.uppercased(), mode: mode, source: source, updatedAt: now(), updatedBy: actor.name)
        if mode == .own, let other = book.owner(of: b.dir, machine: machine), other.key != key, other.dir == b.dir {
            return .failure(.taken(dir: b.dir, by: other.key))
        }
        save(b, project: project, actor: actor)
        return .success(b)
    }

    /// Binds the default folder when the key has no binding. Nil when it cannot.
    @discardableResult
    func ensure(_ item: Item, source: WorktreeBinding.Source, actor: EventActor) -> WorktreeBinding? {
        if let b = book.binding(item.key) { return b }
        guard let (_, snap, _) = store.item(key: item.key) else { return nil }
        let parent = item.parentId.flatMap { pid in snap.items.first { $0.id == pid }?.key }
        return ensure(key: item.key, title: item.title, parent: parent, project: snap.summary, source: source, actor: actor)
    }

    @discardableResult
    func ensure(key: String, title: String, parent: String?, project: ProjectSummary, source: WorktreeBinding.Source,
                actor: EventActor) -> WorktreeBinding? {
        if let b = book.binding(key) { return b }
        guard source != .auto || mayAct() else { return nil }
        switch bind(key: key, title: title, parent: parent, project: project, BindRequest(), source: source, actor: actor) {
        case .success(let b): return b
        case .failure(let e):
            log.info("No worktree binding for \(key, privacy: .public): \(e.message, privacy: .public)")
            return nil
        }
    }

    /// Binds a folder that exists to a known item. Nil when the store does not know the key.
    func link(key: String, dir: String, machine: String, branch: String?, source: WorktreeBinding.Source,
              actor: EventActor) -> Result<WorktreeBinding, BindError>? {
        guard let (_, snap, item) = store.item(key: key) else { return nil }
        let parent = item.parentId.flatMap { pid in snap.items.first { $0.id == pid }?.key }
        let r = BindRequest(worktree: dir, machine: machine, branch: branch ?? "")
        return bind(key: item.key, title: item.title, parent: parent, project: snap.summary, r, source: source, actor: actor)
    }

    /// Binds the review group of a sub-item that has no binding, so that its review folds into the parent.
    /// It is for the items made before the bindings (OVERSIRE-584).
    func adopt(_ reviews: [ReviewSummary]) {
        for r in reviews where r.kind == .code && r.parts == nil && book.binding(r.key) == nil {
            guard let group = r.group, let (_, snap, item) = store.item(key: r.key), let pid = item.parentId,
                  let parent = snap.items.first(where: { $0.id == pid })?.key else { continue }
            guard mayAct() else { return }
            let req = BindRequest(worktree: group, machine: r.machine, branch: r.repos.first?.branch ?? "", root: r.root)
            if case .failure(let e) = bind(key: item.key, title: item.title, parent: parent, project: snap.summary, req,
                                           source: .auto, actor: EventActor(type: .system, name: "binder")) {
                log.info("No worktree binding for \(r.key, privacy: .public): \(e.message, privacy: .public)")
            }
        }
    }

    /// Writes the parent again when the tracker moved the item.
    func reconcileParents() {
        for b in book.records.values {
            guard let (_, snap, item) = store.item(key: b.key) else { continue }
            let parent = item.parentId.flatMap { pid in snap.items.first { $0.id == pid }?.key.uppercased() }
            guard parent != b.parent else { continue }
            var n = b
            n.parent = parent
            if parent == nil, n.mode == .parent { continue }   // keep the shared group until a person moves it
            n.updatedAt = now()
            book.save(n)
        }
    }

    private func save(_ b: WorktreeBinding, project: ProjectSummary, actor: EventActor) {
        book.save(b)
        var payload: [String: JSONValue] = ["group": .string(b.group), "root": .string(b.root), "machine": .string(b.machine),
                                            "branch": .string(b.branch), "mode": .string(b.mode.rawValue), "source": .string(b.source.rawValue)]
        if let p = b.parent { payload["parent"] = .string(p) }
        let summary = "\(b.group) on \(b.machine)"
        if b.source == .auto {
            events.system(.itemWorktreeBound, item: b.key, project: project.identifier, actor: "binder", verb: "worktree", summary,
                          payload: payload, parentItem: b.parent)
        } else {
            events.action(.itemWorktreeBound, item: b.key, project: project.identifier, verb: "worktree", summary, payload: payload,
                          actorType: actor.type, actor: actor.name, via: actor.via, parentItem: b.parent)
        }
        onBound?(b)
    }
}

extension WorktreeBinding {
    /// The `worktree` data of the `item.create` and `item.bindWorktree` answers.
    var json: JSONValue {
        var o: [String: JSONValue] = ["group": .string(group), "root": .string(root), "machine": .string(machine), "branch": .string(branch),
                                      "mode": .string(mode.rawValue), "dir": .string(dir)]
        if let parent { o["parent"] = .string(parent) }
        return .object(o)
    }
}
