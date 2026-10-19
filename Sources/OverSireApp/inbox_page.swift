import Cocoa
import OverSireCore

// One line of the inbox, from Plane, GitHub, Orca, the AI checks or the intake.
struct InboxEntry {
    enum Source: String {
        case plane = "Plane", mention = "Mention", run = "GitHub", agent = "Orca", ai = "AI", intake = "Intake"
        var tab: Route.InboxTab {
            switch self {
            case .plane: return .all
            case .mention: return .mentions
            case .run: return .runs
            case .agent, .ai: return .agents
            case .intake: return .intake
            }
        }
        var color: NSColor {
            switch self {
            case .plane, .run: return Palette.mut
            case .mention: return Palette.acc
            case .agent: return Palette.warn
            case .ai: return Palette.acc
            case .intake: return Palette.intake
            }
        }
    }

    let id: String
    let source: Source
    let title: String
    let body: String
    let at: Date
    var unread: Bool
    let route: Route?
    var url: String? = nil
    var intake: (projectKey: String, item: IntakeItem)? = nil
    var activityId: String? = nil
    /// The other Plane changes of the same item and day, in this one line.
    var groupedIds: [String] = []
    var itemKey: String? = nil
    var itemURL: String? = nil
    var projectKey: String? = nil     // "SLING"
    var priority: String? = nil       // "High"; nil counts as "None"
    /// The item of a Plane change, also when the item is gone.
    var groupKey: String? = nil
}

// The project and priority filters of the Inbox. An empty set lets each entry pass.
struct InboxFilter: Codable, Equatable {
    static let noProject = "No project"
    static let noPriority = "None"
    private static let projectsKey = "inbox.filter.projects", prioritiesKey = "inbox.filter.priorities"

    var projects: Set<String> = []
    var priorities: Set<String> = []

    var isOn: Bool { !projects.isEmpty || !priorities.isEmpty }

    func pass(_ e: InboxEntry) -> Bool {
        (projects.isEmpty || projects.contains(e.projectKey ?? Self.noProject))
            && (priorities.isEmpty || priorities.contains(e.priority ?? Self.noPriority))
    }

    // The priority name of a raw value ("high" or "High"). Other values give nil.
    static func priorityName(_ raw: String?) -> String? {
        guard let r = raw?.lowercased() else { return nil }
        return StatusOption.priorities.first { $0.id == r || $0.name.lowercased() == r }?.name
    }

    static func load(_ d: UserDefaults = .standard) -> InboxFilter {
        InboxFilter(projects: Set(d.stringArray(forKey: projectsKey) ?? []), priorities: Set(d.stringArray(forKey: prioritiesKey) ?? []))
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(projects.sorted(), forKey: Self.projectsKey)
        d.set(priorities.sorted(), forKey: Self.prioritiesKey)
    }
}

// Builds the inbox and keeps the read state of the lines that are not Plane activity.
final class InboxFeed {
    private static let readKey = "inboxRead"
    private var read: Set<String>

    init() { read = Set(UserDefaults.standard.stringArray(forKey: InboxFeed.readKey) ?? []) }

