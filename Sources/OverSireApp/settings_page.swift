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

    private var page: Route.SettingsPage { if case .settings(let p) = route { return p }; return .general }
    private var app: GHActionsBar? { NSApp.delegate as? GHActionsBar }

    override var isEditing: Bool { super.isEditing || promptDirty }

    override func build(_ col: NSStackView) {
        col.addFull(PageHeader("Settings", caption: "OverSire saves each change at once to \((CONFIG_PATH as NSString).abbreviatingWithTildeInPath)."))
        let nav = ListCard()
        for p in Route.SettingsPage.allCases {
            let r = Row([Glyph(symbol(p), size: 13), NSTextField.text(p.title, size: 12.5, weight: p == page ? .semibold : .regular), Spacer()],
                        height: 32, label: p.title) { [weak self] in self?.go(.settings(p)) }
            r.selected = p == page
            nav.add(r)
        }
        let body = NSStackView(v: [], spacing: 10)
        switch page {
        case .general: general(body)
        case .accounts: embed(body, note: "Plane accounts, projects, quick capture and the Orca workspace of each project. GitHub uses the gh login of this Mac.")
        case .repos: embed(body, note: "The GitHub repos and organizations that OverSire polls.")
        case .linking: linking(body)
        case .writeback: writeBack(body)
        case .live: live(body)
        case .orca: orca(body)
        case .queue: queue(body)
        case .ai: ai(body)
        case .notifications: notifications(body)
        case .menubar: menuBar(body)
        case .shortcuts: shortcuts(body)
        }
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        let navCol = NSStackView(v: [], spacing: 0)
        navCol.addFull(nav)
        navCol.addArrangedSubview(filler)
        let two = NSStackView(h: [navCol, body], spacing: 16, align: .top)
        col.addFull(two)
        navCol.widthAnchor.constraint(equalToConstant: 210).isActive = true
        body.widthAnchor.constraint(equalTo: two.widthAnchor, constant: -226).isActive = true
    }

    private func symbol(_ p: Route.SettingsPage) -> String {
        switch p {
        case .general: return "gearshape"
        case .accounts: return "person.crop.circle"
        case .repos: return "shippingbox"
        case .linking: return "link"
        case .writeback: return "square.and.pencil"
        case .live: return "dot.radiowaves.left.and.right"
        case .orca: return "terminal"
        case .queue: return "list.number"
        case .ai: return "sparkles"
        case .notifications: return "bell"
        case .menubar: return "menubar.rectangle"
        case .shortcuts: return "keyboard"
        }
    }

    private func card(_ title: String, _ rows: [NSView]) -> NSView {
        let c = ListCard()
        rows.forEach { c.add($0) }
        let v = NSStackView(v: [SectionTitle(title)], spacing: 6)
        v.addFull(c)
        return v
    }

    private func segmented(_ labels: [String], selected: Int, label: String, _ pick: @escaping (Int) -> Void) -> NSView {
        let s = NSSegmentedControl(labels: labels, trackingMode: .selectOne, target: nil, action: nil)
        s.selectedSegment = selected
        s.controlSize = .small
        s.setAccessibilityLabel(label)
        let box = ClosureTarget { pick(s.selectedSegment); saveConfig(); NotificationCenter.default.post(name: AppWindow.changed, object: nil) }
        s.target = box
        s.action = #selector(ClosureTarget.fire)
        objc_setAssociatedObject(s, "target", box, .OBJC_ASSOCIATION_RETAIN)
        return s
    }

    // MARK: Pages

    private func general(_ b: NSStackView) {
        let themes = Theme.allCases
        b.addFull(card("Look", [
            FieldRow("Theme", note: "System follows the macOS setting.", segmented(themes.map(\.label), selected: themes.firstIndex(of: GENERAL.theme) ?? 1, label: "Theme") { [weak self] i in
                GENERAL.theme = themes[i]
                self?.app?.applySystemAppearance()
                self?.view.window?.appearance = NSApp.appearance
            }),
            FieldRow("Show in", note: "The window opens from both. The menu bar keeps a short view.", showIn()),
            SwitchRow("Open the window at launch", on: GENERAL.openWindowAtLaunch) { GENERAL.openWindowAtLaunch = $0 },
        ]))
        embed(b, page: .general, note: "Accounts, tabs and updates.")
    }

    private func showIn() -> NSView {
        let all = ShowIn.allCases
        let names = ["Menu bar", "Dock", "Both"]
        return segmented(all.map { names[all.firstIndex(of: $0)!] }, selected: all.firstIndex(of: GENERAL.showIn) ?? 2, label: "Show in") { [weak self] i in
            GENERAL.showIn = all[i]
            self?.app?.applyShowIn()
        }
    }

    private func linking(_ b: NSStackView) {
        b.addFull(card("Rules", [
            SwitchRow("Orca card name", note: "The card is named after the item key, as FRITZ-28.", on: LINKING.card) { LINKING.card = $0 },
            SwitchRow("Worktree folder", note: "A checkout in .wt/<key>/.", on: LINKING.folder) { LINKING.folder = $0 },
            SwitchRow("Branch prefix", note: "A branch <key>/… or <key>-…, as fritz-28/desktop-app.", on: LINKING.prefix) { LINKING.prefix = $0 },
            SwitchRow("Run branch", note: "The run branch is the branch of a linked checkout.", on: LINKING.branch) { LINKING.branch = $0 },
            SwitchRow("Run commit", note: "The run head commit is the HEAD of a linked checkout.", on: LINKING.head) { LINKING.head = $0 },
            SwitchRow("Pull request", note: "The PR of the branch names the key.", on: LINKING.pr) { LINKING.pr = $0 },
            SwitchRow("Commit title", note: "The commit title names the key.", on: LINKING.trailer) { LINKING.trailer = $0 },
        ]))
        let f = NSTextField()
        f.placeholderString = "Type a branch or card name, as fritz-28/desktop-app"
        f.stringValue = branchTest
        f.delegate = self
        f.identifier = NSUserInterfaceItemIdentifier("branchTest")
        f.setAccessibilityLabel("Branch to test")
        let known = Set(data.projectStore.tracked.map { $0.identifier.uppercased() })
        let t = branchTest.trimmingCharacters(in: .whitespaces)
        let result: String
        if t.isEmpty { result = "OverSire shows the item that the name links to." }
        else if let k = WorkstreamIndex.key(inBranch: t, known: known) { result = "Links to \(k) by the branch prefix." }
        else if let k = WorkstreamIndex.key(in: t, known: known, whole: true) { result = "Links to \(k) by the card or folder name." }
        else { result = "No link. The name does not start with the key of a tracked project (\(known.sorted().prefix(6).joined(separator: ", ")))." }
        let c = Card(title: "Test a name")
        c.add(f)
        c.add(NSTextField.text(result, size: 12.5, color: t.isEmpty ? Palette.dim : Palette.fg, lines: 0))
        b.addFull(c)
    }

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField, f.identifier?.rawValue == "branchTest" else { return }
        branchTest = f.stringValue
        reload()
        if let nf = view.findField("branchTest") { view.window?.makeFirstResponder(nf); nf.currentEditor()?.selectedRange = NSRange(location: nf.stringValue.count, length: 0) }
    }

    private func writeBack(_ b: NSStackView) {
        let on = AGENTS.writeBack.enabled
        b.addFull(Banner(.info, title: "OverSire does not overwrite text that people wrote.",
                         body: "It adds links and labels, and keeps its own block between markers at the end of the body."))
        b.addFull(card("Write back to Plane", [
            SwitchRow("Write back", note: "Turn off to keep Plane read only.", on: on) { AGENTS.writeBack.enabled = $0 },
            SwitchRow("Links", note: "Add the ChangeRequest, run and worktree links once.", on: AGENTS.writeBack.links, enabled: on) { AGENTS.writeBack.links = $0 },
            SwitchRow("Session labels", note: "session:working, session:needs-input, session:done.", on: AGENTS.writeBack.labels, enabled: on) { AGENTS.writeBack.labels = $0 },
            SwitchRow("OverSire block", note: "Status, worktree, CI and PR at the end of the body.", on: AGENTS.writeBack.block, enabled: on) { AGENTS.writeBack.block = $0 },
            SwitchRow("Session comment", note: "One comment with the session summary when the session ends. Needs AI.", on: AGENTS.writeBack.sessionComment, enabled: on) { AGENTS.writeBack.sessionComment = $0 },
            SwitchRow("Move to In review", note: "Set the status when the PR opens.", on: AGENTS.writeBack.moveToReview, enabled: on) { AGENTS.writeBack.moveToReview = $0 },
        ]))
    }

    private func orca(_ b: NSStackView) {
        let o = PROJECTS_CFG.orca
        let ready = data.agentIndex.ready != nil
        b.addFull(Banner(o.enabled ? (ready ? .ok : .warning) : .idle,
                         title: o.enabled ? (ready ? "Orca is on." : "Orca is on, but OverSire could not read it.") : "Orca is off.",
                         body: "CLI \(o.cli) · \(o.environment.map { "environment \($0)" } ?? "this Mac") · agent \(o.agent)",
                         actions: [ActionButton("Edit Orca settings") { [weak self] in self?.go(.settings(.accounts)) }]))
        var rows: [NSView] = []
        for p in data.projectStore.tracked.sorted(by: { $0.identifier < $1.identifier }) {
            let root = o.roots[p.ref.storeKey].flatMap { $0.isEmpty ? nil : $0 }
            rows.append(FieldRow(p.identifier, note: p.title, NSTextField.text(root.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No workspace", size: 12,
                                                                              color: root == nil ? Palette.dim : Palette.mut, mono: true)))
        }
        if rows.isEmpty { rows.append(EmptyNote("No tracked Plane projects.")) }
        b.addFull(card("Orca workspace of each project", rows))
    }

    private func live(_ b: NSStackView) {
        let normal = MenuChip("\(Int(POLL_NORMAL)) s", symbol: "clock") {
            [15, 30, 60, 120, 300].map { s in MenuAction("\(s) s") { [weak self] in POLL_NORMAL = TimeInterval(s); self?.pollChanged() } }
        }
        let active = MenuChip("\(Int(POLL_ACTIVE)) s", symbol: "clock") {
            [5, 10, 20, 30].map { s in MenuAction("\(s) s") { [weak self] in POLL_ACTIVE = TimeInterval(s); self?.pollChanged() } }
        }
        b.addFull(card("Polling", [
            FieldRow("Poll GitHub each", note: "When the cloud is off, and for repos without a webhook.", normal),
            FieldRow("While you look at a run in progress", note: "The popover is open and a run is in progress.", active),
        ]))
        embed(b, note: "OverSire cloud sends GitHub and Plane webhooks to this Mac, so pages update in seconds, not at the next poll. With the cloud live, a poll only checks the state at the reconcile time. Set up the cloud with the oversire/cloud repo, then connect here with its URL and a device token.")
    }

    private func pollChanged() {
        saveConfig()
        app?.scheduleTimer()
        NotificationCenter.default.post(name: AppWindow.changed, object: nil)
    }

    private func queue(_ b: NSStackView) {
        let modes = AIMode.allCases
        let quiet = MenuChip("\(Int(AGENTS.quietMinutes)) min", symbol: "clock") {
            [5, 10, 15, 30, 60].map { m in MenuAction("\(m) min") { AGENTS.quietMinutes = Double(m); saveConfig(); NotificationCenter.default.post(name: AppWindow.changed, object: nil) } }
        }
        b.addFull(card("Queue", [
            SwitchRow("Auto start", note: "Start the next item when a slot is free and its condition holds.", on: AGENTS.autoStart) { AGENTS.autoStart = $0 },
            FieldRow("AI checks", note: "Ask me shows a card. Auto acts at once.",
                     segmented(modes.map(\.label), selected: modes.firstIndex(of: AGENTS.aiMode) ?? 1, label: "AI checks") { AGENTS.aiMode = modes[$0] }),
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
        c.add(NSTextField.text("{KEY}, {title}, {url} and {body} take the values of the item.", size: 11.5, color: Palette.dim))
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
        embed(b, page: .ai, note: "Endpoint, model and API key. The key stays in the Keychain.")
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
                         actions: [ActionButton("Open project settings") { [weak self] in self?.go(.settings(.accounts)) }]))
    }

    private func menuBar(_ b: NSStackView) {
        b.addFull(card("Menu bar", [
            FieldRow("Show in", showIn()),
            SwitchRow("Small popover", note: "Now, Runs and Work. Off: the full popover of OverSire 1.", on: GENERAL.smallPopover) { GENERAL.smallPopover = $0 },
            SwitchRow("Runs tab", on: TABS.actions) { TABS.actions = $0 },
            SwitchRow("Pull requests tab", on: TABS.prs) { TABS.prs = $0 },
            SwitchRow("Insights tab", on: TABS.insights) { TABS.insights = $0 },
        ]))
        b.addFull(NSTextField.text("The icon is blue while a run is in progress, red for a failed run that no one ignored, else green. A dot shows a session that waits for you, or unread Plane activity.", size: 12, color: Palette.dim, lines: 0))
    }

    private func shortcuts(_ b: NSStackView) {
        let f = ShortcutField(GENERAL.windowKey)
        f.onChange = { [weak self] code, mods in
            GENERAL.windowKey = KeyShortcut(keyCode: code, modifiers: mods)
            saveConfig()
            _ = self?.app?.applyWindowHotKey()
        }
        f.setAccessibilityLabel("Window shortcut")
        b.addFull(card("Global", [
            FieldRow("Open the window", note: "From any app.", f),
            FieldRow("New item", note: "Set in Accounts › quick capture.", NSTextField.text(PROJECTS_CFG.capture.shortcutLabel, size: 12, color: Palette.mut, mono: true)),
        ]))
        let keys: [(String, String)] = [("⌘K", "Search or jump to a page"), ("⌘[  ⌘]", "Back and forward"), ("⌘R", "Refresh"),
                                         ("⌃⌘S", "Show or hide the sidebar"), ("⌘0", "Bring the window to the front"),
                                         ("1  2  3  H", "Intake: accept, duplicate, decline, snooze"), ("⌘,", "Settings")]
        b.addFull(card("In the window", keys.map { FieldRow($0.1, NSTextField.text($0.0, size: 12, color: Palette.mut, mono: true)) }))
    }

    // MARK: Embedded settings

    private func embed(_ b: NSStackView, page p: Route.SettingsPage? = nil, note: String) {
        let p = p ?? page
        b.addFull(NSTextField.text(note, size: 12, color: Palette.dim, lines: 0))
        let key = "\(p.rawValue)-\(NSApp.appearance?.name.rawValue ?? "system")"
        var vc = SettingsPage.embedded[key]
        if vc == nil {
            NSApp.withPinnedAppearance {
                vc = data.settingsVC(p)
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
