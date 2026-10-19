import Cocoa
import OverSireCore

// A switch with a title and a note. It saves the config when it flips.
final class SwitchRow: Row {
    private let flip: (Bool) -> Void

    init(_ title: String, note: String? = nil, on: Bool, enabled: Bool = true, _ flip: @escaping (Bool) -> Void) {
        self.flip = flip
        let sw = NSSwitch()
        sw.state = on ? .on : .off
        sw.isEnabled = enabled
        sw.controlSize = .small
        sw.setAccessibilityLabel(title)
        super.init([TwoLine(title, note, weight: .medium), Spacer(), sw], height: note == nil ? 40 : 52, label: title)
        sw.target = self
        sw.action = #selector(changed(_:))
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed(_ sw: NSSwitch) {
        flip(sw.state == .on)
        saveConfig()
        NotificationCenter.default.post(name: AppWindow.changed, object: nil)
    }
}

// A label at the left and any control at the right.
final class FieldRow: Row {
    init(_ title: String, note: String? = nil, _ control: NSView) {
        super.init([TwoLine(title, note, weight: .medium), Spacer(), control], height: note == nil ? 40 : 52, label: title)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// Settings in the window: a list of pages at the left, the page at the right.
final class SettingsPage: Page, NSTextFieldDelegate {
    private static var embedded: [String: NSViewController] = [:]
    private var branchTest = ""
    private let promptView = NSTextView()
    private var promptDirty = false

    private var page: Route.SettingsPage { if case .settings(let p, _, _) = route { return p }; return .general }
    private var tab: Route.SettingsTab { if case .settings(_, let t?, _) = route { return t }; return .projects }
    private var anchor: String? { if case .settings(_, _, let a) = route { return a }; return nil }
    var app: GHActionsBar? { NSApp.delegate as? GHActionsBar }

    override var isEditing: Bool { super.isEditing || promptDirty }

    override func build(_ col: NSStackView) {
        col.addFull(PageHeader("Settings", caption: "OverSire saves each change at once to \((CONFIG_PATH as NSString).abbreviatingWithTildeInPath)."))
        let nav = ListCard()
        for p in Route.SettingsPage.allCases {
            let r = Row([Glyph(p.symbol, size: 13), NSTextField.text(p.title, size: 12.5, weight: p == page ? .semibold : .regular), Spacer()],
                        height: 32, label: p.title) { [weak self] in self?.go(.settings(p)) }
            r.selected = p == page
            nav.add(r)
        }
        let body = NSStackView(v: [], spacing: 10)
        if page != .agents { AgentCommandsCard.drafts = [:] }
        switch page {
        case .general: general(body)
        case .accounts: accounts(body)
        case .projects:
            let strip = TabStrip(Route.SettingsTab.allCases.map(\.title), selected: Route.SettingsTab.allCases.firstIndex(of: tab) ?? 0)
            strip.onSelect = { [weak self] i in self?.go(.settings(.projects, tab: Route.SettingsTab.allCases[i])) }
            body.addArrangedSubview(strip)
            switch tab {
            case .projects: projects(body)
            case .repos:
                let filters: [String: RepoListModel.Filter] = ["tracked": .tracked, "problems": .problems]
                body.addFull(RepoListView(catalog: data.repoCatalog, setup: data.cloudSetup, filter: anchor.flatMap { filters[$0] } ?? .all) { [weak self] f in
                    self?.go(.settings(.projects, tab: .repos, anchor: filters.first { $0.value == f }?.key))
                })
            case .linking: linking(body); writeBack(body)
            }
        case .agents: runtime(body); queue(body); planner(body)
        case .ai: ai(body)
        case .notifications: notifications(body)
        }
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        let navCol = NSStackView(v: [], spacing: 0)
        navCol.addFull(nav)
        navCol.addArrangedSubview(filler)
        let two = NSStackView(h: [navCol, body], spacing: 16, align: .top)
        col.addFull(two)
        navCol.widthAnchor.constraint(equalToConstant: 210).isActive = true
        // Not required: an embedded menu bar pane has a fixed width, and a narrow page scrolls sideways.
        let bw = body.widthAnchor.constraint(equalTo: two.widthAnchor, constant: -226)
        bw.priority = .defaultHigh
        bw.isActive = true
    }

    private func card(_ title: String, _ rows: [NSView]) -> NSView { section(title, anchor: nil, rows) }

    // A titled card. The anchor is the id that a route anchor and the search scroll to.
    func section(_ title: String, anchor: String?, _ rows: [NSView]) -> NSView {
        let c = ListCard()
        rows.forEach { c.add($0) }
        let v = NSStackView(v: [SectionTitle(title)], spacing: 6)
        v.addFull(c)
        if let anchor { v.identifier = NSUserInterfaceItemIdentifier("anchor-\(anchor)") }
        return v
    }

    // MARK: Pages

    private func linking(_ b: NSStackView) {
        let rules = ChipGroup([
            .init("Orca card is the key", on: LINKING.card) { LINKING.card = $0 },
            .init("Worktree .wt/<key>", on: LINKING.folder) { LINKING.folder = $0 },
            .init("Branch starts with the key", on: LINKING.prefix) { LINKING.prefix = $0 },
            .init("PR names the key", on: LINKING.pr) { LINKING.pr = $0 },
            .init("Commit title names the key", on: LINKING.trailer) { LINKING.trailer = $0 },
            .init("Run branch = checkout", on: LINKING.branch) { LINKING.branch = $0 },
            .init("Run commit = HEAD", on: LINKING.head) { LINKING.head = $0 },
        ], label: "Link an item to code when")
        let f = NSTextField()
        f.placeholderString = "fritz-28/desktop-app"
        f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        f.stringValue = branchTest
        f.delegate = self
        f.identifier = NSUserInterfaceItemIdentifier("branchTest")
        f.setAccessibilityLabel("Test a name")
        f.setContentHuggingPriority(.init(1), for: .horizontal)
        f.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        let known = Set(data.projectStore.tracked.map { $0.identifier.uppercased() })
        let t = branchTest.trimmingCharacters(in: .whitespaces)
        let result: NSView
        if t.isEmpty { result = NSTextField.text("Shows the item that a branch, card or folder name links to.", size: 11.5, color: Palette.dim) }
        else if let k = WorkstreamIndex.key(inBranch: t, known: known) { result = Pill(.ok, text: "→ \(k) · branch prefix") }
        else if let k = WorkstreamIndex.key(in: t, known: known, whole: true) { result = Pill(.ok, text: "→ \(k) · card or folder name") }
        else {
            let p = Pill(.idle, text: "No link")
            p.toolTip = "The name does not start with the key of a tracked project (\(known.sorted().prefix(6).joined(separator: ", ")))."
            result = p
        }
        let test = NSStackView(h: [NSTextField.text("Test a name", size: 12, color: Palette.dim), f, result], spacing: 8)
        let body = NSStackView(v: [], spacing: 14)
        body.addFull(rules)
        body.addFull(test)
        b.addFull(section("Link an item to code when", anchor: "linking", [Padded(body)]))
    }

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField, f.identifier?.rawValue == "branchTest" else { return }
        branchTest = f.stringValue
        reload()
        if let nf = view.findField("branchTest") { view.window?.makeFirstResponder(nf); nf.currentEditor()?.selectedRange = NSRange(location: nf.stringValue.count, length: 0) }
    }

    private func writeBack(_ b: NSStackView) {
        let on = AGENTS.writeBack.enabled
        b.addFull(section("Write back to Plane", anchor: "write-back", [
            SwitchRow("Write back", note: "Off keeps Plane read only. OverSire never edits text that people wrote.", on: on) { AGENTS.writeBack.enabled = $0 },
            Padded(ChipGroup([
                .init("Links", on: AGENTS.writeBack.links) { AGENTS.writeBack.links = $0 },
                .init("Session labels", on: AGENTS.writeBack.labels) { AGENTS.writeBack.labels = $0 },
                .init("OverSire block", on: AGENTS.writeBack.block) { AGENTS.writeBack.block = $0 },
                .init("Session comment · AI", on: AGENTS.writeBack.sessionComment) { AGENTS.writeBack.sessionComment = $0 },
                .init("Move to In review on PR", on: AGENTS.writeBack.moveToReview) { AGENTS.writeBack.moveToReview = $0 },
            ], label: "What OverSire writes", enabled: on,
               note: "Links and labels go in once. The OverSire block sits between markers at the end of the body.")),
        ]))
    }

    private func runtime(_ b: NSStackView) {
        let r = PROJECTS_CFG.runtime
        let agents = AgentCommandsCard.known + (AgentCommandsCard.known.contains(r.agent) ? [] : [r.agent])
        let agent = PopUp(agents, selected: agents.firstIndex(of: r.agent) ?? 0, label: "Default agent") { i in
            PROJECTS_CFG.runtime.agent = agents[i]
            saveConfig()
            AgentCommandsCard.changed()
        }
        let prompt = TextInput(r.prompt, placeholder: RuntimeConfig.defaultPrompt, label: "Prompt", mono: true) { v in
            PROJECTS_CFG.runtime.prompt = v.trimmingCharacters(in: .whitespacesAndNewlines)
            saveConfig()
        }
        prompt.widthAnchor.constraint(greaterThanOrEqualToConstant: 340).isActive = true
        b.addFull(card("Agent", [
            FieldRow("Default agent", note: "For each runtime. A project can choose another agent.", agent),
            FieldRow("Prompt", note: "{url}, {key} (lowercase), {KEY} and {title}. Keep {url} first.", prompt),
        ]))
        b.addFull(AgentCommandsCard(examples: commandExamples, usedBy: commandUsers))
        orca(b)
    }

    // The last started item, then a sample key of the first tracked project.
    private var commandExamples: [AgentCommandsCard.Example] {
        var out: [AgentCommandsCard.Example] = []
        if let k = data.agentIndex.lastStarted {
            out.append(.init(key: k, title: data.projectStore.item(key: k)?.item.title ?? k))
        }
        let project = data.projectStore.tracked.map(\.identifier).sorted().first ?? "ENG"
        out.append(.init(key: project + "-42", title: "Fix the retry on 503"))
        return out
    }

    // Each runtime account, and each runtime of an online runner. Orca types a command; agent-wire does not.
    private var commandUsers: [AgentCommandsCard.User] {
        var out = ENV.accounts(.runtime).map { a in
            AgentCommandsCard.User(name: "\(a.account.provider.rawValue.capitalized) · \(a.account.id == "local" ? "this Mac" : a.account.id)",
                                   terminal: a.account.provider == .orca)
        }
        for r in cloudAIRecords?.runners ?? [] where r.online {
            out += r.runtimes.map { AgentCommandsCard.User(name: "Runner \(r.device) · \($0.rawValue)", terminal: $0 == .orca) }
        }
        return out
    }

    private func orca(_ b: NSStackView) {
        let o = PROJECTS_CFG.orca
        let ready = data.agentIndex.ready != nil
        b.addFull(Banner(o.enabled ? (ready ? .ok : .warning) : .idle,
                         title: o.enabled ? (ready ? "Orca is on." : "Orca is on, but OverSire could not read it.") : "Orca is off.",
                         body: "CLI \(o.cli) · \(o.environment.map { "environment \($0)" } ?? "this Mac")",
                         actions: [ActionButton("Edit Orca settings") { [weak self] in self?.go(.settings(.projects, tab: .projects)) }]))
        var rows: [NSView] = []
        for p in data.projectStore.tracked.sorted(by: { $0.identifier < $1.identifier }) {
            let root = o.roots[p.ref.storeKey].flatMap { $0.isEmpty ? nil : $0 }
            rows.append(FieldRow(p.identifier, note: p.title, NSTextField.text(root.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No workspace", size: 12,
                                                                              color: root == nil ? Palette.dim : Palette.mut, mono: true)))
        }
        if rows.isEmpty { rows.append(EmptyNote("No tracked Plane projects.")) }
        b.addFull(card("Orca workspace of each project", rows))
    }

    private func queue(_ b: NSStackView) {
        let modes = AIMode.allCases
        let quiet = MenuChip("\(Int(AGENTS.quietMinutes)) min", symbol: "clock") {
            [5, 10, 15, 30, 60].map { m in MenuAction("\(m) min") { AGENTS.quietMinutes = Double(m); saveConfig(); NotificationCenter.default.post(name: AppWindow.changed, object: nil) } }
        }
        b.addFull(card("Queue", [
            SwitchRow("Auto start", note: "Start the next item when a slot is free and its condition holds.", on: AGENTS.autoStart) { AGENTS.autoStart = $0 },
            FieldRow("AI checks", note: "Ask me shows a card. Auto acts at once.",
                     Segmented(modes.map(\.label), selected: modes.firstIndex(of: AGENTS.aiMode) ?? 1, label: "AI checks") { AGENTS.aiMode = modes[$0] }),
            FieldRow("Quiet time", note: "A session with no output this long gets a check.", quiet),
            FieldRow("Start label", note: "A Plane label that adds the item to the queue.", textField(AGENTS.startLabel, id: "startLabel")),
            FieldRow("Bot assignee", note: "A Plane user that adds the item to the queue when assigned.", textField(AGENTS.botUser, id: "botUser")),
        ]))
        b.addFull(card("Intake agent", [
            SwitchRow("Scratch worktree", note: "Work in .wt/intake-<key>, not in the main checkout.", on: AGENTS.intakeScratch) { AGENTS.intakeScratch = $0 },
        ]))
        let c = Card(title: "Intake prompt", trailing: [
            ActionButton("Reset") { [weak self] in
                AGENTS.intakePrompt = AgentsConfig.defaultIntakePrompt
                saveConfig()
                self?.promptDirty = false
                self?.reload()
            },
            ActionButton("Save", style: .primary) { [weak self] in
                guard let self else { return }
                AGENTS.intakePrompt = self.promptView.string
                saveConfig()
                self.promptDirty = false
                self.reload()
            },
        ])
        if !promptDirty { promptView.string = AGENTS.intakePrompt }
        promptView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        promptView.isRichText = false
        promptView.textColor = Palette.fg
        promptView.backgroundColor = Palette.raise
        promptView.delegate = self
        promptView.setAccessibilityLabel("Intake prompt")
        let scroll = NSScrollView()
        scroll.documentView = promptView
        scroll.hasVerticalScroller = true
        promptView.autoresizingMask = [.width]
        promptView.isVerticallyResizable = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        c.add(scroll)
        c.add(NSTextField.text("{KEY}, {title}, {url} and {body} take the values of the item. {vision} adds the project vision, or nothing.", size: 11.5, color: Palette.dim))
        b.addFull(c)
    }

    private func textField(_ value: String, id: String) -> NSView {
        let f = NSTextField()
        f.stringValue = value
        f.identifier = NSUserInterfaceItemIdentifier(id)
        f.target = self
        f.action = #selector(fieldDone(_:))
        f.setAccessibilityLabel(id)
        f.widthAnchor.constraint(equalToConstant: 180).isActive = true
        return f
    }

    @objc private func fieldDone(_ f: NSTextField) {
        let v = f.stringValue.trimmingCharacters(in: .whitespaces)
        switch f.identifier?.rawValue {
        case "startLabel": AGENTS.startLabel = v
        case "botUser": AGENTS.botUser = v
        default: return
        }
        saveConfig()
    }

    func controlTextDidEndEditing(_ n: Notification) {
        if let f = n.object as? NSTextField, f.identifier?.rawValue != "branchTest" { fieldDone(f) }
    }

    private func ai(_ b: NSStackView) {
        let on = AIClient.current != nil
        if !on {
            b.addFull(Banner(.idle, title: "AI is off.", body: "Set the endpoint, model and key below. The switches take effect when AI is on. The intake agent and flaky marks work without it."))
        }
        let hour = MenuChip(String(format: "%02d:00", AI_CFG.digestHour), symbol: "sunrise") {
            (5...11).map { h in MenuAction(String(format: "%02d:00", h)) { AI_CFG.digestHour = h; saveConfig(); NotificationCenter.default.post(name: AppWindow.changed, object: nil) } }
        }
        b.addFull(card("Sessions", [
            SwitchRow("Done and stuck checks", note: "Check a session that goes quiet. The queue can start the next item.", on: AI_CFG.agentChecks) { AI_CFG.agentChecks = $0 },
            SwitchRow("Queue order", note: "Suggest an order for each lane.", on: AI_CFG.queueOrder) { AI_CFG.queueOrder = $0 },
            SwitchRow("Intake agent", note: "Check intake items in an Orca terminal in plan mode. Needs Orca, not an AI key.", on: AI_CFG.intakeAgent) { AI_CFG.intakeAgent = $0 },
            SwitchRow("Session summary", note: "Summarize the session on the item page.", on: AI_CFG.sessionSummary) { AI_CFG.sessionSummary = $0 },
        ]))
        b.addFull(card("CI", [
            SwitchRow("Explain failures", note: "A short cause for a failed run that no session watches.", on: AI_CFG.ciExplain) { AI_CFG.ciExplain = $0 },
            SwitchRow("Flaky workflows", note: "Mark a workflow that failed and then passed on the same commit. Re-run its next failure once before the alert.", on: AI_CFG.flaky) { AI_CFG.flaky = $0 },
            SwitchRow("Morning digest", note: "A short digest on Home once a day.", on: AI_CFG.digest) { AI_CFG.digest = $0 },
            FieldRow("Digest time", hour),
        ]))
        b.addFull(card("New items", [
            SwitchRow("Title and fields", on: AI_CFG.titleAndFields) { AI_CFG.titleAndFields = $0 },
            SwitchRow("Tidy the text", on: AI_CFG.tidy) { AI_CFG.tidy = $0 },
            SwitchRow("Pick the project", on: AI_CFG.pickProject) { AI_CFG.pickProject = $0 },
        ]))
        embed(b, vc: "ai", note: "Endpoint, model and API key. The key stays in the Keychain.")
    }

    // MARK: Planner

    private var plannerProject: String?

    private func planner(_ b: NSStackView) {
        if !hasCloud {
            b.addFull(NSStackView(h: [PlannerCard.cloudMark(), NSTextField.text(
                "The Planner needs OverSire Cloud. It orders each queue lane, so that two items do not change the same code area at the same time.",
                size: 12, color: Palette.dim, lines: 2), Spacer()], spacing: 8))
        }
        let projects = data.projectStore.tracked
        guard let first = projects.first else { b.addFull(EmptyNote("Track a project first.", symbol: "folder")); return }
        let pk = projects.first { $0.ref.storeKey == plannerProject }?.ref.storeKey ?? first.ref.storeKey
        let book = data.planner
        let s = book.settings(pk)
        let name = projects.first { $0.ref.storeKey == pk }?.title ?? pk
        let pick = MenuChip(name, symbol: "folder") { [weak self] in
            projects.map { p in MenuAction(p.title) { self?.plannerProject = p.ref.storeKey; self?.reload() } }
        }
        let modes: [PlannerSettings.Mode] = [.off, .hourly, .live]
        let modeNote: String
        switch s.mode {
        case .off: modeNote = "Off: no plan changes. The queue still holds items whose area is busy."
        case .live: modeNote = "Live: a check about 2 minutes after a change."
        default: modeNote = "Hourly: at most one check each hour. A held item gets a check at once."
        }
        let shared: [PlannerSettings.SharedFeature] = [.serial, .parallel]
        b.addFull(card("Planner", [
            FieldRow("Project", pick),
            FieldRow("Planner", note: modeNote,
                     Segmented(["Off", "Hourly", "Live"], selected: modes.firstIndex(of: s.mode) ?? 1, label: "Planner") { i in
                book.update(pk) { $0.mode = modes[i] }
            }),
            FieldRow("Feature areas", note: "Core areas are always one at a time.",
                     Segmented(["One at a time", "Allow two at once"], selected: shared.firstIndex(of: s.sharedFeature) ?? 0, label: "Feature areas") { i in
                book.update(pk) { $0.sharedFeature = shared[i] }
            }),
        ]))
        b.addFull(areasCard(pk))
        b.addFull(NSTextField.text("Without a cloud account, the changed paths and the import graph stay on this Mac. With one, the paths sync. File text never leaves the Mac.",
                                   size: 11.5, color: Palette.dim, lines: 3))
    }

    private func areasCard(_ pk: String) -> NSView {
        let book = data.planner
        let catalog = book.catalog(pk)
        let add = ActionButton("Add area…", symbol: "plus") { [weak self] in self?.addArea(pk) }
        let scan = ActionButton("Scan imports", symbol: "arrow.triangle.branch") { [weak self] in self?.app?.scanImportGraphs(force: true) }
        scan.toolTip = "Read the imports of the repo and propose areas. Only paths go to the cloud."
        scan.isEnabled = hasCloud
        let rows: [NSView] = catalog.areas.map { a in
            let rules = a.rules.map { $0.source == .user ? $0.glob : "\($0.glob) (\($0.source.rawValue))" }.joined(separator: ", ")
            let kind = MenuChip(a.kind.isCore ? "◆ Core" : "◇ Feature") {
                [(AreaKind.core, "◆ Core"), (.feature, "◇ Feature")].map { k, t in
                    MenuAction(t) { book.update(catalog: pk) { c in if let i = c.areas.firstIndex(where: { $0.name == a.name }) { c.areas[i].kind = k } } }
                }
            }
            kind.setAccessibilityLabel("Kind of \(a.name)")
            var views: [NSView] = [TwoLine(a.name, rules.isEmpty ? "No path rules" : rules, weight: .medium), Spacer()]
            if a.proposed {
                views += [NSTextField.text("From the import graph", size: 11.5, color: Palette.dim), kind,
                          ActionButton("Accept") { book.update(catalog: pk) { c in if let i = c.areas.firstIndex(where: { $0.name == a.name }) { c.areas[i].proposed = false } } },
                          ActionButton("Dismiss") { book.update(catalog: pk) { c in c.areas.removeAll { $0.name == a.name } } }]
            } else {
                views += [kind, ActionButton("Rules…") { [weak self] in self?.editRules(pk, a) }]
            }
            return Row(views, height: 52, label: "\(a.name), \(a.kind.isCore ? "core" : "feature")\(a.proposed ? ", proposed" : ""). \(rules)")
        }
        let v = NSStackView(v: [SectionTitle("Areas", count: catalog.areas.count, action: NSStackView(h: [scan, add], spacing: 6))], spacing: 6)
        let c = ListCard()
        rows.forEach { c.add($0) }
        if rows.isEmpty { c.add(EmptyNote("No areas yet. The Planner proposes areas from the import graph of the repos.", symbol: "square.dashed")) }
        v.addFull(c)
        v.addFull(NSTextField.text("A path rule is a glob: * is one part of a path, ** is any number of parts. Your rules win over learned and graph rules.",
                                   size: 11.5, color: Palette.dim, lines: 2))
        return v
    }

    private func addArea(_ pk: String) {
        let a = NSAlert()
        a.messageText = "New area"
        a.informativeText = "An area has lower-case letters, digits and hyphens. Use commas between the path rules."
        let name = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        name.placeholderString = "status-page"
        let globs = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        globs.placeholderString = "Sources/OverSireApp/status_*.swift"
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 54))
        box.addSubview(name)
        box.addSubview(globs)
        a.accessoryView = box
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = name
        guard a.runModal() == .alertFirstButtonReturn, let n = ItemAreas.clean([name.stringValue]).first else { return }
        let rules = globs.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { AreaRule(glob: $0, source: .user) }
        data.planner.update(catalog: pk) { c in
            c.areas.removeAll { $0.name == n }
            c.areas.append(AreaDef(name: n, kind: .core, rules: rules))
        }
        reload()
    }