    func entries(_ data: AppData) -> [InboxEntry] {
        let store = data.projectStore
        var out: [InboxEntry] = []
        for e in store.activity(limit: 200, project: nil) {
            let found = store.item(e.itemId)
            let key = found?.item.key ?? ""
            let source: InboxEntry.Source = { if case .mention = e.change { return .mention }; return .plane }()
            let title = found.map { "\($0.item.key) \($0.item.title)" } ?? "A removed item"
            out.append(InboxEntry(id: "plane|" + e.id, source: source, title: title,
                                  body: (e.actor.map { "\($0): " } ?? "") + e.text, at: e.at, unread: e.unread,
                                  route: key.isEmpty ? nil : .item(key, .activity), url: e.url, activityId: e.id,
                                  itemKey: found?.item.key, itemURL: found?.item.url, groupKey: "\(e.projectKey)|\(e.itemId)"))
        }
        out = Self.grouped(out)
        let day = Date().addingTimeInterval(-86400)
        for (repo, runs) in data.grouped {
            for r in latestPerWorkflow(runs) where r.status == "completed" && lastActivity(r) > day && (r.isFailure || data.workstreams.link(runId: r.id) != nil) {
                let t = Tone(r)
                let link = data.workstreams.link(runId: r.id)
                let id = "run|\(r.id)|\(r.attempt ?? 1)"
                out.append(InboxEntry(id: id, source: .run, title: "\(r.workflowName ?? r.name) #\(r.number) · \(t.word)",
                                      body: "\(repo) · \(r.headBranch)" + (link.map { " · \($0.key)" } ?? ""),
                                      at: lastActivity(r), unread: !read.contains(id), route: .run(repo: repo, id: r.id), url: r.url))
            }
        }
        for (key, a) in data.agentIndex.agents where a.phase != .working && a.phase != .starting {
            let id = "agent|\(key)|\(a.phase)|\(Int(a.since.timeIntervalSince1970))"
            let st = data.agentIndex.state(key)
            let title = a.phase == .waiting ? "\(key) session asks a question" : a.phase == .done ? "\(key) · \((st ?? .done).label)" : "\(key) session did not start"
            out.append(InboxEntry(id: id, source: .agent, title: title, body: a.message ?? "",
                                  at: a.since, unread: !read.contains(id), route: .item(key, .session),
                                  itemKey: key, itemURL: store.item(key: key)?.2.url))
        }
        for c in data.aiChecks.checks.prefix(30) {
            let id = "ai|" + c.id
            out.append(InboxEntry(id: id, source: .ai, title: "AI check: \(c.key) · \(c.verdict.word)",
                                  body: c.evidence.joined(separator: " · "), at: c.at,
                                  unread: c.state == .pending && !read.contains(id), route: .agents, itemKey: c.key))
        }
        for (pk, snap) in store.snapshots {
            for i in snap.intake ?? [] {
                let num = store.intakeKeys[i.workItemId].map { "\(snap.summary.identifier)-\($0)" } ?? snap.summary.identifier
                out.append(InboxEntry(id: "intake|" + i.id, source: .intake, title: "\(num) \(i.name)",
                                      body: [i.author.map { "by \($0)" }, i.priority, i.source?.replacingOccurrences(of: "_", with: " ").lowercased()]
                                        .compactMap { $0 }.joined(separator: " · "),
                                      at: i.createdAt, unread: true, route: nil, intake: (pk, i)))
            }
        }
        let resolver = ProjectResolver(PROJECTS_CFG)
        for i in out.indices {
            var e = out[i]
            if let (pk, item) = e.intake {
                e.projectKey = store.snapshots[pk]?.summary.identifier.uppercased()
                e.priority = InboxFilter.priorityName(item.priority)
            } else if let found = (e.itemKey ?? linkedKey(e, data)).flatMap({ store.item(key: $0) }) {
                e.projectKey = found.snap.summary.identifier.uppercased()
                e.priority = InboxFilter.priorityName(found.item.fields["Priority"])
            } else if case .run(let repo, _) = e.route {
                e.projectKey = resolver.project(forRepo: repo)
            }
            out[i] = e
        }
        return out.sorted { $0.at > $1.at }
    }

    /// One line for the Plane changes of one item on one day. The newest change shows, plus the count.
    static func grouped(_ list: [InboxEntry], calendar: Calendar = .current) -> [InboxEntry] {
        var out: [InboxEntry] = []
        var at: [String: Int] = [:]
        for e in list.sorted(by: { $0.at > $1.at }) {
            guard e.source == .plane, let key = e.groupKey ?? e.itemKey, e.activityId != nil else { out.append(e); continue }
            let k = "\(key)|\(calendar.startOfDay(for: e.at).timeIntervalSince1970)"
            guard let i = at[k] else { at[k] = out.count; out.append(e); continue }
            out[i].groupedIds.append(e.activityId!)
            out[i].unread = out[i].unread || e.unread
        }
        for i in out.indices where !out[i].groupedIds.isEmpty {
            let e = out[i]
            out[i] = InboxEntry(id: e.id, source: e.source, title: e.title, body: "\(e.groupedIds.count + 1) changes · last: \(e.body)", at: e.at,
                                unread: e.unread, route: e.route, url: e.url, activityId: e.activityId, groupedIds: e.groupedIds,
                                itemKey: e.itemKey, itemURL: e.itemURL, groupKey: e.groupKey)
        }
        return out
    }

    // The item of a run line.
    private func linkedKey(_ e: InboxEntry, _ data: AppData) -> String? {
        if case .run(_, let id) = e.route { return data.workstreams.link(runId: id)?.key }
        return nil
    }

