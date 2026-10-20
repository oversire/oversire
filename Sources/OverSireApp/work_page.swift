import AppKit
import OverSireCore

// Work: your items, the queue and the worktrees. The Items tab shows In progress, Up next (the queue) and Not started.
final class WorkPage: Page {
    typealias Entry = (item: Item, snap: ProjectSnapshot, stream: Workstream?)
    typealias Lane = (priority: String, entries: [Entry])
    private let table = ColumnLayout(id: "mine", columns: ItemLine.columns(keyWidth: 120))
    private var more: [String: MoreRows] = [:]
    override var buildsLater: Bool { true }

    /// In progress, then Not started. In each: priority lanes, Urgent first. In a lane: Needs input, Blocked on you,
    /// Looks stuck or CI failing, Working, then the rest. Last: the newest activity.
    static func groups(_ list: [Entry], status: (String) -> ItemStatus?) -> [(title: String, lanes: [Lane])] {
        func attention(_ e: Entry) -> Int {
            let a = status(e.item.key)?.attention ?? 4
            return e.stream?.ci?.word == Tone.bad.word ? min(a, 2) : a
        }
        func priority(_ e: Entry) -> Int {
            StatusOption.priorities.firstIndex { $0.name == e.item.fields["Priority"] } ?? StatusOption.priorities.count - 1
        }
        let ranked = list.map { (e: $0, a: attention($0), p: priority($0)) }
        let started = ranked.filter { ($0.e.snap.option($0.e.item.statusOptionId)?.category ?? .todo) != .todo }
        let todo = ranked.filter { ($0.e.snap.option($0.e.item.statusOptionId)?.category ?? .todo) == .todo }
        func lanes(_ g: [(e: Entry, a: Int, p: Int)]) -> [Lane] {
            StatusOption.priorities.indices.compactMap { p in
                let es = g.filter { $0.p == p }.sorted { ($0.a, $1.e.item.activityAt) < ($1.a, $0.e.item.activityAt) }.map(\.e)
                let name = StatusOption.priorities[p].name
                return es.isEmpty ? nil : (name == "None" ? "No priority" : name, es)
            }
        }
        return [("In progress", lanes(started)), ("Not started", lanes(todo))].filter { !$0.lanes.isEmpty }
    }

    static func order(_ list: [Entry], status: (String) -> ItemStatus?) -> [Entry] {
        groups(list, status: status).flatMap { $0.lanes.flatMap(\.entries) }
    }

    /// The groups of the Items tab. A queued item shows only in Up next.
    static func itemGroups(_ list: [Entry], queued: (String) -> Bool, status: (String) -> ItemStatus?) -> [(title: String, lanes: [Lane])] {
        groups(list.filter { !queued($0.item.key) }, status: status)
    }

    /// The open root items of the user in all projects.
    static func mine(_ data: AppData) -> [Entry] {
        data.projectStore.snapshots.values.flatMap { snap in
            snap.rootItems.filter { $0.isMine(snap.me) && snap.option($0.statusOptionId)?.category != .done }
                .map { ($0, snap, data.workstreams.stream($0.key)) }
        }
    }

    /// The page title, the caption, the actions and the tabs. The Worktrees tab uses it too.
    static func header(_ page: Page, tab: Route.WorkTab, caption: String, actions: [NSView], in col: NSStackView) {
        let data = page.data
        let worktrees = data.agentIndex.cards.filter { AgentsPage.cardKey($0, data: data) != nil }.count
        let tabs: [Route.WorkTab] = [.items, .worktrees]
        let strip = TabStrip(["Items", "Worktrees"], selected: tabs.firstIndex(of: tab) ?? 0, counts: [mine(data).count, worktrees])
        strip.onSelect = { [weak page] i in page?.go(.work(tabs[i])) }
        col.addFull(PageHeader("Work", caption: caption, actions: actions))
        col.addArrangedSubview(strip)
    }

    override func build(_ col: NSStackView) {
        let q = data.queue
        let used = q.lanes.reduce(0) { $0 + q.busy($1) }
        let slots = q.lanes.reduce(0) { $0 + AGENTS.slots($1.project) }
        let list = WorkPage.mine(data)
        var caption = "\(list.count) open items of yours"
        if slots > 0 { caption += " · \(used) of \(slots) session slots used" }
        let auto = ToggleChip("Auto start", on: AGENTS.autoStart) { [weak self] in AGENTS.autoStart.toggle(); saveConfig(); self?.reload() }
        WorkPage.header(self, tab: .items, caption: caption, actions: [auto], in: col)

        let job = data.statusJob
        let groups = WorkPage.itemGroups(list, queued: q.contains, status: job.item)
        let card = ListCard()
        card.add(TableHeader(table))
        if let g = groups.first(where: { $0.title == "In progress" }) { group(card, g, queue: false) }
        upNext(card)
        if let g = groups.first(where: { $0.title == "Not started" }) { group(card, g, queue: true) }
        pageBusy = data.projectsLoading
        if card.list.arrangedSubviews.count == 1 { card.add(data.projectsLoading ? LoadingNote("Loading your items") : EmptyNote("No open items are yours.")) }
        col.addFull(card)
    }

