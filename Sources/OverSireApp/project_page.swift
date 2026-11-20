import Cocoa
import OverSireCore

// One item in a page list: status, key, title, sub-items, agent (with a spinner while CI runs), priority, assignee, time.
final class ItemLine: TableRow {
    static func columns(keyWidth: CGFloat = 104) -> [TableColumn] {
        [TableColumn(id: "status", title: "", width: 16, min: 16),
         TableColumn(id: "key", title: "ID", width: keyWidth, min: 60),
         TableColumn(id: "title", title: "Title", width: 200, min: 160, flexible: true),
         TableColumn(id: "sub", title: "Sub", width: 52, min: 36, optional: true),
         TableColumn(id: "session", title: "Status", width: 132, min: 60, optional: true),
         TableColumn(id: "priority", title: "Priority", width: 72, min: 50, optional: true),
         TableColumn(id: "who", title: "Who", width: 34, min: 24, optional: true),
         TableColumn(id: "updated", title: "Updated", width: 60, min: 44, optional: true)]
    }

    init(_ item: Item, snap: ProjectSnapshot, stream: Workstream?, status: ItemStatus?, layout: ColumnLayout, commands: RowCommander? = nil,
         cleanup: [CleanupLine] = [], go: @escaping (Route) -> Void) {
        let opt = snap.option(item.statusOptionId)
        let finish = ItemLine.finishChip(item, snap: snap, cleanup: cleanup)
        var cells: [String: NSView] = [
            "status": StatusGlyph.item(item, snap: snap).sized(16),
            "key": NSTextField.text(item.key, size: 11.5, color: Palette.dim, mono: true),
            "title": NSTextField.text(item.title, size: 13),
            "updated": RelativeTimeLabel(item.activityAt),
        ]
        let prog = snap.progress(of: item.id)
        if prog.total > 0 {
            cells["sub"] = NSStackView(h: [ProgressRing(done: prog.done, started: snap.started(of: item.id), total: prog.total).sized(14),
                                           NSTextField.text("\(prog.done)/\(prog.total)", size: 11.5, color: Palette.dim)], spacing: 4)
        }
        cells["session"] = CIRunningMark.after(finish ?? StatusPill.or(status), stream: stream)
        if let p = item.fields["Priority"], p != "None" { cells["priority"] = Chiplet(p) }
        if let who = item.assignees.first { cells["who"] = Avatar(who) }
        let parts = [finish?.accessibilityLabel() ?? opt?.name, status?.label, stream?.ci.map { "CI \($0.word)" }, item.fields["Priority"]].compactMap { $0 }
        super.init(layout, cells: cells, label: "\(item.key) \(item.title). " + parts.joined(separator: ", ")) { go(.item(item.key, .overview)) }
        itemActions(url: item.url, key: item.key, tracker: ENV.trackerName(snap.summary.ref.account))
        commands?.attach(self) { RowMenu.item(item, snap: snap, stream: stream, local: PROJECTS_CFG.local(snap.summary.identifier), caps: $0,
                                          tracker: ENV.trackerName(snap.summary.ref.account)) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "Done · N open" for a Done item with open sub-items. "Done · cleanup" for a finished item with leftovers. Else nil.
    static func finishChip(_ item: Item, snap: ProjectSnapshot, cleanup: [CleanupLine]) -> Chiplet? {
        if snap.isDoneWithOpenSubItems(item) {
            let n = snap.openSubItems(of: item.id)
            let c = Chiplet("Done · \(n) open", symbol: "exclamationmark.triangle.fill", color: Palette.bad)
            c.toolTip = "\(ENV.trackerName(snap.summary.ref.account)) says \(snap.option(item.statusOptionId)?.name ?? "Done"), but \(n) sub-item\(n == 1 ? " is" : "s are") open."
            c.setAccessibilityLabel("Done, \(n) sub-item\(n == 1 ? "" : "s") open")
            return c
        }
        guard !cleanup.isEmpty else { return nil }
        let c = Chiplet("Done · cleanup", symbol: "bubbles.and.sparkles", color: Palette.warn)
        let kinds = cleanup.map(\.kind.noun).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        c.toolTip = "Done. \(cleanup.count) thing\(cleanup.count == 1 ? "" : "s") to clean up: \(kinds.joined(separator: ", "))"
        c.setAccessibilityLabel(c.toolTip!)
        return c
    }

    /// The values that an item line shows.
    static func hash(_ item: Item, snap: ProjectSnapshot, stream: Workstream?, status: ItemStatus?, cleanup: [CleanupLine] = []) -> Int {
        let prog = snap.progress(of: item.id)
        return PageRow.hash([item, snap.option(item.statusOptionId), prog.done, snap.started(of: item.id), prog.total, status?.label, status?.tone.word, status?.tip,
                             stream?.ci?.word, snap.isDoneWithOpenSubItems(item), snap.openSubItems(of: item.id), cleanup.map(\.kind.noun)])
    }
}

// A small spinner after a status while CI runs for the item. A passed or failed run has no mark.
enum CIRunningMark {
    static let label = "CI is running"

    static func after(_ view: NSView?, stream: Workstream?) -> NSView? {
        guard stream?.ciRunning == true else { return view }
        let s = Spinner(size: .mini)
        s.toolTip = label
        s.setAccessibilityLabel(label)
        return NSStackView(h: [view, s].compactMap { $0 }, spacing: 5)
    }
}

// Initials in a round badge. The name is the tooltip.
final class Avatar: Box {
    init(_ name: String, size: CGFloat = 20) {
        super.init(fill: projectColor(name).withAlphaComponent(0.75), border: nil, radius: size / 2)
        let words = name.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "_" })
        let initials = (words.count > 1 ? words.prefix(2).compactMap(\.first).map(String.init).joined() : String(name.prefix(2))).uppercased()
        let l = NSTextField.text(initials, size: size * 0.45, weight: .semibold, color: .white)
        addSubview(l)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size),
            l.centerXAnchor.constraint(equalTo: centerXAnchor), l.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = name
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Assignee \(name)")
    }
    required init?(coder: NSCoder) { fatalError() }
}

