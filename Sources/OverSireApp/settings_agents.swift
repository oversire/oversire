import Cocoa
import OverSireCore

// Settings › Agents and queue: how sessions start, the queue, the intake agent and the Planner.
extension SettingsPage {
    static var commandsOpen = false
    static var intakePromptOpen = false
    static var areasOpen = false
    static let quietMinutes = [5, 10, 15, 30, 60]

    func agents(_ b: NSStackView) {
        orcaStatus(b)
        newSessions(b)
        queue(b)
        worktrees(b)
        intakeAndPlanner(b)
    }

    // Only when Orca is off or OverSire cannot read it. The project settings page has the workspace of each project.
    private func orcaStatus(_ b: NSStackView) {
        let o = PROJECTS_CFG.orca
        guard !o.enabled || data.agentIndex.ready == nil else { return }
        b.addFull(Banner(o.enabled ? .warning : .idle,
                         title: o.enabled ? "Orca is on, but OverSire could not read it." : "Orca is off.",
                         body: "CLI \(o.cli.isEmpty ? "not set" : o.cli) · \(o.environment.map { "environment \($0)" } ?? "this Mac")",
                         actions: [ActionButton("Accounts and sync ›") { [weak self] in self?.go(.settings(.accounts)) }]))
    }

    private func newSessions(_ b: NSStackView) {
        let r = PROJECTS_CFG.runtime
        let agents = r.agents
        let agent = PopUp(agents, selected: agents.firstIndex(of: r.agent) ?? 0, label: "Default agent") { i in
            PROJECTS_CFG.runtime.agent = agents[i]
            saveConfig()
            AgentCommandsCard.changed()
        }
        let prompt = TextInput(r.prompt, placeholder: RuntimeConfig.defaultPrompt, label: "Prompt", mono: true, lines: 2) { v in
            PROJECTS_CFG.runtime.prompt = v.trimmingCharacters(in: .whitespacesAndNewlines)
            saveConfig()
        }
        let promptRow = NSStackView(v: [], spacing: 6)
        promptRow.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        promptRow.addArrangedSubview(NSTextField.text("Prompt", size: 13, weight: .medium))
        promptRow.addFull(prompt)
        promptRow.addArrangedSubview(NSTextField.text("Placeholders: {url} {key} {KEY} {title}. Keep {url} first.", size: 11.5, color: Palette.dim))
        let n = r.commands.count
        let open = Self.commandsOpen
        let edit = ActionButton(open ? "Done" : "Edit") { [weak self] in
            Self.commandsOpen.toggle()
            self?.reload()
        }
        edit.setAccessibilityLabel(open ? "Close the agent commands" : "Edit the agent commands")
        b.addFull(section(.sessions, [
            FieldRow("Default agent", note: "A project can choose another.", agent),
            promptRow,
            Row([TwoLine("Agent commands", "\(n == 0 ? "Default commands" : n == 1 ? "1 custom command" : "\(n) custom commands") · used by the queue and intake"),
                 Spacer(), edit], height: 52, label: "Agent commands"),
        ]))
        if open { b.addFull(AgentCommandsCard(examples: commandExamples, usedBy: commandUsers)) }
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

    private func queue(_ b: NSStackView) {
        let modes = AIMode.allCases
        let quiet = Self.quietMinutes
        let notices = QuestionNotice.allCases
        let label = TextInput(AGENTS.startLabel, placeholder: "agent", label: "Start label", mono: true) { v in
            AGENTS.startLabel = v.trimmingCharacters(in: .whitespaces)
            saveConfig()
        }
        let bot = TextInput(AGENTS.botUser, placeholder: "oversire-bot", label: "Bot assignee", mono: true) { v in
            AGENTS.botUser = v.trimmingCharacters(in: .whitespaces)
            saveConfig()
        }
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        bot.widthAnchor.constraint(equalToConstant: 150).isActive = true
        label.toolTip = "A Plane label that adds the item to the queue."
        bot.toolTip = "A Plane user that adds the item to the queue when assigned."
        b.addFull(section(.queue, [
            SwitchRow("Auto start", note: "Start the next item when a slot is free and its condition holds.", on: AGENTS.autoStart) { AGENTS.autoStart = $0 },
            FieldRow("AI checks on quiet sessions", note: "Ask me shows a card. Auto acts at once.",
                     Segmented(modes.map(\.label), selected: modes.firstIndex(of: AGENTS.aiMode) ?? 1, label: "AI checks") { AGENTS.aiMode = modes[$0]; settingsChanged() }),
            FieldRow("Quiet after", note: "A session with no output this long gets a check.",
                     Segmented(quiet.map { "\($0) min" }, selected: quiet.firstIndex(of: Int(AGENTS.quietMinutes)) ?? 1, label: "Quiet after") { i in
                AGENTS.quietMinutes = Double(quiet[i])
                settingsChanged()
            }),
            FieldRow("Add to the queue by", note: "Label or assignee in Plane.", NSStackView(h: [label, bot], spacing: 8)),
            FieldRow("Tell me about a question", note: "One notification when a session waits for an answer.",
                     Segmented(notices.map(\.label), selected: notices.firstIndex(of: AGENTS.questionNotice) ?? 1, label: "Tell me about a question") {
                AGENTS.questionNotice = notices[$0]
                saveConfig()
            }),
        ]))
    }

    private func worktrees(_ b: NSStackView) {
        let c = AGENTS.cleanup
        let waits = CleanupConfig.waits
        let safe = NSStackView(v: [NSTextField.text("Safe to remove means", size: 13, weight: .medium)] + [
            "The item and all its sub-items are finished.",
            "No agent works or waits in the worktree.",
            "The worktree has no changes, and its branch is merged or has no own commits.",
            "A remote branch goes only when its PR is merged. An open PR stays.",
        ].map { NSTextField.text("• " + $0, size: 12, color: Palette.mut, lines: 2) }, spacing: 4)
        safe.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        b.addFull(section(.worktrees, [
            SwitchRow("Remove finished worktrees automatically",
                      note: "Only worktrees that are safe to remove. The others stay and show the reason.", on: c.auto) { AGENTS.cleanup.auto = $0 },
            FieldRow("Wait after the item is finished", note: "OverSire does not remove a worktree before this time.",
                     Segmented(waits.map { CleanupConfig.waitText($0).replacingOccurrences(of: " minutes", with: " min") },
                               selected: waits.firstIndex(of: c.waitMinutes) ?? 1, label: "Wait after the item is finished") { i in
                AGENTS.cleanup.waitMinutes = waits[i]
                settingsChanged()
            }),
            SwitchRow("Only worktrees that OverSire started", note: "Worktrees that you made in Orca stay.", on: c.onlyOurs) { AGENTS.cleanup.onlyOurs = $0 },
            SwitchRow("Run the repo archive hooks", note: "orca worktree rm --run-hooks. A failed hook stops the removal.", on: c.runHooks) {
                AGENTS.cleanup.runHooks = $0
            },
            safe,
        ]))
    }

    private func intakeAndPlanner(_ b: NSStackView) {
        let promptOpen = Self.intakePromptOpen
        let editPrompt = ActionButton(promptOpen ? "Close prompt" : "Edit prompt") { [weak self] in
            Self.intakePromptOpen.toggle()
            self?.reload()
        }
        var rows: [NSView] = [
            SwitchRow("Enhance vague items", note: "Start Enhance for a new intake item with a short note.", on: AGENTS.enhanceVague) { AGENTS.enhanceVague = $0 },
            SwitchRow("Enhance in a scratch worktree", note: ".wt/enhance-<key>, not the main checkout", on: AGENTS.intakeScratch,
                      actions: [editPrompt]) { AGENTS.intakeScratch = $0 },
        ]
        if promptOpen { rows.append(intakePrompt()) }
        rows += plannerRows()
        b.addFull(section(.planner, rows))
        if Self.areasOpen, let pk = plannerKey { b.addFull(areasCard(pk)) }
        if !hasCloud {
            b.addFull(NSStackView(h: [PlannerCard.cloudMark(), NSTextField.text(
                "The Planner needs OverSire Cloud. It orders each queue lane, so that two items do not change the same code area at the same time.",
                size: 12, color: Palette.dim, lines: 2), Spacer()], spacing: 8))
        }
    }

    private func intakePrompt() -> NSView {
        if !promptDirty { promptView.string = AGENTS.intakePrompt }
        promptView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        promptView.isRichText = false
        promptView.textColor = Palette.fg
        promptView.backgroundColor = Palette.raise
        promptView.delegate = self
        promptView.setAccessibilityLabel("Enhance prompt")
        let scroll = NSScrollView()
        scroll.documentView = promptView
        scroll.hasVerticalScroller = true
        promptView.autoresizingMask = [.width]
        promptView.isVerticallyResizable = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        let reset = ActionButton("Reset") { [weak self] in
            AGENTS.intakePrompt = AgentsConfig.defaultIntakePrompt
            saveConfig()
            self?.promptDirty = false
            self?.reload()
        }
        let save = ActionButton("Save", style: .primary) { [weak self] in
            guard let self else { return }
            AGENTS.intakePrompt = self.promptView.string
            saveConfig()
            self.promptDirty = false
            self.reload()
        }
        let v = NSStackView(v: [], spacing: 8)
        v.addFull(scroll)
        v.addFull(NSStackView(h: [NSTextField.text("{{key}}, {{title}}, {{url}} and {{text}} take the values of the item. {{#if vision}}…{{/if}} and {{#if ask}}…{{/if}} show only with a value.",
                                                   size: 11.5, color: Palette.dim, lines: 2), Spacer(), reset, save], spacing: 8))
        return Padded(v)
    }

    private var plannerKey: String? {
        let projects = data.projectStore.tracked
        return projects.first { $0.ref.storeKey == plannerProject }?.ref.storeKey ?? projects.first?.ref.storeKey
    }

    private func plannerRows() -> [NSView] {
        let projects = data.projectStore.tracked
        guard let pk = plannerKey else { return [Padded(EmptyNote("Track a project first.", symbol: "folder"))] }
        let book = data.planner
        let s = book.settings(pk)
        let p = projects.first { $0.ref.storeKey == pk }
        let pick = MenuChip(p?.identifier ?? pk, symbol: "folder") { [weak self] in
            projects.map { p in MenuAction(p.title) { self?.plannerProject = p.ref.storeKey; self?.reload() } }
        }
        pick.setAccessibilityLabel("Planner project")
        let modes: [PlannerSettings.Mode] = [.off, .hourly, .live]
        let modeNote: String
        switch s.mode {
        case .off: modeNote = "Off: no plan changes. The queue still holds items whose area is busy."
        case .live: modeNote = "Live: a check about 2 minutes after a change."
        default: modeNote = "Hourly: at most one check each hour. A held item gets a check at once."
        }
        let n = book.catalog(pk).areas.count
        let areas = ActionButton(Self.areasOpen ? "Close areas" : "Areas") { [weak self] in
            Self.areasOpen.toggle()
            self?.reload()
        }
        let shared: [PlannerSettings.SharedFeature] = [.serial, .parallel]
        let mode = Segmented(["Off", "Hourly", "Live"], selected: modes.firstIndex(of: s.mode) ?? 1, label: "Planner") { i in book.update(pk) { $0.mode = modes[i] } }
        mode.toolTip = modeNote
        return [
            Row([TwoLine("Planner", "\(p?.identifier ?? pk) · \(n == 1 ? "1 area" : "\(n) areas")"), Spacer(), pick, mode, areas], height: 52, label: "Planner"),
            FieldRow("Feature areas", note: "Core areas are always one at a time.",
                     Segmented(["One at a time", "Allow two at once"], selected: shared.firstIndex(of: s.sharedFeature) ?? 0, label: "Feature areas") { i in
                book.update(pk) { $0.sharedFeature = shared[i] }
            }),
        ]
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

}
