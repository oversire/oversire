import Cocoa
import OverSireCore
import OverSireSync
import OverSireAssistant

// A chip that opens a menu of choices, for status, priority and the like.
final class MenuChip: Chiplet {
    private var actions: [MenuAction] = []

    init(_ text: String, symbol: String? = nil, icon: NSView? = nil, color: NSColor = Palette.fg, choices: @escaping () -> [MenuAction]) {
        super.init(text, symbol: symbol, icon: icon, color: color)
        onClick = { [weak self] in
            guard let self else { return }
            self.actions = choices()
            let m = NSMenu()
            self.actions.forEach { m.addItem($0.item) }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: self.bounds.height + 3), in: self)
        }
        setAccessibilityRole(.popUpButton)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// The page of one work item: its summary, status, session, sub-items and activity.
final class ItemPage: Page, NSTextFieldDelegate {
    override var fillsHeight: Bool { tab == .subitems }
    private let subTable = ColumnLayout(id: "subitems-2", columns: ItemLine.columns())
    private enum Source: String, CaseIterable { case all = "All", plane = "Plane", github = "GitHub", orca = "Orca", oversire = "OverSire" }

    private let markdown = MarkdownView(width: 600)
    private var markdownHeight: NSLayoutConstraint?
    private let summaryMarkdown = MarkdownView(width: 600)
    private var summaryHeight: NSLayoutConstraint?
    private var descriptionOpen = false
    private var hiddenSummaries: Set<String> = []
    private var timeline: [ActivityEntry]?
    private var tail: [String] = []
    /// The live terminal or chat of the session, when its daemon gives a stream (OVERSIRE-285, OVERSIRE-286).
    private var live: LiveSessionCard?
    private var streamChecked = Date.distantPast
    private var tailAt = Date.distantPast
    private var saving: String?
    private var note: (Tone, String)?
    private var cleanupOff: Set<String> = []   // safe cleanup lines that the user unchecked
    private var activitySource = Source.all
    private var replyField: NSTextField?
    private var commentField: NSTextField?
    private var askField: NSTextField?
    private var asking = false
    private var sending = false
    private var pendingComment: String?
    private var questionCards: [QuestionID: QuestionCard] = [:]
    private lazy var needsYou = NeedsYouCard(page: self)

    override var pageWidth: CGFloat { 960 }

    private var key: String { if case .item(let k, _) = route { return k }; return "" }
    private var tab: Route.ItemTab { if case .item(_, let t) = route { return t }; return .overview }

    override func viewDidLoad() {
        markdown.translatesAutoresizingMaskIntoConstraints = true
        markdown.onHeight = { [weak self] h in self?.markdownHeight?.constant = max(24, h) }
        summaryMarkdown.translatesAutoresizingMaskIntoConstraints = true
        summaryMarkdown.onHeight = { [weak self] h in self?.summaryHeight?.constant = max(20, h) }
        super.viewDidLoad()
    }

    override func show(_ r: Route) {
        if case .item(let k, let t) = r, k != key || t != tab {
            if k != key { timeline = nil; tail = []; descriptionOpen = false }
            tailAt = .distantPast
            dropLive()
        }
        super.show(r)
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        dropLive()
    }

    private func dropLive() {
        live?.stop()
        live = nil
        streamChecked = .distantPast
    }

    override var watches: DataDomains {
        var d: DataDomains = [.projects, .agents, .questions, .queue, .summaries, .config, .intake]
        switch tab {
        case .overview: d.formUnion([.relations, .planner, .runs, .prs])
        case .session, .activity: d.formUnion([.runs, .prs])
        case .subitems: break
        }
        return d
    }
    override var shownItems: Set<String>? { [key.uppercased(), key] }
    override var shownProjects: Set<String>? { data.projectStore.item(key: key).map { [$0.0] } }

    override var isEditing: Bool {
        super.isEditing || !(replyField?.stringValue.isEmpty ?? true) || !(commentField?.stringValue.isEmpty ?? true) || !(askField?.stringValue.isEmpty ?? true)
            || questionCards.values.contains { $0.isTyping }
    }

    // The fetches of the page run here, not in `sections()`: the window calls `sections()` for each change.
    override func reload(reason: String) {
        if let (_, _, item) = data.projectStore.item(key: key) {
            loadData(item: item, stream: data.workstreams.stream(key))
            if tab == .overview, data.projectStore.relations.supports(item.key) { data.projectStore.relations.load([item.key]) }
        } else {
            pageBusy = data.projectsLoading
        }
        super.reload(reason: reason)
    }

    // Each row hash holds only what the row shows. A change updates only the rows whose data changed.
    override func sections() -> [PageSection]? {
        let store = data.projectStore
        guard let (pk, snap, item) = store.item(key: key) else {
            let k = key, loading = data.projectsLoading
            return [PageSection("missing", rows: [
                PageRow("header", k) { PageHeader(k, caption: "Work item") },
                PageRow("body", k, loading) {
                    guard loading else {
                        return EmptyNote("OverSire has no item \(k). It may be in a project that OverSire does not track, or it was deleted.",
                                         symbol: "questionmark.square.dashed")
                    }
                    let c = ListCard()
                    c.add(LoadingNote("Loading \(k)"))
                    return c
                },
            ])]
        }
        let stream = data.workstreams.stream(key)
        var top = [headRow(snap: snap, item: item)]
        if let note { top.append(PageRow("note", "\(note.0)", note.1) { Banner(note.0, title: note.1) }) }
        if snap.isDoneWithOpenSubItems(item) { top.append(openSubItemsRow(snap: snap, item: item)) }
        top.append(tabsRow(snap: snap, item: item))
        let rows: [PageRow]
        switch tab {
        case .overview: rows = overview(pk: pk, snap: snap, item: item, stream: stream)
        case .session: rows = session(stream: stream)
        case .subitems: rows = subItems(snap: snap, item: item)
        case .activity: rows = activity(item: item, stream: stream)
        }
        return [PageSection("top", rows: top), PageSection(tab.rawValue, rows: rows)]
    }

    // A hash part for values that are not Hashable.
    private static func sig(_ parts: Any?...) -> String { parts.map { String(describing: $0) }.joined(separator: "|") }

    private func tabsRow(snap: ProjectSnapshot, item: Item) -> PageRow {
        let prog = snap.progress(of: item.id)
        let started = snap.started(of: item.id)
        let warn = snap.isDoneWithOpenSubItems(item)
        let asks = data.questions.count(key: key)
        let tab = self.tab
        return PageRow("tabs", tab, prog.done, started, prog.total, warn, asks) { [unowned self] in
            let tabs = Route.ItemTab.allCases
            var sub = TabStrip.Tab(title: "Sub-items")
            if prog.total > 0 {
                sub.lead = [ProgressRing(done: prog.done, started: started, total: prog.total).sized(14)]
                if warn { sub.trail = [Glyph("exclamationmark.triangle.fill", color: Palette.warn, size: 11)] }
                sub.label = "Sub-items, \(prog.done) of \(prog.total) done" + (warn ? ", Done with open sub-items" : "")
            }
            let sessionTab = TabStrip.Tab(title: "Session", count: asks > 0 ? asks : nil,
                                          label: asks > 0 ? "Session, \(asks) question\(asks == 1 ? "" : "s")" : nil)
            let strip = TabStrip(tabs: [TabStrip.Tab(title: "Overview"), sessionTab, sub, TabStrip.Tab(title: "Activity")],
                                 selected: tabs.firstIndex(of: tab) ?? 0)
            strip.onSelect = { [weak self] i in guard let self else { return }; self.go(.item(self.key, tabs[i])) }
            return NSStackView(h: [strip, Spacer()])
        }
    }

