import AppKit
import OverSireCore
import OverSireAI

// The queue: a link to the sessions that need you, then one card per lane. The Board view shows Running, Up next, Waits and Held.
// A card that shares an area with a card that runs at the same time gets a red border and a ▲ line.
final class QueuePage: Page {
    /// The open review sheet, for `--uishots`.
    static weak var openSheet: NSWindow?
    static var windowNumber: Int? { openSheet?.windowNumber }
    private static let viewKey = "queue.view"
    private static var shotView: String?

    private var orders: [String: (order: [String], reason: String)] = [:]   // lane project → AI order
    private var ordering: Set<String> = []   // lane projects that wait for the AI order
    private var asked: Set<String> = []      // lane project + keys, asked once
    private var after: Set<String> = []      // lanes that show the board with the Planner order
    private var updated: Set<String> = []    // lanes with an accepted plan change in this page
    private var sheet: NSWindow?
    private var narrow = false

    private var board: Bool {
        get { (UIShots.shooting ? Self.shotView : UserDefaults.standard.string(forKey: Self.viewKey)) != "list" }
        set {
            if UIShots.shooting { Self.shotView = newValue ? "board" : "list" } else { UserDefaults.standard.set(newValue ? "board" : "list", forKey: Self.viewKey) }
        }
    }

    override var pageWidth: CGFloat { 1240 }

    override func viewDidLayout() {
        super.viewDidLayout()
        let n = view.bounds.width < 760
        guard n != narrow else { return }
        narrow = n
        DispatchQueue.main.async { [weak self] in self?.reload() }
    }

    override func build(_ col: NSStackView) {
        let mode = Segmented(AIMode.allCases.map(\.label), selected: AIMode.allCases.firstIndex(of: AGENTS.aiMode) ?? 0, label: "AI checks") { [weak self] i in
            AGENTS.aiMode = AIMode.allCases[i]
            saveConfig()
            self?.reload()
        }
        let view = Segmented(["Board", "List"], selected: board ? 0 : 1, label: "Queue view") { [weak self] i in
            self?.board = i == 0
            self?.reload()
        }
        let add = ActionButton("Add", symbol: "plus")
        add.onClick = { [weak self, weak add] in if let add { self?.addMenu(add) } }
        add.setAccessibilityLabel("Add to the queue")
        col.addFull(PageHeader("Lane board", caption: "Items start in Orca, in order, when a slot frees.", actions: [
            ToggleChip("Auto start", on: AGENTS.autoStart) { [weak self] in AGENTS.autoStart.toggle(); saveConfig(); self?.reload() },
            NSTextField.text("AI checks", size: 12, color: Palette.dim), mode, view, add,
        ]))
        let text: String
        switch AGENTS.aiMode {
        case .auto: text = "AI checks quiet sessions. A \"looks done\" check frees the slot. A \"looks stuck\" check asks you."
        case .ask: text = "AI checks quiet sessions and asks you before it acts."
        case .off: text = "AI checks are off. The queue moves when a session ends."
        }
        col.addFull(NSStackView(h: [NSTextField.text(text, size: 12, color: Palette.dim, lines: 2), Spacer(),
                                    ActionButton("AI features", style: .link) { [weak self] in self?.go(.settings(.ai)) }], spacing: 8))
        if data.agentIndex.ready == nil {
            col.addFull(Banner(.warning, title: "Orca is off or not installed.", body: "The queue starts items in Orca.",
                               actions: [ActionButton("Runtime settings") { [weak self] in self?.go(.settings(.agents)) }]))
        }
        needsYou(col)

        let q = data.queue
        var held = hasCloud || UIShots.cloud == true ? (cloudAIRecords?.orders.filter { $0.state == .held } ?? []) : []
        held.sort { $0.createdAt < $1.createdAt }
        if q.lanes.isEmpty {
            col.addFull(EmptyNote("The queue is empty. Add items here, or from an item page.", symbol: "list.bullet"))
        }
        for lane in q.lanes {
            let prefix = lane.identifier.uppercased() + "-"
            let mine = held.filter { $0.itemKey?.uppercased().hasPrefix(prefix) == true }
            held.removeAll { o in mine.contains { $0.id == o.id } }
            col.addFull(laneCard(lane, held: mine))
        }
        if !held.isEmpty { col.addFull(heldCard(held)) }
        col.addFull(planeNote())
    }