// A card on the board: key, title and chips.
final class BoardCard: Row {
    init(_ item: Item, snap: ProjectSnapshot, stream: Workstream?, status: ItemStatus?, commands: RowCommander? = nil, go: @escaping (Route) -> Void) {
        var chips: [NSView] = []
        if let status { chips.append(StatusPill(status)) }
        if let ci = stream?.ci { chips.append(Glyph(ci, size: 12)) }
        if let p = item.fields["Priority"], p != "None" { chips.append(Chiplet(p)) }
        let col = NSStackView(v: [NSTextField.text(item.key, size: 11, color: Palette.dim, mono: true),
                                  NSTextField.text(item.title, size: 12.5, weight: .medium, lines: 3)], spacing: 4)
        if !chips.isEmpty { col.addArrangedSubview(NSStackView(h: chips + [Spacer()], spacing: 5)) }
        super.init([col], height: 54, inset: 10, label: "\(item.key) \(item.title)") { go(.item(item.key, .overview)) }
        restFill = Palette.raise; restBorder = Palette.line; radius = 8
        itemActions(url: item.url, key: item.key, tracker: ENV.trackerName(snap.summary.ref.account))
        commands?.attach(self) { RowMenu.item(item, snap: snap, stream: stream, local: PROJECTS_CFG.local(snap.summary.identifier), caps: $0,
                                          tracker: ENV.trackerName(snap.summary.ref.account)) }
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// What a project page shows for a key with no items yet.
enum ProjectLookup: Hashable {
    case loading, failed(String), looking, untracked(canTrack: Bool)

    /// `tracked`: OverSire tracks the key. `asked`: the catalog was refreshed for the key.
    static func of(tracked: Bool, fetching: Bool, error: String?, catalogBusy: Bool, asked: Bool, inCatalog: Bool) -> ProjectLookup {
        if tracked { return !fetching ? error.map { .failed($0) } ?? .loading : .loading }
        return !asked || catalogBusy ? .looking : .untracked(canTrack: inCatalog)
    }

    /// The state for a key. An unknown key starts one catalog refresh. `changed` runs when that refresh ends.
    init(key: String, data: AppData, changed: @escaping () -> Void) {
        let store = data.projectStore, catalog = data.projectCatalog
        let summary = store.tracked.first { $0.identifier.uppercased() == key }
        var asked = true
        if summary == nil, catalog.lookUp(key) {
            asked = false
            var token: Any?
            token = NotificationCenter.default.addObserver(forName: ProjectCatalog.changed, object: catalog, queue: .main) { _ in
                guard !catalog.refreshing else { return }
                token.map(NotificationCenter.default.removeObserver)
                token = nil
                changed()
            }
        }
        let storeKey = summary?.ref.storeKey ?? ""
        self = .of(tracked: summary != nil, fetching: store.refreshing.contains(storeKey), error: store.errors[storeKey],
                   catalogBusy: catalog.refreshing, asked: asked, inCatalog: catalog.project(key: key) != nil)
    }

    func view(key: String, data: AppData?) -> NSView {
        switch self {
        case .loading: return LoadingNote("Loading the items of \(key)…")
        case .looking: return LoadingNote("Looking for \(key) in \(ENV.trackerNames())…")
        case .failed(let error):
            let retry = ActionButton("Try again", symbol: "arrow.clockwise") {
                guard let store = data?.projectStore, let p = store.tracked.first(where: { $0.identifier.uppercased() == key }) else { return }
                store.refresh([p.ref.storeKey], force: true, priority: .user) { _ in }
            }
            let name = data?.projectStore.tracked.first { $0.identifier.uppercased() == key }.map { ENV.trackerName($0.ref.account) } ?? ENV.trackerNames()
            return Banner(.bad, title: "\(name) did not give the items of \(key)", body: error, actions: [retry])
        case .untracked(let canTrack):
            if let l = data?.clientLink, l.isWaiting { return WaitingNote(data?.clientName ?? "home") }
            guard canTrack, let p = data?.projectCatalog.project(key: key) else {
                return EmptyNote("OverSire does not track \(key). \(ENV.trackerNames()) has no open project with this key.", symbol: "questionmark.folder")
            }
            let track = ActionButton("Track \(key)", symbol: "plus") {
                if !PROJECTS_CFG.picked.contains(p.ref.storeKey) { PROJECTS_CFG.picked.append(p.ref.storeKey) }
                saveConfig()
                (NSApp.delegate as? GHActionsBar)?.applyProjectSelection()
            }
            return NSStackView(v: [EmptyNote("OverSire does not track \(key).", symbol: "folder"), track], spacing: 10)
        }
    }
}

/// The three tabs of a project page. Plan is the default. The key "projectView" replaces "projectLayout".
enum ProjectTab: String, CaseIterable {
    case plan, list, board

    static let key = "projectView"

    var title: String { rawValue.capitalized }

    static func stored(_ defaults: UserDefaults = .standard) -> ProjectTab {
        ProjectTab(rawValue: defaults.string(forKey: key) ?? "") ?? .plan
    }
}

// One project: the plan, a list grouped by status, or a board.
final class ProjectPage: Page, PlanHost {
    override var fillsHeight: Bool { tab == .list || (tab == .plan && plan.segment != .summary) }
    private(set) var tab = UIShots.shooting ? .plan : ProjectTab.stored() {
        didSet { if !UIShots.shooting { UserDefaults.standard.set(tab.rawValue, forKey: ProjectTab.key) } }
    }
    private var board: Bool { tab == .board }
    let plan = PlanControls()
    /// A place on the plan that another page asks for, by project identifier. The page shows it, then clears it.
    static var pending: [String: PlanFocus] = [:]
    private var memoryWatch: NSObjectProtocol?
    // Group by epic, for all projects like the layout. A shot starts with Status and keeps the choice in memory.
    private static let groupKey = "projectGroupByEpic"
    private(set) var groupByEpic = !UIShots.shooting && UserDefaults.standard.bool(forKey: ProjectPage.groupKey)
    private var foldedEpics: Set<String> = []
    private var onlyAgent = false
    private var onlyFailing = false
    private var onlyMine = false
    private var showDone = false
    private var showSubItems = false
    private let table = ColumnLayout(id: "project-items-2", columns: ItemLine.columns())
    private var more: [String: MoreRows] = [:]   // by status option id
    override var buildsLater: Bool { true }

    private var projectKey: String { if case .project(let k) = route { return k }; return "" }

    override var watches: DataDomains { [.projects, .intake, .agents, .runs, .summaries, .config, .relations, .questions] }
    override var parts: [PagePart] { data.projectStore.key(identifier: projectKey).map { [data.projectStore.part([$0])] } ?? [] }

    override func viewed() {
        data.projectStore.key(identifier: projectKey).map(data.projectStore.viewed)
        if let f = Self.pending.removeValue(forKey: projectKey) { show(plan: f.segment, focus: f.key, epic: f.epic) }
        // The page builds before it shows, so a new visit builds again with its `since`.
        if tab == .plan, enterPlan() { reload(reason: "plan visit") }
        memoryWatch = memoryWatch ?? NotificationCenter.default.addObserver(forName: ProjectMemory.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.tab == .plan else { return }
            self.reload(reason: "north star")
        }
    }

    override func detach() {
        super.detach()
        PlanVisits.shared.leave(projectKey)
    }

    deinit { memoryWatch.map(NotificationCenter.default.removeObserver) }

    @discardableResult
    private func enterPlan() -> Bool {
        data.projectStore.key(identifier: projectKey).map(data.projectStore.loadPlan)
        return PlanVisits.shared.enter(projectKey)
    }

    /// Shows the plan in this segment. A key or an epic is the place to show; Map and Timeline use it.
    func show(plan segment: PlanView.Segment, focus key: String? = nil, epic: EpicID? = nil) {
        let entering = tab != .plan
        tab = .plan
        plan.segment = segment
        plan.focus = key != nil || epic != nil ? PlanFocus(segment: segment, key: key, epic: epic) : nil
        if entering { enterPlan() }
        reload()
    }

    func planChanged() { reload() }

    override var shownProjects: Set<String>? { snapshot.map { [$0.summary.ref.storeKey] } }

    private var snapshot: ProjectSnapshot? { data.projectStore.snapshots.values.first { $0.summary.identifier.uppercased() == projectKey } }

    override func sections() -> [PageSection]? {
        let store = data.projectStore
        pageBusy = data.projectsLoading
        let key = projectKey
        guard let snap = snapshot else {
            let lookup = ProjectLookup(key: key, data: data) { [weak self] in self?.reload() }
            return [PageSection("top", rows: [
                PageRow("header", key) { PageHeader(key, caption: "Project") },
                PageRow("lookup", key, lookup) { [weak self] in lookup.view(key: key, data: self?.data) },
            ])]
        }
        let ws = data.workstreams, job = data.statusJob
        var items = snap.listed(subItems: showSubItems)
        // A favorite sub-item shows also without Sub-items.
        if !showSubItems { items += snap.items.filter { $0.parentId != nil && FAVORITES.contains($0.key) && !items.contains($0) } }
        if onlyAgent { items = items.filter { ws.stream($0.key)?.agent != nil } }
        if onlyFailing { items = items.filter { ws.stream($0.key)?.ci?.word == Tone.bad.word } }
        if onlyMine { items = items.filter { $0.isMine(snap.me) } }
        let open = snap.notDoneCount(snap.rootItems)
        let intake = snap.intake?.count ?? 0
        let board = board, ident = snap.summary.identifier
        let hasEpics = snap.epics != nil
        let byEpic = Self.groupsByEpic(snap: snap, board: board, preferred: groupByEpic)
        let shown = tab
        let header = PageRow("header", snap.summary.title, snap.summary.url, open, intake, shown, hasEpics, groupByEpic) { [weak self] in
            var actions: [NSView] = []
            if intake > 0 {
                actions.append(ActionButton("\(intake) intake", symbol: "tray.and.arrow.down") { self?.go(.intake(key)) })
            }
            if shown != .plan, Self.showsGroupBy(snap: snap, board: board) {
                let group = NSSegmentedControl(labels: ["Status", "Epic"], trackingMode: .selectOne, target: self, action: #selector(ProjectPage.groupChanged(_:)))
                group.selectedSegment = byEpic ? 1 : 0
                group.setAccessibilityLabel("Group by")
                actions.append(group)
            }
            let seg = NSSegmentedControl(labels: ProjectTab.allCases.map(\.title), trackingMode: .selectOne, target: self, action: #selector(ProjectPage.layoutChanged(_:)))
            seg.selectedSegment = ProjectTab.allCases.firstIndex(of: shown) ?? 0
            seg.setAccessibilityLabel("Project view")
            actions.append(seg)
            if hasEpics {
                let new = ActionButton("New epic", symbol: "plus") { [weak self] in
                    guard let self else { return }
                    NewEpicSheet.present(over: self.view.window, snap: snap, data: self.data)
                }
                new.toolTip = "Make an epic in \(snap.summary.title)"
                actions.append(new)
            }
            actions.append(ActionButton("Open in \(ENV.trackerName(snap.summary.ref.account))", symbol: "arrow.up.right.square") {
                if let url = URL(string: snap.summary.url) { NSWorkspace.shared.open(url) }
            })
            let gear = ActionButton("", symbol: "gearshape") { self?.go(.projectSettings(key, .appearance)) }
            gear.toolTip = "Project settings (⌘,)"
            gear.setAccessibilityLabel("Project settings")
            actions.append(gear)
            return PageHeader(snap.summary.title, updated: { [weak store] in store?.snapshots.values.first { $0.summary.identifier == ident }?.fetchedAt },
                              caption: { "\(open) open · updated \($0)" }, actions: actions)
        }
        let flags = [onlyMine, onlyAgent, onlyFailing, showSubItems, showDone]
        let caption = byEpic ? "Grouped by epic · nearest target date first · then priority" : "Favorites first · grouped by status · sorted by priority, Done by last change"
        let filters = PageRow("filters", flags, byEpic) { [weak self] in
            NSStackView(h: [
                ToggleChip("Mine", on: flags[0]) { self?.flip(\.onlyMine) },
                ToggleChip("Has session", on: flags[1]) { self?.flip(\.onlyAgent) },
                ToggleChip("CI failing", on: flags[2]) { self?.flip(\.onlyFailing) },
                ToggleChip("Sub-items", on: flags[3]) { self?.flip(\.showSubItems) },
                ToggleChip("Show done", on: flags[4]) { self?.flip(\.showDone) },
                Spacer(),
                NSTextField.text(caption, size: 12, color: Palette.dim),
            ], spacing: 6)
        }
        if shown == .plan {
            let model = PlanModel.build(data: data, snap: snap, controls: plan)
            let controls = plan
            return [PageSection("top", rows: [header]), PageSection("plan", rows: [
                PageRow("plan", hash: model.fingerprint, update: { ($0 as? PlanView)?.show(model) }) { [weak self] in
                    self.map { PlanView(model, controls: controls, host: $0) } ?? NSView()
                },
            ])]
        }
        let top = PageSection("top", rows: [header, filters])

        if byEpic { return [top, PageSection("items", rows: [epicTable(snap, items, ws, job)])] }
        let groups = statusGroups(snap, items)
        if board {
            let hash = PageRow.hash(groups.map { g -> AnyHashable in
                [g.0.id, g.0.name, g.1.count] + g.1.prefix(25).map { AnyHashable(ItemLine.hash($0, snap: snap, stream: ws.stream($0.key), status: job.item($0.key))) }
            })
            return [top, PageSection("items", rows: [PageRow("board", hash: hash) { [weak self] in self?.boardView(groups, ws, snap) ?? NSView() }])]
        }
        var rows: [PageRow] = []
        for (opt, its) in groups where !its.isEmpty {
            rows.append(StickyListCard.group(opt.id, opt.name, count: its.count, extra: [opt.rank, opt.color] as [AnyHashable]) { [weak self] in
                [self?.groupGlyph(opt) ?? NSView()]
            })
            let m = more[opt.id] ?? MoreRows()
            more[opt.id] = m
            rows += PageRow.limited(its, more: m, reload: { [weak self] in self?.reload() }) { [weak self, table, commands] i in
                let stream = ws.stream(i.key), st = job.item(i.key), cleanup = data.cleaner.lines(i.key, data: data)
                return PageRow(i.key, hash: ItemLine.hash(i, snap: snap, stream: stream, status: st, cleanup: cleanup)) {
                    ItemLine(i, snap: snap, stream: stream, status: st, layout: table, commands: commands, cleanup: cleanup) { self?.go($0) }
                }
            }.map { r in r.id == "more" ? PageRow("more.\(opt.id)", hash: r.hash, make: r.make) : r }
        }
        if rows.isEmpty { rows = [PageRow("empty", 0) { EmptyNote("No items match the filters.", symbol: "line.3.horizontal.decrease.circle") }] }
        let table = table
        return [top, PageSection("items", rows: [PageRow.list("table", rows: rows) { StickyListCard.table(table) }])]
    }

    /// The list grouped by epic: one sticky row for each epic, then its items. "No epic" is last.
    private func epicTable(_ snap: ProjectSnapshot, _ items: [Item], _ ws: WorkstreamIndex, _ job: StatusJob) -> PageRow {
        let data = self.data, store = data.projectStore
        let blocked = Set(snap.items.filter { $0.epicId != nil && !store.blockers(of: $0.key).isEmpty }.map(\.id))
        let filtered = onlyMine || onlyAgent || onlyFailing
        let ident = snap.summary.identifier
        var rows: [PageRow] = []
        for g in Self.epicGroups(snap: snap, items: snap.groupSorted(items), blocked: blocked) {
            // Done items hide as in the status groups. An empty open epic shows, unless a filter is on.
            let hidden = showDone ? [] : g.items.filter { snap.isHiddenDone($0, afterDays: PROJECTS_CFG.hideDoneAfterDays) }
            let shown = g.items.filter { i in !hidden.contains(i) }
            if shown.isEmpty, hidden.isEmpty, filtered || g.epic == nil { continue }
            let folded = foldedEpics.contains(g.id)
            let fold = GroupFold(expanded: !folded) { [weak self] in
                if self?.foldedEpics.remove(g.id) == nil { self?.foldedEpics.insert(g.id) }
                self?.reload()
            }
            if let r = g.epic {
                let epic = r.epic
                let args: [String: JSONValue] = ["project": .string(ident), "epic": .string(epic.id.rawValue)]
                let lead = EpicGroupHeader.leadName(epic, snap: snap)
                rows.append(StickyListCard.group(g.id, g.title, count: shown.count, extra: [r, lead] as [AnyHashable], fold: fold, showCount: false, lead: {
                    EpicGroupHeader.lead(r)
                }, trailing: { [weak self] in
                    EpicGroupHeader.trailing(r, lead: lead, open: { self?.go(.epic(ident, epic.id.rawValue, .overview)) }, close: r.readyToClose ? {
                        guard let self else { return }
                        self.data.actions.click("epic.close", args, in: self.view.window, confirm: "Close \(epic.title)?")
                    } : nil)
                }))
            } else {
                rows.append(StickyListCard.group(g.id, g.title, count: shown.count, fold: fold, lead: { [Glyph("circle.dashed", color: Palette.dim, size: 13)] }))
            }
            guard fold.expanded else { continue }
            let m = more["epic." + g.id] ?? MoreRows()
            more["epic." + g.id] = m
            rows += PageRow.limited(shown, more: m, reload: { [weak self] in self?.reload() }) { [weak self, table, commands] i in
                let stream = ws.stream(i.key), st = job.item(i.key), cleanup = data.cleaner.lines(i.key, data: data)
                return PageRow(i.key, hash: ItemLine.hash(i, snap: snap, stream: stream, status: st, cleanup: cleanup)) {
                    ItemLine(i, snap: snap, stream: stream, status: st, layout: table, commands: commands, cleanup: cleanup) { self?.go($0) }
                }
            }.map { r in r.id == "more" ? PageRow("more.epic.\(g.id)", hash: r.hash, make: r.make) : r }
            if !hidden.isEmpty {
                rows.append(PageRow("hidden.\(g.id)", hidden.count) {
                    let n = hidden.count
                    let b = ActionButton("Show done", style: .link) { [weak self] in self?.flip(\.showDone) }
                    let row = NSStackView(h: [NSTextField.text("\(n) done item\(n == 1 ? "" : "s") hidden", size: 12, color: Palette.dim), b, Spacer()], spacing: 6)
                    row.edgeInsets = NSEdgeInsets(top: 6, left: 56, bottom: 6, right: 10)
                    return row
                })
            }
        }
        if rows.isEmpty { rows = [PageRow("empty", 0) { EmptyNote("No items match the filters.", symbol: "line.3.horizontal.decrease.circle") }] }
        let table = table
        return PageRow.list("table", rows: rows) { StickyListCard.table(table) }
    }

    /// The Group by control shows in the list layout of a project with epics.
    static func showsGroupBy(snap: ProjectSnapshot, board: Bool) -> Bool { !board && snap.epics != nil }

    static func groupsByEpic(snap: ProjectSnapshot, board: Bool, preferred: Bool) -> Bool { preferred && showsGroupBy(snap: snap, board: board) }

    /// The epics in the order of `ProjectSnapshot.epicGroups`, with their progress. The items with no epic are last.
    static func epicGroups(snap: ProjectSnapshot, items: [Item], blocked: Set<String> = [], now: Date = Date())
        -> [(id: String, title: String, epic: EpicRollup?, items: [Item])] {
        snap.epicGroups(items).map { g in
            g.epic.map { ($0.id.rawValue, $0.title, snap.rollup($0, blocked: blocked, now: now), g.items) } ?? ("none", "No epic", nil, g.items)
        }
    }

    private func statusGroups(_ snap: ProjectSnapshot, _ items: [Item]) -> [(StatusOption, [Item])] {
        Self.statusGroups(snap, items, showDone: showDone, hideDoneAfterDays: PROJECTS_CFG.hideDoneAfterDays, favorite: FAVORITES.contains)
    }

    private func groupGlyph(_ opt: StatusOption) -> NSView {
        opt.id == Favorites.groupId ? Favorites.glyph(size: 13) : StatusGlyph(category: opt.category, color: projectColor(opt.color), name: opt.name).sized(16)
    }

    // Favorites first, also when Done. Then the tracker states in their rank order. Without Show done, Done items follow
    // the "Hide Done items" setting. A Done item with open sub-items goes in the first started group (`listStateId`).
    static func statusGroups(_ snap: ProjectSnapshot, _ items: [Item], showDone: Bool, hideDoneAfterDays days: Int,
                             favorite: (String) -> Bool = { _ in false }) -> [(StatusOption, [Item])] {
        let opts = snap.statusOptions.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
        let favs = snap.groupSorted(items.filter { favorite($0.key) })
        let others = items.filter { !favorite($0.key) }
        let sorted = snap.groupSorted(showDone ? others : others.filter { !snap.isHiddenDone($0, afterDays: days) })
        var out = opts.map { o in (o, sorted.filter { snap.listStateId($0) == o.id }) }
        let known = Set(opts.map(\.id))
        let rest = sorted.filter { !known.contains(snap.listStateId($0) ?? "") }
        if !rest.isEmpty { out.append((StatusOption(id: "", name: "No status", color: "GRAY"), rest)) }
        if !favs.isEmpty { out.insert((StatusOption(id: Favorites.groupId, name: Favorites.title, color: "YELLOW"), favs), at: 0) }
        return out
    }

    private func boardView(_ groups: [(StatusOption, [Item])], _ ws: WorkstreamIndex, _ snap: ProjectSnapshot) -> NSView {
        let cols: [NSView] = groups.filter { !$0.1.isEmpty || ![.done, .blocked].contains($0.0.category) }.map { opt, its in
            let c = Card(padding: 10, spacing: 8)
            c.add(NSStackView(h: [groupGlyph(opt),
                                  NSTextField.text(opt.name, size: 12.5, weight: .semibold),
                                  NSTextField.text("\(its.count)", size: 12, color: Palette.dim)], spacing: 6))
            for i in its.prefix(25) { c.add(BoardCard(i, snap: snap, stream: ws.stream(i.key), status: data.statusJob.item(i.key), commands: commands) { [weak self] in self?.go($0) }) }
            if its.count > 25 { c.add(NSTextField.text("\(its.count - 25) more", size: 12, color: Palette.dim)) }
            if its.isEmpty { c.add(NSTextField.text("No items", size: 12, color: Palette.dim)) }
            return c
        }
        let row = NSStackView(h: cols, spacing: 10, align: .top)
        row.distribution = .fillEqually
        return row
    }

    private func flip(_ k: ReferenceWritableKeyPath<ProjectPage, Bool>) {
        self[keyPath: k].toggle()
        reload()
    }

    @objc fileprivate func groupChanged(_ s: NSSegmentedControl) {
        groupByEpic = s.selectedSegment == 1
        if !UIShots.shooting { UserDefaults.standard.set(groupByEpic, forKey: ProjectPage.groupKey) }
        reload()
    }

    @objc fileprivate func layoutChanged(_ s: NSSegmentedControl) {
        let picked = ProjectTab.allCases[max(0, s.selectedSegment)]
        guard picked != tab else { return }
        if tab == .plan { PlanVisits.shared.leave(projectKey) }
        tab = picked
        if tab == .plan { enterPlan() }
        reload()
    }
}

extension NSView {
    // Fixed size for a view that draws itself in its frame.
    func fixedWidth(_ w: CGFloat) -> Self {
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: w).isActive = true
        return self
    }

    func sized(_ s: CGFloat) -> Self {
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: s).isActive = true
        heightAnchor.constraint(equalToConstant: s).isActive = true
        return self
    }
}
