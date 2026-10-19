import Cocoa
import OverSireCore

// The plan: each queue lane as a board with Now, Next and Later. A card that shares an area with another card in its column
// gets a red border and a ▲ line. With a plan change of the Planner, a toggle shows the board after it.
final class PlanPage: Page {
    /// The open review sheet, for `--uishots`.
    static weak var openSheet: NSWindow?
    static var windowNumber: Int? { openSheet?.windowNumber }

    private var after: Set<String> = []     // lanes that show the board with the suggestions
    private var updated: Set<String> = []   // lanes with an accepted plan change in this page
    private var sheet: NSWindow?

    override func build(_ col: NSStackView) {
        col.addFull(PageHeader("Plan", caption: "Items that change the same code area do not run at the same time. Now runs at once, Next starts when a slot frees."))
        if !hasCloud {
            col.addFull(NSStackView(h: [PlannerCard.cloudMark(), NSTextField.text(
                "The Planner needs OverSire Cloud: it proposes the order and the code areas. The board shows the queue and your area tags.",
                size: 12, color: Palette.dim, lines: 2), Spacer()], spacing: 8))
        }
        let lanes = data.queue.lanes
        if lanes.isEmpty { col.addFull(EmptyNote("The queue is empty. Add items to the queue to see the plan.", symbol: "list.bullet")) }
        for lane in lanes { lanePart(col, lane) }
    }