    // The checks moved to Work › Worktrees. One line links there.
    private func needsYou(_ col: NSStackView) {
        let n = NeedsYouCard(page: self).count(data)
        guard n > 0 else { return }
        let tone = Tone(SessionState.needsInput)
        let link = ActionButton("\(n) \(n == 1 ? "session needs" : "sessions need") you · Worktrees", style: .link) { [weak self] in self?.go(.work(.worktrees)) }
        col.addFull(NSStackView(h: [Glyph(tone.symbol, color: tone.color, size: 12), link, Spacer()], spacing: 6))
    }

    // MARK: Lanes

    private func laneCard(_ lane: QueueLane, held: [WorkOrder]) -> NSView {
        let q = data.queue
        let slots = AGENTS.slots(lane.project)
        let busy = q.busy(lane)
        let root = PROJECTS_CFG.orca.roots[lane.project].map { ($0 as NSString).lastPathComponent } ?? "no Orca workspace"
        let slotChip = MenuChip("\(busy) of \(slots) slot\(slots == 1 ? "" : "s")") { [weak self] in
            (1...4).map { n in MenuAction("\(n) session\(n == 1 ? "" : "s") at a time") { AGENTS.slots[lane.project] = n; saveConfig(); self?.syncSlots(lane.project, n); self?.reload() } }
        }
        let ws = NSTextField.text(root, size: 11.5, color: Palette.dim, mono: true)
        ws.lineBreakMode = .byTruncatingMiddle
        ws.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let c = Card(padding: 12, spacing: 8)
        c.add(NSStackView(h: [NSTextField.text(lane.identifier, size: 14, weight: .semibold), SlotMeter(busy: busy, slots: slots), slotChip,
                              Glyph("folder", color: Palette.dim, size: 11), ws, Spacer()], spacing: 8))
        if let e = q.state(lane.project)?.error { c.add(Banner(.warning, title: e)) }
        let plan = hasCloud ? data.suggestions.openPlan(lane: lane.project) : nil
        if let plan, let draft = plan.plan { c.add(plannerLine(plan, draft: draft, lane: lane)) }
        else if updated.contains(lane.project) { c.add(Banner(.ok, title: "✓ Plan updated.")) }
        let suggestion = orderSuggestion(lane)
        if suggestion == nil, ordering.contains(lane.project) { c.add(InlineSpinner("The AI reads the lane and proposes an order…")) }
        if let s = suggestion {
            c.add(Banner(.info, title: "AI order: " + s.order.joined(separator: ", "), body: s.reason,
                         actions: [ActionButton("Apply") { [weak self] in q.reorder(lane.project, keys: s.order); self?.orders[lane.project] = nil }]))
        }
        let draft = after.contains(lane.project) ? plan?.plan : nil
        let pick = lane.pick(state: q.state(lane.project), world: q.world(workstreams: nil))
        let book = q.areaBook()
        let planner = data.planner
        let kind: (String) -> AreaKind = { draft?.kinds?[$0] ?? planner.kind($0, project: lane.project) }
        let b = QueueBoard(lane: lane, running: q.running(lane), slots: slots, holds: pick.holds,
                           held: held.compactMap { o in o.itemKey.map { ($0, o.hold) } },
                           areas: { book?.areas(key: $0) ?? [] }, kind: kind, draft: draft)
        if board { c.add(columns(b, lane: lane, pick: pick, kind: kind)) } else { list(c, b, lane: lane, pick: pick, kind: kind) }
        return c
    }

