import AppKit
import OverSireCore

// Work: your items, the queue and the worktrees. The Items tab shows In progress, Done, Up next (the queue) and Not started.
final class WorkPage: Page {
    typealias Entry = (item: Item, snap: ProjectSnapshot, stream: Workstream?)
    typealias Lane = (priority: String, entries: [Entry])
    private let table = ColumnLayout(id: "mine", columns: ItemLine.columns(keyWidth: 120))
    private var more: [String: MoreRows] = [:]
    override var buildsLater: Bool { true }
    override var fillsHeight: Bool { true }

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

    /// The label row of a priority lane.
    static func laneRow(_ lane: Lane) -> NSView {
        Row([NSTextField.text(lane.priority.uppercased(), size: 10.5, weight: .semibold, color: Palette.dim),
             NSTextField.text("\(lane.entries.count)", size: 10.5, color: Palette.dim), Spacer()], height: 22, inset: 22)
    }

    /// The open root items of the user in all projects.
    static func mine(_ data: AppData) -> [Entry] {
        data.projectStore.snapshots.values.flatMap { snap in
            snap.rootItems.filter { $0.isMine(snap.me) && !snap.isFinished($0) }
                .map { ($0, snap, data.workstreams.stream($0.key)) }
        }
    }

    /// The sections of the Items tab, top to bottom. The ids are the fold keys in `PROJECTS_CFG.workFolded`.
    enum Section: String, CaseIterable { case progress, done, upNext = "upnext", todo }

    /// Your finished root items: finished in the "Hide Done items after" window, or with cleanup left at any age. Newest first.
    static func done(_ data: AppData, now: Date = Date()) -> [Entry] {
        done(Array(data.projectStore.snapshots.values), days: PROJECTS_CFG.hideDoneAfterDays, now: now) {
            !data.cleaner.lines($0, data: data).isEmpty
        }.map { ($0.item, $0.snap, data.workstreams.stream($0.item.key)) }
    }

    static func done(_ snaps: [ProjectSnapshot], days: Int, now: Date, cleanup: (String) -> Bool) -> [(item: Item, snap: ProjectSnapshot)] {
        snaps.flatMap { snap in
            snap.rootItems.filter { i in
                guard i.isMine(snap.me), snap.isFinished(i) else { return false }
                return !snap.isHiddenDone(i, afterDays: days == 0 ? 1 : days, now: now) || cleanup(i.key)
            }.map { ($0, snap) }
        }.sorted { $0.item.updatedAt > $1.item.updatedAt }
    }

    /// The note of the Done header for the "Hide Done items after" days.
    static func doneNote(days: Int) -> String {
        switch days {
        case ..<0: return "Only items with cleanup left"
        case 0, 1: return "Last 24 h"
        default: return "Last \(days) days"
        }
    }

    /// The page title, the caption, the actions and the tabs. The Worktrees tab uses it too.
    /// `extra` holds the values of `actions` and `trailing`.
    static func header(_ page: Page, tab: Route.WorkTab, caption: String, extra: AnyHashable = 0, actions: @escaping () -> [NSView],
                       trailing: @escaping () -> [NSView] = { [] }) -> [PageRow] {
        let data = page.data
        let worktrees = data.agentIndex.cards.filter { AgentsPage.cardKey($0, data: data) != nil }.count
        let mine = mine(data).count
        let tabs: [Route.WorkTab] = [.items, .worktrees]
        return [
            PageRow("header", caption, extra) { PageHeader("Work", caption: caption, actions: actions()) },
            PageRow("tabs", tab.rawValue, mine, worktrees, extra) { [weak page] in
                let strip = TabStrip(["Items", "Worktrees"], selected: tabs.firstIndex(of: tab) ?? 0, counts: [mine, worktrees])
                strip.onSelect = { i in page?.go(.work(tabs[i])) }
                return NSStackView(h: [strip, Spacer()] + trailing(), spacing: 8)
            },
        ]
    }

    override var watches: DataDomains { [.projects, .agents, .runs, .queue, .summaries, .planner, .config] }