    private func editRules(_ pk: String, _ area: AreaDef) {
        let a = NSAlert()
        a.messageText = "Path rules of \(area.name)"
        a.informativeText = "Use commas between the rules. Learned and graph rules stay."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        f.stringValue = area.rules.filter { $0.source == .user }.map(\.glob).joined(separator: ", ")
        a.accessoryView = f
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let user = f.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .map { AreaRule(glob: $0, source: .user) }
        data.planner.update(catalog: pk) { c in
            guard let i = c.areas.firstIndex(where: { $0.name == area.name }) else { return }
            c.areas[i].rules = user + c.areas[i].rules.filter { $0.source != .user }
        }
        reload()
    }

    private func notifications(_ b: NSStackView) {
        b.addFull(card("GitHub Actions", [
            SwitchRow("Run started", on: NOTIFICATIONS.started) { NOTIFICATIONS.started = $0 },
            SwitchRow("Run passed", on: NOTIFICATIONS.succeeded) { NOTIFICATIONS.succeeded = $0 },
            SwitchRow("Run failed", note: "A flaky workflow gets one re-run first.", on: NOTIFICATIONS.failed) { NOTIFICATIONS.failed = $0 },
            SwitchRow("Run cancelled", on: NOTIFICATIONS.cancelled) { NOTIFICATIONS.cancelled = $0 },
            SwitchRow("Other endings", on: NOTIFICATIONS.other) { NOTIFICATIONS.other = $0 },
        ]))
        b.addFull(Banner(.info, title: "Plane notifications are set for each project.",
                         actions: [ActionButton("Open project settings") { [weak self] in self?.go(.settings(.projects, tab: .projects)) }]))
    }

