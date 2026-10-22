import Cocoa
import OverSireCore

// A thing that a row menu does. Builders return commands as data, so tests can compare them.
enum RowCommand: Equatable {
    case open(Route)
    case openURL(String)
    case copy(String)
    case finder(path: String)
    case terminal(path: String)
    case status(itemId: String, optionId: String)
    case priority(itemId: String, priorityId: String)
    case assignMe(itemId: String)
    case startSession(key: String)
    case run(repo: String, runId: String, RunAction)
    case ignoreFailure(repo: String, runId: String, Bool)
    case copyJobLog(repo: String, jobId: String)
    case explain(repo: String, runId: String, jobId: String?)
    case rerunJob(repo: String, runId: String, jobId: String)
    case approve(repo: String, number: Int)
    case merge(repo: String, number: Int)
    case revealCard(String)
    case sendInput(key: String)
    case triage(entryId: String)
    case onlyProject(String)
    case refreshProject(String)
    case useTrackerIcon(String)
    case hideProject(String)
    case removeWorktree(card: String)
}

// One line of a row menu.
enum MenuEntry: Equatable {
    case action(String, RowCommand, checked: Bool = false)
    case submenu(String, [MenuEntry])
    case separator

    var title: String? {
        switch self {
        case .action(let t, _, _), .submenu(let t, _): return t
        case .separator: return nil
        }
    }
}

extension Array where Element == MenuEntry {
    var titles: [String] { compactMap(\.title) }

    func command(_ title: String) -> RowCommand? {
        for e in self {
            if case .action(let t, let c, _) = e, t == title { return c }
        }
        return nil
    }

    // Drops separators at the ends and doubled separators.
    var tidy: [MenuEntry] {
        var out: [MenuEntry] = []
        for e in self where !(e == .separator && (out.isEmpty || out.last == .separator)) { out.append(e) }
        if out.last == .separator { out.removeLast() }
        return out
    }
}

// The menus of each row type. Capabilities hide the provider actions.
enum RowMenu {
    static func item(_ item: Item, snap: ProjectSnapshot, stream: Workstream?, local: ProjectLocalSettings,
                     caps: Set<Capability>, tracker: String = "Plane") -> [MenuEntry] {
        var out: [MenuEntry] = [.action("Open", .open(.item(item.key, .overview))), .action("Open in \(tracker)", .openURL(item.url)), .separator,
                                .action("Copy ID", .copy(item.key)), .action("Copy link", .copy(item.url)),
                                .action("Copy ID and title", .copy("\(item.key) \(item.title)")), .action("Copy branch name", .copy(local.branch(for: item))),
                                .separator]
        if !snap.statusOptions.isEmpty {
            out.append(.submenu("Status", snap.statusOptions.map {
                .action($0.name, .status(itemId: item.id, optionId: $0.id), checked: $0.id == item.statusOptionId)
            }))
        }
        if !item.isMine(snap.me) { out.append(.action("Assign to me", .assignMe(itemId: item.id))) }
        out.append(.submenu("Priority", StatusOption.priorities.map {
            .action($0.name, .priority(itemId: item.id, priorityId: $0.id), checked: $0.name == (item.fields["Priority"] ?? "None"))
        }))
        out.append(.separator)
        if stream?.agent != nil {
            out.append(.action("Open session", .open(.item(item.key, .session))))
        } else if caps.contains(.sessionInput) {
            out.append(.action("Start session in Orca…", .startSession(key: item.key)))
        }
        if let pr = stream?.prs.first { out.append(.action("Open pull request", .openURL(pr.pr.url))) }
        if let r = stream?.runs.first { out.append(.action("Open latest run", .open(.run(repo: r.repo, id: r.run.id)))) }
        return out.tidy
    }