    private func loadData(item: Item, stream: Workstream?) {
        if timeline == nil {
            data.projectStore.timeline(itemId: item.id) { [weak self] e in
                guard let self, self.key == item.key else { return }
                self.timeline = e
                if self.tab == .activity { self.reload() }
            }
        }
        if let a = stream?.agent, tab == .session, live?.sessionID != a.paneKey, -streamChecked.timeIntervalSinceNow > 15 {
            streamChecked = Date()
            let k = key
            data.agentIndex.stream(k) { [weak self] t in
                guard let self, self.key == k, self.tab == .session, let t, let id = a.paneKey else { return }
                self.live?.stop()
                self.live = t.view == .chat ? self.chatCard(a, session: id, request: t.request) : self.terminalCard(session: id, request: t.request)
                self.reload()
            }
        }
        if stream?.agent != nil, live == nil, tab == .session, -tailAt.timeIntervalSinceNow > 5 {
            tailAt = Date()
            data.agentIndex.tail(key, lines: 60) { [weak self] lines in
                guard let self, lines != self.tail else { return }
                self.tail = lines
                if !self.isEditing { self.reload() }
            }
        }
    }

    // MARK: Head and properties

    private func headRow(snap: ProjectSnapshot, item: Item) -> PageRow {
        let prog = snap.progress(of: item.id)
        let cleanup = data.cleaner.lines(item.key, data: data)
        return PageRow("head", item, snap.summary, snap.statusOptions, prog.done, prog.total, snap.openSubItems(of: item.id),
                       snap.canCloseParent(item), data.questions.count(key: key), saving, data.queue.contains(key),
                       Self.sig(cleanup, data.statusJob.item(key)), canEnhance) { [unowned self] in self.head(snap: snap, item: item, cleanup: cleanup) }
    }

    private var enhanceTarget: EnhanceTarget? {
        data.projectStore.item(key: key).flatMap { $0.item.ref(in: $0.snap.summary.ref) }.map { .item($0) }
    }

    private var canEnhance: Bool {
        guard let t = enhanceTarget else { return false }
        return data.enhanceAgent.available && data.enhanceAgent.state(t) == nil
    }

