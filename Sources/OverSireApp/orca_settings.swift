import Cocoa
import OverSireCore
import RuntimeOrca

// Settings → Projects → Orca: the agent, the prompt template, and the Orca workspace of each
// Plane project. The Orca account (CLI and environment) is on the Providers page.
extension ProjectSettingsVC {
    struct OrcaProbe {
        var environment: String?
        var version: String?
        var error: String?
        var repos: [RuntimeRepo] = []
    }
    static var orcaProbe: OrcaProbe?
    static var orcaProbing = false
    static let orcaAgents = ["claude", "codex", "opencode"]

    func orcaSection(y: CGFloat, w: CGFloat, in doc: NSView) -> CGFloat {
        var y = y + 4
        let l = NSTextField(labelWithString: cfg.orca.enabled
            ? "Orca account: \(cfg.orca.environment ?? "this Mac"). Change it in Settings › Providers."
            : "Add an Orca account in Settings › Providers to start items with ▶.")
        l.font = .systemFont(ofSize: 12)
        l.frame = NSRect(x: 16, y: y + 2, width: w - 100, height: 18)
        doc.addSubview(l)
        let test = NSButton(title: ProjectSettingsVC.orcaProbing ? "Testing…" : "Test", target: self, action: #selector(testOrca))
        test.bezelStyle = .rounded; test.font = .systemFont(ofSize: 11)
        test.frame = NSRect(x: w - 72, y: y - 2, width: 60, height: 26)
        test.isEnabled = !ProjectSettingsVC.orcaProbing
        test.toolTip = "Run orca status on the chosen host"
        doc.addSubview(test)
        y += 30
        let probe = ProjectSettingsVC.orcaProbe
        if probe == nil || probe?.environment != cfg.orca.environment { probeOrca() }

        let installed = FileManager.default.isExecutableFile(atPath: cfg.orca.cli)
        var status = installed ? "Orca CLI · " + (cfg.orca.cli as NSString).abbreviatingWithTildeInPath : "Orca CLI not found at \(cfg.orca.cli)"
        var color = NSColor.secondaryLabelColor
        if let p = probe, installed {
            if let v = p.version { status += " · \(v) · connected" } else if let e = p.error { status += " · " + e; color = C_FAILURE }
        }
        if !installed { color = C_FAILURE }
        let st = NSTextField(labelWithString: status)
        st.font = .systemFont(ofSize: 11); st.textColor = color
        st.lineBreakMode = .byTruncatingMiddle; st.toolTip = status
        st.frame = NSRect(x: 16, y: y, width: w - 32, height: 16)
        doc.addSubview(st)
        y += 24

        let agents = ProjectSettingsVC.orcaAgents + (ProjectSettingsVC.orcaAgents.contains(cfg.orca.agent) ? [] : [cfg.orca.agent])
        y = popupRow("Agent", agents, agents.firstIndex(of: cfg.orca.agent) ?? 0, #selector(orcaAgentChanged(_:)), y: y, in: doc)

        let pl = NSTextField(labelWithString: "Prompt")
        pl.font = .systemFont(ofSize: 12)
        pl.frame = NSRect(x: 16, y: y + 4, width: 80, height: 18)
        doc.addSubview(pl)
        let pf = NSTextField(frame: NSRect(x: 80, y: y, width: w - 96, height: 24))
        pf.stringValue = cfg.orca.prompt
        pf.placeholderString = OrcaConfig.defaultPrompt
        pf.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        pf.identifier = NSUserInterfaceItemIdentifier("orca-prompt")
        pf.target = self; pf.action = #selector(orcaPromptChanged(_:))
        doc.addSubview(pf)
        y += 28
        let hint = NSTextField(labelWithString: "{url}, {key} (lowercase), {KEY} and {title}. Keep {url} first: Orca keeps only the start of a prompt.")
        hint.font = .systemFont(ofSize: 10.5); hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 80, y: y, width: w - 96, height: 14)
        doc.addSubview(hint)
        y += 24

        // Project → Orca workspace.
        let heads: [(String, CGFloat)] = [("Plane project", 16), ("Orca workspace", 170), ("Root CLAUDE.md", w - 130)]
        for (t, x) in heads {
            let h = NSTextField(labelWithString: t)
            h.font = .systemFont(ofSize: 10, weight: .semibold); h.textColor = .secondaryLabelColor
            h.frame = NSRect(x: x, y: y, width: 140, height: 14)
            doc.addSubview(h)
        }
        y += 18
        let repos = probe?.repos ?? []
        let projects = catalog.resolve(cfg)
        if projects.isEmpty {
            let e = NSTextField(labelWithString: "Pick projects above first.")
            e.font = .systemFont(ofSize: 11); e.textColor = .tertiaryLabelColor
            e.frame = NSRect(x: 16, y: y, width: w - 32, height: 16)
            doc.addSubview(e)
            y += 22
        }
        for p in projects {
            let key = p.ref.storeKey
            if cfg.orca.roots[key] == nil, let g = OrcaConfig.guess(p, repos) { cfg.orca.roots[key] = g }
            let root = cfg.orca.roots[key].flatMap { $0.isEmpty ? nil : $0 }
            let name = NSTextField(labelWithString: p.identifier)
            name.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
            name.toolTip = "\(p.ref.workspace) › \(p.title)"
            name.frame = NSRect(x: 16, y: y + 4, width: 150, height: 16)
            doc.addSubview(name)
            let pop = NSPopUpButton(frame: NSRect(x: 166, y: y, width: w - 310, height: 24), pullsDown: false)
            pop.font = .systemFont(ofSize: 12)
            pop.addItem(withTitle: "— ask each time —")
            var paths = repos.map(\.path)
            if let root, !paths.contains(root) { paths.append(root) }
            for path in paths {
                pop.addItem(withTitle: repos.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent)
                pop.lastItem?.representedObject = path
                pop.lastItem?.toolTip = path
            }
            pop.selectItem(at: root.flatMap { paths.firstIndex(of: $0).map { $0 + 1 } } ?? 0)
            pop.identifier = NSUserInterfaceItemIdentifier(key)
            pop.target = self; pop.action = #selector(orcaRootChanged(_:))
            doc.addSubview(pop)
            let md = NSTextField(labelWithString: ProjectSettingsVC.claudeMDState(root, remote: cfg.orca.environment != nil))
            md.font = .systemFont(ofSize: 11); md.textColor = .secondaryLabelColor
            md.frame = NSRect(x: w - 130, y: y + 4, width: 118, height: 16)
            doc.addSubview(md)
            y += 28
        }
        let help = NSTextField(wrappingLabelWithString: "▶ opens a Claude session named with the item key in an Orca card of the same name, and sends the prompt. The agent sets the status. The root CLAUDE.md tells it how to make the worktree group.")
        help.font = .systemFont(ofSize: 11); help.textColor = .secondaryLabelColor
        help.frame = NSRect(x: 16, y: y + 2, width: w - 32, height: 44)
        doc.addSubview(help)
        return y + 50
    }

    // "groups" when the root CLAUDE.md tells the agent about worktree groups.
    static func claudeMDState(_ root: String?, remote: Bool) -> String {
        guard let root else { return "—" }
        if remote { return "on the server" }
        guard let text = try? String(contentsOfFile: (root as NSString).appendingPathComponent("CLAUDE.md"), encoding: .utf8) else { return "missing" }
        return text.range(of: "worktree group", options: .caseInsensitive) != nil ? "groups" : "no groups"
    }

    func probeOrca() {
        guard !ProjectSettingsVC.orcaProbing else { return }
        ProjectSettingsVC.orcaProbing = true
        let rt = cfg.orca.runtime
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var p = OrcaProbe(environment: rt.environment)
            switch Result(blocking: { try await rt.version() }) {
            case .success(let v): p.version = v
            case .failure(let e): p.error = e.message
            }
            p.repos = (try? Result(blocking: { try await rt.repos() }).get()) ?? []
            DispatchQueue.main.async {
                ProjectSettingsVC.orcaProbe = p
                ProjectSettingsVC.orcaProbing = false
                self?.rebuild()
            }
        }
    }

    @objc func testOrca() {
        ProjectSettingsVC.orcaProbe = nil
        probeOrca()
        rebuild()
    }
    @objc func orcaPromptChanged(_ sender: NSTextField) { cfg.orca.prompt = sender.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    @objc func orcaAgentChanged(_ sender: NSPopUpButton) { cfg.orca.agent = sender.titleOfSelectedItem ?? "claude" }
    @objc func orcaRootChanged(_ sender: NSPopUpButton) {
        guard let key = sender.identifier?.rawValue else { return }
        cfg.orca.roots[key] = sender.selectedItem?.representedObject as? String ?? ""
        rebuild()
    }
}
