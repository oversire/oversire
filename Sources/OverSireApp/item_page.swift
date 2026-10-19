import Cocoa
import OverSireCore

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

// The page of one work item: its workstream, session, sub-items and activity, with the properties at the side.
final class ItemPage: Page, NSTextFieldDelegate {
    private let subTable = ColumnLayout(id: "subitems", columns: ItemLine.columns())
    private enum Source: String, CaseIterable { case all = "All", plane = "Plane", github = "GitHub", orca = "Orca", oversire = "OverSire" }

    private let markdown = MarkdownView(width: 600)
    private var markdownHeight: NSLayoutConstraint?
    private let summaryMarkdown = MarkdownView(width: 600)
    private var summaryHeight: NSLayoutConstraint?
    private var descriptionOpen = false
    private var hiddenSummaries: Set<String> = []
    private var summaryObserver: Any?
    private var timeline: [ActivityEntry]?
    private var tail: [String] = []
    private var tailAt = Date.distantPast
    private var saving: String?
    private var note: (Tone, String)?
    private var activitySource = Source.all
    private var replyField: NSTextField?
    private var commentField: NSTextField?
    private var askField: NSTextField?
    private var asking = false
    private var sending = false
    private var pendingComment: String?
    private var relationObserver: Any?
    private var narrow = false

    override var pageWidth: CGFloat { 1240 }

    private var key: String { if case .item(let k, _) = route { return k }; return "" }
    private var tab: Route.ItemTab { if case .item(_, let t) = route { return t }; return .overview }

    override func viewDidLoad() {
        markdown.translatesAutoresizingMaskIntoConstraints = true
        markdown.onHeight = { [weak self] h in self?.markdownHeight?.constant = max(24, h) }
        summaryMarkdown.translatesAutoresizingMaskIntoConstraints = true
        summaryMarkdown.onHeight = { [weak self] h in self?.summaryHeight?.constant = max(20, h) }
        super.viewDidLoad()
        relationObserver = NotificationCenter.default.addObserver(forName: RelationCache.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.tab == .overview, !self.isEditing else { return }
            self.reload()
        }
        summaryObserver = NotificationCenter.default.addObserver(forName: ItemSummaries.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.tab == .overview, !self.isEditing else { return }
            self.reload()
        }
    }

