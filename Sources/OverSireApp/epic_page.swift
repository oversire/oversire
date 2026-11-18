import AppKit
import OverSireCore
import OverSireAssistant

// The page of one epic: the goal, the items, the progress with the burn-up chart, the sessions and the recent activity.
final class EpicPage: Page {
    private let markdown = MarkdownView(width: 600)
    private var markdownHeight: NSLayoutConstraint?
    private var editor: MarkdownEditor?
    private var saving = false
    private var note: (Tone, String)?
    private var allDone = false
    private static let sideWidth: CGFloat = 340
    private static let doneShown = 3

    private var project: String { if case .epic(let p, _, _) = route { return p }; return "" }
    private var epicID: EpicID { if case .epic(_, let id, _) = route { return EpicID(rawValue: id) }; return "" }
    private var tab: Route.EpicTab { if case .epic(_, _, let t) = route { return t }; return .overview }

    private func found() -> (snap: ProjectSnapshot, epic: Epic)? { data.projectStore.epic(project, epicID) }

    private func blocked(_ snap: ProjectSnapshot) -> Set<String> {
        Set(snap.items.filter { $0.epicId != nil && !data.projectStore.blockers(of: $0.key).isEmpty }.map(\.id))
    }

    override func viewDidLoad() {
        markdown.translatesAutoresizingMaskIntoConstraints = true
        markdown.onHeight = { [weak self] h in self?.markdownHeight?.constant = max(24, h) }
        super.viewDidLoad()
    }

    override func show(_ r: Route) {
        if case .epic(let p, let id, _) = r, p != project || id != epicID.rawValue {
            editor = nil
            allDone = false
            note = nil
        }
        super.show(r)
    }

    override var watches: DataDomains { [.projects, .agents, .questions, .queue, .relations, .summaries, .config, .events] }
    override var shownProjects: Set<String>? { found().map { [$0.snap.summary.ref.storeKey] } }
    override var shownItems: Set<String>? { found().map { [$0.epic.eventKey] } }
    override var isEditing: Bool { super.isEditing || editor != nil }

    override var parts: [PagePart] {
        guard let (snap, epic) = found() else { return [data.projectStore.plane] }
        var out = [data.projectStore.part([snap.summary.ref.storeKey])]
        if tab != .items { out += [JOURNAL.part(epic.eventKey), EPIC_BURNUPS.part(epic.eventKey)] }
        return out
    }

    // The fetches run here, not in `sections()`: the window calls `sections()` for each change.
    override func reload(reason: String) {
        if let (snap, epic) = found() {
            if tab != .items {
                JOURNAL.load(epic.eventKey)
                EPIC_BURNUPS.load(epic.eventKey, members: snap.members(of: epic.id).compactMap(\.key))
            }
        } else {
            pageBusy = data.projectsLoading
        }
        super.reload(reason: reason)
    }

    override func sections() -> [PageSection]? {
        guard let (snap, epic) = found() else {
            let loading = data.projectsLoading, p = project
            return [PageSection("missing", rows: [
                PageRow("header", p) { PageHeader("Epic", caption: p) },
                PageRow("body", p, loading) {
                    loading ? LoadingNote("Loading the epic") : EmptyNote("OverSire has no such epic in \(p). It may be deleted, or its project is not tracked.",
                                                                        symbol: "questionmark.square.dashed")
                },
            ])]
        }
        let r = snap.rollup(epic, blocked: blocked(snap), now: Date())
        var top = [headRow(snap, r)]
        if let note { top.append(PageRow("note", "\(note.0.word)", note.1) { Banner(note.0, title: note.1) }) }
        top.append(tabsRow(r))
        let rows: [PageRow]
        switch tab {
        case .overview: rows = [overview(snap, r)]
        case .items: rows = [itemsRow(snap, r)]
        case .timeline: rows = [timelineRow(r)]
        }
        return [PageSection("top", rows: top), PageSection(tab.rawValue, rows: rows)]
    }

    // MARK: Head

    private func headRow(_ snap: ProjectSnapshot, _ r: EpicRollup) -> PageRow {
        let next = snap.nextReady(in: r.epic.id, blocked: blocked(snap)).prefix(5).map(\.key)
        return PageRow("head", r, snap.summary, next, saving) { [unowned self] in self.head(snap, r) }
    }

