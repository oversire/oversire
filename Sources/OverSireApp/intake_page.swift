import Cocoa
import OverSireCore

// Intake: the items that wait for triage, with a tab for each project. The AI suggestion shows under its row.
final class IntakeListPage: Page {
    override var fillsHeight: Bool { true }
    private var busy: Set<String> = []
    private var note: String?
    private let more = MoreRows()
    override var buildsLater: Bool { true }

    /// The count for each project, the largest first.
    static func counts(_ list: [FeedEntry]) -> [(project: String, count: Int)] {
        Dictionary(grouping: list) { $0.projectKey ?? FeedFilter.noProject }
            .map { (project: $0.key, count: $0.value.count) }
            .sorted { ($1.count, $0.project) < ($0.count, $1.project) }
    }

    static func addedToday(_ list: [FeedEntry], now: Date = Date(), calendar: Calendar = .current) -> Int {
        list.filter { calendar.isDate($0.at, inSameDayAs: now) }.count
    }

    override var watches: DataDomains { [.projects, .intake, .questions, .config] }

    override func sections() -> [PageSection]? {
        pageBusy = data.loadingFirst
        for (pk, snap) in data.projectStore.snapshots where !(snap.intake ?? []).isEmpty {
            data.projectStore.loadIntakeKeys(projectKey: pk) { [weak self] in self?.reload() }
        }
        let all = ActivityFeed.intake(data)
        let counts = IntakeListPage.counts(all)
        let tabs: [String?] = [nil] + counts.map(\.project)
        var project: String?
        if case .intake(let p) = route { project = p }
        let selected = tabs.firstIndex(of: project) ?? 0
        let shown = all.filter { selected == 0 || $0.projectKey == tabs[selected] }

        commands.intercept = { [weak self] c in
            guard let self, case .triage(let id) = c else { return false }
            if let (pk, item) = all.first(where: { $0.id == id })?.intake { self.data.intakeAgent.start(projectKey: pk, item: item) }
            return true
        }
        let agent = data.intakeAgent
        let open = shown.compactMap(\.intake).filter { agent.state($0.item) == nil }
        let canEnhance = agent.available && !open.isEmpty
        let today = IntakeListPage.addedToday(all)
        let caption = "\(all.count) items wait for triage" + (today > 0 ? " · +\(today) today" : "")
        var top: [PageRow] = [
            PageRow("header", caption, canEnhance ? open.count : -1) { [weak self] in
                var actions: [NSView] = []
                if canEnhance {
                    let b = ActionButton("Enhance all", symbol: "sparkles", style: .primary) {
                        open.forEach { agent.start(projectKey: $0.projectKey, item: $0.item) }
                        self?.reload()
                    }
                    b.setAccessibilityLabel("Enhance all \(open.count) items")
                    actions.append(b)
                }
                return PageHeader("Intake", caption: caption, actions: actions)
            },
            PageRow("strip", selected, counts.map { "\($0.project) \($0.count)" }, all.count, full: false) { [weak self] in
                let strip = TabStrip(["All"] + counts.map(\.project), selected: selected, counts: [all.count] + counts.map(\.count))
                strip.onSelect = { i in self?.go(.intake(tabs[i])) }
                return strip
            },
        ]
        if let note { top.append(PageRow("note", note) { Banner(.info, title: note) }) }
        if !shown.isEmpty {
            top.append(PageRow("keys", 0) {
                NSTextField.text("Keys on a focused line: 1 accept · Q accept and queue · 2 duplicate · 3 decline · H snooze one day. Tab moves between lines.",
                                 size: 12, color: Palette.dim, lines: 2)
            })
            top.append(PageRow("enhance", 0) {
                NSStackView(h: [Glyph("sparkles", color: Palette.acc, size: 11), NSTextField.text(
                    "Enhance: an agent reads the code, asks you what the code cannot tell, and writes a new description. You check what goes to Plane.",
                    size: 12, color: Palette.dim, lines: 2)], spacing: 6)
            })
        }
        var rows = PageRow.limited(shown, more: more, reload: { [weak self] in self?.reload() }) { [weak self] e in
            let state = e.intake.flatMap { agent.state($0.item) }.map { String(describing: $0) }
            return PageRow(e.id, e.rowHash, state, e.intake.map { self?.busy.contains($0.item.id) ?? false }, agent.available) {
                self?.row(e) ?? NSView()
            }
        }
        if rows.isEmpty {
            let loading = data.loadingFirst
            rows = [PageRow(loading ? "loading" : "empty", 0) { loading ? LoadingNote("Loading the intake") : EmptyNote("No intake waits for triage.") }]
        }
        let table = shown.isEmpty ? nil : FeedLine.intakeLayout
        let list = PageRow.list(table == nil ? "list.plain" : "list", rows: rows) { StickyListCard.table(table) }
        return [PageSection("top", rows: top), PageSection("intake", rows: [list])]
    }