    private func head(snap: ProjectSnapshot, item: Item, cleanup: [CleanupLine]) -> NSView {
        let project = Chiplet(snap.summary.title, symbol: "folder", color: Palette.acc) { [weak self] in self?.go(.project(snap.summary.identifier)) }
        let copy = Chiplet(item.key, symbol: "doc.on.doc", color: Palette.dim, mono: true)
        copy.toolTip = "Copy \(item.key)"
        copy.setAccessibilityLabel("Copy \(item.key)")
        copy.onClick = { [weak copy] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(item.key, forType: .string)
            copy?.flash("Copied")
        }
        var top: [NSView] = [copy, project, Spacer()]
        let asks = data.questions.count(key: key)
        if asks > 0 { top.append(Pill(.question, text: "Waits for you · \(asks) question\(asks == 1 ? "" : "s")")) }
        let keyLine = NSStackView(h: top, spacing: 8)
        var chips: [NSView] = [statusChip(snap: snap, item: item)]
        if !snap.isDoneWithOpenSubItems(item),
           let c = ItemLine.finishChip(item, snap: snap, cleanup: cleanup) { chips.append(c) }
        if snap.canCloseParent(item), let done = snap.firstState(group: "completed", else: .done) {
            let b = ActionButton("Close parent?", style: .link) { [weak self] in self?.save("status", "item.setStatus", done.id) }
            b.toolTip = "All sub-items are finished. Set \(item.key) to \(done.name)."
            chips.append(b)
        }
        chips.append(priorityChip(item))
        chips += item.labels.prefix(4).map { Chiplet($0, symbol: "tag") as NSView }
        if !item.assignees.isEmpty { chips.append(Chiplet(item.assignees.joined(separator: ", "), symbol: "person")) }
        let at = item.activityAt
        chips.append(RelativeTimeLabel({ at }, size: 12, format: { "Updated " + $0 }))
        if let saving { chips.append(NSStackView(h: [Spinner(size: .mini), NSTextField.text("Saving \(saving)…", size: 12, color: Palette.dim)], spacing: 5)) }
        let inQueue = data.queue.contains(key)
        var actions: [NSView] = [ActionButton(inQueue ? "In the queue" : "Add to queue", symbol: "text.line.first.and.arrowtriangle.forward") { [weak self] in
            guard let self else { return }
            if inQueue { self.go(.work(.items)) } else { self.data.actions.run("queue.add", ["key": .string(key)]) { _ in self.reload() } }
        }]
        if let s = data.statusJob.item(key) {
            actions.append(StatusPill(s))
        } else {
            // A split button: the left part starts with the default agent, the arrow picks another one for one start.
            let b = ActionButton("Start in Orca", symbol: "play.fill", style: .primary)
            b.onClick = { [weak self, weak b] in
                guard let self, let b else { return }
                SessionStartMenu(self.data).start(item, snap: snap, at: b)
            }
            let more = ActionButton("", symbol: "chevron.down", style: .primary)
            more.setAccessibilityLabel("Start in Orca with")
            more.toolTip = "Start in Orca with another agent"
            more.onClick = { [weak self, weak b, weak more] in
                guard let self, let b, let more else { return }
                SessionStartMenu(self.data).agents(item, snap: snap, at: b).popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.height + 2), in: more)
            }
            actions.append(NSStackView(h: [b, more], spacing: 1))
        }
        if canEnhance, let t = enhanceTarget {
            let b = ActionButton("Enhance", symbol: "sparkles") { [weak self] in self?.data.enhanceAgent.start(projectKey: snap.summary.ref.storeKey, target: t) }
            b.toolTip = "A read-only agent reads the code and writes a better description"
            actions.insert(b, at: 0)
        }
        actions += [
            ActionButton("Copy link", symbol: "link") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Route.item(self.key, .overview).url.absoluteString, forType: .string)
            },
            ActionButton("Open in Plane", symbol: "arrow.up.right.square") { NSWorkspace.shared.open(URL(string: item.url)!) },
        ]
        let v = NSStackView(v: [], spacing: 7)
        v.addFull(keyLine)
        v.addFull(NSTextField.text(item.title, size: 22, weight: .semibold, lines: 3))
        v.addFull(NSStackView(h: [Wrap(chips), Spacer()] + actions, spacing: 6))
        return v
    }

    private func statusChip(snap: ProjectSnapshot, item: Item) -> NSView {
        let opt = snap.option(item.statusOptionId)
        let open = snap.isDoneWithOpenSubItems(item) ? snap.openSubItems(of: item.id) : 0
        let name = (opt?.name ?? "No status") + (open > 0 ? " · \(open) sub-item\(open == 1 ? "" : "s") open" : "")
        let glyph = StatusGlyph.item(item, snap: snap).sized(12)
        return MenuChip(name, icon: glyph) { [weak self] in
            snap.statusOptions.map { o in
                let a = MenuAction(o.name) { self?.save("status", "item.setStatus", o.id) }
                a.item.state = o.id == item.statusOptionId ? .on : .off
                return a
            }
        }
    }

    // MARK: Done with open sub-items

    private func openSubItemsRow(snap: ProjectSnapshot, item: Item) -> PageRow {
        let open = snap.openDescendants(of: item.id)
        return PageRow("open-subs", open, snap.progress(of: item.id).total, snap.option(item.statusOptionId)?.name) { [unowned self] in
            self.openSubItemsBanner(snap: snap, item: item, open: open)
        }
    }

    private func openSubItemsBanner(snap: ProjectSnapshot, item: Item, open: [String]) -> NSView {
        let total = snap.progress(of: item.id).total
        let closeTitle = "Close \(open.count) sub-item\(open.count == 1 ? "" : "s")"
        return Banner(.warning, title: "Plane says \(snap.option(item.statusOptionId)?.name ?? "Done"), but \(open.count) of \(max(total, open.count)) sub-items are open.",
                      body: "OverSire counts this item as not finished. Close the sub-items, or move the parent back to In progress.",
                      actions: [
                        ActionButton(closeTitle, symbol: "checkmark.circle", style: .primary) { [weak self] in self?.closeSubItems(open, snap: snap, item: item) },
                        ActionButton("Reopen parent", symbol: "arrow.uturn.backward") { [weak self] in
                            guard let self else { return }
                            self.saving = "status"
                            self.reload()
                            self.data.actions.run("item.reopen", ["key": .string(item.key)]) { [weak self] in self?.saved($0) }
                        },
                      ])
    }

    // A sheet with one checkbox for each open sub-item. Sub-items that OverSire did not load share one box.
    private func closeSubItems(_ ids: [String], snap: ProjectSnapshot, item: Item) {
        let loaded = ids.compactMap { id in snap.items.first { $0.id == id } }
        let stubs = ids.filter { id in !loaded.contains { $0.id == id } }
        var boxes: [(NSButton, [String])] = loaded.map { (NSButton(checkboxWithTitle: "\($0.key)  \($0.title)", target: nil, action: nil), [$0.id]) }
        if !stubs.isEmpty {
            boxes.append((NSButton(checkboxWithTitle: "\(stubs.count) more sub-item\(stubs.count == 1 ? "" : "s") that OverSire did not load", target: nil, action: nil), stubs))
        }
        boxes.forEach { $0.0.state = .on; $0.0.lineBreakMode = .byTruncatingTail }
        let list = NSStackView(v: boxes.map(\.0), spacing: 6)
        list.frame = NSRect(x: 0, y: 0, width: 380, height: list.fittingSize.height)
        let state = snap.firstState(group: "completed", else: .done)?.name ?? "Done"
        AlertConfirm.show(.init(title: "Close the open sub-items of \(item.key)?", info: "OverSire sets each checked sub-item to \(state) and adds a comment.",
                                buttons: ["Close sub-items", "Cancel"], accessory: list), in: view.window) { [weak self] r in
            guard let self, r.button == 0 else { return }
            let chosen = boxes.filter { $0.0.state == .on }.flatMap(\.1)
            guard !chosen.isEmpty else { return }
            self.saving = "sub-items"
            self.note = nil
            self.reload()
            self.data.actions.run("item.closeSubItems", ["key": .string(item.key), "keys": .array(chosen.map(JSONValue.string))]) { [weak self] in self?.saved($0) }
        }
    }

    private func saved(_ r: ActionResult) {
        saving = nil
        if case .ok = r {} else { note = (.bad, r.summary) }
        reload()
    }

    // MARK: Cleanup

    // The card updates in place, so a check or a run does not build the page again.
    private func cleanupRow(_ item: Item) -> PageRow? {
        let lines = data.cleaner.lines(item.key, data: data)
        guard !lines.isEmpty else { return nil }
        let off = cleanupOff, running = data.cleaner.running.contains(item.key.uppercased())
        return PageRow("cleanup", Self.sig(lines), off, running, update: { ($0 as? CleanupCard)?.show(lines, off: off, running: running) }) { [unowned self] in
            let c = CleanupCard(run: { [weak self] in self?.runCleanup() }) { [weak self] id in
                guard let self else { return }
                if self.cleanupOff.remove(id) == nil { self.cleanupOff.insert(id) }
                self.reload()
            }
            c.show(lines, off: off, running: running)
            return c
        }
    }

    // The Cleaner posts a change for this item when the run starts and ends.
    private func runCleanup() {
        let chosen = data.cleaner.lines(key, data: data).filter { $0.safe && $0.removable && !cleanupOff.contains($0.id) }
        guard !chosen.isEmpty else { return }
        data.actions.run("worktree.remove", ["key": .string(key), "lines": .array(chosen.map { .string($0.id) })]) { [weak self] r in
            guard let self else { return }
            let failed: Bool = { if case .ok = r { return false } else { return true } }()
            guard failed || self.note != nil else { return }
            self.note = failed ? (.bad, r.summary) : nil
            self.reload()
        }
    }

    private func priorityChip(_ item: Item) -> NSView {
        let cur = item.fields["Priority"] ?? "None"
        return MenuChip(cur == "None" ? "No priority" : cur, symbol: "flag") { [weak self] in
            StatusOption.priorities.map { p in
                let a = MenuAction(p.name) { self?.save("priority", "item.setPriority", p.id) }
                a.item.state = p.name == cur ? .on : .off
                return a
            }
        }
    }

    // `what` names the busy chip. `action` takes the key and one option id.
    private func save(_ what: String, _ action: String, _ option: String) {
        saving = what
        note = nil
        reload()
        data.actions.run(action, ["key": .string(key), what == "status" ? "status" : "priority": .string(option)]) { [weak self] in self?.saved($0) }
    }

    // MARK: Overview

    private func overview(pk: String, snap: ProjectSnapshot, item: Item, stream: Workstream?) -> [PageRow] {
        let body = (item.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sums = data.itemSummaries
        let k = item.key.uppercased()
        let long = ItemSummaries.offers(body)
        let summary = hiddenSummaries.contains(item.key) ? nil : sums.summary(item.key)
        let busy = sums.busy.contains(k)
        var rows: [PageRow] = []
        if summary != nil || busy || (long && (sums.hasEngine || sums.errors[k] != nil)) {
            let linked = ItemPage.linkedKeys(body, except: k).filter { data.projectStore.item(key: $0) != nil }
            rows.append(PageRow("summary", Self.sig(summary), busy, sums.errors[k], summary != nil && sums.isStale(k, body: body), sums.hasEngine,
                                AI_CFG.itemSummary, linked, body.count) { [unowned self] in
                self.summaryPanel(item, body: body, summary: summary, busy: busy, linked: linked)
            })
        }
        if let r = enhanceRow(pk: pk) { rows.append(r) }
        rows += questionRows()
        rows.append(statusRow(stream: stream))
        if let r = cleanupRow(item) { rows.append(r) }
        if hasCloud, data.suggestions.openPlan(naming: item.key) != nil {
            rows.append(PageRow("suggestion", item.key) { [unowned self] in self.suggestion(item) })
        }
        if let r = plannerRow(item) { rows.append(r) }
        if let r = attachmentRow(snap: snap, item: item) { rows.append(r) }
        let open = descriptionOpen, hasSummary = summary != nil
        rows.append(PageRow("description", body, hasSummary, open, pk) { [unowned self] in
            self.descriptionCard(body, pk: pk, hasSummary: hasSummary, open: open)
        })
        return rows
    }

    // The hash holds each input of StatusCard.
    private func statusRow(stream: Workstream?) -> PageRow {
        let job = data.statusJob, agents = data.agentIndex
        let k = key.uppercased()
        let s = job.status(k)
        let print = Self.sig(s, job.reading.contains(k), stream, agents.agent(k), job.item(k), s.flatMap(job.outOfDate), job.on,
                             agents.watch(k)?.recap, data.projectStore.isDone(key: k), AGENTS.writeBack, data.questions.entries(key: key))
        return PageRow("status", print) { [unowned self] in
            StatusCard(key: self.key, stream: stream, data: self.data, needsYou: self.needsYou) { [weak self] in self?.go($0) }.build()
        }
    }

    // The web view keeps its holder while the body stays the same.
    // No row for an item with no files, or before the first list.
    private func attachmentRow(snap: ProjectSnapshot, item: Item) -> PageRow? {
        let book = data.attachments
        guard let ref = item.ref(in: snap.summary.ref), let files = book.files(of: ref, changedAt: item.activityAt), !files.isEmpty else { return nil }
        return PageRow("attachments", hash: PageRow.hash(AttachmentStrip.sig(files, of: ref, book: book))) { AttachmentStrip(files, of: ref, book: book) }
    }

    private func descriptionCard(_ body: String, pk: String, hasSummary: Bool, open: Bool) -> NSView {
        let d = Card(title: "Description", trailing: body.isEmpty ? [] : [NSTextField.text("\(body.count.formatted()) characters", size: 12, color: Palette.dim)])
        if body.isEmpty {
            d.add(NSTextField.text("No description.", size: 12.5, color: Palette.dim))
            return d
        }
        if hasSummary {
            d.add(Row([Glyph(open ? "chevron.down" : "chevron.right", color: Palette.dim, size: 11),
                       NSTextField.text(open ? "Hide full description" : "Show full description", size: 12.5, color: Palette.mut), Spacer()],
                      height: 26, inset: 2, label: open ? "Hide full description" : "Show full description") { [weak self] in
                self?.descriptionOpen.toggle()
                self?.reload()
            })
        }
        if !hasSummary || open {
            d.add(markdownHolder(markdown, height: &markdownHeight, min: 24))
            data.projectStore.resolveImages(body, projectKey: pk) { [weak self] out in self?.markdown.show(out, mode: .rendered) }
        }
        return d
    }

    private func markdownHolder(_ view: MarkdownView, height: inout NSLayoutConstraint?, min: CGFloat) -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        view.removeFromSuperview()
        holder.addSubview(view)
        view.autoresizingMask = [.width, .height]
        view.frame = holder.bounds
        let h = holder.heightAnchor.constraint(equalToConstant: max(min, view.contentHeight))
        h.isActive = true
        height = h
        return holder
    }

    // MARK: Summary

    // The Summary card: the AI summary of a long description, a placeholder while the AI works, or the error.
    private func summaryPanel(_ item: Item, body: String, summary: ItemSummary?, busy: Bool, linked: [String]) -> NSView {
        let sums = data.itemSummaries
        let k = item.key.uppercased()
        var head: [NSView] = []
        if AI_CFG.itemSummary, sums.hasEngine {
            let auto = Chiplet("Auto", symbol: "sparkles", color: Palette.run)
            auto.toolTip = "OverSire summarizes open items that changed in the last 7 days (Settings › AI)"
            head.append(auto)
        }
        if let summary { head.append(NSTextField.text(relativeTime(summary.at), size: 12, color: Palette.dim)) }
        if busy {
            head.append(NSStackView(h: [Spinner(size: .mini), NSTextField.text("Summarizing…", size: 12, color: Palette.dim)], spacing: 5))
        } else if sums.hasEngine {
            let b = ActionButton(summary == nil ? "Summarize" : "Refresh", symbol: summary == nil ? "sparkles" : "arrow.clockwise",
                                 style: summary == nil ? .plain : .link, key: "S") { [weak self] in
                guard let self else { return }
                self.hiddenSummaries.remove(item.key)
                sums.summarize(item)
                self.reload()
            }
            b.toolTip = "Ask the AI for a summary of the description (⌘⇧S)"
            head.append(b)
        }
        if summary != nil {
            head.append(ActionButton("Hide", style: .link) { [weak self] in
                self?.hiddenSummaries.insert(item.key)
                self?.reload()
            })
        }
        let c = Card(title: "Summary", trailing: head, spacing: 9)
        if let err = sums.errors[k], !busy {
            c.add(Banner(.bad, title: "No summary.", body: err,
                         actions: sums.hasEngine ? [ActionButton("Retry") { sums.summarize(item) }] : []))
        } else if summary != nil, sums.isStale(k, body: body), !busy {
            c.add(Banner(.warning, title: "The description changed after this summary.", body: "Click Refresh for a new one."))
        }
        if let summary {
            c.add(markdownHolder(summaryMarkdown, height: &summaryHeight, min: 20))
            summaryMarkdown.show(summary.markdown, mode: .rendered)
            if !linked.isEmpty {
                let chips = linked.map { key in Chiplet(key, symbol: "link") { [weak self] in self?.go(.item(key, .overview)) } as NSView }
                c.add(NSStackView(h: [NSTextField.text("Linked:", size: 12, color: Palette.dim), Wrap(chips), Spacer()], spacing: 6))
            }
            c.add(NSTextField.text("From the description of \(body.count.formatted()) characters · \(summary.length.formatted()) characters",
                                   size: 11.5, color: Palette.dim))
        } else if busy {
            c.add(NSTextField.text("The AI reads \(body.count.formatted()) characters. You can leave this page. The summary goes into the cache.",
                                   size: 12.5, color: Palette.dim, lines: 2))
        } else {
            c.add(NSTextField.text("The description has \(body.count.formatted()) characters. Click Summarize for a short summary.",
                                   size: 12.5, color: Palette.dim, lines: 2))
        }
        return c
    }

    // Item keys in a description, in order, without repeats. Pure, for the selftest.
    static func linkedKeys(_ body: String, except: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: "\\b[A-Z][A-Z0-9]{1,15}-[0-9]{1,6}\\b") else { return [] }
        var out: [String] = []
        for m in re.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let r = Range(m.range, in: body) else { continue }
            let k = String(body[r])
            if k != except, !out.contains(k) { out.append(k) }
            if out.count == 8 { break }
        }
        return out
    }

    // MARK: Planner

    private func plannerRow(_ item: Item) -> PageRow? {
        let rc = data.projectStore.relations
        guard rc.supports(item.key) else { return nil }
        let rels = rc.relations(item.key)
        let project = data.projectStore.item(key: item.key)?.snap.summary.ref.storeKey ?? ""
        let areas = self.areas(item) ?? []
        let shown = (rels ?? []).map { r in data.projectStore.item(key: r.item.key)?.item }
        let print = Self.sig(rels, shown, data.projectStore.blockers(of: item.key), self.areas(item), areas.map { data.planner.kind($0, project: project) },
                             rc.errors[item.key.uppercased()])
        return PageRow("planner", print) { [unowned self] in self.plannerCard(item) }
    }

    private func plannerCard(_ item: Item) -> NSView {
        let rc = data.projectStore.relations
        let actions = PlannerCard.Actions(
            open: { [weak self] k in self?.go(.item(k, .overview)) },
            add: { [weak self] k in self?.pickRelation(k, for: item) },
            remove: { [weak self] r in self?.writeRelations(RelationPatch(remove: [r]), item: item) },
            editAreas: { [weak self] in self?.editAreas(item) })
        let project = data.projectStore.item(key: item.key)?.snap.summary.ref.storeKey ?? ""
        let planner = data.planner
        return PlannerCard(relations: rc.relations(item.key), store: data.projectStore, openBlockers: data.projectStore.blockers(of: item.key),
                            areas: areas(item), kind: { planner.kind($0, project: project) }, error: rc.errors[item.key.uppercased()], actions: actions)
    }

    private func pickRelation(_ kind: RelationKind, for item: Item) {
        guard let w = view.window?.windowController as? AppWindow else { return }
        let title = PlannerCard.groups.first { $0.0 == kind }?.1 ?? ""
        let have = Set((data.projectStore.relations.relations(item.key) ?? []).map(\.item.key))
        CommandPalette.pickItem(over: w, prompt: "\(title) \(item.key): type a key or a title", exclude: have.union([item.key])) { [weak self] k in
            guard let self, let found = self.data.projectStore.item(key: k), let ref = found.item.ref(in: found.snap.summary.ref) else { return }
            self.writeRelations(RelationPatch(add: [ItemRelation(kind: kind, item: ref)]), item: item)
        }
    }

    private func writeRelations(_ patch: RelationPatch, item: Item) {
        saving = "relations"
        reload()
        data.projectStore.relations.apply(patch, to: item.key) { [weak self] err in
            guard let self else { return }
            self.saving = nil
            self.note = err.map { (.bad, "Could not change the relations: \($0)") }
            self.reload()
        }
    }

    /// Nil without a cloud account.
    private func areas(_ item: Item) -> [String]? {
        guard hasCloud, let ref = itemRef(item) else { return nil }
        return data.areas.areas(of: ref)
    }

    private func itemRef(_ item: Item) -> ItemRef? {
        data.projectStore.item(key: item.key).flatMap { item.ref(in: $0.snap.summary.ref) }
    }

    private func editAreas(_ item: Item) {
        guard let ref = itemRef(item) else { return }
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        f.stringValue = data.areas.areas(of: ref).joined(separator: ", ")
        f.placeholderString = "api, status-page"
        let r = AlertConfirm.run(.init(title: "Code areas of \(item.key)",
                                       info: "The queue does not start two items with the same area at a time. Use commas between the areas. "
                                           + "An area has lower-case letters, digits and hyphens. At most \(ItemAreas.maxAreas) areas.",
                                       buttons: ["Save", "Cancel"], accessory: f, focus: f))
        guard r.button == 0 else { return }
        data.areas.save(f.stringValue.split(separator: ",").map(String.init), for: ref)
        reload()
    }

    private func suggestion(_ item: Item) -> NSView {
        Banner(.info, title: "The Planner has a plan change for \(item.key).",
                      actions: [ActionButton("Review") { [weak self] in self?.go(.work(.lanes)) }])
    }

    private func replyRow() -> NSView {
        let f = NSTextField()
        f.placeholderString = "Send to the session…"
        f.setAccessibilityLabel("Reply to the session")
        f.delegate = self
        f.stringValue = replyField?.stringValue ?? ""
        f.target = self
        f.action = #selector(sendReply)
        replyField = f
        let b = ActionButton("Send", style: .primary) { [weak self] in self?.sendReply() }
        if sending { b.busy("Sending…") }
        return NSStackView(h: [f, b], spacing: 6)
    }

    @objc private func sendReply() {
        guard let f = replyField else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending else { return }
        sending = true
        reload()
        // The Send click is the consent: no second ask.
        data.actions.run("session.send", ["key": .string(key), "text": .string(text)]) { [weak self] r in
            guard let self else { return }
            self.sending = false
            if case .ok = r { self.replyField?.stringValue = ""; self.note = nil; self.tailAt = .distantPast } else { self.note = (.bad, "Could not send: \(r.summary)") }
            self.reload()
        }
    }

    // MARK: Session

    // The question cards of the item. Overview and Session both show them; one tab builds at a time.
    private func enhanceRow(pk: String) -> PageRow? {
        guard let t = enhanceTarget, let state = data.enhanceAgent.state(t) else { return nil }
        return PageRow("enhance", Self.sig(state)) { [unowned self] in
            EnhancePanel(state, projectKey: pk, target: t, agent: self.data.enhanceAgent, questions: self.data.questions) { [weak self] err in
                self?.note = err.map { (.bad, $0) }
                self?.reload()
            }
        }
    }

    // The questions of an Enhance worker show in its card.
    private func questionRows() -> [PageRow] {
        let enhancing = enhanceTarget.flatMap { data.enhanceAgent.state($0)?.run?.session }
        let entries = data.questions.entries(key: key).filter { $0.question.session != enhancing }
        questionCards = questionCards.filter { id, _ in entries.contains { $0.question.id == id } }
        return entries.map { e in
            PageRow("q-\(e.question.id)", e) { [unowned self] in
                let c = self.data.questions.card(e)
                self.questionCards[e.question.id] = c
                return c
            }
        }
    }

    private func session(stream: Workstream?) -> [PageRow] {
        var rows = DaemonBanner.rows() + questionRows()
        if let a = stream?.agent {
            let s = data.statusJob.item(key)
            if let live, live.sessionID == a.paneKey {
                let fill = { [unowned self] in live.setHead(self.liveChips(a, chat: live is SessionChatCard), since: a.since) }
                rows.append(PageRow("live-" + live.sessionID, ObjectIdentifier(live), Self.sig(a, s), sending, update: { _ in fill() }) { fill(); return live })
            } else {
                rows.append(PageRow("terminal", Self.sig(a, s), tail, sending) { [unowned self] in self.terminalCard(a, status: s) })
            }
        } else {
            rows.append(PageRow("no-session", key) { Banner(.idle, title: "No Orca session yet.", body: "Start the item in Orca to see its session here.") })
        }
        let notes = data.sessions, k = key.uppercased(), hasAgent = stream?.agent != nil
        rows.append(PageRow("summary", Self.sig(notes.summary(key)), notes.busy.contains(k), hasAgent, AI_CFG.enabled, AI_CFG.sessionSummary,
                            AGENTS.writeBack.sessionComment) { [unowned self] in self.summaryCard(hasAgent: hasAgent) })
        if hasAgent {
            rows.append(PageRow("ask", Self.sig(notes.answers[k]), asking, AI_CFG.enabled) { [unowned self] in self.askCard() })
        }
        return rows
    }

    private func terminalCard(_ a: AgentSession, status s: ItemStatus?) -> NSView {
        let c = Card(title: "Terminal", trailing: [placeChip()])
        c.add(NSStackView(h: terminalHead(a, status: s), spacing: 6))
        if let h = s?.headline, !h.isEmpty { c.add(NSTextField.text(h, size: 12.5, color: Palette.mut, lines: 3)) }
        c.add(tail.isEmpty ? InlineSpinner("Reading the terminal…") : TermView(lines: tail, height: 300))
        if let r = replyRowIfOpen(a) { c.add(r) }
        return c
    }

    private func terminalHead(_ a: AgentSession, status s: ItemStatus?) -> [NSView] {
        [StatusPill.or(s), Chiplet(a.agent.rawValue, symbol: "cpu"), RelativeTimeLabel({ a.since }, size: 12, format: { "since " + $0 }), Spacer()]
    }

    private func replyRowIfOpen(_ a: AgentSession) -> NSView? { a.phase != .done && a.phase != .failed ? replyRow() : nil }

    private func placeChip() -> NSView {
        let agents = data.agentIndex
        return agents.canReveal ? ActionButton("Open in Orca", symbol: "terminal", action: "session.reveal", ["key": .string(key)])
                                : Chiplet("on \(agents.place)", symbol: "desktopcomputer", mono: false)
    }

    /// The agent and the place of a live card: "claude", "Orca · this Mac".
    private func liveChips(_ a: AgentSession, chat: Bool) -> [NSView] {
        let place = data.agentIndex.place
        return chat ? [Chiplet("\(a.agent.rawValue) · agent-wire"), Chiplet("OverSire runner · \(place)")]
                    : [Chiplet(a.agent.rawValue), Chiplet("Orca · \(place)")]
    }

    private func terminalCard(session id: String, request: URLRequest) -> LiveTerminalCard {
        let k = key, place = data.agentIndex.place
        let pop = ActionButton("Pop out", symbol: "macwindow") {
            LiveTerminalWindow.show(sessionID: id, title: "\(k) terminal",
                                    stream: SessionStream(request: request, view: .terminal, socket: URLSessionWebSockets()), runtime: "Orca", place: place)
        }
        pop.setAccessibilityLabel("Open the terminal in its own window")
        var trailing: [NSView] = [pop]
        // Only a session on this Mac opens in Orca. A remote session uses Pop out.
        if data.agentIndex.canReveal { trailing.append(ActionButton("Open in Orca ↗", action: "session.reveal", ["key": .string(k)])) }
        let c = LiveTerminalCard(sessionID: id, stream: SessionStream(request: request, view: .terminal, socket: URLSessionWebSockets()),
                                 runtime: "Orca", place: place, trailing: trailing)
        c.onDetails = { [weak self] in self?.go(.settings(.machines)) }
        c.onRetry = { [weak self] in self?.retryLive(k) }
        return c
    }

    /// The daemon of the session pairs with its runtime again. Then the card connects again.
    private func retryLive(_ k: String) {
        data.agentIndex.daemonSession(k) { [weak self] s in
            guard let self, let s else { return }
            MachinesController.shared.retry(s.machine.rawValue, runtime: s.runtime) { [weak self] in
                guard let self, self.key == k else { return }
                self.live?.stop()
                self.live = nil
                self.streamChecked = .distantPast
                self.reload()
            }
        }
    }

    private func chatCard(_ a: AgentSession, session id: String, request: URLRequest) -> SessionChatCard {
        let k = key
        let open = ActionButton("Open in a terminal", symbol: "terminal") { [weak self] in self?.openInTerminal(k) }
        open.setAccessibilityLabel("Resume the session in a terminal")
        let stop = ActionButton("Stop session", style: .link) { [weak self] in self?.confirmStop(k) }
        stop.setAccessibilityLabel("Stop the session")
        return SessionChatCard(sessionID: id, agent: a.agent.rawValue, stream: SessionStream(request: request, view: .chat, socket: URLSessionWebSockets()),
                               trailing: [open, stop])
    }

    /// On this Mac, Terminal opens in the folder of the session. The harness session id goes to the clipboard.
    private func openInTerminal(_ k: String) {
        let agents = data.agentIndex
        agents.daemonSession(k) { [weak self] s in
            guard let self else { return }
            defer { self.reload() }
            guard let s else { self.note = (.bad, "OverSire could not read the session from its daemon."); return }
            let id = s.harnessSession ?? s.id
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(id, forType: .string)
            if agents.remote {
                self.note = (.info, "The session runs on \(s.machine.rawValue), in \(s.cwd). The \(s.harness) session id \(id) is on the clipboard.")
                return
            }
            NSWorkspace.shared.open([URL(fileURLWithPath: s.cwd)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                                    configuration: NSWorkspace.OpenConfiguration())
            self.note = (.info, "Terminal opens in \(s.cwd). The \(s.harness) session id \(id) is on the clipboard. Stop the chat session before you resume it.")
        }
    }

    private func confirmStop(_ k: String) {
        AlertConfirm.show(.init(title: "Stop the session of \(k)?", info: "The agent stops. The worktree and the turns stay.", buttons: ["Stop", "Cancel"],
                                destructive: true), in: view.window) { [weak self] answer in
            guard answer.button == 0, let self else { return }
            self.data.agentIndex.stop(k) { e in
                self.note = e.map { (.bad, "Could not stop the session: \($0.message)") }
                self.reload()
            }
        }
    }

    private func summaryCard(hasAgent: Bool) -> NSView {
        let notes = data.sessions
        let k = key
        let busy = notes.busy.contains(k.uppercased())
        let summary = notes.summary(k)
        let sum = ActionButton(summary == nil ? "Summarize" : "Summarize again", symbol: "sparkles") { [weak self] in
            notes.summarize(k) { s in
                guard let self, s == nil else { return }
                self.note = (.warning, "No summary. AI is off, or OverSire found no transcript.")
                self.reload()
            }
        }
        sum.isEnabled = hasAgent && AI_CFG.enabled && AI_CFG.sessionSummary
        if busy { sum.busy("Summarizing…") }
        let copy = ActionButton("Copy hand-off", symbol: "doc.on.doc") { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(notes.handoff(k), forType: .string)
            self?.note = (.ok, "The hand-off note is on the clipboard.")
            self?.reload()
        }
        let c = Card(title: "Summary", trailing: [copy, sum])
        if busy, summary == nil {
            c.add(LoadingNote("The AI writes the summary", compact: true))
            return c
        }
        guard let s = summary else {
            let why = !AI_CFG.enabled ? "Turn on AI in Settings › AI to summarize sessions."
                : !AI_CFG.sessionSummary ? "Session summaries are off in Settings › AI."
                : "No summary yet. OverSire writes one when the session ends" + (AGENTS.writeBack.sessionComment ? ", and posts it as one Plane comment." : ".")
            c.add(EmptyNote(why, symbol: "sparkles"))
            return c
        }
        for (title, list) in [("Done", s.done), ("Files", s.files), ("Decisions", s.decisions), ("Open questions", s.questions)] where !list.isEmpty {
            c.add(NSTextField.text(title, size: 12.5, weight: .semibold))
            for l in list {
                c.add(NSStackView(h: [NSTextField.text("•", color: Palette.dim),
                                      NSTextField.text(l, size: 12.5, color: Palette.mut, lines: 3, mono: title == "Files")], spacing: 6, align: .top))
            }
        }
        c.add(NSTextField.text("Updated \(relativeTime(s.at))", size: 11.5, color: Palette.dim))
        return c
    }

    private func askCard() -> NSView {
        let c = Card(title: "Ask about this session")
        for qa in data.sessions.answers[key.uppercased()] ?? [] {
            c.add(NSTextField.text(qa.q, size: 12.5, weight: .semibold))
            c.add(NSTextField.text(qa.a, size: 12.5, color: Palette.mut, lines: 12))
        }
        let f = NSTextField()
        f.placeholderString = AI_CFG.enabled ? "Why did the session change the config?" : "Turn on AI in Settings › AI to ask."
        f.isEnabled = AI_CFG.enabled
        f.setAccessibilityLabel("Question about the session")
        f.stringValue = askField?.stringValue ?? ""
        f.target = self
        f.action = #selector(sendAsk)
        askField = f
        let b = ActionButton("Ask", style: .primary) { [weak self] in self?.sendAsk() }
        b.isEnabled = AI_CFG.enabled
        if asking {
            b.busy("Asking…")
            c.add(LoadingNote("The AI writes the answer", compact: true))
        }
        c.add(NSStackView(h: [f, b], spacing: 6))
        return c
    }

    @objc private func sendAsk() {
        guard let f = askField, !asking else { return }
        let q = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        asking = true
        reload()
        data.sessions.ask(key, question: q) { [weak self] a in
            guard let self else { return }
            self.asking = false
            if a == nil { self.note = (.bad, "AI did not answer. Check Settings › AI.") } else { self.askField?.stringValue = "" }
            self.reload()
        }
    }

    // MARK: Sub-items

    /// In progress and Not started in priority lanes, as on Work. Done has no lanes, the newest change first.
    static func subGroups(_ kids: [Item], snap: ProjectSnapshot, status: (String) -> ItemStatus?) -> [(title: String, lanes: [WorkPage.Lane])] {
        let done = kids.filter(snap.isFinished)
        let open = kids.filter { !snap.isFinished($0) }.map { ($0, snap, nil as Workstream?) }
        var out = WorkPage.groups(open, status: status)
        if !done.isEmpty { out.append(("Done", [("", done.sorted { $0.updatedAt > $1.updatedAt }.map { ($0, snap, nil) })])) }
        return out
    }

    private func subItems(snap: ProjectSnapshot, item: Item) -> [PageRow] {
        let kids = snap.children(of: item.id)
        let progress = snap.progress(of: item.id)
        let started = snap.started(of: item.id)
        var rows: [PageRow] = []
        if progress.total > 0 {
            rows.append(PageRow("progress", progress.done, started, progress.total) {
                var views: [NSView] = [ProgressRing(done: progress.done, started: started, total: progress.total).sized(16),
                                       NSTextField.text("\(progress.done) of \(progress.total) done", size: 13, weight: .semibold)]
                if started > 0 { views.append(NSTextField.text("\(started) in progress", size: 13, color: Palette.mut)) }
                return NSStackView(h: views + [Spacer()], spacing: 8)
            })
        }
        let job = data.statusJob
        let print = kids.map { k in
            ItemLine.hash(k, snap: snap, stream: data.workstreams.stream(k.key), status: job.item(k.key), cleanup: data.cleaner.lines(k.key, data: data))
        }
        rows.append(PageRow("list", print, progress.total) { [unowned self] in
            let list = StickyListCard.table(kids.isEmpty ? nil : self.subTable)
            for g in ItemPage.subGroups(kids, snap: snap, status: job.item) {
                list.addGroup(g.title, count: g.lanes.reduce(0) { $0 + $1.entries.count })
                for lane in g.lanes {
                    if !lane.priority.isEmpty { list.add(WorkPage.laneRow(lane)) }
                    for e in lane.entries {
                        list.add(ItemLine(e.item, snap: snap, stream: self.data.workstreams.stream(e.item.key), status: job.item(e.item.key), layout: self.subTable,
                                          cleanup: self.data.cleaner.lines(e.item.key, data: self.data)) { [weak self] in self?.go($0) })
                    }
                }
            }
            if progress.total > kids.count {
                list.add(Row([NSTextField.text("\(progress.total - kids.count) more sub-items in Plane", size: 12, color: Palette.acc)], height: 32) {
                    NSWorkspace.shared.open(URL(string: item.url)!) })
            }
            if list.isEmpty { list.add(EmptyNote("No sub-items.", symbol: "list.bullet.indent")) }
            return list
        })
        return rows
    }

    // MARK: Activity

    private struct Event { let source: Source; let text: String; let at: Date; var body: String? = nil; var route: Route? = nil }

    private func events(item: Item, stream: Workstream?) -> [Event] {
        var out: [Event] = []
        for e in timeline ?? [] {
            if case .comments(_, let c) = e.change {
                out.append(Event(source: .plane, text: "\(c.author ?? "Someone") commented", at: c.createdAt, body: c.body))
            } else {
                out.append(Event(source: .plane, text: (e.actor.map { "\($0): " } ?? "") + e.text, at: e.at))
            }
        }
        for r in stream?.runs.prefix(20) ?? [] {
            let t = Tone(r.run)
            out.append(Event(source: .github, text: "\(r.run.workflowName ?? r.run.name) #\(r.run.number) \(t.word.lowercased()) on \(r.run.headBranch)",
                             at: lastActivity(r.run), route: .run(repo: r.repo, id: r.run.id)))
        }
        // PRs and sessions come from the work facts, as in the assistant. Sessions on other machines show too.
        let facts = WorkContext(data).facts(item.key)
        for p in facts.prs {
            out.append(Event(source: .github, text: "PR #\(p.number) \(p.title)", at: parseISO(p.updatedAt) ?? .distantPast))
        }
        for s in facts.sessions {
            let label = s.local ? stream?.agent?.label() ?? s.state : "\(s.state) on \(s.machine)"
            out.append(Event(source: .orca, text: "Session: \(label)" + (s.message.map { " · \($0)" } ?? ""), at: s.since))
        }
        for j in data.statusJob.statuses where j.key == key {
            out.append(Event(source: .oversire, text: "Status: \(j.word) · \(j.reply.headline)", at: j.at,
                             body: (j.reply.done + j.reply.next).joined(separator: "\n")))
        }
        return out.sorted { $0.at > $1.at }
    }

    private func activity(item: Item, stream: Workstream?) -> [PageRow] {
        let all = events(item: item, stream: stream)
        let source = activitySource, pending = pendingComment, loading = timeline == nil
        let shown = all.filter { source == .all || $0.source == source }
        return [
            PageRow("filters", source) { [unowned self] in
                NSStackView(h: Source.allCases.map { s in
                    ToggleChip(s.rawValue, on: source == s) { [weak self] in self?.activitySource = s; self?.reload() } as NSView
                } + [Spacer()], spacing: 6)
            },
            PageRow("compose", pending != nil) { [unowned self] in self.composeRow() },
            PageRow("list", Self.sig(shown), pending, loading) { [unowned self] in self.activityList(shown, pending: pending, loading: loading) },
        ]
    }

    private func composeRow() -> NSView {
        let f = NSTextField()
        f.placeholderString = "Write a comment (Markdown). Return sends."
        f.setAccessibilityLabel("Comment")
        f.stringValue = commentField?.stringValue ?? ""
        f.target = self
        f.action = #selector(sendComment)
        commentField = f
        let send = ActionButton("Comment") { [weak self] in self?.sendComment() }
        if pendingComment != nil { send.busy("Sending…") }
        return NSStackView(h: [f, send], spacing: 6)
    }

    private func activityList(_ shown: [Event], pending: String?, loading: Bool) -> NSView {
        let list = ListCard()
        if let pending {
            list.add(Row([Spinner(size: .mini), NSTextField.text(pending, size: 12.5, color: Palette.dim, lines: 2), NSTextField.text("Sending…", size: 11.5, color: Palette.dim)],
                         height: 34, label: "Sending comment: \(pending)"))
        }
        if loading { list.add(LoadingNote("Loading the activity")) }
        for e in shown {
            var col: [NSView] = [NSTextField.text(e.text, size: 12.5, lines: 2)]
            if let b = e.body?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
                let t = NSTextField(labelWithAttributedString: ItemWindow.inline(b, font: .systemFont(ofSize: 12.5)))
                t.maximumNumberOfLines = 12
                t.lineBreakMode = .byWordWrapping
                t.isSelectable = true
                t.translatesAutoresizingMaskIntoConstraints = false
                t.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                t.preferredMaxLayoutWidth = 0
                col.append(t)
            }
            let text = NSStackView(v: col, spacing: 4)
            text.setContentHuggingPriority(.init(1), for: .horizontal)
            let src = Chiplet(e.source.rawValue)
            let srcBox = NSView()
            srcBox.translatesAutoresizingMaskIntoConstraints = false
            srcBox.addSubview(src)
            NSLayoutConstraint.activate([
                srcBox.widthAnchor.constraint(equalToConstant: 64), srcBox.heightAnchor.constraint(equalTo: src.heightAnchor),
                src.leadingAnchor.constraint(equalTo: srcBox.leadingAnchor), src.topAnchor.constraint(equalTo: srcBox.topAnchor),
            ])
            let route = e.route
            let at = e.at
            let row = Row([srcBox, text, RelativeTimeLabel({ at })], height: 34,
                          label: "\(e.source.rawValue): \(e.text)", onClick: route.map { r in { [weak self] in self?.go(r) } })
            row.stack.alignment = .top
            list.add(row)
        }
        if list.isEmpty { list.add(EmptyNote("No activity.")) }
        return list
    }

    @objc private func sendComment() {
        guard let f = commentField else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, pendingComment == nil else { return }
        pendingComment = text
        f.stringValue = ""
        reload()
        data.actions.run("item.comment", ["key": .string(key), "body": .string(text)]) { [weak self] r in
            guard let self else { return }
            self.pendingComment = nil
            if case .ok = r { self.commentField?.stringValue = ""; self.timeline = nil; self.note = nil } else { self.commentField?.stringValue = text; self.note = (.bad, r.summary) }
            self.reload()
        }
    }
}