    private func lanePart(_ col: NSStackView, _ lane: QueueLane) {
        let plan = hasCloud ? data.suggestions.openPlan(lane: lane.project) : nil
        let draft = plan?.plan
        let showAfter = draft != nil && after.contains(lane.project)
        var head: [NSView] = [NSTextField.text(lane.identifier, size: 14, weight: .semibold), Spacer()]
        if draft != nil {
            let seg = NSSegmentedControl(labels: ["Now", "With suggestions"], trackingMode: .selectOne, target: self, action: #selector(toggled(_:)))
            seg.selectedSegment = showAfter ? 1 : 0
            seg.identifier = NSUserInterfaceItemIdentifier(lane.project)
            seg.setAccessibilityLabel("Show the board for \(lane.identifier)")
            head.append(seg)
        }
        col.addFull(NSStackView(h: head, spacing: 8))
        if let plan, let draft {
            let n = draft.lines.count
            var title = "The Planner has \(n) suggestion\(n == 1 ? "" : "s")."
            if let o = draft.overlaps { title += " They lower the overlaps from \(o.before) to \(o.after)." }
            col.addFull(Banner(.info, title: title, actions: [ActionButton("Review", style: .primary) { [weak self] in self?.review(plan, draft) }]))
        } else if updated.contains(lane.project) {
            col.addFull(Banner(.ok, title: "✓ Plan updated."))
        }
        col.addFull(board(lane, draft: showAfter ? draft : nil))
    }

    @objc private func toggled(_ s: NSSegmentedControl) {
        guard let lane = s.identifier?.rawValue else { return }
        if s.selectedSegment == 1 { after.insert(lane) } else { after.remove(lane) }
        reload()
    }

    // MARK: Board

    static func model(lane: QueueLane, running: [String], areas: (String) -> [String], slots: Int, draft: PlanDraft?) -> PlanBoard {
        let keys = draft.map { $0.order(lane.entries.map(\.key)) } ?? lane.entries.map(\.key)
        func a(_ k: String) -> [String] { draft.map { $0.areas(of: k, base: areas(k)) } ?? areas(k) }
        let cards = running.sorted().map { PlanBoard.Card(key: $0, areas: a($0), running: true) } + keys.map { PlanBoard.Card(key: $0, areas: a($0)) }
        return PlanBoard(cards: cards, slots: slots)
    }

    private func board(_ lane: QueueLane, draft: PlanDraft?) -> NSView {
        let q = data.queue, planner = data.planner
        let book = q.areaBook()
        let slots = planner.settings(lane.project).slots
        let b = Self.model(lane: lane, running: q.running(lane), areas: { book?.areas(key: $0) ?? [] }, slots: slots, draft: draft)
        let kind: (String) -> AreaKind = { draft?.kinds?[$0] ?? planner.kind($0, project: lane.project) }
        let clashes = b.clashes(kind: kind)
        let holds = lane.pick(state: q.state(lane.project), world: q.world(workstreams: nil)).holds
        let titles: [(PlanBoard.Column, String, String)] = [
            (.now, "Now", "Runs at the same time, up to \(slots)"), (.next, "Next", "Starts when a slot frees"), (.later, "Later", "Waits"),
        ]
        let columns: [NSView] = titles.map { c, title, note in
            let v = NSStackView(v: [NSStackView(h: [NSTextField.text(title.uppercased(), size: 11, weight: .semibold, color: Palette.dim),
                                                     NSTextField.text("\(b.cards(c).count)", size: 11, color: Palette.dim), Spacer()], spacing: 6),
                                    NSTextField.text(note, size: 11.5, color: Palette.dim)], spacing: 6)
            v.subviews.forEach { $0.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
            for card in b.cards(c) {
                let hold = draft == nil ? holds[card.key].flatMap(Self.holdText) ?? claimText(card.key) : nil
                v.addFull(cardView(card, kind: kind, clash: clashes[card.key], hold: hold))
            }
            if b.cards(c).isEmpty { v.addFull(NSTextField.text("Empty", size: 12, color: Palette.dim)) }
            // The filler takes the height that a taller column adds, so the cards keep the top.
            let fill = NSView()
            fill.setContentHuggingPriority(.init(1), for: .vertical)
            v.addArrangedSubview(fill)
            return v
        }
        let row = NSStackView(h: columns, spacing: 12, align: .top)
        row.distribution = .fillEqually
        return row
    }

    static func holdText(_ h: QueueHold) -> String? {
        switch h {
        case .waits(let keys): return "⏸ Waits for " + keys.joined(separator: ", ")
        case .area(let a, let k): return "⏸ Waits for \(k) (\(a))"
        case .unknown: return nil
        }
    }

    // A running item whose claim could not grow.
    private func claimText(_ key: String) -> String? {
        guard let b = data.planner.claim(key: key)?.blocked?.first, let by = b.by else { return nil }
        return "⏸ Waits for \(by.key) (\(b.area))"
    }

    private func cardView(_ c: PlanBoard.Card, kind: (String) -> AreaKind, clash: (other: String, area: String)?, hold: String?) -> NSView {
        let title = data.projectStore.item(key: c.key)?.item.title ?? ""
        let box = Card(padding: 10, spacing: 5, border: clash == nil ? Palette.line : Palette.bad)
        if clash != nil { box.borderWidth = 2 }
        var head: [NSView] = [Chiplet(c.key, color: Palette.fg, mono: true) { [weak self] in self?.go(.item(c.key, .overview)) }, Spacer()]
        if c.running { head.append(NSTextField.text("● Running", size: 11.5, weight: .semibold, color: Palette.run)) }
        box.add(NSStackView(h: head, spacing: 6))
        box.add(NSTextField.text(title, size: 12.5, lines: 2))
        if !c.areas.isEmpty { box.add(Wrap(c.areas.map { AreaChip($0, kind: kind($0)) })) }
        if let clash { box.add(NSTextField.text("▲ Same area as \(clash.other) (\(clash.area))", size: 11.5, weight: .medium, color: Palette.bad, lines: 2)) }
        if let hold { box.add(NSTextField.text(hold, size: 11.5, color: Palette.warn, lines: 2)) }
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel([c.key, title, c.running ? "running" : nil, c.areas.isEmpty ? nil : "areas " + c.areas.joined(separator: ", "),
                                   clash.map { "same area as \($0.other)" }, hold].compactMap { $0 }.joined(separator: ", "))
        return box
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
}