    private func head(_ snap: ProjectSnapshot, _ r: EpicRollup) -> NSView {
        let e = r.epic
        let desc = ENV.descriptor(snap.summary.ref.account)
        let late = r.lateDays != nil
        let title = NSTextField.text(e.title, size: 20, weight: .semibold, lines: 2)
        title.setContentHuggingPriority(.init(1), for: .horizontal)

        var chips: [NSView] = [Chiplet(EpicColor.word(e.state), icon: EpicGlyph(e.state, late: false, size: 12), color: Palette.fg)]
        if let d = desc, let noun = d.epicNoun { chips.append(Chiplet("\(d.displayName) \(noun)", symbol: "square.stack.3d.up")) }
        chips.append(Chiplet(snap.summary.title, symbol: "folder", color: Palette.acc) { [weak self] in self?.go(.project(snap.summary.identifier)) })
        if let lead = e.lead { chips.append(Chiplet("Lead \(lead)", symbol: "person")) }
        if e.targetDate != nil || late { chips.append(Chiplet(r.due, symbol: late ? nil : "calendar", color: late ? Palette.bad : Palette.mut)) }
        if let c = chips.last as? Chiplet, late { c.setAccessibilityLabel(r.due.replacingOccurrences(of: "▲ ", with: "Late: ")) }
        if saving { chips.append(NSStackView(h: [Spinner(size: .mini), NSTextField.text("Saving…", size: 12, color: Palette.dim)], spacing: 5)) }

        let buttons = actions(snap, r)
        let line = NSStackView(h: [title, Spacer()] + buttons, spacing: 8)
        let chipRow = Wrap(chips)
        let column = NSStackView(v: [line, chipRow], spacing: 8)
        line.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        chipRow.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        let glyph = EpicGlyph(e.state, late: late, size: 28)
        return NSStackView(h: [glyph, column], spacing: 12, align: .top)
    }

