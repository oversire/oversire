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

    override func build(_ col: NSStackView) {
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
        var actions: [NSView] = []
        if agent.available, !open.isEmpty {
            let b = ActionButton("Enhance all", symbol: "sparkles", style: .primary) { [weak self] in
                open.forEach { agent.start(projectKey: $0.projectKey, item: $0.item) }
                self?.reload()
            }
            b.setAccessibilityLabel("Enhance all \(open.count) items")
            actions.append(b)
        }
        let today = IntakeListPage.addedToday(all)
        col.addFull(PageHeader("Intake", caption: "\(all.count) items wait for triage" + (today > 0 ? " · +\(today) today" : ""), actions: actions))
        let strip = TabStrip(["All"] + counts.map(\.project), selected: selected, counts: [all.count] + counts.map(\.count))
        strip.onSelect = { [weak self] i in self?.go(.intake(tabs[i])) }
        col.addArrangedSubview(strip)
        if let note { col.addFull(Banner(.info, title: note)) }
        if !shown.isEmpty {
            col.addFull(NSTextField.text("Keys on a focused line: 1 accept · 2 duplicate · 3 decline · H snooze one day. Tab moves between lines.",
                                         size: 12, color: Palette.dim, lines: 2))
            col.addFull(NSStackView(h: [Glyph("sparkles", color: Palette.acc, size: 11), NSTextField.text(
                "Enhance: an agent reads the code, asks you what the code cannot tell, and writes a new description. You check what goes to Plane.",
                size: 12, color: Palette.dim, lines: 2)], spacing: 6))
        }
        let list = StickyListCard.table(shown.isEmpty ? nil : FeedLine.intakeLayout)
        list.add(shown, more: more) { [unowned self] in self.row($0) }
        if list.isEmpty, data.loadingFirst { list.add(LoadingNote("Loading the intake")) }
        if list.isEmpty { list.add(EmptyNote("No intake waits for triage.")) }
        col.addFull(list)
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