    // A slim line for an open plan change of the Planner.
    private func plannerLine(_ s: Suggestion, draft: PlanDraft, lane: QueueLane) -> NSView {
        let n = draft.lines.count
        var text = "\(n) suggestion\(n == 1 ? "" : "s")"
        if let o = draft.overlaps { text += ". They \(o.phrase)." }
        let t = NSTextField.text(text, size: 12.5, color: Palette.mut)
        t.lineBreakMode = .byTruncatingTail
        t.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let device = RELAY.deviceID.isEmpty ? nil : RELAY.deviceID
        let book = data.suggestions
        let chip = Chiplet("Planner order", symbol: "arrow.triangle.branch", color: Palette.intake)
        let buttons: [NSView] = [
            ToggleChip("With suggestions", on: after.contains(lane.project)) { [weak self] in
                guard let self else { return }
                if self.after.contains(lane.project) { self.after.remove(lane.project) } else { self.after.insert(lane.project) }
                self.reload()
            },
            ActionButton("Apply", style: .primary) { [weak self] in
                book.accept(s.id, drop: [], by: device)
                self?.updated.insert(lane.project)
                self?.after.remove(lane.project)
                self?.reload()
            },
            ActionButton("Review") { [weak self] in self?.review(s, draft) },
            ActionButton("Dismiss") { [weak self] in book.dismiss(s.id, by: device); self?.after.remove(lane.project); self?.reload() },
        ]
        // A narrow lane puts the text on its own line.
        let content: NSView = narrow
            ? NSStackView(v: [NSStackView(h: [chip, Spacer(), PlannerCard.cloudMark()], spacing: 8),
                              NSTextField.text(text, size: 12.5, color: Palette.mut, lines: 2), NSStackView(h: buttons + [Spacer()], spacing: 6)], spacing: 6)
            : NSStackView(h: [chip, t, Spacer()] + buttons + [PlannerCard.cloudMark()], spacing: 8)
        if let v = content as? NSStackView, v.orientation == .vertical { v.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true } }
        content.setAccessibilityElement(true)
        content.setAccessibilityRole(.group)
        content.setAccessibilityLabel("Planner order: \(text)")
        let box = Box(fill: Palette.intake.withAlphaComponent(0.06), border: Palette.intake.withAlphaComponent(0.4), radius: 8)
        let pad = Padded(content, vertical: 7, side: 10)
        box.addSubview(pad)
        NSLayoutConstraint.activate([
            pad.leadingAnchor.constraint(equalTo: box.leadingAnchor), pad.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            pad.topAnchor.constraint(equalTo: box.topAnchor), pad.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    private func columns(_ b: QueueBoard, lane: QueueLane, pick: QueueLane.Pick, kind: @escaping (String) -> AreaKind) -> NSView {
        let parts: [(String, [NSView], String)] = [
            ("Running", b.running.map { runningCard($0, kind: kind) } + freeSlots(b.free, lane: lane), "No slot"),
            ("Up next", b.next.enumerated().map { i, card in entryCard(card, number: i + 1, lane: lane, kind: kind) }, "Empty"),
            ("Waits", b.waits.map { entryCard($0, number: nil, lane: lane, kind: kind) }, "Empty"),
            ("Held", b.held.map { heldCard($0, kind: kind) }, hasCloud ? "Empty" : "Needs OverSire Cloud"),
        ]
        let counts = [b.running.count, b.next.count, b.waits.count, b.held.count]
        let views: [NSView] = parts.enumerated().map { i, part in
            let (title, cards, empty) = part
            let v = NSStackView(v: [NSStackView(h: [NSTextField.text(title.uppercased(), size: 11, weight: .semibold, color: Palette.dim),
                                                     NSTextField.text("\(counts[i])", size: 11, color: Palette.dim), Spacer()], spacing: 6)], spacing: 6)
            v.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
            for card in cards { v.addFull(card) }
            if cards.isEmpty { v.addFull(NSTextField.text(empty, size: 12, color: Palette.dim)) }
            // The filler takes the height that a taller column adds, so the cards keep the top.
            let fill = NSView()
            fill.setContentHuggingPriority(.init(1), for: .vertical)
            v.addArrangedSubview(fill)
            return v
        }
        func row(_ vs: [NSView]) -> NSStackView {
            let r = NSStackView(h: vs, spacing: 12, align: .top)
            r.distribution = .fillEqually
            return r
        }
        guard narrow else { return row(views) }
        let two = NSStackView(v: [row(Array(views[0..<2])), row(Array(views[2..<4]))], spacing: 14)
        two.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: two.widthAnchor).isActive = true }
        return two
    }

