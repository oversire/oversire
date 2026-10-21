import Cocoa
import OverSireCore

// One item in a page list: status, key, title, sub-items, agent, CI, priority, assignee, time.
final class ItemLine: TableRow {
    static func columns(keyWidth: CGFloat = 104) -> [TableColumn] {
        [TableColumn(id: "status", title: "", width: 16, min: 16),
         TableColumn(id: "key", title: "ID", width: keyWidth, min: 60),
         TableColumn(id: "title", title: "Title", width: 200, min: 160, flexible: true),
         TableColumn(id: "sub", title: "Sub", width: 52, min: 36, optional: true),
         TableColumn(id: "session", title: "Status", width: 132, min: 60, optional: true),
         TableColumn(id: "ci", title: "CI", width: 56, min: 36, optional: true),
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
            cells["sub"] = NSStackView(h: [ProgressRing(done: prog.done, total: prog.total).sized(14),
                                           NSTextField.text("\(prog.done)/\(prog.total)", size: 11.5, color: Palette.dim)], spacing: 4)
        }
        cells["session"] = finish ?? StatusPill.or(status)
        if let ci = stream?.ci { cells["ci"] = Chiplet("CI", symbol: ci.symbol, color: ci.color) }
        if let p = item.fields["Priority"], p != "None" { cells["priority"] = Chiplet(p) }
        if let who = item.assignees.first { cells["who"] = Avatar(who) }
        let parts = [finish?.accessibilityLabel() ?? opt?.name, status?.label, stream?.ci.map { "CI \($0.word)" }, item.fields["Priority"]].compactMap { $0 }
        super.init(layout, cells: cells, label: "\(item.key) \(item.title). " + parts.joined(separator: ", ")) { go(.item(item.key, .overview)) }
        itemActions(url: item.url, key: item.key)
        commands?.attach(self) { RowMenu.item(item, snap: snap, stream: stream, local: PROJECTS_CFG.local(snap.summary.identifier), caps: $0) }
    }
    required init?(coder: NSCoder) { fatalError() }

    /// "Done · N open" for a Done item with open sub-items. "Done · cleanup" for a finished item with leftovers. Else nil.
    static func finishChip(_ item: Item, snap: ProjectSnapshot, cleanup: [CleanupLine]) -> Chiplet? {
        if snap.isDoneWithOpenSubItems(item) {
            let n = snap.openSubItems(of: item.id)
            let c = Chiplet("Done · \(n) open", symbol: "exclamationmark.triangle.fill", color: Palette.bad)
            c.toolTip = "Plane says \(snap.option(item.statusOptionId)?.name ?? "Done"), but \(n) sub-item\(n == 1 ? " is" : "s are") open."
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
        return PageRow.hash([item, snap.option(item.statusOptionId), prog.done, prog.total, status?.label, status?.tone.word, status?.tip,
                             stream?.ci?.word, snap.isDoneWithOpenSubItems(item), snap.openSubItems(of: item.id), cleanup.map(\.kind.noun)])
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
        itemActions(url: item.url, key: item.key)
        commands?.attach(self) { RowMenu.item(item, snap: snap, stream: stream, local: PROJECTS_CFG.local(snap.summary.identifier), caps: $0) }
    }
    required init?(coder: NSCoder) { fatalError() }
}

// Items of one project: a list grouped by status, or a board.
final class ProjectPage: Page {
    private static let layoutKey = "projectLayout"
    override var fillsHeight: Bool { !board }
    private var board = UserDefaults.standard.string(forKey: ProjectPage.layoutKey) == "board"
    private var onlyAgent = false
    private var onlyFailing = false
    private var onlyMine = false
    private var showDone = false
    private var showSubItems = false
    private let table = ColumnLayout(id: "project", columns: ItemLine.columns())
    private var more: [String: MoreRows] = [:]   // by status option id
    override var buildsLater: Bool { true }

    private var projectKey: String { if case .project(let k) = route { return k }; return "" }

    override var watches: DataDomains { [.projects, .intake, .agents, .runs, .summaries, .config] }
    override var shownProjects: Set<String>? { snapshot.map { [$0.summary.ref.storeKey] } }

    private var snapshot: ProjectSnapshot? { data.projectStore.snapshots.values.first { $0.summary.identifier.uppercased() == projectKey } }