// The Cleanup card of a finished item. `show` updates the checks, the text and the button in place.
final class CleanupCard: Card {
    private let button: ActionButton
    private let summary = NSTextField.text("", size: 12.5, color: Palette.mut)
    private let flip: (String) -> Void
    private var lines: [CleanupLine] = []
    private var rows: [String: NSStackView] = [:]
    private var boxes: [String: (view: ToggleChip, on: Bool)] = [:]

    init(run: @escaping () -> Void, flip: @escaping (String) -> Void) {
        button = ActionButton("Clean up", symbol: "bubbles.and.sparkles", style: .primary, run)
        self.flip = flip
        super.init(title: "Cleanup", trailing: [button])
        add(summary)
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ lines: [CleanupLine], off: Set<String>, running: Bool) {
        let safe = lines.filter { $0.safe && $0.removable }
        let look = lines.count - safe.count
        let chosen = safe.filter { !off.contains($0.id) }.count
        if running {
            if !button.isBusy { button.busy("Cleaning up…") }
        } else {
            button.done()
            button.title = "Clean up \(chosen)"
            button.isEnabled = chosen > 0
        }
        summary.stringValue = look == 0 ? "The item is finished. These are left over." : "\(safe.count) safe, \(look) need\(look == 1 ? "s" : "") a look."
        if lines != self.lines {
            rows.values.forEach { $0.removeFromSuperview() }
            rows = [:]
            boxes = [:]
            for l in lines { rows[l.id] = row(l); add(rows[l.id]!) }
            self.lines = lines
        }
        for l in lines { setBox(l, on: l.safe && l.removable && !off.contains(l.id)) }
    }