    // A board card: the key, the title, the areas, the shared area and the hold. `actions` show on hover or focus.
    private func card(_ c: QueueBoard.Card, lead: NSView?, badge: NSView?, kind: (String) -> AreaKind, note: String?, noteColor: NSColor = Palette.warn,
                      actions: [NSView] = [], label: String, open: @escaping () -> Void) -> NSView {
        let title = data.projectStore.item(key: c.key)?.item.title ?? ""
        let head = NSStackView(h: (lead.map { [$0] } ?? []) + [NSTextField.text(c.key, size: 12, weight: .semibold, mono: true), Spacer()], spacing: 6)
        let body = NSStackView(v: [head, NSTextField.text(title, size: 12.5, color: Palette.mut, lines: 2)], spacing: 4)
        if let badge { body.addFull(NSStackView(h: [badge, Spacer()], spacing: 0)) }
        if !c.areas.isEmpty { body.addFull(Wrap(c.areas.map { AreaChip($0, kind: kind($0)) })) }
        if let clash = c.clash { body.addFull(NSTextField.text("▲ Same area as \(clash)", size: 11.5, weight: .medium, color: Palette.bad, lines: 2)) }
        if let note { body.addFull(NSTextField.text(note, size: 11.5, color: noteColor, lines: 2)) }
        var reveal: NSView?
        if !actions.isEmpty {
            let line = NSStackView(h: [Spacer()] + actions, spacing: 4)
            body.addFull(line)
            reveal = line
        }
        body.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: body.widthAnchor).isActive = true }
        let row = Row([body], height: 40, inset: 8, label: [label, title, c.areas.isEmpty ? nil : "areas " + c.areas.joined(separator: ", "),
                                                         c.clash.map { "same area as " + $0 }, note].compactMap { $0 }.joined(separator: ", "), onClick: open)
        row.revealViews = reveal.map { [$0] } ?? []
        let box = Box(fill: Palette.raise, border: c.clash == nil ? Palette.line : Palette.bad, radius: 8)
        if c.clash != nil { box.borderWidth = 2 }
        box.addSubview(row)
        row.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 2), row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -2),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 2), row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        return box
    }

    private func runningCard(_ c: QueueBoard.Card, kind: (String) -> AreaKind) -> NSView {
        let badge = data.statusJob.item(c.key).map { StatusPill($0) }
        return card(c, lead: Glyph("play.fill", color: Palette.run, size: 10), badge: badge, kind: kind,
                    note: claimText(c.key), label: "\(c.key) runs") { [weak self] in self?.go(.item(c.key, .session)) }
    }

    private func freeSlots(_ n: Int, lane: QueueLane) -> [NSView] {
        let left = data.queue.left(lane)
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        return (0..<n).map { i in
            guard i < left.count else { return FreeSlot() }
            let l = left[i]
            return FreeSlot("\(l.key) left: \(l.state.label) \(clock.string(from: l.at))")
        }
    }

    private func entryCard(_ c: QueueBoard.Card, number: Int?, lane: QueueLane, kind: (String) -> AreaKind) -> NSView {
        let lead = number.map { NSTextField.text("\($0)", size: 12, weight: .semibold, color: Palette.dim, mono: true) }
        let e = lane.entries.first { $0.key == c.key }
        let cond = e.flatMap { $0.condition == .slot ? nil : $0.condition.label }
        let note = [c.note, cond.map { "🕑 " + $0 }].compactMap { $0 }.joined(separator: "\n")
        let source = e.flatMap { $0.source == .you ? nil : Chiplet($0.source == .label ? "label" : "assignee", symbol: "arrow.down.circle") }
        let v = card(c, lead: lead, badge: source, kind: kind, note: note.isEmpty ? nil : note, noteColor: c.note == nil ? Palette.dim : Palette.warn,
                     actions: entryActions(c.key, lane: lane), label: number.map { "Number \($0): \(c.key)" } ?? "\(c.key) waits") { [weak self] in
            self?.go(.item(c.key, .overview))
        }
        (v.subviews.first as? Row)?.menuItems = { [weak self] in self?.conditionMenu(c.key).map(\.item) ?? [] }
        return v
    }

    private func heldCard(_ c: QueueBoard.Card, kind: (String) -> AreaKind) -> NSView {
        card(c, lead: Glyph("pause.circle", color: Palette.warn, size: 11), badge: nil, kind: kind, note: c.note ?? "Held by the cloud",
             label: "\(c.key) held") { [weak self] in self?.go(.item(c.key, .overview)) }
    }

    // ↑ ↓ Start now ✕ for one queue entry.
    private func entryActions(_ key: String, lane: QueueLane) -> [NSView] {
        let q = data.queue
        let n = lane.entries.firstIndex { $0.key == key } ?? 0
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

    private func conditionMenu(_ key: String) -> [MenuAction] {
        QueueEntry.Condition.allCases.map { c in MenuAction("Start: " + c.label) { [weak self] in self?.data.queue.set(c, for: key); self?.reload() } }
    }

    // The dense list: one line per item.
    private func list(_ card: Card, _ b: QueueBoard, lane: QueueLane, pick: QueueLane.Pick, kind: @escaping (String) -> AreaKind) {
        for c in b.running {
            card.add(line(c, lead: Glyph("play.fill", color: Palette.run, size: 11), kind: kind, status: data.statusJob.item(c.key).map { StatusPill($0) },
                          label: "\(c.key) runs") { [weak self] in self?.go(.item(c.key, .session)) })
        }
        let entries = lane.entries
        for e in entries {
            let c = b.next.first { $0.key == e.key } ?? b.waits.first { $0.key == e.key } ?? QueueBoard.Card(key: e.key)
            let n = (b.next.firstIndex { $0.key == e.key }).map { $0 + 1 }
            let lead = NSTextField.text(n.map(String.init) ?? "–", size: 12, weight: .semibold, color: Palette.dim, mono: true)
            let status: NSView = c.note.map { Chiplet($0, color: pick.holds[e.key]?.isArea == true ? Palette.bad : Palette.warn) }
                ?? Chiplet(pick.next == e.key ? "✓ Starts next" : "✓ Ready", color: Palette.ok)
            let cond = MenuChip(e.condition.label, symbol: "clock") { [weak self] in self?.conditionMenu(e.key) ?? [] }
            card.add(line(c, lead: lead, kind: kind, status: status, actions: [cond] + entryActions(e.key, lane: lane),
                          label: n.map { "Number \($0): \(e.key)" } ?? "\(e.key) waits") { [weak self] in self?.go(.item(e.key, .overview)) })
        }
        for c in b.held {
            card.add(line(c, lead: Glyph("pause.circle", color: Palette.warn, size: 11), kind: kind, status: Chiplet(c.note ?? "Held", color: Palette.warn),
                          label: "\(c.key) held") { [weak self] in self?.go(.item(c.key, .overview)) })
        }
        if b.isEmpty { card.add(NSTextField.text("The lane is empty.", size: 12.5, color: Palette.dim)) }
    }

    private func line(_ c: QueueBoard.Card, lead: NSView, kind: (String) -> AreaKind, status: NSView?, actions: [NSView] = [], label: String,
                      open: @escaping () -> Void) -> NSView {
        let title = NSTextField.text(data.projectStore.item(key: c.key)?.item.title ?? "", size: 12.5)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        title.setContentHuggingPriority(.init(1), for: .horizontal)
        let key = NSTextField.text(c.key, size: 12, mono: true)
        key.setContentCompressionResistancePriority(.required, for: .horizontal)
        let areas = c.areas.map { AreaChip($0, kind: kind($0)) }
        var views: [NSView] = [lead.fixedWidth(22), key, title] + areas
        if let clash = c.clash { views.append(Chiplet("▲ " + clash, color: Palette.bad)) }
        if let status { views.append(status) }
        let row = Row(views, height: 32, inset: 6, label: [label, c.note, c.clash.map { "same area as " + $0 }].compactMap { $0 }.joined(separator: ", "), onClick: open)
        // In a narrow list the areas drop out before the title cuts to nothing.
        for a in areas { row.stack.setVisibilityPriority(.init(rawValue: 800), for: a) }
        row.stack.setClippingResistancePriority(.defaultLow, for: .horizontal)
        // The actions take no width: they show over the trailing edge on hover or focus.
        row.hoverViews = actions
        return row
    }

    // A running item whose claim could not grow.
    private func claimText(_ key: String) -> String? {
        guard let b = data.planner.claim(key: key)?.blocked?.first, let by = b.by else { return nil }
        return "⊘ Area used by \(by.key) (\(b.area))"
    }

    // The hub gate reads the slots from the Planner settings.
    private func syncSlots(_ project: String, _ n: Int) {
        guard hasCloud, data.planner.settings(project).slots != n else { return }
        data.planner.update(project) { $0.slots = n }
    }

    // Held work orders that match no lane.
    private func heldCard(_ orders: [WorkOrder]) -> NSView {
        let c = Card(title: "Held work orders", trailing: [PlannerCard.cloudMark()], padding: 12, spacing: 2)
        for o in orders {
            guard let key = o.itemKey else { continue }
            let note = o.hold.flatMap(QueueBoard.note) ?? "Held"
            c.add(line(QueueBoard.Card(key: key, note: note), lead: Glyph("pause.circle", color: Palette.warn, size: 11), kind: { _ in .core },
                       status: Chiplet(note, color: Palette.warn), label: "\(key) held") { [weak self] in self?.go(.item(key, .overview)) })
        }
        return c
    }

    private func planeNote() -> NSView {
        var how: [String] = []
        if !AGENTS.startLabel.isEmpty { how.append("add the label \"\(AGENTS.startLabel)\"") }
        if !AGENTS.botUser.isEmpty { how.append("assign the item to \(AGENTS.botUser)") }
        let text = how.isEmpty ? "Plane triggers are off." : "To start from Plane, " + how.joined(separator: " or ") + "."
        return NSStackView(h: [Glyph("arrow.down.circle", color: Palette.dim, size: 11), NSTextField.text(text, size: 12, color: Palette.dim, lines: 2), Spacer(),
                               ActionButton("Queue settings", style: .link) { [weak self] in self?.go(.settings(.agents, anchor: "queue")) }], spacing: 6)
    }

    // MARK: Review

    private func review(_ s: Suggestion, _ d: PlanDraft) {
        guard let win = view.window, sheet == nil else { return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 200), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        let lane = s.lane ?? ""
        let close = { [weak self, weak win, weak w] in
            guard let self, let w else { return }
            win?.endSheet(w)
            self.sheet = nil
        }
        let cancel = ActionButton("Close", key: "\u{1b}") { close() }
        let card = Card(title: "Review the plan change", trailing: [cancel], padding: 18, border: .clear)
        card.add(NSTextField.text("Clear a line to keep it out. Nothing changes before you accept.", size: 12, color: Palette.dim, lines: 2))
        card.add(planReview(s, draft: d) { [weak self] in
            close()
            if self?.data.suggestions.all.first(where: { $0.id == s.id })?.state == .accepted { self?.updated.insert(lane) }
            self?.after.remove(lane)
        })
        w.contentView = card
        card.widthAnchor.constraint(equalToConstant: 540).isActive = true
        sheet = w
        win.beginSheet(w)
        Self.openSheet = w
    }

    // MARK: AI order and Add

    // Asks AI once per lane order. A reply that keeps the order is no suggestion.
    private func orderSuggestion(_ lane: QueueLane) -> (order: [String], reason: String)? {
        let keys = lane.entries.map(\.key)
        if let s = orders[lane.project], Set(s.order) == Set(keys), s.order != keys { return s }
        let store = data.projectStore
        guard !keys.contains(where: { store.relations.loading.contains($0.uppercased()) }) else { return nil }
        let blockers = Dictionary(uniqueKeysWithValues: keys.map { ($0, store.blockers(of: $0)) }).filter { !$0.value.isEmpty }
        let tag = lane.project + "|" + keys.joined(separator: ",") + "|" + blockers.keys.sorted().map { $0 + ":" + blockers[$0]!.joined(separator: ",") }.joined(separator: ";")
        guard AGENTS.aiMode != .off, keys.count > 1, !asked.contains(tag) else { return nil }
        asked.insert(tag)
        ordering.insert(lane.project)
        let vision = data.projectStore.tracked.first { $0.ref.storeKey == lane.project }.flatMap { data.memory.vision(of: $0.ref)?.text }
        suggestOrder(lane, store: data.projectStore, vision: vision, blockers: blockers) { [weak self] s in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ordering.remove(lane.project)
                if let s { self.orders[lane.project] = s }
                self.reload()
            }
        }
        return nil
    }

    /// `vision`: the project vision. `blockers`: the open blocker keys of each entry.
    private func suggestOrder(_ lane: QueueLane, store: ProjectStore, vision: String?, blockers: [String: [String]],
                              done: @escaping ((order: [String], reason: String)?) -> Void) {
        guard AI_CFG.queueOrder, lane.entries.count > 1, let ai = AIClient.current else { done(nil); return }
        var bodies: [String: String] = [:]
        for e in lane.entries { bodies[e.key] = store.item(key: e.key)?.item.body }
        let input = AgentPrompts.orderInput(lane.entries, bodies: bodies, vision: vision, blockers: blockers)
        ai.run(.order, input, id: "order:\(lane.id)") { r in
            if case .success(let t) = r { done(AgentPrompts.parseOrder(t, keys: lane.entries.map(\.key))) } else { done(nil) }
        }
    }

    // Open items with no agent, not in the queue, by project.
    private func addMenu(_ anchor: NSView) {
        let m = NSMenu()
        var keep: [MenuAction] = []
        let store = data.projectStore
        for s in store.tracked {
            guard let snap = store.snapshots[s.ref.storeKey] else { continue }
            let open = snap.items.filter { i in
                let cat = snap.option(i.statusOptionId)?.category
                return (cat == .todo || cat == nil) && data.agentIndex.agent(i.key) == nil && !data.queue.contains(i.key)
            }
            guard !open.isEmpty else { continue }
            let sub = NSMenu()
            for i in open.prefix(40) {
                let a = MenuAction("\(i.key)  \(i.title.prefix(70))") { [weak self] in self?.data.queue.add(i, snap: snap) }
                keep.append(a)
                sub.addItem(a.item)
            }
            let mi = NSMenuItem(title: "\(s.title) (\(open.count))", action: nil, keyEquivalent: "")
            mi.submenu = sub
            m.addItem(mi)
        }
        if m.items.isEmpty { m.addItem(withTitle: "No open items without a session", action: nil, keyEquivalent: "").isEnabled = false }
        withExtendedLifetime(keep) {
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 3), in: anchor)
        }
    }
}