    static func run(repo: String, run r: Run, linkedKey: String?, ignored: Bool, caps: Set<Capability>) -> [MenuEntry] {
        let route = Route.run(repo: repo, id: r.id)
        var out: [MenuEntry] = [.action("Open", .open(route)), .action("Open on GitHub", .openURL(r.url)), .separator,
                                .action("Copy link", .copy(r.url)), .action("Copy run ID", .copy(r.id)), .action("Copy commit SHA", .copy(r.headSha)),
                                .separator]
        let done = r.status == RunStatus.completed.rawValue
        if done && r.isFailure && caps.contains(.rerun) { out.append(.action("Re-run failed jobs", .run(repo: repo, runId: r.id, .rerunFailed))) }
        if done && caps.contains(.rerun) { out.append(.action("Re-run all jobs", .run(repo: repo, runId: r.id, .rerun))) }
        if !done && caps.contains(.cancel) { out.append(.action("Cancel run", .run(repo: repo, runId: r.id, .cancel))) }
        if r.isFailure && caps.contains(.logs) { out.append(.action("Explain failure…", .explain(repo: repo, runId: r.id, jobId: nil))) }
        if r.isFailure {
            out += [.separator, .action(ignored ? "Count this failure again" : "Ignore this failure", .ignoreFailure(repo: repo, runId: r.id, !ignored))]
        }
        if let linkedKey { out += [.separator, .action("Open linked item", .open(.item(linkedKey, .overview)))] }
        return out.tidy
    }

    static func job(repo: String, run r: Run, job j: Job, caps: Set<Capability>) -> [MenuEntry] {
        var out: [MenuEntry] = []
        if let u = j.url { out.append(.action("Open job on GitHub", .openURL(u))) }
        if caps.contains(.logs) { out.append(.action("Copy job log", .copyJobLog(repo: repo, jobId: j.id))) }
        if let u = j.url { out.append(.action("Copy job link", .copy(u))) }
        if caps.contains(.logs) && j.status == RunStatus.completed.rawValue && JobChip.failed(j) {
            out += [.separator, .action("Explain failure…", .explain(repo: repo, runId: r.id, jobId: j.id))]
        }
        // GitHub re-runs a job only after the full run ends.
        if caps.contains(.rerunJob) && r.status == RunStatus.completed.rawValue {
            out += [.separator, .action("Re-run this job", .rerunJob(repo: repo, runId: r.id, jobId: j.id))]
        }
        return out.tidy
    }

    static func pr(repo: String, pr p: ChangeRequest, linkedKey: String?, caps: Set<Capability>) -> [MenuEntry] {
        var out: [MenuEntry] = [.action("Open on GitHub", .openURL(p.url)), .separator, .action("Copy link", .copy(p.url)),
                                .action("Copy branch name", .copy(p.headRefName)),
                                .action("Copy checkout command", .copy("gh pr checkout \(p.number) --repo \(repo)")), .separator]
        if caps.contains(.changeActions) {
            if !p.mine { out.append(.action("Approve", .approve(repo: repo, number: p.number))) }
            out.append(.action("Merge…", .merge(repo: repo, number: p.number)))
        }
        if let linkedKey { out += [.separator, .action("Open linked item", .open(.item(linkedKey, .overview)))] }
        return out.tidy
    }

    static func session(card: Workspace, key: String?, checkout: Checkout?, hasAgent: Bool, caps: Set<Capability>,
                        removable: Bool = false) -> [MenuEntry] {
        var out: [MenuEntry] = []
        if let key { out.append(.action("Open item", .open(.item(key, .overview)))) }
        if caps.contains(.reveal) { out.append(.action("Reveal in Orca", .revealCard(card.id))) }
        out.append(.separator)
        let path = checkout?.path ?? card.path
        if !path.isEmpty { out.append(.action("Copy worktree path", .copy(path))) }
        if let b = checkout?.branch, !b.isEmpty { out.append(.action("Copy branch name", .copy(b))) }
        if !path.isEmpty { out += [.action("Show in Finder", .finder(path: path)), .action("Open in Terminal", .terminal(path: path))] }
        if let key, hasAgent, caps.contains(.sessionInput) { out += [.separator, .action("Send input…", .sendInput(key: key))] }
        if removable { out += [.separator, .action("Remove worktree…", .removeWorktree(card: card.id))] }
        return out.tidy
    }