    // MARK: Embedded settings

    private func embed(_ b: NSStackView, vc name: String, note: String) {
        b.addFull(NSTextField.text(note, size: 12, color: Palette.dim, lines: 0))
        let key = "\(name)-\(NSApp.appearance?.name.rawValue ?? "system")"
        var vc = SettingsPage.embedded[key]
        if vc == nil {
            NSApp.withPinnedAppearance {
                vc = data.settingsVC(name)
                _ = vc?.view
            }
        }
        guard let vc else {
            b.addFull(EmptyNote("Open these settings from the menu bar.", symbol: "menubar.rectangle"))
            return
        }
        SettingsPage.embedded[key] = vc
        let v = vc.view
        v.removeFromSuperview()
        v.appearance = NSApp.appearance
        // The menu bar nav (Back and tabs) is the top 44 pt. The sidebar does that job here.
        let nav: CGFloat = 44
        let size = vc.preferredContentSize == .zero ? v.frame.size : vc.preferredContentSize
        let box = Box(fill: Palette.panel, border: Palette.line, radius: 10)
        box.wantsLayer = true
        box.layer?.masksToBounds = true
        v.translatesAutoresizingMaskIntoConstraints = true
        v.frame = NSRect(origin: .zero, size: size)
        box.addSubview(v)
        box.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        box.heightAnchor.constraint(equalToConstant: size.height - nav).isActive = true
        b.addArrangedSubview(box)
    }

    static func dropEmbedded() { embedded = [:] }
}

extension SettingsPage: NSTextViewDelegate {
    func textDidChange(_ n: Notification) { promptDirty = true }
}

// An action target for controls that take a selector.
final class ClosureTarget: NSObject {
    private let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
    @objc func fire() { run() }
}

private extension NSView {
    func findField(_ id: String) -> NSTextField? {
        if let f = self as? NSTextField, f.identifier?.rawValue == id { return f }
        for s in subviews { if let f = s.findField(id) { return f } }
        return nil
    }
}