    func markRead(_ e: InboxEntry, store: ProjectStore) {
        if let a = e.activityId { ([a] + e.groupedIds).forEach(store.markActivityRead); return }
        read.insert(e.id)
        save()
    }

    func markUnread(_ e: InboxEntry, store: ProjectStore) {
        if let a = e.activityId { ([a] + e.groupedIds).forEach(store.markActivityUnread); return }
        read.remove(e.id)
        save()
    }

    func markAllRead(_ list: [InboxEntry], store: ProjectStore) {
        for e in list where e.unread && e.source != .intake {
            if let a = e.activityId { ([a] + e.groupedIds).forEach(store.markActivityRead) } else { read.insert(e.id) }
        }
        save()
    }

    private func save() {
        UserDefaults.standard.set(Array(read.suffix(2000)), forKey: InboxFeed.readKey)
        NotificationCenter.default.post(name: AppWindow.changed, object: nil)
    }
}

// An inbox line. Intake lines take the triage keys 1, 2, 3 and H.
final class InboxRow: TableRow {
    static let layout = ColumnLayout(id: "inbox", columns: [
        TableColumn(id: "unread", title: "", width: 7, min: 7),
        TableColumn(id: "source", title: "Source", width: 64, min: 48),
        TableColumn(id: "title", title: "Title", width: 300, min: 160, flexible: true),
        TableColumn(id: "when", title: "When", width: 56, min: 40, optional: true),
    ])
    /// The Intake tab has one source only.
    static let intakeLayout = ColumnLayout(id: "inbox-intake", columns: layout.columns.filter { $0.id != "source" })
    var onKey: ((String) -> Bool)?

    init(_ e: InboxEntry, layout: ColumnLayout = InboxRow.layout, onClick: @escaping () -> Void) {
        let dot = Box(fill: e.unread ? Palette.acc : .clear, border: nil, radius: 3.5)
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        let cells: [String: NSView] = [
            "unread": dot,
            "source": Chiplet(e.source.rawValue, color: e.source.color),
            "title": TwoLine(e.title, e.body, weight: e.unread ? .semibold : .regular),
            "when": NSTextField.text(relativeTime(e.at), size: 11.5, color: Palette.dim),
        ]
        super.init(layout, cells: cells, height: 48,
                   label: (e.unread ? "Unread. " : "") + "\(e.source.rawValue): \(e.title). \(e.body)", onClick: onClick)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func keyDown(with event: NSEvent) {
        if let c = event.charactersIgnoringModifiers?.lowercased(), event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           onKey?(c) == true { return }
        super.keyDown(with: event)
    }
}

final class InboxPage: Page {
    private let feed = InboxFeed()
    private var busy: Set<String> = []
    private var note: String?
    private var filter = InboxFilter.load() { didSet { filter.save(); reload() } }
    private weak var projectChip: MenuChip?
    private weak var priorityChip: MenuChip?
    private let more = MoreRows()
    private lazy var needsYou = NeedsYouCard(page: self)
    override var buildsLater: Bool { true }

    private var tab: Route.InboxTab {
        guard case .inbox(let t) = route, Route.InboxTab.visible(data.has, cloud: hasCloud).contains(t) else { return .all }
        return t
    }