    static func activity(_ e: FeedEntry, projectKey: String?, canTriage: Bool, tracker: String = "Plane") -> [MenuEntry] {
        var out: [MenuEntry] = []
        if e.route != nil || e.intake != nil { out.append(.action("Open", e.route.map { .open($0) } ?? .openURL(e.url ?? ""))) }
        if let u = e.itemURL ?? e.url { out.append(.action(e.source == .run ? "Open on GitHub" : "Open in \(tracker)", .openURL(u))) }
        out.append(.separator)
        if let k = e.itemKey { out.append(.action("Copy ID", .copy(k))) }
        if let u = e.itemURL ?? e.url { out.append(.action("Copy link", .copy(u))) }
        if e.intake != nil && canTriage { out += [.separator, .action("Triage with AI", .triage(entryId: e.id))] }
        if let projectKey { out += [.separator, .action("Only this project", .onlyProject(projectKey))] }
        return out.tidy
    }

    static func sidebarProject(_ p: ProjectSummary, hasTrackerIcon: Bool, tracker: String = "Plane") -> [MenuEntry] {
        let k = p.identifier.uppercased()
        var out: [MenuEntry] = [.action("Open \(p.title)", .open(.project(k))), .action("Project settings…", .open(.projectSettings(k, .appearance))),
                                .action("Links and Orca workspace…", .open(.projectSettings(k, .links))), .separator,
                                .action("Open in \(tracker)", .openURL(p.url)), .action("Copy link", .copy(p.url)),
                                .action("Refresh project", .refreshProject(p.ref.storeKey)), .separator,
                                .action("Set icon…", .open(.projectSettings(k, .appearance)))]
        if hasTrackerIcon { out.append(.action("Use tracker icon", .useTrackerIcon(k))) }
        out.append(.action("Hide from sidebar", .hideProject(k)))
        return out.tidy
    }
}

// Runs the row menu commands. A page handles its own commands first with `intercept`.
final class RowCommander {
    let data: AppData
    private let go: (Route) -> Void
    var intercept: ((RowCommand) -> Bool)?

    init(data: AppData, go: @escaping (Route) -> Void) {
        self.data = data
        self.go = go
    }

    var caps: Set<Capability> { Set([.rerun, .rerunJob, .cancel, .logs, .changeActions, .sessionInput, .reveal].filter(data.has)) }

    func items(_ entries: [MenuEntry], anchor: NSView?) -> [NSMenuItem] {
        entries.map { e in
            switch e {
            case .separator: return .separator()
            case .action(let t, let c, let checked):
                let i = MenuAction(t) { [weak self, weak anchor] in self?.run(c, anchor: anchor) }.item
                i.state = checked ? .on : .off
                return i
            case .submenu(let t, let list):
                let i = NSMenuItem(title: t, action: nil, keyEquivalent: "")
                let m = NSMenu(title: t)
                items(list, anchor: anchor).forEach { m.addItem($0) }
                i.submenu = m
                return i
            }
        }
    }

    // Sets the menu of a row.
    func attach(_ row: Row, _ entries: @escaping (Set<Capability>) -> [MenuEntry]) {
        row.menuItems = { [weak self, weak row] in self.map { $0.items(entries($0.caps), anchor: row) } ?? [] }
    }