    override func sections() -> [PageSection]? {
        let q = data.queue
        let used = q.lanes.reduce(0) { $0 + q.busy($1) }
        let slots = q.lanes.reduce(0) { $0 + AGENTS.slots($1.project) }
        let list = WorkPage.mine(data)
        var caption = "\(list.count) open items of yours"
        if slots > 0 { caption += " · \(used) of \(slots) session slots used" }
        let on = AGENTS.autoStart
        let top = WorkPage.header(self, tab: .items, caption: caption, extra: on, actions: { [weak self] in
            [ToggleChip("Auto start", on: on) { AGENTS.autoStart.toggle(); saveConfig(); self?.reload() }]
        })

        let job = data.statusJob
        let groups = WorkPage.itemGroups(list, queued: q.contains, status: job.item)
        var rows: [PageRow] = []
        for section in Section.allCases {
            switch section {
            case .progress: if let g = groups.first(where: { $0.title == "In progress" }) { rows += group(g, id: section, queue: false) }
            case .done: rows += doneGroup()
            case .upNext: rows += upNext()
            case .todo: if let g = groups.first(where: { $0.title == "Not started" }) { rows += group(g, id: section, queue: true) }
            }
        }
        pageBusy = data.projectsLoading
        if rows.isEmpty {
            let loading = data.projectsLoading
            rows = [PageRow(loading ? "loading" : "empty", 0) { loading ? LoadingNote("Loading your items") : EmptyNote("No open items are yours.") }]
        }
        let table = table
        return [PageSection("top", rows: top), PageSection("items", rows: [PageRow.list("table", rows: rows) { StickyListCard.table(table) }])]
    }

    // The fold state of a section. A change saves the config and builds the page again.
    private func fold(_ s: Section) -> GroupFold {
        GroupFold(expanded: !PROJECTS_CFG.workFolded.contains(s.rawValue)) { [weak self] in
            if PROJECTS_CFG.workFolded.remove(s.rawValue) == nil { PROJECTS_CFG.workFolded.insert(s.rawValue) }
            saveConfig()
            self?.reload()
        }
    }

    // One group with a label row for each priority. `queue`: the rows show "＋ Queue" on hover.
    private func group(_ g: (title: String, lanes: [Lane]), id: Section, queue: Bool) -> [PageRow] {
        let job = data.statusJob
        let fold = fold(id)
        var rows = [StickyListCard.group(id.rawValue, g.title, count: g.lanes.reduce(0) { $0 + $1.entries.count }, fold: fold)]
        guard fold.expanded else { return rows }
        for lane in g.lanes {
            rows.append(PageRow("lane.\(g.title).\(lane.priority)", lane.entries.count) { WorkPage.laneRow(lane) })
            let m = more[g.title + lane.priority] ?? MoreRows()
            more[g.title + lane.priority] = m
            rows += PageRow.limited(lane.entries, more: m, reload: { [weak self] in self?.reload() }) { [weak self, table, commands] e in
                let st = job.item(e.item.key)
                return PageRow(e.item.key, hash: PageRow.hash([ItemLine.hash(e.item, snap: e.snap, stream: e.stream, status: st), queue])) {
                    let row = ItemLine(e.item, snap: e.snap, stream: e.stream, status: st, layout: table, commands: commands) { self?.go($0) }
                    if queue {
                        let add = ActionButton("Queue", symbol: "plus") { self?.data.queue.add(e.item, snap: e.snap); self?.reload() }
                        add.setAccessibilityLabel("Add \(e.item.key) to the queue")
                        row.hoverViews = [add]
                    }
                    return row
                }
            }.map { r in r.id == "more" ? PageRow("more.\(g.title).\(lane.priority)", hash: r.hash, make: r.make) : r }
        }
        return rows
    }

