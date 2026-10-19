import Cocoa
import OverSireCore

// A switch with a title and a note. It saves the config when it flips.
final class SwitchRow: Row {
    private let flip: (Bool) -> Void

    init(_ title: String, note: String? = nil, on: Bool, enabled: Bool = true, actions: [NSView] = [], _ flip: @escaping (Bool) -> Void) {
        self.flip = flip
        let sw = NSSwitch()
        sw.state = on ? .on : .off
        sw.isEnabled = enabled
        sw.controlSize = .small
        sw.setAccessibilityLabel(title)
        super.init([TwoLine(title, note, weight: .medium), Spacer()] + actions + [sw], height: note == nil ? 40 : 52, label: title)
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
    let promptView = NSTextView()
    var promptDirty = false
    var plannerProject: String?

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
        case .agents: agents(body)
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