    func run(_ c: RowCommand, anchor: NSView?) {
        if intercept?(c) == true { return }
        let store = data.projectStore
        switch c {
        case .open(let r): go(r)
        case .openURL(let u): if let url = URL(string: u) { NSWorkspace.shared.open(url) }
        case .copy(let s): RowActions.copy(s)
        case .finder(let p): NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        case .terminal(let p):
            NSWorkspace.shared.open([URL(fileURLWithPath: p)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
        case .status(let id, let opt): store.setStatus(itemId: id, optionId: opt) { _ in }
        case .priority(let id, let p): store.update(itemId: id, ItemPatch(priority: p), failure: "Could not change the priority") { _ in }
        case .assignMe(let id): store.assignMe(itemId: id) { _ in }
        case .startSession(let key):
            guard let found = store.item(key: key), let anchor else { return }
            data.agentIndex.start(found.item, snap: found.snap, anchor: anchor)
        case .run(let repo, let id, let a):
            Task { [weak self] in
                _ = await REPO_CLIENT.perform(a, repo: repo, id: id)
                await MainActor.run { self?.data.refresh(force: true, completion: nil) }
            }
        case .ignoreFailure(let repo, let id, let on):
            guard let r = data.grouped.first(where: { $0.0 == repo })?.1.first(where: { $0.id == id }) else { return }
            data.setIgnored([r], ignored: on)
        case .copyJobLog(let repo, let id):
            Task { if let log = await REPO_CLIENT.rawLog(repo, jobId: id) { await MainActor.run { RowActions.copy(log) } } }
        case .rerunJob(let repo, let runId, let jobId):
            Task { [weak self, weak anchor] in
                let err = await REPO_CLIENT.rerunJob(repo: repo, runId: runId, jobId: jobId)
                await MainActor.run {
                    if let err { self?.fail("Could not re-run the job", err, anchor: anchor) }
                    self?.data.refresh(force: true, completion: nil)
                }
            }
        case .approve(let repo, let n), .merge(let repo, let n):
            // Pages that list PRs ask first. Elsewhere the PR opens on GitHub.
            if let u = URL(string: "https://github.com/\(repo)/pull/\(n)") { NSWorkspace.shared.open(u) }
        case .revealCard(let id): data.agentIndex.reveal(card: id)
        case .sendInput(let key): sendInput(key, anchor: anchor)
        case .explain(let repo, let runId, let jobId): explain(repo: repo, runId: runId, jobId: jobId, anchor: anchor)
        case .refreshProject(let k): store.refresh([k], force: true) { _ in }
        case .useTrackerIcon(let k): editLocal(k) { $0.icon = .tracker }
        case .hideProject(let k): editLocal(k) { $0.hidden = true }
        case .removeWorktree: break   // the Worktrees page handles it
        case .triage, .onlyProject: break
        }
    }

    // Without an AI engine the run page opens. Its cause card tells how to set one up.
    private func explain(repo: String, runId: String, jobId: String?, anchor: NSView?) {
        let route = Route.run(repo: repo, id: runId)
        guard data.ciAssist.hasEngine, let anchor, anchor.window != nil else { go(route); return }
        let known = data.grouped.first { $0.0 == repo }?.1.first { $0.id == runId }
        ExplainPopover.show(at: anchor, repo: repo, run: known, runId: runId, jobId: jobId, cia: data.ciAssist) { [weak self] in self?.go(route) }
    }

    private func editLocal(_ key: String, _ change: (inout ProjectLocalSettings) -> Void) {
        var l = PROJECTS_CFG.local(key)
        change(&l)
        PROJECTS_CFG.setLocal(key, l)
        saveConfig()
        Task { await PROJECT_ICONS.sync(key) }
        ChangeBus.shared.post(.config())
    }

    private func fail(_ title: String, _ detail: String, anchor: NSView?) {
        AlertConfirm.tell(title, info: detail, in: anchor?.window)
    }

    private func sendInput(_ key: String, anchor: NSView?) {
        AlertConfirm.input("Send input to the \(key) session", placeholder: "Text for the terminal", button: "Send", in: anchor?.window) { [weak self] text in
            self?.data.agentIndex.send(key, text: text) { _ in }
        }
    }
}