    private func actions(_ snap: ProjectSnapshot, _ r: EpicRollup) -> [NSView] {
        let e = r.epic
        let args: [String: JSONValue] = ["project": .string(snap.summary.identifier), "epic": .string(e.id.rawValue)]
        var out: [NSView] = []
        let ready = snap.nextReady(in: e.id, blocked: blocked(snap)).prefix(5)
        if !e.state.isClosed, let first = ready.first {
            let go = ActionButton("Start next: \(first.key)", symbol: "play.fill", style: .primary)
            go.onClick = { [weak self, weak go] in
                guard let self, let go else { return }
                SessionStartMenu(self.data).start(first, snap: snap, at: go)
            }
            go.setAccessibilityLabel("Start next item, \(first.key)")
            var views: [NSView] = [go]
            if ready.count > 1 {
                let more = ActionButton("", symbol: "chevron.down", style: .primary)
                more.setAccessibilityLabel("Pick the item to start")
                more.toolTip = "Pick another ready item of this epic"
                more.onClick = { [weak self, weak more] in
                    guard let self, let more else { return }
                    let menu = NSMenu()
                    for item in ready {
                        let a = MenuAction("\(item.key)  \(item.title)") { [weak self, weak more] in
                            guard let self, let more else { return }
                            SessionStartMenu(self.data).start(item, snap: snap, at: more)
                        }
                        menu.addItem(a.item)
                    }
                    menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 2), in: more)
                }
                views.append(more)
            }
            out.append(NSStackView(h: views, spacing: 1))
        }
        if !e.state.isClosed {
            out.append(ActionButton("Add items", symbol: "plus") { [weak self] in self?.addItems(snap, e) })
        }
        if let url = URL(string: e.url), !e.url.isEmpty {
            let name = ENV.descriptor(snap.summary.ref.account)?.displayName ?? "tracker"
            out.append(ActionButton("Open in \(name)", symbol: "arrow.up.right.square", style: .ghost) { NSWorkspace.shared.open(url) })
        }
        if !e.state.isClosed {
            let close = ActionButton("Close epic", symbol: "checkmark", action: "epic.close", args, confirm: "Close \(e.title)?")
            if r.open > 0 {
                close.isEnabled = false
                close.toolTip = "\(r.open) item\(r.open == 1 ? " is" : "s are") open"
            }
            out.append(close)
        }
        return out
    }

    private func tabsRow(_ r: EpicRollup) -> PageRow {
        let tab = self.tab, total = r.total
        return PageRow("tabs", tab.rawValue, total) { [unowned self] in
            let tabs = Route.EpicTab.allCases
            let strip = TabStrip(tabs: [TabStrip.Tab(title: "Overview"), TabStrip.Tab(title: "Items", count: total), TabStrip.Tab(title: "Timeline")],
                                 selected: tabs.firstIndex(of: tab) ?? 0)
            strip.onSelect = { [weak self] i in
                guard let self, case .epic(let p, let id, _) = self.route else { return }
                self.go(.epic(p, id, tabs[i]))
            }
            return NSStackView(h: [strip, Spacer()], spacing: 8)
        }
    }

    // MARK: Overview

    private func overview(_ snap: ProjectSnapshot, _ r: EpicRollup) -> PageRow {
        let e = r.epic
        let key = e.eventKey
        let journal = JOURNAL.rows(key), history = EPIC_BURNUPS.rows(key)
        let editing = editor != nil
        let job = data.statusJob
        let members = members(snap, e)
        let live = members.map { m in [AnyHashable(m.key), AnyHashable(job.item(m.key)?.label), AnyHashable(data.questions.count(key: m.key))] }
        let items = itemsSig(snap, members)
        return PageRow("overview", r, snap.summary, editing, saving, allDone, items, journal?.count, history?.count, live, journal?.last?.id) { [unowned self] in
            // The empty view at the end takes the spare height, so the goal card keeps its own height.
            let rest = NSView()
            rest.translatesAutoresizingMaskIntoConstraints = false
            rest.setContentHuggingPriority(.init(1), for: .vertical)
            let left = NSStackView(v: [self.goalCard(snap, e), self.itemsCard(snap, r, members), rest], spacing: 14)
            let right = NSStackView(v: [self.progressCard(snap, r, journal: journal, history: history), self.sessionsCard(snap, members),
                                        self.recentCard(journal, history)], spacing: 14)
            for v in left.arrangedSubviews { v.widthAnchor.constraint(equalTo: left.widthAnchor).isActive = true }
            for v in right.arrangedSubviews { v.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true }
            right.widthAnchor.constraint(equalToConstant: Self.sideWidth).isActive = true
            let both = NSStackView(h: [left, right], spacing: 14, align: .top)
            left.setContentHuggingPriority(.init(1), for: .horizontal)
            return both
        }
    }

    /// The loaded items of the epic. Open first, then by priority and key. Done items last.
    private func members(_ snap: ProjectSnapshot, _ e: Epic) -> [Item] {
        snap.items.filter { $0.epicId == e.id }.sorted { a, b in
            let (da, db) = (snap.isClosed(a.statusOptionId), snap.isClosed(b.statusOptionId))
            if da != db { return !da }
            let (ra, rb) = (LaneOrder.rank(a.fields["Priority"]), LaneOrder.rank(b.fields["Priority"]))
            if ra != rb { return ra < rb }
            return a.key.localizedStandardCompare(b.key) == .orderedAscending
        }
    }

    private func itemsSig(_ snap: ProjectSnapshot, _ items: [Item]) -> Int {
        PageRow.hash(items.map { [AnyHashable($0), AnyHashable(snap.option($0.statusOptionId))] })
    }

    // MARK: Goal

    private func goalCard(_ snap: ProjectSnapshot, _ e: Epic) -> NSView {
        let canEdit = ENV.descriptor(snap.summary.ref.account)?.epicFields.contains(.goal) ?? false
        var trailing: [NSView] = []
        if canEdit, editor == nil {
            let edit = ActionButton("Edit", symbol: "pencil", style: .ghost) { [weak self] in self?.beginEdit(e) }
            edit.isEnabled = !saving
            trailing.append(edit)
        }
        let c = Card(title: "Goal", trailing: trailing)
        if let editor {
            editor.removeFromSuperview()
            c.add(editor)
            let save = ActionButton(saving ? "Saving…" : "Save", style: .primary) { [weak self] in self?.save(snap, e) }
            save.isEnabled = !saving
            let cancel = ActionButton("Cancel", style: .ghost) { [weak self] in self?.cancelEdit() }
            c.add(NSStackView(h: [save, cancel, NSTextField.text("⌘S saves. Esc cancels. The goal stays Markdown.", size: 12, color: Palette.dim), Spacer()],
                              spacing: 8))
            return c
        }
        let goal = (e.goal ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty else {
            c.add(NSTextField.text("No goal yet.", size: 12.5, color: Palette.dim))
            return c
        }
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        markdown.removeFromSuperview()
        holder.addSubview(markdown)
        markdown.autoresizingMask = [.width, .height]
        markdown.frame = holder.bounds
        let h = holder.heightAnchor.constraint(equalToConstant: max(24, markdown.contentHeight))
        h.isActive = true
        markdownHeight = h
        c.add(holder)
        markdown.show(goal, mode: .rendered)
        return c
    }

    private func beginEdit(_ e: Epic) {
        let ed = MarkdownEditor(e.goal ?? "", height: 220)
        ed.onSave = { [weak self] in if let self, let (snap, epic) = self.found() { self.save(snap, epic) } }
        ed.onCancel = { [weak self] in self?.cancelEdit() }
        editor = ed
        note = nil
        reload()
        DispatchQueue.main.async { [weak self, weak ed] in if let ed { self?.view.window?.makeFirstResponder(ed.text) } }
    }

    private func cancelEdit() {
        editor = nil
        reload()
    }

    private func save(_ snap: ProjectSnapshot, _ e: Epic) {
        guard let text = editor?.string, !saving else { return }
        guard text != (e.goal ?? "") else { cancelEdit(); return }
        saving = true
        note = nil
        reload()
        let args: [String: JSONValue] = ["project": .string(snap.summary.identifier), "epic": .string(e.id.rawValue), "goal": .string(text)]
        data.actions.run("epic.update", args) { [weak self] r in
            guard let self else { return }
            self.saving = false
            if case .ok = r { self.editor = nil } else { self.note = (.bad, r.summary) }
            self.reload()
        }
    }

    // MARK: Items

    private func itemsCard(_ snap: ProjectSnapshot, _ r: EpicRollup, _ items: [Item]) -> NSView {
        let c = Card(title: "Items", trailing: [NSTextField.text("Open first · then priority", size: 12, color: Palette.dim)], spacing: 2)
        if items.isEmpty {
            c.add(NSTextField.text("No loaded items. Use Add items.", size: 12.5, color: Palette.dim))
            return c
        }
        let open = items.filter { !snap.isClosed($0.statusOptionId) }
        let done = items.filter { snap.isClosed($0.statusOptionId) }
        let shownDone = allDone ? done : Array(done.prefix(Self.doneShown))
        for item in open + shownDone { c.add(itemLine(snap, item)) }
        // Items that are done but not loaded count here too.
        let hidden = r.done - shownDone.count
        if hidden > 0 || (allDone && done.count > Self.doneShown) {
            let text = allDone ? "Show fewer done items" : "\(hidden) more done item\(hidden == 1 ? "" : "s")"
            c.add(Row([Glyph(allDone ? "chevron.up" : "chevron.down", color: Palette.dim, size: 11),
                       NSTextField.text(text, size: 12.5, color: Palette.mut), Spacer()], height: 30, label: text) { [weak self] in
                self?.allDone.toggle()
                self?.reload()
            })
        }
        return c
    }

    private func itemLine(_ snap: ProjectSnapshot, _ item: Item) -> NSView {
        let st = data.statusJob.item(item.key)
        let opt = snap.option(item.statusOptionId)?.name ?? "No status"
        let key = NSTextField.text(item.key, size: 11.5, color: Palette.dim, mono: true).fixedWidth(96)
        let title = NSTextField.text(item.title, size: 13)
        title.setContentHuggingPriority(.init(1), for: .horizontal)
        let status: NSView = st.map { StatusPill($0) } ?? NSTextField.text(opt, size: 11.5, color: Palette.mut)
        let who: NSView = item.assignees.first.map { Avatar($0) } ?? Spacer(20)
        var label = "\(item.key) \(item.title). \(opt)"
        if let st { label += ", \(st.label)" }
        return Row([StatusGlyph.item(item, snap: snap).sized(16), key, title, status, who], height: 36, inset: 0, label: label) { [weak self] in
            self?.go(.item(item.key, .overview))
        }
    }

    private func itemsRow(_ snap: ProjectSnapshot, _ r: EpicRollup) -> PageRow {
        let items = members(snap, r.epic)
        let job = data.statusJob
        let live = items.map { [AnyHashable($0.key), AnyHashable(job.item($0.key)?.label)] }
        return PageRow("items", r.total, itemsSig(snap, items), allDone, live) { [unowned self] in self.itemsCard(snap, r, items) }
    }

    // MARK: Add items

    // The open items of the project that are not in the epic, as a list of checkboxes.
    private func addItems(_ snap: ProjectSnapshot, _ e: Epic) {
        let names = Dictionary((snap.epics ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { a, _ in a })
        let candidates = snap.items.filter { $0.epicId != e.id && !snap.isClosed($0.statusOptionId) }
            .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.prefix(200)
        guard !candidates.isEmpty else {
            AlertConfirm.tell("No items to add", info: "Each open item of \(snap.summary.identifier) is in \(e.title) already, or OverSire did not load it.", in: view.window)
            return
        }
        let boxes = candidates.map { i -> (NSButton, String) in
            let other = i.epicId.flatMap { names[$0] }.map { "  (now in \($0))" } ?? ""
            let b = NSButton(checkboxWithTitle: "\(i.key)  \(i.title)\(other)", target: nil, action: nil)
            b.lineBreakMode = .byTruncatingTail
            return (b, i.key)
        }
        let list = NSStackView(v: boxes.map(\.0), spacing: 6)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 420, height: min(list.fittingSize.height, 260)))
        list.frame = NSRect(x: 0, y: 0, width: 420, height: list.fittingSize.height)
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        AlertConfirm.show(.init(title: "Add items to \(e.title)?", info: "An item sits in one epic only. A checked item leaves its other epic.",
                                buttons: ["Add items", "Cancel"], accessory: scroll), in: view.window) { [weak self] r in
            guard let self, r.button == 0 else { return }
            let chosen = boxes.filter { $0.0.state == .on }.map(\.1)
            guard !chosen.isEmpty else { return }
            self.saving = true
            self.note = nil
            self.reload()
            let args: [String: JSONValue] = ["project": .string(snap.summary.identifier), "epic": .string(e.id.rawValue),
                                             "keys": .array(chosen.map(JSONValue.string))]
            self.data.actions.run("epic.addItems", args) { [weak self] r in
                guard let self else { return }
                self.saving = false
                if case .ok = r {} else { self.note = (.bad, r.summary) }
                self.reload()
            }
        }
    }

    // MARK: Progress

    private func progressCard(_ snap: ProjectSnapshot, _ r: EpicRollup, journal: [Event]?, history: [Event]?) -> NSView {
        let c = Card(title: "Progress")
        let big = NSTextField.text(r.total == 0 ? "No items" : "\(r.done) of \(r.total) done", size: 24, weight: .semibold)
        c.add(big)
        c.add(EpicBar(done: r.done, started: r.started, total: r.total, height: 8))
        let todo = max(0, r.total - r.done - r.started)
        func legend(_ shape: String, _ word: String, _ n: Int, _ color: NSColor) -> NSView {
            let v = NSStackView(h: [NSTextField.text(shape, size: 12, color: color), NSTextField.text("\(word) \(n)", size: 11.5, color: Palette.mut)], spacing: 4)
            v.setAccessibilityElement(true)
            v.setAccessibilityLabel("\(word), \(n)")
            return v
        }
        c.add(NSStackView(h: [legend("●", "Done", r.done, Palette.ok), legend("◐", "In progress", r.started, Palette.run), legend("○", "To do", todo, Palette.dim), Spacer()],
                          spacing: 12))
        if let burn = EPIC_BURNUPS.burnUp(r, epicRows: journal, now: Date()) {
            let chart = BurnUpChart(burn)
            c.add(chart)
            c.add(NSTextField.text("Dashed: scope · solid: done · last \(BurnUpChart.days / 7) weeks", size: 11, color: Palette.dim))
        } else if case .failed = EPIC_BURNUPS.part(r.epic.eventKey).state {
            c.add(NSTextField.text("The history is not available. The daemon did not answer.", size: 12, color: Palette.dim, lines: 2))
        } else {
            c.add(NSStackView(h: [Spinner(size: .mini), NSTextField.text("Loading the history", size: 12, color: Palette.dim)], spacing: 6))
        }
        return c
    }

    // MARK: Sessions

    private func sessionsCard(_ snap: ProjectSnapshot, _ items: [Item]) -> NSView {
        let job = data.statusJob
        let live = items.filter { job.item($0.key) != nil || data.questions.count(key: $0.key) > 0 }
        let c = Card(title: "Sessions", trailing: live.isEmpty ? [] : [NSTextField.text("\(live.count)", size: 12, color: Palette.dim)])
        guard !live.isEmpty else {
            c.add(NSTextField.text("No sessions run for these items.", size: 12.5, color: Palette.dim))
            return c
        }
        for item in live.prefix(8) {
            let asks = data.questions.count(key: item.key)
            let status: NSView = job.item(item.key).map { StatusPill($0) }
                ?? Pill(.question, text: "\(asks) question\(asks == 1 ? "" : "s")")
            let title = NSTextField.text(item.title, size: 12)
            title.setContentHuggingPriority(.init(1), for: .horizontal)
            c.add(Row([NSTextField.text(item.key, size: 11.5, color: Palette.dim, mono: true), title, status], height: 30, inset: 0,
                      label: "\(item.key) \(item.title), \(job.item(item.key)?.label ?? "waits for you")") { [weak self] in
                self?.go(.item(item.key, .overview))
            })
        }
        if live.count > 8 { c.add(NSTextField.text("\(live.count - 8) more", size: 11.5, color: Palette.dim)) }
        return c
    }

    // MARK: Recent

    /// The newest rows of the epic and its items. Views of an item are not news.
    private func recent(_ journal: [Event]?, _ history: [Event]?) -> [Event] {
        ItemJournal.merge(journal ?? [], history ?? []).filter { $0.kind != .itemViewed }.reversed()
    }

    private func recentCard(_ journal: [Event]?, _ history: [Event]?) -> NSView {
        let rows = Array(recent(journal, history).prefix(10))
        let c = Card(title: "Recent", trailing: [ActionButton("Timeline", style: .link) { [weak self] in
            guard let self, case .epic(let p, let id, _) = self.route else { return }
            self.go(.epic(p, id, .timeline))
        }])
        guard !rows.isEmpty else {
            c.add(NSTextField.text(journal == nil ? "Loading the activity…" : "No activity yet.", size: 12.5, color: Palette.dim))
            return c
        }
        for e in rows {
            let text = NSTextField.text(e.headline, size: 12, lines: 2)
            let at = e.at
            let sub = NSStackView(h: [NSTextField.text(e.item ?? "", size: 11, color: Palette.dim, mono: true), RelativeTimeLabel({ at }, size: 11)], spacing: 6)
            let v = NSStackView(v: [text, sub], spacing: 2)
            v.setAccessibilityElement(true)
            v.setAccessibilityLabel("\(e.headline), \(e.item ?? ""), \(relativeTime(at))")
            c.add(v)
        }
        return c
    }

    // MARK: Timeline

    private func timelineRow(_ r: EpicRollup) -> PageRow {
        let key = r.epic.eventKey
        let journal = JOURNAL.rows(key), history = EPIC_BURNUPS.rows(key)
        let part = JOURNAL.part(key)
        return PageRow("timeline", journal?.count, history?.count, journal?.last?.id, part.state) { [unowned self] in
            let rows = Array(self.recent(journal, history).prefix(300))
            let c = Card(title: "Timeline", trailing: [ReadAccessory(part)])
            guard !rows.isEmpty else {
                c.add(journal == nil ? LoadingNote("Loading the activity", height: 60, compact: true) : EmptyNote("No activity yet.", symbol: "clock"))
                return c
            }
            for e in rows {
                let at = NSTextField.text(timestampFmt.string(from: e.at), size: 11.5, color: Palette.dim).fixedWidth(110)
                let item = NSTextField.text(e.item ?? "", size: 11.5, color: Palette.dim, mono: true).fixedWidth(110)
                let tag = EventTag(e.kind).view()
                let tagBox = NSStackView(h: [tag, Spacer()], spacing: 0).fixedWidth(90)
                let text = NSTextField.text(e.headline, size: 12.5)
                text.setContentHuggingPriority(.init(1), for: .horizontal)
                c.add(Row([at, item, tagBox, text], height: 30, inset: 0,
                          label: "\(timestampFmt.string(from: e.at)), \(e.item ?? ""), \(EventTag(e.kind).word), \(e.headline)"))
            }
            return c
        }
    }
}

private extension EpicRollup {
    var due: String { EpicBoard.due(self) }
}
