import Cocoa
import OverSireCore

// One line of the feed, from Plane, GitHub, Orca, the AI checks or the intake.
struct FeedEntry {
    enum Source: String, CaseIterable {
        case plane = "Plane", mention = "Mention", run = "GitHub", agent = "Orca", ai = "AI", intake = "Intake"
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
    let route: Route?
    var url: String? = nil
    var intake: (projectKey: String, item: IntakeItem)? = nil
    var activityId: String? = nil
    /// The other Plane changes of the same item and day, in this one line.
    var groupedIds: [String] = []
    var itemKey: String? = nil
    var itemURL: String? = nil
    var projectKey: String? = nil     // "SLING"
    var intakeKey: String? = nil      // "SLING-102"; nil while the number loads

    /// Changes when the line must update.
    var rowHash: Int {
        PageRow.hash([id, source.rawValue, title, body, at, route.map { String(describing: $0) }, url, intake?.item.id, activityId,
                      groupedIds, itemKey, itemURL, projectKey, intakeKey])
    }

    /// The ID cell of an intake line. "SLING-–" while the number loads: never the work item UUID.
    var shownID: String { intakeKey ?? "\(projectKey ?? "")-–" }
    /// The item of a Plane change, also when the item is gone.
    var groupKey: String? = nil
}

// The Project and Source filters of Activity. An empty set lets each entry pass.
struct FeedFilter: Codable, Equatable {
    static let noProject = "No project"
    private static let projectsKey = "activity.filter.projects", sourcesKey = "activity.filter.sources"

    var projects: Set<String> = []
    var sources: Set<String> = []

    var isOn: Bool { !projects.isEmpty || !sources.isEmpty }

    func pass(_ e: FeedEntry) -> Bool {
        (projects.isEmpty || projects.contains(e.projectKey ?? Self.noProject))
            && (sources.isEmpty || sources.contains(e.source.rawValue))
    }

    static func load(_ d: UserDefaults = .standard) -> FeedFilter {
        FeedFilter(projects: Set(d.stringArray(forKey: projectsKey) ?? []), sources: Set(d.stringArray(forKey: sourcesKey) ?? []))
    }

    func save(_ d: UserDefaults = .standard) {
        d.set(projects.sorted(), forKey: Self.projectsKey)
        d.set(sources.sorted(), forKey: Self.sourcesKey)
    }
}

// Builds the Activity feed and the Intake list. The feed keeps no read state.
enum ActivityFeed {
    static func entries(_ data: AppData) -> [FeedEntry] {
        let store = data.projectStore
        var out: [FeedEntry] = []
        for e in store.activity(limit: 200, project: nil) {
            let found = store.item(e.itemId)
            let key = found?.item.key ?? ""
            let source: FeedEntry.Source = { if case .mention = e.change { return .mention }; return .plane }()
            let title = found.map { "\($0.item.key) \($0.item.title)" } ?? "A removed item"
            out.append(FeedEntry(id: "plane|" + e.id, source: source, title: title, body: (e.actor.map { "\($0): " } ?? "") + e.text, at: e.at,
                                     route: key.isEmpty ? nil : .item(key, .activity), url: e.url, activityId: e.id,
                                     itemKey: found?.item.key, itemURL: found?.item.url, groupKey: "\(e.projectKey)|\(e.itemId)"))
        }
        out = grouped(out)
        let day = Date().addingTimeInterval(-86400)
        for (repo, runs) in data.grouped {
            for r in latestPerWorkflow(runs) where r.status == "completed" && lastActivity(r) > day && (r.isFailure || data.workstreams.link(runId: r.id) != nil) {
                let link = data.workstreams.link(runId: r.id)
                out.append(FeedEntry(id: "run|\(r.id)|\(r.attempt ?? 1)", source: .run, title: "\(r.workflowName ?? r.name) #\(r.number) · \(Tone(r).word)",
                                         body: "\(repo) · \(r.headBranch)" + (link.map { " · \($0.key)" } ?? ""),
                                         at: lastActivity(r), route: .run(repo: repo, id: r.id), url: r.url, itemKey: link?.key))
            }
        }
        for (key, a) in data.agentIndex.agents where a.phase != .working && a.phase != .starting {
            let st = data.agentIndex.state(key)
            let title = a.phase == .waiting ? "\(key) session asks a question" : a.phase == .done ? "\(key) · \((st ?? .done).label)" : "\(key) session did not start"
            out.append(FeedEntry(id: "agent|\(key)|\(a.phase)|\(Int(a.since.timeIntervalSince1970))", source: .agent, title: title,
                                     body: a.message ?? "", at: a.since, route: .item(key, .session),
                                     itemKey: key, itemURL: store.item(key: key)?.2.url))
        }
        for r in data.cleaner.records {
            out.append(FeedEntry(id: "cleanup|\(r.at.timeIntervalSince1970)|\(r.text)", source: .agent, title: r.text, body: "Cleanup · Plane does not change",
                                 at: r.at, route: .item(r.key, .overview), itemKey: r.key, itemURL: store.item(key: r.key)?.2.url))
        }
        for c in data.statusJob.statuses.prefix(30) where c.byAI && c.state != .working {
            out.append(FeedEntry(id: "ai|" + c.id, source: .ai, title: "Status: \(c.key) · \(c.word)", body: c.reply.headline, at: c.at,
                                     route: .item(c.key, .session), itemKey: c.key))
        }
        let resolver = ProjectResolver(PROJECTS_CFG)
        for i in out.indices {
            if let k = out[i].itemKey, let found = store.item(key: k) {
                out[i].projectKey = found.snap.summary.identifier.uppercased()
            } else if case .run(let repo, _) = out[i].route {
                out[i].projectKey = resolver.project(forRepo: repo)
            }
        }
        return out.sorted { $0.at > $1.at }
    }

