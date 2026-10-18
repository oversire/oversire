import Cocoa
import OverSireCore

// A chip with a dashed border, for a code area tag. The ◇ glyph tells it apart without the border.
final class AreaChip: Chiplet {
    private let dash = CAShapeLayer()

    init(_ area: String) {
        super.init("◇ \(area)", mono: true)
        border = nil
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [3, 2]
        layer?.addSublayer(dash)
        setAccessibilityLabel("Area \(area)")
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        super.updateLayer()
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance { dash.strokeColor = Palette.dim.cgColor }
    }

    override func layout() {
        super.layout()
        needsDisplay = true
    }
}

// The Sequence card on the item page: the tracker relations and, with a cloud account, the code areas.
final class SequenceCard: Card {
    struct Actions {
        var open: (String) -> Void
        var add: (RelationKind) -> Void
        var remove: (ItemRelation) -> Void
        var editAreas: () -> Void
    }

    static let groups: [(RelationKind, String)] = [(.blockedBy, "Blocked by"), (.blocks, "Blocks"), (.relatesTo, "Related")]
    private var keep: [MenuAction] = []

    /// `relations` nil shows a skeleton. `areas` nil hides the Areas row (no cloud account).
    init(relations: [ItemRelation]?, store: ProjectStore, openBlockers: [String], areas: [String]?, error: String?, actions: Actions) {
        let addButton = ActionButton("Add relation…", symbol: "plus")
        super.init(title: "Sequence", trailing: [addButton])
        setAccessibilityLabel("Sequence")
        addButton.onClick = { [weak self, weak addButton] in
            guard let self, let add = addButton else { return }
            let m = NSMenu()
            self.keep = [("Blocked by…", RelationKind.blockedBy), ("Blocks…", .blocks), ("Related to…", .relatesTo)].map { t, k in
                MenuAction(t) { actions.add(k) }
            }
            self.keep.forEach { m.addItem($0.item) }
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: add.bounds.height + 3), in: add)
        }
        guard let relations else {
            for _ in 0..<3 { add(Self.skeletonRow()) }
            setAccessibilityLabel("Sequence. Loading the relations.")
            return
        }
        if let error { add(NSTextField.text("Could not load the relations: \(error)", size: 12, color: Palette.bad, lines: 2)) }
        for (kind, title) in Self.groups {
            let rows = relations.filter { $0.kind == kind }
            for (i, r) in rows.enumerated() {
                add(Self.line(i == 0 ? title : "", Self.relationRow(r, store: store, actions: actions)))
            }
        }
        if relations.isEmpty { add(Self.line("", NSTextField.text("No relations yet.", size: 12.5, color: Palette.dim))) }
        if let areas {
            let edit = ActionButton("Edit", style: .link) { actions.editAreas() }
            edit.setAccessibilityLabel("Edit areas")
            let chips: [NSView] = areas.isEmpty ? [NSTextField.text("None", size: 12.5, color: Palette.dim)] : areas.map { AreaChip($0) }
            add(Self.line("Areas", NSStackView(h: chips + [Self.cloudMark(), edit, Spacer()], spacing: 6)))
        }
        let total = relations.filter { $0.kind == .blockedBy }.count
        add(NSTextField.text(Self.state(open: openBlockers, total: total), size: 11.5, color: Palette.dim, lines: 2))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The state in words.
    static func state(open: [String], total: Int) -> String {
        if total == 0 { return "No blockers. The queue can start this item." }
        if open.isEmpty { return "All \(total) blocker\(total == 1 ? " is" : "s are") done. The queue can start this item." }
        let n = open.count
        return "Waits on \(n) open blocker\(n == 1 ? "" : "s"). The queue holds this item until \(open.joined(separator: ", ")) \(n == 1 ? "is" : "are") done."
    }

    static func cloudMark() -> NSView {
        let c = Chiplet("Cloud", symbol: "cloud", color: Palette.intake)
        c.setAccessibilityLabel("Needs OverSire Cloud")
        return c
    }

    private static func line(_ label: String, _ value: NSView) -> NSView {
        let k = NSTextField.text(label, size: 11.5, color: Palette.dim)
        k.widthAnchor.constraint(equalToConstant: 82).isActive = true
        value.setContentHuggingPriority(.init(1), for: .horizontal)
        return NSStackView(h: [k, value], spacing: 10)
    }

    private static func relationRow(_ r: ItemRelation, store: ProjectStore, actions: Actions) -> NSView {
        let found = store.item(key: r.item.key)
        let opt = found.flatMap { $0.snap.option($0.item.statusOptionId) }
        let status = found == nil ? "Not tracked" : (opt?.name ?? "No status")
        let ring = StatusGlyph(category: opt?.category ?? .todo, color: projectColor(opt?.color ?? "GRAY"), name: status).sized(14)
        let title = NSTextField.text(found?.item.title ?? r.item.key, size: 12.5)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let word = NSTextField.text(status, size: 11.5, color: Palette.dim)
        word.setContentCompressionResistancePriority(.required, for: .horizontal)
        let views: [NSView] = [ring, NSTextField.text(r.item.key, size: 11.5, color: Palette.mut, mono: true), title, word, Spacer()]
        let kind = groups.first { $0.0 == r.kind }?.1 ?? r.kind.rawValue
        let row = Row(views, height: 28, inset: 4, label: "\(kind) \(r.item.key), \(found?.item.title ?? ""), \(status)") { actions.open(r.item.key) }
        let remove = MenuAction("Remove") { actions.remove(r) }
        row.menuItems = { [remove] in [remove.item] }
        let x = ActionButton("", symbol: "xmark") { actions.remove(r) }
        x.isBordered = false
        x.setAccessibilityLabel("Remove \(kind.lowercased()) \(r.item.key)")
        x.toolTip = "Remove"
        row.hoverViews = [x]
        return row
    }

    private static func skeletonRow() -> NSView {
        let bars: [NSView] = [82, 14, 90, 220].map { w in
            let b = Box(fill: Palette.line, border: nil, radius: 4)
            b.widthAnchor.constraint(equalToConstant: w).isActive = true
            b.heightAnchor.constraint(equalToConstant: 10).isActive = true
            return b
        }
        let s = NSStackView(h: bars + [Spacer()], spacing: 10)
        s.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)
        s.setAccessibilityElement(false)
        return s
    }
}

