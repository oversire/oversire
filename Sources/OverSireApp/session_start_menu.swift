import Cocoa
import OverSireCore

// The menus of a session start. A menu at the button picks the Orca workspace or the agent.
// Then the session.start action runs with the choice as args.
struct SessionStartMenu {
    let data: AppData

    init(_ data: AppData) { self.data = data }

    /// Starts in the saved workspace of the project. Without one, a menu at `anchor` asks for it.
    func start(_ item: Item, snap: ProjectSnapshot, at anchor: NSView, agent: String? = nil) {
        let window = anchor.window
        pickRoot(snap, at: anchor, key: item.key) { root in self.run(item, root: root, agent: agent, in: window) }
    }

    /// Gives nil when the project has a saved Orca workspace. Else a menu at `anchor` asks for one.
    func pickRoot(_ snap: ProjectSnapshot, at anchor: NSView, key: String, _ done: @escaping (String?) -> Void) {
        if let root = PROJECTS_CFG.orca.roots[snap.summary.ref.storeKey], !root.isEmpty { done(nil); return }
        let agents = data.agentIndex
        agents.workspaces { [weak anchor] r in
            switch r {
            case .failure(let e):
                agents.fail(key, e.message)
                AlertConfirm.tell("OverSire cannot read the Orca workspaces", info: e.message, in: anchor?.window)
            case .success(let repos):
                let menu = NSMenu()
                menu.addItem(withTitle: "Run \(snap.summary.identifier) items in…", action: nil, keyEquivalent: "").isEnabled = false
                let guess = OrcaConfig.guess(snap.summary, repos)
                let sorted = repos.sorted { a, b in
                    if (a.path == guess) != (b.path == guess) { return a.path == guess }
                    if a.folder != b.folder { return a.folder }
                    return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
                for repo in sorted {
                    let mi = MenuAction(repo.name) { done(repo.path) }.item
                    mi.toolTip = repo.path
                    mi.image = NSImage(systemSymbolName: repo.folder ? "folder" : "arrow.triangle.branch", accessibilityDescription: nil)
                    menu.addItem(mi)
                }
                if repos.isEmpty { menu.addItem(withTitle: "Orca has no workspaces", action: nil, keyEquivalent: "").isEnabled = false }
                // A rebuild can remove the anchor while Orca replies.
                if let anchor, anchor.window != nil {
                    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
                } else {
                    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                }
            }
        }
    }

    // A failed start offers a retry. Other states open the terminal.
    func pill(_ item: Item, snap: ProjectSnapshot, at anchor: NSView) {
        let agents = data.agentIndex
        guard let a = agents.agent(item.key), a.phase == .failed else { data.actions.click("session.reveal", ["key": .string(item.key)], in: anchor.window); return }
        let menu = NSMenu()
        let head = NSMenuItem(title: a.message ?? "The session did not start", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())
        menu.addItem(MenuAction("Try again") { [weak anchor] in
            agents.clearFailure(item.key)
            if let anchor { self.start(item, snap: snap, at: anchor) }
        }.item)
        if PROJECTS_CFG.orca.roots[snap.summary.ref.storeKey]?.isEmpty == false {
            menu.addItem(MenuAction("Choose another workspace…") { [weak anchor] in
                agents.clearFailure(item.key)
                PROJECTS_CFG.orca.roots[snap.summary.ref.storeKey] = nil
                saveConfig()
                if let anchor { self.start(item, snap: snap, at: anchor) }
            }.item)
        }
        menu.addItem(MenuAction("Dismiss") { agents.clearFailure(item.key) }.item)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 2), in: anchor)
    }

    /// "Start in Orca with": one start with another agent. The default does not change.
    /// `header`: false for a submenu, which has the title already.
    func agents(_ item: Item, snap: ProjectSnapshot, at anchor: NSView, header: Bool = true) -> NSMenu {
        let menu = NSMenu()
        if header { menu.addItem(withTitle: "Start in Orca with", action: nil, keyEquivalent: "").isEnabled = false }
        let d = PROJECTS_CFG.defaultAgent(item.key)
        AgentMenu.build(into: menu, picked: nil, standard: d) { [weak anchor] a in
            guard let anchor else { return }
            self.start(item, snap: snap, at: anchor, agent: a == d ? nil : a)
        }
        return menu
    }

    /// "Run a runbook": the runbooks with the project default first, and "Start at a step".
    func runbooks(into menu: NSMenu, _ item: Item, snap: ProjectSnapshot, at anchor: NSView, started: @escaping (RunbookRun) -> Void) {
        let books = PROJECTS_CFG.runtime.runbooks
        guard !books.isEmpty else { return }
        let first = PROJECTS_CFG.runbook(for: snap.summary.identifier)
        let sorted = books.filter { $0.id == first?.id } + books.filter { $0.id != first?.id }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Run a runbook", action: nil, keyEquivalent: "").isEnabled = false
        for b in sorted {
            let mi = MenuAction(b.id == first?.id ? "\(b.name) (default)" : b.name) { [weak anchor] in
                guard let anchor else { return }
                self.runbook(b, item, snap: snap, at: anchor, started: started)
            }.item
            mi.toolTip = b.steps.map(\.name).joined(separator: " → ")
            menu.addItem(mi)
        }
        let at = NSMenuItem(title: "Start at a step", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for b in sorted {
            let one = NSMenuItem(title: b.name, action: nil, keyEquivalent: "")
            let steps = NSMenu()
            for (i, st) in b.steps.enumerated() where i > 0 {
                steps.addItem(MenuAction("\(i + 1). \(st.name)") { [weak anchor] in
                    guard let anchor else { return }
                    self.runbook(b, item, snap: snap, at: anchor, step: st.id, started: started)
                }.item)
            }
            one.submenu = steps
            one.isEnabled = b.steps.count > 1
            sub.addItem(one)
        }
        at.submenu = sub
        menu.addItem(at)
    }

    /// Starts a runbook on the sessions machine. Without a saved Orca workspace, a menu at `anchor` asks for it.
    func runbook(_ book: Runbook, _ item: Item, snap: ProjectSnapshot, at anchor: NSView, step: String? = nil, started: @escaping (RunbookRun) -> Void) {
        let window = anchor.window
        pickRoot(snap, at: anchor, key: item.key) { root in
            var s = RunbookStarter()
            if let root { s.root = { _ in root } }
            Task {
                do {
                    let run = try await s.start(book, item: item, in: snap.summary, at: step)
                    await MainActor.run { started(run) }
                } catch {
                    let info = (error as? ProviderError)?.message ?? error.localizedDescription
                    await MainActor.run { AlertConfirm.tell("\(book.name) did not start on \(item.key)", info: info, in: window) }
                }
            }
        }
    }

    // A failure shows its reason: the pill alone is easy to miss.
    private func run(_ item: Item, root: String?, agent: String?, in window: NSWindow?) {
        var args: [String: JSONValue] = ["key": .string(item.key)]
        if let root { args["root"] = .string(root) }
        if let agent { args["agent"] = .string(agent) }
        data.actions.click("session.start", args, in: window, asked: true)
    }
}