    deinit { [relationObserver, summaryObserver].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver) }

    // Below 760 pt the side rail moves under the header as a row of sections.
    override func viewDidLayout() {
        super.viewDidLayout()
        let n = view.bounds.width < 760
        guard n != narrow else { return }
        narrow = n
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    override func show(_ r: Route) {
        if case .item(let k, let t) = r, k != key || t != tab { if k != key { timeline = nil; tail = []; descriptionOpen = false }; tailAt = .distantPast }
        super.show(r)
    }

    override var isEditing: Bool {
        super.isEditing || !(replyField?.stringValue.isEmpty ?? true) || !(commentField?.stringValue.isEmpty ?? true) || !(askField?.stringValue.isEmpty ?? true)
    }

    override func build(_ col: NSStackView) {
        let store = data.projectStore
        guard let (pk, snap, item) = store.item(key: key) else {
            col.addFull(PageHeader(key, caption: "Work item"))
            pageBusy = data.projectsLoading
            if data.projectsLoading {
                let c = ListCard()
                c.add(LoadingNote("Loading \(key)"))
                col.addFull(c)
            } else {
                col.addFull(EmptyNote("OverSire has no item \(key). It may be in a project that OverSire does not track, or it was deleted.",
                                      symbol: "questionmark.square.dashed"))
            }
            return
        }
        let stream = data.workstreams.stream(key)
        loadData(item: item, stream: stream)

        let main = NSStackView(v: [], spacing: 14)
        main.addFull(head(snap: snap, item: item, stream: stream))
        if narrow { main.addFull(rail(snap: snap, item: item, stream: stream)) }
        if let note { main.addFull(Banner(note.0, title: note.1)) }
        let prog = snap.progress(of: item.id)
        let tabs = Route.ItemTab.allCases
        let strip = TabStrip(["Overview", "Session", prog.total > 0 ? "Sub-items \(prog.done)/\(prog.total)" : "Sub-items", "Activity"],
                             selected: tabs.firstIndex(of: tab) ?? 0)
        strip.onSelect = { [weak self] i in guard let self else { return }; self.go(.item(self.key, tabs[i])) }
        main.addArrangedSubview(strip)
        switch tab {
        case .overview: overview(main, pk: pk, snap: snap, item: item, stream: stream)
        case .session: session(main, stream: stream)
        case .subitems: subItems(main, snap: snap, item: item, progress: prog)
        case .activity: activity(main, item: item, stream: stream)
        }
        if narrow { col.addFull(main); return }
        let side = NSStackView(v: [], spacing: 0)
        side.addFull(rail(snap: snap, item: item, stream: stream))
        for s in [main, side] {
            let fill = NSView()
            fill.setContentHuggingPriority(.init(1), for: .vertical)
            s.addArrangedSubview(fill)
        }
        main.setContentHuggingPriority(.init(1), for: .horizontal)
        let two = NSStackView(h: [main, side], spacing: 18, align: .top)
        two.distribution = .fill
        col.addFull(two)
        side.widthAnchor.constraint(equalToConstant: 300).isActive = true
    }

    private func loadData(item: Item, stream: Workstream?) {
        if timeline == nil {
            data.projectStore.timeline(itemId: item.id) { [weak self] e in
                guard let self, self.key == item.key else { return }
                self.timeline = e
                if self.tab == .activity { self.reload() }
            }
        }
        if stream?.agent != nil, -tailAt.timeIntervalSinceNow > 5 {
            tailAt = Date()
            data.agentIndex.tail(key, lines: tab == .session ? 60 : 14) { [weak self] lines in
                guard let self, lines != self.tail else { return }
                self.tail = lines
                if !self.isEditing { self.reload() }
            }
        }
    }

    // MARK: Head and properties

    private func head(snap: ProjectSnapshot, item: Item, stream: Workstream?) -> NSView {
        let project = Chiplet(snap.summary.title, symbol: "folder", color: Palette.acc) { [weak self] in self?.go(.project(snap.summary.identifier)) }
        let keyLine = NSStackView(h: [NSTextField.text(item.key, size: 12, color: Palette.dim, mono: true), project, Spacer()], spacing: 8)
        var chips: [NSView] = [statusChip(snap: snap, item: item), priorityChip(item)]
        chips += item.labels.prefix(4).map { Chiplet($0, symbol: "tag") as NSView }
        if let saving { chips.append(NSStackView(h: [Spinner(size: .mini), NSTextField.text("Saving \(saving)…", size: 12, color: Palette.dim)], spacing: 5)) }
        let inQueue = data.queue.contains(key)
        var actions: [NSView] = [ActionButton(inQueue ? "In the queue" : "Add to queue", symbol: "text.line.first.and.arrowtriangle.forward") { [weak self] in
            guard let self else { return }
            if inQueue { self.go(.queue) } else { self.data.queue.add(item, snap: snap) }
        }]
        if let a = stream?.agent {
            actions.append(Pill(Tone(a.phase), text: a.label()))
        } else {
            let b = ActionButton("Start in Orca", symbol: "play.fill", style: .primary)
            b.onClick = { [weak self, weak b] in
                guard let self, let b else { return }
                self.data.agentIndex.start(item, snap: snap, anchor: b)
            }
            actions.append(b)
        }
        let v = NSStackView(v: [], spacing: 7)
        v.addFull(keyLine)
        v.addFull(NSTextField.text(item.title, size: 22, weight: .semibold, lines: 3))
        v.addFull(NSStackView(h: [Wrap(chips), Spacer()] + actions, spacing: 6))
        return v
    }

    private func statusChip(snap: ProjectSnapshot, item: Item) -> NSView {
        let opt = snap.option(item.statusOptionId)
        let name = opt?.name ?? "No status"
        let glyph = StatusGlyph(category: opt?.category ?? .todo, color: projectColor(opt?.color ?? "GRAY"), name: name).sized(12)
        return MenuChip(name, icon: glyph) { [weak self] in
            snap.statusOptions.map { o in
                let a = MenuAction(o.name) { self?.save("status", ItemPatch(status: o.id)) }
                a.item.state = o.id == item.statusOptionId ? .on : .off
                return a
            }
        }
    }

    private func priorityChip(_ item: Item) -> NSView {
        let cur = item.fields["Priority"] ?? "None"
        return MenuChip(cur == "None" ? "No priority" : cur, symbol: "flag") { [weak self] in
            StatusOption.priorities.map { p in
                let a = MenuAction(p.name) { self?.save("priority", ItemPatch(priority: p.id)) }
                a.item.state = p.name == cur ? .on : .off
                return a
            }
        }
    }

    private func save(_ what: String, _ patch: ItemPatch) {
        guard let (_, _, item) = data.projectStore.item(key: key) else { return }
        saving = what
        note = nil
        reload()
        data.projectStore.update(itemId: item.id, patch, failure: "Could not change the \(what)") { [weak self] ok in
            guard let self else { return }
            self.saving = nil
            if !ok { self.note = (.bad, self.data.projectStore.lastError ?? "Plane did not take the change.") }
            self.reload()
        }
    }

    // One card: Properties, Code and Links. A column at the side, or a row of sections on a narrow page.
    private func rail(snap: ProjectSnapshot, item: Item, stream: Workstream?) -> NSView {
        func section(_ title: String, _ rows: [NSView]) -> NSStackView {
            let v = NSStackView(v: [], spacing: 7)
            v.addFull(NSTextField.text(title.uppercased(), size: 11, weight: .semibold, color: Palette.dim))
            rows.forEach { v.addFull($0) }
            return v
        }
        func line(_ name: String, _ value: NSView) -> NSView {
            let n = NSTextField.text(name, size: 12, color: Palette.dim)
            n.widthAnchor.constraint(equalToConstant: 72).isActive = true
            value.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            return NSStackView(h: [n, value, Spacer()], spacing: 6, align: value is Chiplet ? .centerY : .firstBaseline)
        }
        func text(_ s: String, mono: Bool = false) -> NSView { NSTextField.text(s, size: 12.5, lines: 2, mono: mono) }
        func link(_ title: String, _ symbol: String, _ action: @escaping () -> Void) -> NSView {
            Row([Glyph(symbol, size: 13), NSTextField.text(title, size: 12.5), Spacer()], height: 28, inset: 4, label: title, onClick: action)
        }

        let props = section("Properties", [
            line("Status", statusChip(snap: snap, item: item)), line("Priority", priorityChip(item)),
            line("Assignees", text(item.assignees.isEmpty ? "—" : item.assignees.joined(separator: ", "))),
            line("Labels", text(item.labels.isEmpty ? "—" : item.labels.joined(separator: ", "))),
            line("Updated", text(relativeTime(item.activityAt))),
        ])
        let co = stream?.checkouts.first { !$0.branch.isEmpty } ?? stream?.checkouts.first
        let pr = stream?.prs.first
        var code: [NSView] = []
        if co == nil && pr == nil {
            code.append(NSTextField.text("No checkout, branch or PR yet.", size: 12.5, color: Palette.dim, lines: 2))
        } else {
            code.append(line("Checkout", text(co.map { ($0.path as NSString).lastPathComponent } ?? "—", mono: true)))
            code.append(line("Branch", text(co?.branch.isEmpty == false ? co!.branch : "—", mono: true)))
            code.append(line("PR", pr.map { p in
                Chiplet("#\(p.pr.number) \(p.pr.isDraft ? "draft" : p.pr.state.lowercased())", symbol: "arrow.triangle.pull") {
                    NSWorkspace.shared.open(URL(string: p.pr.url)!) } as NSView } ?? text("—")))
        }
        let links = section("Links", [
            link("Copy for agent", "doc.on.doc") { [weak self] in self?.data.projectStore.copyForAgent(item.id) },
            link("Copy OverSire link", "link") { [weak self] in
                guard let self else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Route.item(self.key, .overview).url.absoluteString, forType: .string)
            },
            link("Open in Plane", "arrow.up.right.square") { NSWorkspace.shared.open(URL(string: item.url)!) },
        ])
        let sections = [props, section("Code", code), links]
        let c = Card(padding: 14, spacing: 12)
        if narrow {
            let row = NSStackView(h: sections, spacing: 18, align: .top)
            row.distribution = .fillEqually
            c.add(row)
        } else {
            for (i, v) in sections.enumerated() {
                if i > 0 {
                    let rule = Box(fill: Palette.line, border: nil, radius: 0)
                    rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
                    c.add(rule)
                }
                c.add(v)
            }
        }
        return c
    }

    // MARK: Overview

    private func overview(_ main: NSStackView, pk: String, snap: ProjectSnapshot, item: Item, stream: Workstream?) {
        if let s = stream, s.agent != nil || !s.runs.isEmpty || !s.checkouts.isEmpty {
            main.addFull(workstream(s, snap: snap, item: item))
        } else {
            main.addFull(NSStackView(h: [Glyph("moon.zzz", color: Palette.dim, size: 13),
                                         NSTextField.text("No session yet. Start it in Orca or add it to the queue of \(snap.summary.title).",
                                                          size: 12.5, color: Palette.dim, lines: 2), Spacer()], spacing: 6))
        }
        if let card = suggestion(item) { main.addFull(card) }
        if let card = plannerCard(item) { main.addFull(card) }
        let body = (item.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let sums = data.itemSummaries
        let long = ItemSummaries.offers(body)
        let summary = hiddenSummaries.contains(item.key) ? nil : sums.summary(item.key)
        let busy = sums.busy.contains(item.key.uppercased())
        var trailing: [NSView] = []
        if long { trailing.append(NSTextField.text("\(body.count.formatted()) characters", size: 12, color: Palette.dim)) }
        if long, summary == nil, sums.hasEngine || sums.summary(item.key) != nil {
            let b = ActionButton(busy ? "Summarizing…" : "Summarize", symbol: "sparkles", key: "S") { [weak self] in
                guard let self else { return }
                if self.hiddenSummaries.remove(item.key) == nil { sums.summarize(item) }
                self.reload()
            }
            b.isEnabled = !busy
            b.toolTip = "Ask the AI for a summary of the description (⌘⇧S)"
            trailing.append(b)
        }
        let d = Card(title: "Description", trailing: trailing)
        if body.isEmpty {
            d.add(NSTextField.text("No description.", size: 12.5, color: Palette.dim))
            main.addFull(d)
            return
        }
        if summary != nil || busy || (long && sums.errors[item.key.uppercased()] != nil) {
            d.add(summaryPanel(item, body: body, summary: summary, busy: busy))
        }
        if summary != nil {
            let open = descriptionOpen
            d.add(Row([Glyph(open ? "chevron.down" : "chevron.right", color: Palette.dim, size: 11),
                       NSTextField.text(open ? "Hide full description" : "Show full description", size: 12.5, color: Palette.mut), Spacer()],
                      height: 26, inset: 2, label: open ? "Hide full description" : "Show full description") { [weak self] in
                self?.descriptionOpen.toggle()
                self?.reload()
            })
        }
        if summary == nil || descriptionOpen {
            d.add(markdownHolder(markdown, height: &markdownHeight, min: 24))
            data.projectStore.resolveImages(body, projectKey: pk) { [weak self] out in self?.markdown.show(out, mode: .rendered) }
        }
        main.addFull(d)
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

    // The AI summary of a long description: the cached one, a placeholder while the AI works, or the error.
    private func summaryPanel(_ item: Item, body: String, summary: ItemSummary?, busy: Bool) -> NSView {
        let sums = data.itemSummaries
        let k = item.key.uppercased()
        let v = NSStackView(v: [], spacing: 9)
        var head: [NSView] = [Glyph("sparkles", color: Palette.run, size: 12),
                              NSTextField.text("AI SUMMARY", size: 11, weight: .semibold, color: Palette.dim), Spacer()]
        if let summary { head.append(NSTextField.text(relativeTime(summary.at), size: 12, color: Palette.dim)) }
        if busy {
            head.append(NSStackView(h: [Spinner(size: .mini), NSTextField.text("Summarizing…", size: 12, color: Palette.dim)], spacing: 5))
        } else if summary != nil, sums.hasEngine {
            head.append(ActionButton("Refresh", symbol: "arrow.clockwise", style: .link) { sums.summarize(item) })
        }
        if summary != nil {
            head.append(ActionButton("Hide", style: .link) { [weak self] in
                self?.hiddenSummaries.insert(item.key)
                self?.reload()
            })
        }
        v.addFull(NSStackView(h: head, spacing: 6))
        if let err = sums.errors[k], !busy {
            v.addFull(Banner(.bad, title: "No summary.", body: err,
                             actions: sums.hasEngine ? [ActionButton("Retry") { sums.summarize(item) }] : []))
        } else if summary != nil, sums.isStale(k, body: body), !busy {
            v.addFull(Banner(.warning, title: "The description changed after this summary.", body: "Click Refresh for a new one."))
        }
        if let summary {
            v.addFull(markdownHolder(summaryMarkdown, height: &summaryHeight, min: 20))
            summaryMarkdown.show(summary.markdown, mode: .rendered)
            let linked = ItemPage.linkedKeys(body, except: k).filter { data.projectStore.item(key: $0) != nil }
            if !linked.isEmpty {
                let chips = linked.map { key in Chiplet(key, symbol: "link") { [weak self] in self?.go(.item(key, .overview)) } as NSView }
                v.addFull(NSStackView(h: [NSTextField.text("Linked:", size: 12, color: Palette.dim), Wrap(chips), Spacer()], spacing: 6))
            }
        } else if busy {
            v.addFull(NSTextField.text("The AI reads \(body.count.formatted()) characters. You can leave this page. The summary goes into the cache.",
                                       size: 12.5, color: Palette.dim, lines: 2))
        }
        let box = Box(fill: Palette.bg, border: Palette.line, radius: 8)
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
        ])
        return box
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

    private func plannerCard(_ item: Item) -> NSView? {
        let rc = data.projectStore.relations
        guard rc.supports(item.key) else { return nil }
        rc.load([item.key])
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
        let a = NSAlert()
        a.messageText = "Code areas of \(item.key)"
        a.informativeText = "The queue does not start two items with the same area at a time. Use commas between the areas. "
            + "An area has lower-case letters, digits and hyphens. At most \(ItemAreas.maxAreas) areas."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        f.stringValue = data.areas.areas(of: ref).joined(separator: ", ")
        f.placeholderString = "api, status-page"
        a.accessoryView = f
        a.addButton(withTitle: "Save")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        data.areas.save(f.stringValue.split(separator: ",").map(String.init), for: ref)
        reload()
    }

    private func suggestion(_ item: Item) -> NSView? {
        guard hasCloud, data.suggestions.openPlan(naming: item.key) != nil else { return nil }
        return Banner(.info, title: "The Planner has a plan change for \(item.key).",
                      actions: [ActionButton("Review") { [weak self] in self?.go(.queue) }])
    }

    private func workstream(_ s: Workstream, snap: ProjectSnapshot, item: Item) -> NSView {
        var trailing: [NSView] = []
        if let a = s.agent {
            trailing.append(ActionButton("Open in Orca", symbol: "terminal") { [weak self] in self?.data.agentIndex.reveal(self?.key ?? "") })
            if a.phase == .failed { trailing.append(ActionButton("Dismiss") { [weak self] in self?.data.agentIndex.clearFailure(self?.key ?? "") }) }
        }
        let c = Card(title: "Workstream", trailing: trailing, spacing: 12)
        var chips: [NSView] = []
        for co in s.checkouts.prefix(3) {
            chips.append(Chiplet((co.path as NSString).lastPathComponent, symbol: "folder", mono: true))
            if !co.branch.isEmpty { chips.append(Chiplet(co.branch, symbol: "arrow.triangle.branch", mono: true)) }
        }
        if let a = s.agent { chips.append(Chiplet("\(a.agent.rawValue)\(a.repo.isEmpty ? "" : " · " + a.repo)", symbol: "cpu")) }
        if !chips.isEmpty { c.add(NSStackView(h: chips + [Spacer()], spacing: 6)) }

        let left = NSStackView(v: [], spacing: 8)
        if let a = s.agent {
            left.addFull(NSStackView(h: [NSTextField.text("Session", size: 12.5, weight: .semibold), Pill(Tone(a.phase), text: a.label()), Spacer()], spacing: 6))
            let lines = tail.isEmpty ? [a.message ?? "Reading the terminal…"] : Array(tail.suffix(14))
            left.addFull(TermView(lines: lines, height: 150))
            if a.phase != .done && a.phase != .failed { left.addFull(replyRow()) }
        }
        let right = NSStackView(v: [], spacing: 8)
        let ciTitle = NSTextField.text("CI on this work", size: 12.5, weight: .semibold)
        ciTitle.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        right.addFull(NSStackView(h: [ciTitle,
                                      NSTextField.text("matched by branch, commit or title", size: 11.5, color: Palette.dim), Spacer()], spacing: 6))
        let runs = ListCard()
        for r in s.runs.prefix(5) { runs.add(RunLine(repo: r.repo, run: r.run, data: data, commands: commands) { [weak self] in self?.go($0) }) }
        if runs.isEmpty { runs.add(EmptyNote("No runs yet.", symbol: "circle.dashed")) }
        right.addFull(runs)
        if s.agent != nil, s.ci?.word == Tone.bad.word, s.agent?.phase != .done {
            right.addFull(NSStackView(h: [Glyph("eye", color: Palette.dim, size: 12),
                                          NSTextField.text("The session works on this branch. It usually sees the failure and fixes it.", size: 11.5, color: Palette.dim, lines: 2)], spacing: 5))
        }
        for p in s.prs.prefix(2) {
            right.addFull(NSStackView(h: [NSTextField.text("Pull request", size: 12.5, weight: .semibold),
                                          Chiplet("#\(p.pr.number) \(p.pr.isDraft ? "draft" : p.pr.state.lowercased())", symbol: "arrow.triangle.pull") {
                                              NSWorkspace.shared.open(URL(string: p.pr.url)!) }, Spacer()], spacing: 6))
        }
        let wb = AGENTS.writeBack
        right.addFull(NSTextField.text("On Plane", size: 12.5, weight: .semibold))
        var onPlane: [NSView] = []
        if !wb.enabled {
            onPlane.append(Chiplet("Write-back is off"))
        } else {
            if wb.links { onPlane.append(Chiplet("links", symbol: "link")) }
            if wb.labels { onPlane.append(Chiplet("session:* label", symbol: "tag")) }
            if wb.block { onPlane.append(Chiplet("OverSire block", symbol: "text.append")) }
        }
        onPlane.append(Chiplet("Edit…", color: Palette.acc) { [weak self] in self?.go(.settings(.projects, tab: .linking, anchor: "writeback")) })
        onPlane.append(Spacer())
        right.addFull(NSStackView(h: onPlane, spacing: 6))

        if s.agent == nil {
            c.add(right)
        } else {
            let two = NSStackView(h: [left, right], spacing: 14, align: .top)
            two.distribution = .fillEqually
            c.add(two)
        }
        return c
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
        data.agentIndex.send(key, text: text) { [weak self] err in
            guard let self else { return }
            self.sending = false
            if let err { self.note = (.bad, "Could not send: \(err.message)") } else { self.replyField?.stringValue = ""; self.note = nil; self.tailAt = .distantPast }
            self.reload()
        }
    }

    // MARK: Session

    private func session(_ main: NSStackView, stream: Workstream?) {
        if let a = stream?.agent {
            let c = Card(title: "Terminal", trailing: [ActionButton("Open in Orca", symbol: "terminal") { [weak self] in self?.data.agentIndex.reveal(self?.key ?? "") }])
            c.add(NSStackView(h: [Pill(Tone(a.phase), text: a.label()), Chiplet(a.agent.rawValue, symbol: "cpu"),
                                  NSTextField.text("since \(relativeTime(a.since))", size: 12, color: Palette.dim), Spacer()], spacing: 6))
            c.add(tail.isEmpty ? InlineSpinner("Reading the terminal…") : TermView(lines: tail, height: 300))
            if a.phase != .done && a.phase != .failed { c.add(replyRow()) }
            main.addFull(c)
        } else {
            main.addFull(Banner(.idle, title: "No Orca session yet.", body: "Start the item in Orca to see its session here."))
        }
        main.addFull(summaryCard(hasAgent: stream?.agent != nil))
        if stream?.agent != nil { main.addFull(askCard()) }
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

    private func subItems(_ main: NSStackView, snap: ProjectSnapshot, item: Item, progress: (done: Int, total: Int)) {
        let kids = snap.children(of: item.id)
        let list = ListCard()
        if progress.total > 0 {
            list.add(Row([ProgressRing(done: progress.done, total: progress.total).sized(16),
                          NSTextField.text("\(progress.done) of \(progress.total) done", size: 13, weight: .semibold), Spacer()], height: 36))
        }
        for k in kids { list.add(ItemLine(k, snap: snap, stream: data.workstreams.stream(k.key), layout: subTable) { [weak self] in self?.go($0) }) }
        if progress.total > kids.count {
            list.add(Row([NSTextField.text("\(progress.total - kids.count) more sub-items in Plane", size: 12, color: Palette.acc)], height: 32) {
                NSWorkspace.shared.open(URL(string: item.url)!) })
        }
        if list.isEmpty { list.add(EmptyNote("No sub-items.", symbol: "list.bullet.indent")) }
        main.addFull(list)
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
        for p in stream?.prs ?? [] {
            out.append(Event(source: .github, text: "PR #\(p.pr.number) \(p.pr.title)", at: parseISO(p.pr.updatedAt) ?? .distantPast))
        }
        if let a = stream?.agent {
            out.append(Event(source: .orca, text: "Session: \(a.label())" + (a.message.map { " · \($0)" } ?? ""), at: a.since))
        }
        for j in data.aiChecks.checks where j.key == key {
            let state = j.state == .retired ? "retired: " + (j.retired ?? "out of date") : j.state.rawValue
            out.append(Event(source: .oversire, text: "AI check: \(j.verdict.word) · \(state)", at: j.at, body: j.evidence.joined(separator: "\n")))
        }
        return out.sorted { $0.at > $1.at }
    }

    private func activity(_ main: NSStackView, item: Item, stream: Workstream?) {
        let all = events(item: item, stream: stream)
        main.addFull(NSStackView(h: Source.allCases.map { s in
            ToggleChip(s.rawValue, on: activitySource == s) { [weak self] in self?.activitySource = s; self?.reload() } as NSView
        } + [Spacer()], spacing: 6))

        let f = NSTextField()
        f.placeholderString = "Write a comment (Markdown). Return sends."
        f.setAccessibilityLabel("Comment")
        f.stringValue = commentField?.stringValue ?? ""
        f.target = self
        f.action = #selector(sendComment)
        commentField = f
        let send = ActionButton("Comment") { [weak self] in self?.sendComment() }
        if pendingComment != nil { send.busy("Sending…") }
        main.addFull(NSStackView(h: [f, send], spacing: 6))

        let list = ListCard()
        if let pendingComment {
            list.add(Row([Spinner(size: .mini), NSTextField.text(pendingComment, size: 12.5, color: Palette.dim, lines: 2), NSTextField.text("Sending…", size: 11.5, color: Palette.dim)],
                         height: 34, label: "Sending comment: \(pendingComment)"))
        }
        if timeline == nil { list.add(LoadingNote("Loading the activity")) }
        for e in all where activitySource == .all || e.source == activitySource {
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
            let row = Row([srcBox, text, NSTextField.text(relativeTime(e.at), size: 11.5, color: Palette.dim)], height: 34,
                          label: "\(e.source.rawValue): \(e.text)", onClick: route.map { r in { [weak self] in self?.go(r) } })
            row.stack.alignment = .top
            list.add(row)
        }
        if list.isEmpty { list.add(EmptyNote("No activity.")) }
        main.addFull(list)
    }

    @objc private func sendComment() {
        guard let f = commentField, let (_, _, item) = data.projectStore.item(key: key) else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, pendingComment == nil else { return }
        pendingComment = text
        f.stringValue = ""
        reload()
        data.projectStore.comment(itemId: item.id, body: text) { [weak self] ok in
            guard let self else { return }
            self.pendingComment = nil
            if !ok { self.commentField?.stringValue = text }
            if ok { self.commentField?.stringValue = ""; self.timeline = nil; self.note = nil } else { self.note = (.bad, self.data.projectStore.lastError ?? "Plane did not take the comment.") }
            self.reload()
        }
    }
}