// A sequence suggestion of the hub: one check box for each line. Accept sends the cleared lines as edit.drop.
final class SequenceSuggestionCard: Card {
    private var cleared: Set<Int> = []

    init(_ s: Suggestion, draft: SequenceDraft, store: ProjectStore, now: Date = Date(),
         accept: @escaping (Set<Int>) -> Void, dismiss: @escaping () -> Void, open: @escaping (String) -> Void) {
        super.init(fill: Palette.intake.withAlphaComponent(0.06), border: Palette.intake.withAlphaComponent(0.55))
        let key = s.subjectKey ?? ""
        let title = NSTextField.text(store.item(key: key)?.item.title ?? s.title, size: 13, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        add(NSStackView(h: [Chiplet("Sequencing", symbol: "arrow.triangle.branch", color: Palette.intake),
                            Chiplet(key, color: Palette.fg, mono: true) { open(key) }, title, Spacer(), SequenceCard.cloudMark()], spacing: 7))
        add(NSTextField.text(s.body, size: 12.5, color: Palette.mut, lines: 4))
        for (i, line) in draft.lines.enumerated() {
            let box = NSButton(checkboxWithTitle: Self.text(line, store: store), target: self, action: #selector(toggled(_:)))
            box.tag = i
            box.state = .on
            box.font = .systemFont(ofSize: 12.5)
            add(box)
        }
        let ok = ActionButton("Accept", style: .primary) { [weak self] in accept(self?.cleared ?? []) }
        ok.setAccessibilityLabel("Accept the checked lines")
        add(NSStackView(h: [ok, ActionButton("Dismiss") { dismiss() }, Spacer(),
                            NSTextField.text(s.expiresText(now: now), size: 11.5, color: Palette.dim)], spacing: 6))
        setAccessibilityLabel("Sequencing suggestion for \(key): \(s.title)")
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggled(_ b: NSButton) {
        if b.state == .on { cleared.remove(b.tag) } else { cleared.insert(b.tag) }
    }

    static func text(_ line: SequenceDraft.Line, store: ProjectStore) -> String {
        func rel(_ r: ItemRelation) -> String {
            let kind = r.kind == .relatesTo ? "Related to" : SequenceCard.groups.first { $0.0 == r.kind }?.1 ?? r.kind.rawValue
            return [kind, r.item.key, store.item(key: r.item.key)?.item.title].compactMap { $0 }.joined(separator: " ")
        }
        switch line {
        case .add(let r): return "+ " + rel(r)
        case .remove(let r): return "− Remove: " + rel(r).prefix(1).lowercased() + rel(r).dropFirst()
        case .areas(let a): return "+ Areas " + a.map { "◇ " + $0 }.joined(separator: "  ")
        }
    }
}