    private func row(_ l: CleanupLine) -> NSStackView {
        let ok = l.safe && l.removable
        var parts: [NSView] = [Pill(ok ? .ok : .warning, text: ok ? "Safe" : "Look"), NSTextField.text(l.title, size: 12.5, weight: .medium),
                               NSTextField.text(l.detail, size: 12, color: Palette.dim), Spacer()]
        if let url = l.url.flatMap(URL.init(string:)) {
            parts.append(ActionButton(l.kind == .pr ? "Open the PR" : "Open", style: .link) { NSWorkspace.shared.open(url) })
        }
        return NSStackView(h: parts, spacing: 8)
    }

    // ToggleChip has a fixed state. A new chip takes the place of the old one, and keeps the focus.
    private func setBox(_ l: CleanupLine, on: Bool) {
        guard let row = rows[l.id], boxes[l.id]?.on != on else { return }
        let ok = l.safe && l.removable
        let id = l.id
        let box = ToggleChip("", on: on, enabled: ok) { [weak self] in self?.flip(id) }
        box.setAccessibilityLabel(l.title)
        let old = boxes[l.id]?.view
        let focused = old.map { window?.firstResponder === $0 } ?? false
        old?.removeFromSuperview()
        row.insertArrangedSubview(box, at: 0)
        boxes[l.id] = (box, on)
        if focused { window?.makeFirstResponder(box) }
    }
}