    // Finished items. A row with cleanup left shows the "Done · cleanup" chip. The cleanup actions are on the item page.
    // The header shows the cleanup count also when the group is folded.
    private func doneGroup() -> [PageRow] {
        let list = WorkPage.done(data)
        guard !list.isEmpty else { return [] }
        let job = data.statusJob
        let cleanups = Dictionary(list.map { ($0.item.key, data.cleaner.lines($0.item.key, data: data)) }, uniquingKeysWith: { a, _ in a })
        let left = cleanups.values.filter { !$0.isEmpty }.count
        let note = WorkPage.doneNote(days: PROJECTS_CFG.hideDoneAfterDays)
        let fold = fold(.done)
        var rows = [StickyListCard.group(Section.done.rawValue, "Done", count: list.count, extra: [note, "\(left)"], fold: fold, trailing: {
            let hint = NSTextField.text(note, size: 12, color: Palette.dim)
            guard left > 0 else { return [hint] }
            let flag = Chiplet("\(left) need\(left == 1 ? "s" : "") cleanup", symbol: "bubbles.and.sparkles", color: Palette.warn)
            flag.toolTip = "\(left) finished item\(left == 1 ? " has" : "s have") things to clean up"
            return [hint, flag]
        })]
        guard fold.expanded else { return rows }
        let m = more["Done"] ?? MoreRows()
        more["Done"] = m
        rows += PageRow.limited(list, more: m, reload: { [weak self] in self?.reload() }) { [weak self, table, commands] e in
            let st = job.item(e.item.key), cleanup = cleanups[e.item.key] ?? []
            return PageRow("done." + e.item.key, hash: ItemLine.hash(e.item, snap: e.snap, stream: e.stream, status: st, cleanup: cleanup)) {
                ItemLine(e.item, snap: e.snap, stream: e.stream, status: st, layout: table, commands: commands, cleanup: cleanup) { self?.go($0) }
            }
        }.map { r in r.id == "more" ? PageRow("more.done", hash: r.hash, make: r.make) : r }
        return rows
    }

    // The queue: each lane in start order, with why an entry waits. ↑ ↓, Start now and ✕ show on hover.
    private func upNext() -> [PageRow] {
        let q = data.queue
        let entries = q.lanes.flatMap { l in l.entries.map { (l, $0) } }
        guard !entries.isEmpty else { return [] }
        // The Planner plan changes show on the lane board.
        let plans = hasCloud ? data.suggestions.openPlans().count : 0
        let fold = fold(.upNext)
        var rows = [StickyListCard.group(Section.upNext.rawValue, "Up next", count: entries.count, extra: plans, fold: fold) { [] } trailing: { [weak self] in [
            NSTextField.text("Starts in this order when a slot frees", size: 12, color: Palette.dim),
            ActionButton(plans > 0 ? "Lane board · \(plans) plan change\(plans == 1 ? "" : "s")" : "Lane board", style: .link) {
                self?.go(.work(.lanes))
            },
        ] }]
        guard fold.expanded else { return rows }
        let world = q.world(workstreams: data.workstreams)
        for lane in q.lanes {
            let pick = lane.pick(state: q.state(lane.project), world: world)
            for (i, e) in lane.entries.enumerated() {
                let why: String
                if let h = pick.holds[e.key] { why = QueueBoard.note(h) }
                else if e.condition != .slot { why = "🕑 " + e.condition.label }
                else { why = pick.next == e.key ? "✓ Starts next" : "Queued" }
                let text = data.projectStore.item(key: e.key)?.item.title ?? e.title
                let held = pick.holds[e.key] != nil, count = lane.entries.count
                rows.append(PageRow("queue." + e.key, i, why, text, held, count, lane.identifier) { [weak self] in
                    let title = NSTextField.text(text, size: 12.5)
                    title.lineBreakMode = .byTruncatingTail
                    title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                    let row = Row([NSTextField.text("\(i + 1)", size: 12, weight: .semibold, color: Palette.dim, mono: true).fixedWidth(16),
                                   NSTextField.text(e.key, size: 12, color: Palette.dim, mono: true).fixedWidth(120), title, Spacer(),
                                   Chiplet(why, color: held ? Palette.warn : Palette.mut)],
                                  height: 36, label: "Up next \(i + 1) in \(lane.identifier): \(e.key), \(why)") { self?.go(.item(e.key, .overview)) }
                    row.hoverViews = self?.actions(e.key, lane: lane, at: i) ?? []
                    return row
                })
            }
        }
        return rows
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
