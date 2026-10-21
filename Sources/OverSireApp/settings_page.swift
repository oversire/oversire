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
        ChangeBus.shared.post(.config())
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
    private static var query = ""
    private static var hit = 0
    private static var flash: String?
    private let nav = ListCard()
    private lazy var search = SettingsSearchField(Self.query)
    private var hits: [SettingsIndex.Entry] = []
    private var scrolled: Route?
    private weak var pane: NSScrollView?
    override var fillsHeight: Bool { true }
    private var branchTest = ""
    let promptView = NSTextView()
    var promptDirty = false
    var plannerProject: String?

    private var page: Route.SettingsPage { if case .settings(let p, _, _) = route { return p }; return .general }
    private var tab: Route.SettingsTab { if case .settings(_, let t?, _) = route { return t }; return .projects }
    private var anchor: String? { if case .settings(_, _, let a) = route { return a }; return nil }
    var app: GHActionsBar? { NSApp.delegate as? GHActionsBar }

    override var isEditing: Bool { super.isEditing || promptDirty }
    override var watches: DataDomains { [.config, .connection] }

    override func build(_ col: NSStackView) {
        col.addFull(PageHeader("Settings", caption: "OverSire saves each change at once to \((CONFIG_PATH as NSString).abbreviatingWithTildeInPath)."))
        search.onChange = { [weak self] q in
            Self.query = q
            Self.hit = 0
            self?.renderNav()
        }
        search.onMove = { [weak self] d in
            guard let self else { return }
            Self.hit = max(0, min(self.hits.count - 1, Self.hit + d))
            self.renderNav()
        }
        search.onOpen = { [weak self] in
            guard let self, self.hits.indices.contains(Self.hit) else { return }
            self.open(self.hits[Self.hit])
        }
        renderNav()
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
                let repos = RepoListView(catalog: data.repoCatalog, setup: data.cloudSetup, filter: anchor.flatMap { filters[$0] } ?? .all) { [weak self] f in
                    self?.go(.settings(.projects, tab: .repos, anchor: filters.first { $0.value == f }?.key))
                }
                repos.identifier = SettingsAnchor.repos.id
                body.addFull(repos)
            case .linking: linking(body); writeBack(body)
            }
        case .agents: agents(body)
        case .ai: ai(body)
        case .notifications: notifications(body)
        case .logs: logs(body)
        }
        let navCol = NSStackView(v: [], spacing: 8)
        navCol.addFull(search)
        navCol.addFull(nav)
        let two = SidePane(side: navCol, body: body, sideWidth: 210, keep: "settings-\(route)")
        pane = two.pane
        col.addFull(two)
        if let a = anchor, route != scrolled {
            scrolled = route
            let flash = Self.flash
            Self.flash = nil
            DispatchQueue.main.async { [weak self] in self?.reveal(a, flash: flash) }
        }
    }

    // MARK: Search

    // The 6 pages, or the matches while the field has text.
    private func renderNav() {
        nav.list.clear()
        hits = SettingsIndex.search(Self.query)
        if Self.query.trimmingCharacters(in: .whitespaces).isEmpty {
            for p in Route.SettingsPage.allCases {
                let n = p == .logs ? data.openProblems.count ?? 0 : 0
                var cells: [NSView] = [Glyph(p.symbol, size: 13), NSTextField.text(p.title, size: 12.5, weight: p == page ? .semibold : .regular), Spacer()]
                if n > 0 { cells.append(NSTextField.text("▲ \(n)", size: 11.5, weight: .semibold, color: Palette.warn)) }
                let r = Row(cells, height: 32, label: n > 0 ? "\(p.title), \(n) problem\(n == 1 ? "" : "s")" : p.title) { [weak self] in self?.go(.settings(p)) }
                r.selected = p == page
                nav.add(r)
            }
        } else if hits.isEmpty {
            nav.add(Padded(NSTextField.text("No setting matches.", size: 12, color: Palette.dim), vertical: 10, side: 12))
        } else {
            for (i, e) in hits.enumerated() {
                let r = Row([TwoLine(e.title, e.anchor.path, titleSize: 12.5, lines: 1)], height: 44, label: "\(e.title), \(e.anchor.path)") { [weak self] in self?.open(e) }
                r.selected = i == Self.hit
                nav.add(r)
            }
        }
    }

    private func open(_ e: SettingsIndex.Entry) {
        Self.query = ""
        Self.hit = 0
        search.stringValue = ""
        Self.flash = e.title
        scrolled = nil
        if e.anchor.route == route { reload() } else { go(e.anchor.route) }
    }

    @objc func focusSearch(_ sender: Any?) {
        view.window?.makeFirstResponder(search)
    }

    // Scrolls to the section, and flashes the row with the title.
    private func reveal(_ anchor: String, flash: String?) {
        guard let scroll = pane, let doc = scroll.documentView, let section = doc.find(NSUserInterfaceItemIdentifier("anchor-" + anchor)) else { return }
        doc.layoutSubtreeIfNeeded()
        let target = flash.flatMap { t in section.findBox { $0.accessibilityLabel() == t } }
        let top = section.convert(section.bounds, to: doc).minY
        var y = top - 8
        if let target {
            let r = target.convert(target.bounds, to: doc)
            if r.maxY > y + scroll.contentView.bounds.height { y = r.minY - 80 }
        }
        scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, min(y, doc.frame.height - scroll.contentView.bounds.height))))
        scroll.reflectScrolledClipView(scroll.contentView)
        (target ?? (flash != nil ? section.findBox { $0 is ListCard } : nil))?.flash()
    }

    // A titled card. A route anchor and the search scroll to it.
    func section(_ anchor: SettingsAnchor, _ rows: [NSView]) -> NSView {
        let c = ListCard()
        rows.forEach { c.add($0) }
        let v = NSStackView(v: [SectionTitle(anchor.title)], spacing: 6)
        v.addFull(c)
        v.identifier = anchor.id
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
        b.addFull(section(.linking, [Padded(body)]))
    }

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField, f.identifier?.rawValue == "branchTest" else { return }
        branchTest = f.stringValue
        reload()
        if let nf = view.findField("branchTest") { view.window?.makeFirstResponder(nf); nf.currentEditor()?.selectedRange = NSRange(location: nf.stringValue.count, length: 0) }
    }

    private func writeBack(_ b: NSStackView) {
        let on = AGENTS.writeBack.enabled
        b.addFull(section(.writeback, [
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
    func find(_ id: NSUserInterfaceItemIdentifier) -> NSView? {
        if identifier == id { return self }
        for s in subviews { if let v = s.find(id) { return v } }
        return nil
    }

    func findBox(_ match: (Box) -> Bool) -> Box? {
        if let b = self as? Box, match(b) { return b }
        for s in subviews { if let v = s.findBox(match) { return v } }
        return nil
    }

    func findField(_ id: String) -> NSTextField? {
        if let f = self as? NSTextField, f.identifier?.rawValue == id { return f }
        for s in subviews { if let f = s.findField(id) { return f } }
        return nil
    }
}
