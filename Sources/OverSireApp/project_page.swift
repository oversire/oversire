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
         go: @escaping (Route) -> Void) {
        let opt = snap.option(item.statusOptionId)
        var cells: [String: NSView] = [
            "status": StatusGlyph(category: opt?.category ?? .todo, color: projectColor(opt?.color ?? "GRAY"), name: opt?.name ?? "No status").sized(16),
            "key": NSTextField.text(item.key, size: 11.5, color: Palette.dim, mono: true),
            "title": NSTextField.text(item.title, size: 13),
            "updated": NSTextField.text(relativeTime(item.activityAt), size: 11.5, color: Palette.dim),
        ]
        let prog = snap.progress(of: item.id)
        if prog.total > 0 {
            cells["sub"] = NSStackView(h: [ProgressRing(done: prog.done, total: prog.total).sized(14),
                                           NSTextField.text("\(prog.done)/\(prog.total)", size: 11.5, color: Palette.dim)], spacing: 4)
        }
        cells["session"] = StatusPill.or(status)
        if let ci = stream?.ci { cells["ci"] = Chiplet("CI", symbol: ci.symbol, color: ci.color) }
        if let p = item.fields["Priority"], p != "None" { cells["priority"] = Chiplet(p) }
        if let who = item.assignees.first { cells["who"] = Avatar(who) }
        let parts = [opt?.name, status?.label, stream?.ci.map { "CI \($0.word)" }, item.fields["Priority"]].compactMap { $0 }
        super.init(layout, cells: cells, label: "\(item.key) \(item.title). " + parts.joined(separator: ", ")) { go(.item(item.key, .overview)) }
        itemActions(url: item.url, key: item.key)
        commands?.attach(self) { RowMenu.item(item, snap: snap, stream: stream, local: PROJECTS_CFG.local(snap.summary.identifier), caps: $0) }
    }
    required init?(coder: NSCoder) { fatalError() }
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

    override func build(_ col: NSStackView) {
        let store = data.projectStore
        pageBusy = data.projectsLoading
        guard let snap = store.snapshots.values.first(where: { $0.summary.identifier.uppercased() == projectKey }) else {
            col.addFull(PageHeader(projectKey, caption: "Project"))
            if data.projectsLoading {
                let c = ListCard()
                c.add(LoadingNote("Loading \(projectKey)"))
                col.addFull(c)
            } else {
                col.addFull(EmptyNote("OverSire does not track a project with the key \(projectKey).", symbol: "questionmark.folder"))
            }
            return
        }
        let ws = data.workstreams
        var items = snap.listed(subItems: showSubItems)
        if onlyAgent { items = items.filter { ws.stream($0.key)?.agent != nil } }
        if onlyFailing { items = items.filter { ws.stream($0.key)?.ci?.word == Tone.bad.word } }
        if onlyMine { items = items.filter { $0.isMine(snap.me) } }
        let open = snap.notDoneCount(snap.rootItems)

        var actions: [NSView] = []
        if let n = snap.intake?.count, n > 0 {
            actions.append(ActionButton("\(n) intake", symbol: "tray.and.arrow.down") { [weak self] in self?.go(.inbox(.intake)) })
        }
        let seg = NSSegmentedControl(labels: ["List", "Board"], trackingMode: .selectOne, target: self, action: #selector(layoutChanged(_:)))
        seg.selectedSegment = board ? 1 : 0
        seg.setAccessibilityLabel("Layout")
        actions.append(seg)
        actions.append(ActionButton("Open in Plane", symbol: "arrow.up.right.square") { NSWorkspace.shared.open(URL(string: snap.summary.url)!) })
        let gear = ActionButton("", symbol: "gearshape") { [weak self] in self?.go(.projectSettings(self?.projectKey ?? "", .appearance)) }
        gear.toolTip = "Project settings (⌘,)"
        gear.setAccessibilityLabel("Project settings")
        actions.append(gear)
        col.addFull(PageHeader(snap.summary.title, caption: "\(open) open · updated \(relativeTime(snap.fetchedAt))", actions: actions))

        let filters = NSStackView(h: [
            ToggleChip("Mine", on: onlyMine) { [weak self] in self?.flip(\.onlyMine) },
            ToggleChip("Has session", on: onlyAgent) { [weak self] in self?.flip(\.onlyAgent) },
            ToggleChip("CI failing", on: onlyFailing) { [weak self] in self?.flip(\.onlyFailing) },
            ToggleChip("Sub-items", on: showSubItems) { [weak self] in self?.flip(\.showSubItems) },
            ToggleChip("Show done", on: showDone) { [weak self] in self?.flip(\.showDone) },
            Spacer(),
            NSTextField.text("Grouped by status · sorted by priority, Done by last change", size: 12, color: Palette.dim),
        ], spacing: 6)
        col.addFull(filters)

        let groups = statusGroups(snap, items)
        if board { col.addFull(boardView(groups, ws, snap)); return }
        let list = ListCard()
        list.add(TableHeader(table))
        for (opt, its) in groups where !its.isEmpty {
            let head = Row([StatusGlyph(category: opt.category, color: projectColor(opt.color), name: opt.name).sized(16),
                            NSTextField.text(opt.name, size: 12.5, weight: .semibold),
                            NSTextField.text("\(its.count)", size: 12, color: Palette.dim), Spacer()], height: 32)
            head.restFill = Palette.raise
            list.add(head)
            let m = more[opt.id] ?? MoreRows()
            more[opt.id] = m
            list.add(its, more: m) { [weak self, table] i in ItemLine(i, snap: snap, stream: ws.stream(i.key), status: self?.data.statusJob.item(i.key), layout: table) { self?.go($0) } }
        }
        if list.list.arrangedSubviews.count == 1 { list.add(EmptyNote("No items match the filters.", symbol: "line.3.horizontal.decrease.circle")) }
        col.addFull(list)
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

    @objc private func layoutChanged(_ s: NSSegmentedControl) {
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