    private func row(_ e: FeedEntry) -> NSView {
        guard let (pk, item) = e.intake else { return NSView() }
        let agent = data.intakeAgent
        var actions: [NSView] = []
        if busy.contains(item.id) {
            actions.append(Spinner())
        } else {
            if agent.available && agent.state(item) == nil {
                actions.append(ActionButton("Enhance", symbol: "sparkles", style: .primary) { agent.start(projectKey: pk, item: item) })
            }
            actions.append(ActionButton("Accept  1") { [weak self] in self?.triage(pk, item, .accept) })
            actions.append(ActionButton("Accept and queue  Q") { [weak self] in self?.queue(pk, item) })
            actions.append(ActionButton("Duplicate  2") { IntakeWindow.show(projectKey: pk, workItemId: item.workItemId) })
            actions.append(ActionButton("Decline  3") { [weak self] in self?.triage(pk, item, .decline) })
            actions.append(ActionButton("Snooze  H") { [weak self] in self?.triage(pk, item, .snooze(until: Date().addingTimeInterval(86400))) })
        }
        actions.forEach { ($0 as? NSButton)?.controlSize = .small }
        let pill = agent.state(item).flatMap { IntakeAgent.pill($0) }.map { Pill($0.tone, text: $0.text) }
        let r = FeedLine(e, layout: FeedLine.intakeLayout, badge: pill) { IntakeWindow.show(projectKey: pk, workItemId: item.workItemId) }
        r.hoverViews = actions
        r.onKey = { [weak self] c in
            switch c {
            case "1": self?.triage(pk, item, .accept)
            case "q": self?.queue(pk, item)
            case "2": IntakeWindow.show(projectKey: pk, workItemId: item.workItemId)
            case "3": self?.triage(pk, item, .decline)
            case "h": self?.triage(pk, item, .snooze(until: Date().addingTimeInterval(86400)))
            default: return false
            }
            return true
        }
        let canTriage = agent.available && agent.state(item) == nil
        commands.attach(r) { _ in RowMenu.activity(e, projectKey: nil, canTriage: canTriage) }
        guard let state = agent.state(item) else { return r }
        let panel = IntakePanel(state, projectKey: pk, item: item, agent: agent, questions: data.questions) { [weak self] err in
            self?.note = err
            self?.reload()
        }
        let v = NSStackView(v: [r, panel], spacing: 6)
        r.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        panel.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -28).isActive = true
        v.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        v.alignment = .centerX
        return v
    }

    // Accepts the item and adds the start label. Checked Enhance changes go with it.
    private func queue(_ pk: String, _ item: IntakeItem) {
        busy.insert(item.id)
        reload()
        data.intakeAgent.apply(projectKey: pk, item: item, accept: true, queue: true) { [weak self] err in
            guard let self else { return }
            self.busy.remove(item.id)
            self.note = err
            self.reload()
        }
    }

    private func triage(_ pk: String, _ item: IntakeItem, _ action: IntakeAction) {
        busy.insert(item.id)
        reload()
        data.projectStore.triage(projectKey: pk, item: item, action: action) { [weak self] ok in
            guard let self else { return }
            self.busy.remove(item.id)
            self.note = ok ? nil : (self.data.projectStore.lastError ?? "Plane did not accept the change.")
            self.reload()
        }
    }
}