// One block for each slot: filled while a session runs in it. The text next to it gives the count.
final class SlotMeter: NSStackView {
    init(busy: Int, slots: Int) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 3
        translatesAutoresizingMaskIntoConstraints = false
        for i in 0..<max(busy, slots) {
            let b = Box(fill: i < busy ? (i < slots ? Palette.run : Palette.bad) : nil, border: i < busy ? nil : Palette.line, radius: 2)
            b.widthAnchor.constraint(equalToConstant: 12).isActive = true
            b.heightAnchor.constraint(equalToConstant: 8).isActive = true
            addArrangedSubview(b)
        }
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// An empty slot in the Running column.
// `left` names the session that freed it.
final class FreeSlot: Box {
    init(_ left: String? = nil) {
        super.init(fill: nil, border: Palette.line, radius: 8)
        let text = "Free slot" + (left.map { "\n" + $0 } ?? "")
        let t = NSTextField.text(text, size: 12, color: Palette.dim, lines: 3)
        t.alignment = .center
        addSubview(t)
        t.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([t.centerXAnchor.constraint(equalTo: centerXAnchor), t.centerYAnchor.constraint(equalTo: centerYAnchor),
                                     t.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
                                     heightAnchor.constraint(equalTo: t.heightAnchor, constant: left == nil ? 28 : 16)])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text.replacingOccurrences(of: "\n", with: ", "))
    }
    required init?(coder: NSCoder) { fatalError() }
}