    override func sections() -> [PageSection]? {
        let store = data.projectStore
        pageBusy = data.projectsLoading
        let key = projectKey
        guard let snap = snapshot else {
            let loading = data.projectsLoading
            return [PageSection("top", rows: [
                PageRow("header", key) { PageHeader(key, caption: "Project") },
                PageRow(loading ? "loading" : "missing", key) {
                    guard loading else { return EmptyNote("OverSire does not track a project with the key \(key).", symbol: "questionmark.folder") }
                    let c = ListCard()
                    c.add(LoadingNote("Loading \(key)"))
                    return c
                },
            ])]
        }
        let ws = data.workstreams, job = data.statusJob
        var items = snap.listed(subItems: showSubItems)
        if onlyAgent { items = items.filter { ws.stream($0.key)?.agent != nil } }
        if onlyFailing { items = items.filter { ws.stream($0.key)?.ci?.word == Tone.bad.word } }
        if onlyMine { items = items.filter { $0.isMine(snap.me) } }
        let open = snap.notDoneCount(snap.rootItems)
        let intake = snap.intake?.count ?? 0
        let board = board, ident = snap.summary.identifier
        let header = PageRow("header", snap.summary.title, snap.summary.url, open, intake, board) { [weak self] in
            var actions: [NSView] = []
            if intake > 0 {
                actions.append(ActionButton("\(intake) intake", symbol: "tray.and.arrow.down") { self?.go(.intake(key)) })
            }
            let seg = NSSegmentedControl(labels: ["List", "Board"], trackingMode: .selectOne, target: self, action: #selector(ProjectPage.layoutChanged(_:)))
            seg.selectedSegment = board ? 1 : 0
            seg.setAccessibilityLabel("Layout")
            actions.append(seg)
            actions.append(ActionButton("Open in Plane", symbol: "arrow.up.right.square") { NSWorkspace.shared.open(URL(string: snap.summary.url)!) })
            let gear = ActionButton("", symbol: "gearshape") { self?.go(.projectSettings(key, .appearance)) }
            gear.toolTip = "Project settings (⌘,)"
            gear.setAccessibilityLabel("Project settings")
            actions.append(gear)
            return PageHeader(snap.summary.title, updated: { [weak store] in store?.snapshots.values.first { $0.summary.identifier == ident }?.fetchedAt },
                              caption: { "\(open) open · updated \($0)" }, actions: actions)
        }
        let flags = [onlyMine, onlyAgent, onlyFailing, showSubItems, showDone]
        let filters = PageRow("filters", flags) { [weak self] in
            NSStackView(h: [
                ToggleChip("Mine", on: flags[0]) { self?.flip(\.onlyMine) },
                ToggleChip("Has session", on: flags[1]) { self?.flip(\.onlyAgent) },
                ToggleChip("CI failing", on: flags[2]) { self?.flip(\.onlyFailing) },
                ToggleChip("Sub-items", on: flags[3]) { self?.flip(\.showSubItems) },
                ToggleChip("Show done", on: flags[4]) { self?.flip(\.showDone) },
                Spacer(),
                NSTextField.text("Grouped by status · sorted by priority, Done by last change", size: 12, color: Palette.dim),
            ], spacing: 6)
        }
        let top = PageSection("top", rows: [header, filters])

        let groups = statusGroups(snap, items)
        if board {
            let hash = PageRow.hash(groups.map { g -> AnyHashable in
                [g.0.id, g.0.name, g.1.count] + g.1.prefix(25).map { AnyHashable(ItemLine.hash($0, snap: snap, stream: ws.stream($0.key), status: job.item($0.key))) }
            })
            return [top, PageSection("items", rows: [PageRow("board", hash: hash) { [weak self] in self?.boardView(groups, ws, snap) ?? NSView() }])]
        }
        var rows: [PageRow] = []
        for (opt, its) in groups where !its.isEmpty {
            rows.append(StickyListCard.group(opt.id, opt.name, count: its.count, extra: [opt.category.rank, opt.color] as [AnyHashable]) {
                [StatusGlyph(category: opt.category, color: projectColor(opt.color), name: opt.name).sized(16)]
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

    // Plane states in their category order. Without Show done, Done items follow the "Hide Done items" setting.
    private func statusGroups(_ snap: ProjectSnapshot, _ items: [Item]) -> [(StatusOption, [Item])] {
        let opts = snap.statusOptions.enumerated().sorted { ($0.element.category.rank, $0.offset) < ($1.element.category.rank, $1.offset) }.map(\.element)
        let days = PROJECTS_CFG.hideDoneAfterDays
        let sorted = snap.groupSorted(showDone ? items : items.filter { !snap.isHiddenDone($0, afterDays: days) })
        var out = opts.map { o in (o, sorted.filter { $0.statusOptionId == o.id }) }
        let known = Set(opts.map(\.id))
        let rest = sorted.filter { !known.contains($0.statusOptionId ?? "") }
        if !rest.isEmpty { out.append((StatusOption(id: "", name: "No status", color: "GRAY"), rest)) }
        return out
    }

    private func boardView(_ groups: [(StatusOption, [Item])], _ ws: WorkstreamIndex, _ snap: ProjectSnapshot) -> NSView {
        let cols: [NSView] = groups.filter { !$0.1.isEmpty || $0.0.category != .done }.map { opt, its in
            let c = Card(padding: 10, spacing: 8)
            c.add(NSStackView(h: [StatusGlyph(category: opt.category, color: projectColor(opt.color), name: opt.name).sized(16),
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

    @objc fileprivate func layoutChanged(_ s: NSSegmentedControl) {
        board = s.selectedSegment == 1
        UserDefaults.standard.set(board ? "board" : "list", forKey: ProjectPage.layoutKey)
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