    override func build(_ col: NSStackView) {
        pageBusy = data.loadingFirst
        let all = feed.entries(data)
        commands.intercept = { [weak self] c in
            guard let self else { return false }
            switch c {
            case .markRead(let id, let read):
                guard let e = all.first(where: { $0.id == id }) else { return true }
                if read { self.feed.markRead(e, store: self.data.projectStore) } else { self.feed.markUnread(e, store: self.data.projectStore) }
                self.reload()
            case .triage(let id):
                if let (pk, item) = all.first(where: { $0.id == id })?.intake { self.data.intakeAgent.start(projectKey: pk, item: item) }
            case .onlyProject(let k): self.filter.projects = [k]
            default: return false
            }
            return true
        }
        for (pk, snap) in data.projectStore.snapshots where !(snap.intake ?? []).isEmpty {
            data.projectStore.loadIntakeKeys(projectKey: pk) { [weak self] in self?.reload() }
        }
        let tabs = Route.InboxTab.visible(data.has, cloud: hasCloud)
        let kept = all.filter(filter.pass)
        let plans = hasCloud ? data.suggestions.openPlans() : []
        let counts = tabs.map { t in t == .suggestions ? plans.count : kept.filter { t == .all ? true : $0.source.tab == t }.count }
        col.addFull(PageHeader("Inbox", caption: "Plane, GitHub, Orca and AI checks in one list. Intake waits for triage.",
                               actions: [ActionButton("Mark all read", symbol: "checkmark") { [weak self] in
            guard let self else { return }
            self.feed.markAllRead(kept, store: self.data.projectStore)
        }]))
        let strip = TabStrip(tabs.map { $0.rawValue.capitalized }, selected: tabs.firstIndex(of: tab) ?? 0, counts: counts)
        strip.onSelect = { [weak self] i in self?.go(.inbox(tabs[i])) }
        col.addArrangedSubview(strip)
        if tab == .suggestions {
            suggestions(col, plans)
            return
        }
        col.addArrangedSubview(filterBar(all.filter { tab == .all || $0.source.tab == tab }))
        if let note { col.addFull(Banner(.info, title: note)) }
        if tab == .agents, let c = needsYou.card() { col.addFull(c) }
        if tab == .intake {
            col.addFull(NSTextField.text("Keys on a focused line: 1 accept · 2 duplicate · 3 decline · H snooze one day. Tab moves between lines.",
                                         size: 12, color: Palette.dim, lines: 2))
        }
        let shown = kept.filter { tab == .all || $0.source.tab == tab }
        let list = ListCard()
        if !shown.isEmpty { list.add(TableHeader(tab == .intake ? InboxRow.intakeLayout : InboxRow.layout)) }
        list.add(shown, more: more) { [unowned self] in self.row($0) }
        if list.isEmpty, data.loadingFirst { list.add(LoadingNote("Loading the inbox")) }
        if list.isEmpty {
            list.add(EmptyNote(filter.isOn ? "No entry matches the filters." : tab == .intake ? "No intake waits for triage." : "Nothing here. Inbox zero."))
        }
        col.addFull(list)
    }

    private func suggestions(_ col: NSStackView, _ list: [Suggestion]) {
        col.addFull(NSStackView(h: [NSTextField.text("The Planner proposes the order, blockers and code areas. Nothing changes before you accept.",
                                                     size: 12, color: Palette.dim, lines: 2), Spacer(), PlannerCard.cloudMark()], spacing: 8))
        if list.isEmpty { col.addFull(EmptyNote("No open plan changes.", symbol: "lightbulb")) }
        for s in list { if let d = s.plan { col.addFull(planCard(s, draft: d)) } }
    }

    // The Project and Priority chips. A menu value shows its count in this tab, with the other filter on.
    private func filterBar(_ inTab: [InboxEntry]) -> NSView {
        let projects = InboxPage.counts(inTab.filter { filter.priorities.isEmpty || filter.priorities.contains($0.priority ?? InboxFilter.noPriority) }) {
            $0.projectKey ?? InboxFilter.noProject
        }
        let priorities = InboxPage.counts(inTab.filter { filter.projects.isEmpty || filter.projects.contains($0.projectKey ?? InboxFilter.noProject) }) {
            $0.priority ?? InboxFilter.noPriority
        }
        let order = StatusOption.priorities.map(\.name)
        let p = chip("Project", filter.projects, projects.sorted { ($0.key == InboxFilter.noProject ? 1 : 0, $0.key) < ($1.key == InboxFilter.noProject ? 1 : 0, $1.key) }) {
            [weak self] in self?.filter.projects = $0
        }
        let q = chip("Priority", filter.priorities, priorities.sorted { (order.firstIndex(of: $0.key) ?? 9) < (order.firstIndex(of: $1.key) ?? 9) }) {
            [weak self] in self?.filter.priorities = $0
        }
        projectChip = p
        priorityChip = q
        var views: [NSView] = [p, q]
        if filter.isOn { views.append(Chiplet("Clear", symbol: "xmark", color: Palette.acc) { [weak self] in self?.filter = InboxFilter() }) }
        views.append(Spacer())
        views.append(NSTextField.text("P project · ⇧P priority · ⌘⌫ clear", size: 11.5, color: Palette.dim))
        return NSStackView(h: views, spacing: 8)
    }