    /// The intake items that wait for triage, the newest first.
    static func intake(_ data: AppData) -> [FeedEntry] {
        let store = data.projectStore
        var out: [FeedEntry] = []
        for (pk, snap) in store.snapshots {
            for i in snap.intake ?? [] {
                var e = FeedEntry(id: "intake|" + i.id, source: .intake, title: i.name,
                                      body: [i.author.map { "by \($0)" }, i.priority, i.source?.replacingOccurrences(of: "_", with: " ").lowercased()]
                                        .compactMap { $0 }.joined(separator: " · "),
                                      at: i.createdAt, route: nil, intake: (pk, i))
                e.projectKey = snap.summary.identifier.uppercased()
                e.intakeKey = store.intakeKeys[i.workItemId].map { "\(snap.summary.identifier)-\($0)" }
                out.append(e)
            }
        }
        return out.sorted { $0.at > $1.at }
    }

    /// One line for the Plane changes of one item on one day. The newest change shows, plus the count.
    static func grouped(_ list: [FeedEntry], calendar: Calendar = .current) -> [FeedEntry] {
        var out: [FeedEntry] = []
        var at: [String: Int] = [:]
        for e in list.sorted(by: { $0.at > $1.at }) {
            guard e.source == .plane, let key = e.groupKey ?? e.itemKey, e.activityId != nil else { out.append(e); continue }
            let k = "\(key)|\(calendar.startOfDay(for: e.at).timeIntervalSince1970)"
            guard let i = at[k] else { at[k] = out.count; out.append(e); continue }
            out[i].groupedIds.append(e.activityId!)
        }
        for i in out.indices where !out[i].groupedIds.isEmpty {
            let e = out[i]
            out[i] = FeedEntry(id: e.id, source: e.source, title: e.title, body: "\(e.groupedIds.count + 1) changes · last: \(e.body)", at: e.at,
                                   route: e.route, url: e.url, activityId: e.activityId, groupedIds: e.groupedIds,
                                   itemKey: e.itemKey, itemURL: e.itemURL, groupKey: e.groupKey)
        }
        return out
    }
}

// A feed line. Intake lines show the item ID in place of the source and take the triage keys 1, Q, 2, 3 and H.
final class FeedLine: TableRow {
    static let layout = ColumnLayout(id: "activity", columns: [
        TableColumn(id: "source", title: "Source", width: 64, min: 48),
        TableColumn(id: "title", title: "What", width: 300, min: 160, flexible: true),
        TableColumn(id: "when", title: "When", width: 56, min: 40, optional: true),
    ])
    static let intakeLayout = ColumnLayout(id: "intake", columns: [
        TableColumn(id: "id", title: "ID", width: 96, min: 64),
        TableColumn(id: "title", title: "Title", width: 300, min: 160, flexible: true),
        TableColumn(id: "when", title: "When", width: 56, min: 40, optional: true),
    ])
    var onKey: ((String) -> Bool)?

    /// `badge` shows after the title, for example the Enhance pill of an intake line.
    init(_ e: FeedEntry, layout: ColumnLayout = FeedLine.layout, badge: NSView? = nil, onClick: @escaping () -> Void) {
        let title = TwoLine(e.title, e.body)
        let cells: [String: NSView] = [
            "source": Chiplet(e.source.rawValue, color: e.source.color),
            "id": Chiplet(e.shownID, color: e.intakeKey == nil ? Palette.dim : Palette.intake),
            "title": badge.map { NSStackView(h: [title, $0], spacing: 8) } ?? title,
            "when": RelativeTimeLabel(e.at),
        ]
        super.init(layout, cells: cells, height: 48, label: "\(e.intakeKey.map { $0 + " " } ?? "")\(e.source.rawValue): \(e.title). \(e.body)", onClick: onClick)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func keyDown(with event: NSEvent) {
        if let c = event.charactersIgnoringModifiers?.lowercased(), event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           onKey?(c) == true { return }
        super.keyDown(with: event)
    }
}

// Activity: the full feed. No unread state, no badge: Home and Intake hold what needs you.
final class ActivityPage: Page {
    override var fillsHeight: Bool { true }
    private var filter = FeedFilter.load() { didSet { filter.save(); reload() } }
    private weak var projectChip: MenuChip?
    private weak var sourceChip: MenuChip?
    private let more = MoreRows()
    override var buildsLater: Bool { true }

