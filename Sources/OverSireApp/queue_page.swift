import AppKit
import OverSireCore

// The queue: one lane per project, and the AI checks of quiet agents.
final class QueuePage: Page {
    private var orders: [String: (order: [String], reason: String)] = [:]   // lane project → AI order
    private var ordering: Set<String> = []   // lane projects that wait for the AI order
    private var asked: Set<String> = []                                      // lane project + keys, asked once

    override func build(_ col: NSStackView) {
        let seg = NSSegmentedControl(labels: AIMode.allCases.map(\.label), trackingMode: .selectOne, target: self, action: #selector(modeChanged(_:)))
        seg.selectedSegment = AIMode.allCases.firstIndex(of: AGENTS.aiMode) ?? 0
        seg.setAccessibilityLabel("AI mode")
        col.addFull(PageHeader("Queue", caption: "Items start in Orca, in order, when a slot frees. AI checks sessions that go quiet.",
                               actions: [NSTextField.text("AI acts", size: 12, color: Palette.dim), seg]))
        let mode: String
        switch AGENTS.aiMode {
        case .auto: mode = "Auto: a \"looks done\" check frees the slot and the next item starts. A \"looks stuck\" check always asks you."
        case .ask: mode = "Ask me: AI checks quiet sessions and waits for your approval."
        case .off: mode = "Off: the queue moves only when a session ends by itself."
        }
        col.addFull(NSStackView(h: [
            ToggleChip("Auto start", on: AGENTS.autoStart) { [weak self] in AGENTS.autoStart.toggle(); saveConfig(); self?.reload() },
            NSTextField.text(mode, size: 12, color: Palette.dim, lines: 2),
            Spacer(),
            ActionButton("AI features", style: .link) { [weak self] in self?.go(.settings(.ai)) },
        ], spacing: 8))
        if data.agentIndex.ready == nil {
            col.addFull(Banner(.warning, title: "Orca is off or not installed.", body: "The queue starts items in Orca.",
                               actions: [ActionButton("Orca settings") { [weak self] in self?.go(.settings(.orca)) }]))
        }

        let left = NSStackView(v: [SectionTitle("AI checks", count: data.aiChecks.pending.count)], spacing: 10)
        checks(left)
        let right = NSStackView(v: [], spacing: 10)
        lanes(right)
        for s in [left, right] {
            let fill = NSView()
            fill.setContentHuggingPriority(.init(1), for: .vertical)
            s.addArrangedSubview(fill)
        }
        left.setHuggingPriority(.init(1), for: .horizontal)
        let two = NSStackView(h: [left, right], spacing: 18, align: .top)
        col.addFull(two)
        right.widthAnchor.constraint(equalToConstant: 470).isActive = true
    }

    @objc private func modeChanged(_ s: NSSegmentedControl) {
        AGENTS.aiMode = AIMode.allCases[s.selectedSegment]
        saveConfig()
        reload()
    }

    // MARK: AI checks

    private func checks(_ col: NSStackView) {
        let judge = data.aiChecks
        guard AGENTS.aiMode != .off, AI_CFG.agentChecks else {
            col.addFull(EmptyNote(AGENTS.aiMode == .off ? "AI checks are off." : "Session checks are off in Settings › AI.", symbol: "sparkles"))
            return
        }
        let shown = judge.checks.filter { $0.state == .pending } + judge.checks.filter { $0.state != .pending }.prefix(6)
        if shown.isEmpty {
            col.addFull(EmptyNote("No checks yet. A session gets a check after \(Int(AGENTS.quietMinutes)) quiet minutes.", symbol: "sparkles"))
        }
        for j in shown { col.addFull(checkCard(j)) }
    }

    private func checkCard(_ j: Judgement) -> NSView {
        let pending = j.state == .pending
        let tone: Tone = j.verdict == .done ? .done : .warning
        let c = Card(border: pending ? tone.color.withAlphaComponent(0.55) : Palette.line)
        let title = data.projectStore.item(key: j.key)?.item.title ?? ""
        let sub = NSTextField.text(title, size: 12, color: Palette.dim)
        sub.lineBreakMode = .byTruncatingTail
        sub.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        var head: [NSView] = [Glyph("sparkles", color: Palette.acc),
                              NSTextField.text("\(j.key) · \(j.verdict.word)", size: 13, weight: .semibold), sub]
        if let a = data.agentIndex.agent(j.key) { head.append(Pill(Tone(a.phase), text: a.label())) }
        head.append(Spacer())
        if !pending { head.append(Chiplet(j.state == .approved ? "Approved" : "Held", symbol: j.state == .approved ? "checkmark" : "pause")) }
        head.append(NSTextField.text(relativeTime(j.at) + (j.byAI ? " · AI" : " · rule"), size: 11.5, color: Palette.dim))
        c.add(NSStackView(h: head, spacing: 7))
        for e in j.evidence {
            c.add(NSStackView(h: [NSTextField.text("•", color: Palette.dim), NSTextField.text(e, size: 12.5, color: Palette.mut, lines: 2)], spacing: 6, align: .top))
        }
        let act = Box(fill: Palette.raise, border: Palette.line, radius: 6)
        let actText = NSTextField.text(j.action, size: 12, color: Palette.fg, lines: 3, mono: true)
        act.addSubview(actText)
        actText.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            actText.leadingAnchor.constraint(equalTo: act.leadingAnchor, constant: 10),
            actText.trailingAnchor.constraint(equalTo: act.trailingAnchor, constant: -10),
            actText.topAnchor.constraint(equalTo: act.topAnchor, constant: 8),
            actText.bottomAnchor.constraint(equalTo: act.bottomAnchor, constant: -8),
        ])
        c.add(act)
        if pending {
            let judge = data.aiChecks
            var acts: [NSView] = [ActionButton("Approve", style: .primary) { judge.approve(j.id) }]
            if j.verdict == .stuck { acts.append(ActionButton("Free the slot") { judge.release(j.id) }) }
            acts += [ActionButton("Hold") { judge.hold(j.id) },
                     ActionButton("Open session") { [weak self] in self?.go(.item(j.key, .session)) }, Spacer()]
            c.add(NSStackView(h: acts, spacing: 6))
        }
        c.alphaValue = pending ? 1 : 0.8
        return c
    }

    // MARK: Lanes

    private func lanes(_ col: NSStackView) {
        let add = ActionButton("Add to queue", symbol: "plus")
        add.onClick = { [weak self, weak add] in if let add { self?.addMenu(add) } }
        col.addFull(NSStackView(h: [SectionTitle("Lanes", count: data.queue.lanes.count), Spacer(), add], spacing: 6))
        let q = data.queue
        if q.lanes.isEmpty { col.addFull(EmptyNote("The queue is empty. Add items here, or from an item page.", symbol: "list.bullet")) }
        for lane in q.lanes { col.addFull(laneCard(lane)) }
        let plane = Card(title: "Start from Plane")
        var how: [String] = []
        if !AGENTS.startLabel.isEmpty { how.append("add the label \"\(AGENTS.startLabel)\" to an item") }
        if !AGENTS.botUser.isEmpty { how.append("assign it to \(AGENTS.botUser)") }
        plane.add(NSTextField.text(how.isEmpty ? "Plane triggers are off." : how.joined(separator: ", or ").prefix(1).uppercased() + how.joined(separator: ", or ").dropFirst()
                                   + ". OverSire adds it to the lane of its project.", size: 12.5, color: Palette.mut, lines: 3))
        plane.add(ActionButton("Sessions and queue settings", style: .link) { [weak self] in self?.go(.settings(.queue)) })
        col.addFull(plane)
    }

    private func laneCard(_ lane: QueueLane) -> NSView {
        let q = data.queue
        let slots = AGENTS.slots(lane.project)
        let busy = q.busy(lane)
        let root = PROJECTS_CFG.orca.roots[lane.project].map { ($0 as NSString).lastPathComponent } ?? "no Orca workspace"
        let slotChip = MenuChip("\(busy)/\(slots) slots", symbol: "square.stack") { [weak self] in
            (1...4).map { n in MenuAction("\(n) session\(n == 1 ? "" : "s") at a time") { AGENTS.slots[lane.project] = n; saveConfig(); self?.reload() } }
        }
        let c = Card(padding: 10, spacing: 4)
        c.add(NSStackView(h: [Glyph("folder", color: Palette.acc), NSTextField.text(lane.identifier, size: 13, weight: .semibold),
                              NSTextField.text(root, size: 11.5, color: Palette.dim, mono: true), Spacer(), slotChip], spacing: 7))
        if let e = lane.error { c.add(Banner(.warning, title: e)) }
        let suggestion = orderSuggestion(lane)
        if suggestion == nil, ordering.contains(lane.project) { c.add(InlineSpinner("The AI reads the lane and proposes an order…")) }
        if let s = suggestion {
            c.add(Banner(.info, title: "AI order: " + s.order.joined(separator: ", "), body: s.reason,
                         actions: [ActionButton("Apply") { [weak self] in q.reorder(lane.project, keys: s.order); self?.orders[lane.project] = nil }]))
        }
        let prefix = lane.identifier.uppercased() + "-"
        for (k, a) in data.agentIndex.agents.sorted(by: { $0.key < $1.key }) where k.hasPrefix(prefix) && [.starting, .working, .waiting].contains(a.phase) {
            let title = data.projectStore.item(key: k)?.item.title ?? ""
            c.add(Row([Glyph("play.fill", color: Palette.run, size: 11).fixedWidth(22), Chiplet(k, color: Palette.fg, mono: true),
                       TwoLine(title, nil, titleSize: 12.5, weight: .regular), Pill(Tone(a.phase), text: a.label())],
                      height: 34, inset: 6, label: "\(k) runs: \(a.label())") { [weak self] in self?.go(.item(k, .session)) })
        }
        for (n, e) in lane.entries.enumerated() { c.add(entryRow(e, n: n, lane: lane)) }
        if lane.entries.isEmpty { c.add(NSTextField.text("The lane is empty.", size: 12.5, color: Palette.dim)) }
        return c
    }

    private func entryRow(_ e: QueueEntry, n: Int, lane: QueueLane) -> NSView {
        let q = data.queue
        let num = NSTextField.text("\(n + 1)", size: 12, weight: .semibold, color: Palette.dim)
        num.alignment = .center
        let cond = MenuChip(e.condition.label, symbol: "clock") { [weak self] in
            QueueEntry.Condition.allCases.map { c in MenuAction(c.label) { q.set(c, for: e.key); self?.reload() } }
        }
        let up = ActionButton("", symbol: "chevron.up") { q.move(e.key, by: -1) }
        up.isEnabled = n > 0
        up.setAccessibilityLabel("Move up")
        let down = ActionButton("", symbol: "chevron.down") { q.move(e.key, by: 1) }
        down.isEnabled = n < lane.entries.count - 1
        down.setAccessibilityLabel("Move down")
        let start = ActionButton("Start now")
        start.onClick = { [weak start] in q.start(e.key, project: lane.project, anchor: start) }
        let remove = ActionButton("", symbol: "xmark") { q.remove(e.key) }
        remove.setAccessibilityLabel("Remove \(e.key) from the queue")
        let source = e.source == .you ? nil : Chiplet(e.source == .label ? "label" : "assignee", symbol: "arrow.down.circle")
        let top = Row([num.fixedWidth(22), Chiplet(e.key, color: Palette.fg, mono: true), TwoLine(e.title, nil, titleSize: 12.5, weight: .regular)]
                      + (source.map { [$0] } ?? []), height: 30, inset: 6, label: "Number \(n + 1): \(e.key) \(e.title)") { [weak self] in
            self?.go(.item(e.key, .overview))
        }
        let actions = NSStackView(h: [Spacer(34), cond, Spacer(), up, down, start, remove], spacing: 4)
        let v = NSStackView(v: [top, actions], spacing: 2)
        top.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        actions.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -6).isActive = true
        return v
    }

    // Asks AI once per lane order. A reply that keeps the order is no suggestion.
    private func orderSuggestion(_ lane: QueueLane) -> (order: [String], reason: String)? {
        let keys = lane.entries.map(\.key)
        if let s = orders[lane.project], Set(s.order) == Set(keys), s.order != keys { return s }
        let tag = lane.project + "|" + keys.joined(separator: ",")
        guard AGENTS.aiMode != .off, keys.count > 1, !asked.contains(tag) else { return nil }
        asked.insert(tag)
        ordering.insert(lane.project)
        data.aiChecks.suggestOrder(lane, store: data.projectStore) { [weak self] s in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ordering.remove(lane.project)
                if let s { self.orders[lane.project] = s }
                self.reload()
            }
        }
        return nil
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