    private func chip(_ name: String, _ picked: Set<String>, _ values: [(key: String, value: Int)], set: @escaping (Set<String>) -> Void) -> MenuChip {
        let text = picked.isEmpty ? "Any" : picked.count == 1 ? picked.first! : "\(picked.count) picked"
        let c = MenuChip("\(name): \(text)", symbol: "chevron.down", color: picked.isEmpty ? Palette.mut : Palette.fg) {
            let any = MenuAction("Any") { set([]) }
            any.item.state = picked.isEmpty ? .on : .off
            return [any] + values.map { v in
                let a = MenuAction("\(v.key)  \(v.value)") { set(picked.symmetricDifference([v.key])) }
                a.item.state = picked.contains(v.key) ? .on : .off
                return a
            }
        }
        if !picked.isEmpty { c.border = Palette.acc }
        c.setAccessibilityLabel("\(name) filter: \(text)")
        return c
    }

    static func counts(_ list: [InboxEntry], by key: (InboxEntry) -> String) -> [String: Int] {
        list.reduce(into: [:]) { $0[key($1), default: 0] += 1 }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 51, mods == .command, filter.isOn { filter = InboxFilter(); return }
        if event.charactersIgnoringModifiers?.lowercased() == "p", mods.isEmpty || mods == .shift {
            (mods.isEmpty ? projectChip : priorityChip)?.onClick?()
            return
        }
        super.keyDown(with: event)
    }

    private func row(_ e: InboxEntry) -> NSView {
        var actions: [NSView] = []
        if let (pk, item) = e.intake {
            if busy.contains(item.id) {
                actions.append(Spinner())
            } else {
                if data.intakeAgent.available && data.intakeAgent.state(item) == nil {
                    actions.append(ActionButton("Check in Orca", symbol: "sparkles", style: .primary) { [weak self] in
                        self?.data.intakeAgent.start(projectKey: pk, item: item)
                    })
                }
                actions.append(ActionButton("Accept  1") { [weak self] in self?.triage(pk, item, .accept) })
                actions.append(ActionButton("Duplicate  2") { IntakeWindow.show(projectKey: pk, workItemId: item.workItemId) })
                actions.append(ActionButton("Decline  3") { [weak self] in self?.triage(pk, item, .decline) })
                actions.append(ActionButton("Snooze  H") { [weak self] in self?.triage(pk, item, .snooze(until: Date().addingTimeInterval(86400))) })
            }
        }
        actions.forEach { ($0 as? NSButton)?.controlSize = .small }
        let r = InboxRow(e, layout: tab == .intake ? InboxRow.intakeLayout : InboxRow.layout) { [weak self] in self?.open(e) }
        if e.intake == nil, let key = e.itemKey, let url = e.itemURL {
            r.itemActions(url: url, key: key)
        } else if e.intake == nil, e.source == .run, let url = e.url {
            r.copyLink = url
            r.hoverViews = [IconButton("link", label: "Copy link", tip: "Copy link (⇧⌘C)", copy: url),
                            IconButton("arrow.up.right.square", label: "Open on GitHub", tip: "Open on GitHub") { NSWorkspace.shared.open(URL(string: url)!) }]
        } else {
            r.hoverViews = actions
        }
        if let (pk, item) = e.intake {
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
        }
        let canTriage = e.intake.map { data.intakeAgent.available && data.intakeAgent.state($0.item) == nil } ?? false
        commands.attach(r) { _ in RowMenu.inbox(e, projectKey: e.projectKey, canTriage: canTriage) }
        guard let (pk, item) = e.intake, let state = data.intakeAgent.state(item) else { return r }
        let panel = IntakePanel(state, projectKey: pk, item: item, agent: data.intakeAgent) { [weak self] err in
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

    private func open(_ e: InboxEntry) {
        if e.unread && e.intake == nil { feed.markRead(e, store: data.projectStore) }
        if let (pk, item) = e.intake { IntakeWindow.show(projectKey: pk, workItemId: item.workItemId); return }
        if let r = e.route { go(r) }
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

// A menu item that runs a closure. Keep the object alive with the item.
final class MenuAction: NSObject {
    private let run: () -> Void
    let item: NSMenuItem

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        super.init()
        item.action = #selector(fire)
        item.target = self
        item.representedObject = self
    }

    @objc private func fire() { run() }
}