    override var watches: DataDomains { [.projects, .runs, .agents, .intake, .summaries, .questions, .config] }

    override func sections() -> [PageSection]? {
        pageBusy = data.loadingFirst
        let all = ActivityFeed.entries(data)
        commands.intercept = { [weak self] c in
            guard let self, case .onlyProject(let k) = c else { return false }
            self.filter.projects = [k]
            return true
        }
        let header = PageRow("header", 0) { PageHeader("Activity", caption: "Plane, GitHub, Orca and AI in one feed. The newest is first.") }
        let bar = filterBarRow(all)
        let shown = all.filter(filter.pass)
        var rows = PageRow.limited(shown, more: more, reload: { [weak self] in self?.reload() }) { [weak self] e in
            PageRow(e.id, hash: e.rowHash) { self?.row(e) ?? NSView() }
        }
        if rows.isEmpty {
            let loading = data.loadingFirst, on = filter.isOn
            rows = [PageRow(loading ? "loading" : "empty", on) {
                loading ? LoadingNote("Loading the activity") : EmptyNote(on ? "No entry matches the filters." : "No activity yet.")
            }]
        }
        let table = shown.isEmpty ? nil : FeedLine.layout
        let list = PageRow.list(table == nil ? "list.plain" : "list", rows: rows) { StickyListCard.table(table) }
        return [PageSection("top", rows: [header, bar]), PageSection("feed", rows: [list])]
    }

    private func filterBarRow(_ all: [FeedEntry]) -> PageRow {
        let counts = ActivityPage.counts(all) { ($0.projectKey ?? FeedFilter.noProject) + "|" + $0.source.rawValue }
        return PageRow("filters", filter.projects, filter.sources, counts, full: false) { [weak self] in self?.filterBar(all) ?? NSView() }
    }

    // The Project and Source chips. A menu value shows its count with the other filter on.
    private func filterBar(_ all: [FeedEntry]) -> NSView {
        let projects = ActivityPage.counts(all.filter { filter.sources.isEmpty || filter.sources.contains($0.source.rawValue) }) {
            $0.projectKey ?? FeedFilter.noProject
        }
        let sources = ActivityPage.counts(all.filter { filter.projects.isEmpty || filter.projects.contains($0.projectKey ?? FeedFilter.noProject) }) {
            $0.source.rawValue
        }
        let order = FeedEntry.Source.allCases.map(\.rawValue)
        let none = FeedFilter.noProject
        let p = chip("Project", filter.projects, projects.sorted { ($0.key == none ? 1 : 0, $0.key) < ($1.key == none ? 1 : 0, $1.key) }) {
            [weak self] in self?.filter.projects = $0
        }
        let s = chip("Source", filter.sources, sources.sorted { (order.firstIndex(of: $0.key) ?? 9) < (order.firstIndex(of: $1.key) ?? 9) }) {
            [weak self] in self?.filter.sources = $0
        }
        projectChip = p
        sourceChip = s
        var views: [NSView] = [p, s]
        if filter.isOn { views.append(Chiplet("Clear", symbol: "xmark", color: Palette.acc) { [weak self] in self?.filter = FeedFilter() }) }
        views.append(Spacer())
        views.append(NSTextField.text("P project · ⇧P source · ⌘⌫ clear", size: 11.5, color: Palette.dim))
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

    static func counts(_ list: [FeedEntry], by key: (FeedEntry) -> String) -> [String: Int] {
        list.reduce(into: [:]) { $0[key($1), default: 0] += 1 }
    }

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if event.keyCode == 51, mods == .command, filter.isOn { filter = FeedFilter(); return }
        if event.charactersIgnoringModifiers?.lowercased() == "p", mods.isEmpty || mods == .shift {
            (mods.isEmpty ? projectChip : sourceChip)?.onClick?()
            return
        }
        super.keyDown(with: event)
    }

    private func row(_ e: FeedEntry) -> NSView {
        let r = FeedLine(e) { [weak self] in
            if let route = e.route { self?.go(route) } else if let u = e.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
        }
        if e.source == .run, let url = e.url {
            r.copyLink = url
            r.hoverViews = [IconButton("link", label: "Copy link", tip: "Copy link (⇧⌘C)", copy: url),
                            IconButton("arrow.up.right.square", label: "Open on GitHub", tip: "Open on GitHub") { NSWorkspace.shared.open(URL(string: url)!) }]
        } else if let key = e.itemKey, let url = e.itemURL {
            r.itemActions(url: url, key: key)
        }
        commands.attach(r) { _ in RowMenu.activity(e, projectKey: e.projectKey, canTriage: false) }
        return r
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