    private func head(_ card: ListCard, _ title: String, count: Int, trailing: [NSView] = []) {
        let head = Row([NSTextField.text(title, size: 12.5, weight: .semibold), NSTextField.text("\(count)", size: 12, color: Palette.dim), Spacer()] + trailing, height: 32)
        head.restFill = Palette.raise
        card.add(head)
    }

    // One group with a label row for each priority. `queue`: the rows show "＋ Queue" on hover.
    private func group(_ card: ListCard, _ g: (title: String, lanes: [Lane]), queue: Bool) {
        let job = data.statusJob
        head(card, g.title, count: g.lanes.reduce(0) { $0 + $1.entries.count })
        for lane in g.lanes {
            card.add(Row([NSTextField.text(lane.priority.uppercased(), size: 10.5, weight: .semibold, color: Palette.dim),
                          NSTextField.text("\(lane.entries.count)", size: 10.5, color: Palette.dim), Spacer()], height: 22, inset: 22))
            let m = more[g.title + lane.priority] ?? MoreRows()
            more[g.title + lane.priority] = m
            card.add(lane.entries, more: m) { [weak self, table, commands] e in
                let row = ItemLine(e.item, snap: e.snap, stream: e.stream, status: job.item(e.item.key), layout: table, commands: commands) { self?.go($0) }
                if queue {
                    let add = ActionButton("Queue", symbol: "plus") { [weak self] in self?.data.queue.add(e.item, snap: e.snap); self?.reload() }
                    add.setAccessibilityLabel("Add \(e.item.key) to the queue")
                    row.hoverViews = [add]
                }
                return row
            }
        }
    }

    // The queue: each lane in start order, with why an entry waits. ↑ ↓, Start now and ✕ show on hover.
    private func upNext(_ card: ListCard) {
        let q = data.queue
        let entries = q.lanes.flatMap { l in l.entries.map { (l, $0) } }
        guard !entries.isEmpty else { return }
        head(card, "Up next", count: entries.count, trailing: [
            NSTextField.text("Starts in this order when a slot frees", size: 12, color: Palette.dim),
            ActionButton("Lane board", style: .link) { [weak self] in self?.go(.work(.lanes)) },
        ])
        let world = q.world(workstreams: data.workstreams)
        for lane in q.lanes {
            let pick = lane.pick(state: q.state(lane.project), world: world)
            for (i, e) in lane.entries.enumerated() {
                let why: String
                if let h = pick.holds[e.key] { why = QueueBoard.note(h) }
                else if e.condition != .slot { why = "🕑 " + e.condition.label }
                else { why = pick.next == e.key ? "✓ Starts next" : "Queued" }
                let title = NSTextField.text(data.projectStore.item(key: e.key)?.item.title ?? e.title, size: 12.5)
                title.lineBreakMode = .byTruncatingTail
                title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                let row = Row([NSTextField.text("\(i + 1)", size: 12, weight: .semibold, color: Palette.dim, mono: true).fixedWidth(16),
                               NSTextField.text(e.key, size: 12, color: Palette.dim, mono: true).fixedWidth(120), title, Spacer(),
                               Chiplet(why, color: pick.holds[e.key] == nil ? Palette.mut : Palette.warn)],
                              height: 36, label: "Up next \(i + 1) in \(lane.identifier): \(e.key), \(why)") { [weak self] in self?.go(.item(e.key, .overview)) }
                row.hoverViews = actions(e.key, lane: lane, at: i)
                card.add(row)
            }
        }
    }

    private func actions(_ key: String, lane: QueueLane, at n: Int) -> [NSView] {
        let q = data.queue
        let up = ActionButton("", symbol: "chevron.up") { q.move(key, by: -1) }
        up.isEnabled = n > 0
        up.setAccessibilityLabel("Move \(key) up")
        let down = ActionButton("", symbol: "chevron.down") { q.move(key, by: 1) }
        down.isEnabled = n < lane.entries.count - 1
        down.setAccessibilityLabel("Move \(key) down")
        let start = ActionButton("Start now")
        start.onClick = { [weak start] in q.start(key, project: lane.project, anchor: start) }
        let remove = ActionButton("", symbol: "xmark") { q.remove(key) }
        remove.setAccessibilityLabel("Remove \(key) from the queue")
        return [up, down, start, remove]
    }
}
