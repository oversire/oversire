import Cocoa
import OverSireCore

// A chip with a dashed border, for a code area tag. The glyph tells the kind without the border: ◆ core, ◇ feature.
final class AreaChip: Chiplet {
    private let dash = CAShapeLayer()

    init(_ area: String, kind: AreaKind = .feature) {
        super.init("\(kind.isCore ? "◆" : "◇") \(area)", mono: true)
        border = nil
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [3, 2]
        layer?.addSublayer(dash)
        setAccessibilityLabel("\(kind.isCore ? "Core" : "Feature") area \(area)")
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

// The Planner card on the item page: the tracker relations and, with a cloud account, the code areas.
final class PlannerCard: Card {
    struct Actions {
        var open: (String) -> Void
        var add: (RelationKind) -> Void
        var remove: (ItemRelation) -> Void
        var editAreas: () -> Void
    }

    static let groups: [(RelationKind, String)] = [(.blockedBy, "Blocked by"), (.blocks, "Blocks"), (.relatesTo, "Related")]
    private var keep: [MenuAction] = []

    /// `relations` nil shows a skeleton. `areas` nil hides the Areas row (no cloud account).
    init(relations: [ItemRelation]?, store: ProjectStore, openBlockers: [String], areas: [String]?, kind: (String) -> AreaKind = { _ in .core },
         error: String?, actions: Actions) {
        let addButton = ActionButton("Add relation…", symbol: "plus")
        super.init(title: "Planner", trailing: [addButton])
        setAccessibilityLabel("Planner")
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
            setAccessibilityLabel("Planner. Loading the relations.")
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
            let chips: [NSView] = areas.isEmpty ? [NSTextField.text("None", size: 12.5, color: Palette.dim)] : areas.map { AreaChip($0, kind: kind($0)) }
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

// A plan change of the hub: each line as a sentence with a check box and its reason. Accept sends the cleared lines as edit.drop.
final class PlanReviewView: NSStackView {
    private var cleared: Set<Int> = []
    private let count: Int
    private var ok: ActionButton!

    init(_ s: Suggestion, draft: PlanDraft, store: ProjectStore, kind: @escaping (String) -> AreaKind, now: Date = Date(),
         accept: @escaping (Set<Int>) -> Void, dismiss: @escaping () -> Void) {
        count = draft.lines.count
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        if let o = draft.overlaps {
            addFull(NSTextField.text("These changes \(o.phrase).", size: 12.5, color: Palette.mut, lines: 2))
        }
        for (i, line) in draft.lines.enumerated() {
            let box = NSButton(checkboxWithTitle: Self.sentence(line, store: store, kind: { draft.kinds?[$0] ?? kind($0) }),
                               target: self, action: #selector(toggled(_:)))
            box.tag = i
            box.state = .on
            box.font = .systemFont(ofSize: 12.5)
            box.setAccessibilityHelp(line.reason)
            let why = NSTextField.text(line.reason, size: 11.5, color: Palette.dim, lines: 2)
            let v = NSStackView(v: [box, why], spacing: 1)
            why.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20).isActive = true
            why.trailingAnchor.constraint(equalTo: v.trailingAnchor).isActive = true
            addFull(v)
        }
        ok = ActionButton(Self.acceptTitle(count), style: .primary) { [weak self] in accept(self?.cleared ?? []) }
        ok.setAccessibilityLabel("Accept the checked lines")
        addFull(NSStackView(h: [ok, ActionButton("Dismiss") { dismiss() }, Spacer(),
                                NSTextField.text(s.expiresText(now: now), size: 11.5, color: Palette.dim)], spacing: 6))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Plan change: \(s.title)")
    }
    required init(coder: NSCoder) { fatalError() }

    @objc private func toggled(_ b: NSButton) {
        if b.state == .on { cleared.remove(b.tag) } else { cleared.insert(b.tag) }
        ok.title = Self.acceptTitle(count - cleared.count)
        ok.isEnabled = cleared.count < count
    }

    static func acceptTitle(_ n: Int) -> String { "Accept \(n)" }

    /// The line in plain words, without +, − or a diff.
    static func sentence(_ line: PlanDraft.Line, store: ProjectStore, kind: (String) -> AreaKind) -> String {
        func rel(_ r: ItemRelation) -> String {
            switch r.kind {
            case .blockedBy: return "blocked by \(r.item.key)"
            case .blocks: return "blocking \(r.item.key)"
            default: return "related to \(r.item.key)"
            }
        }
        func area(_ a: String) -> String { "\(kind(a).isCore ? "◆" : "◇") \(a)" }
        switch line {
        case .order(let l):
            return l.after.map { "Start \(l.item.key) after \($0.key)." } ?? "Start \(l.item.key) first."
        case .relation(let l):
            let parts = l.add.map { "Mark \(l.item.key) as \(rel($0))." } + l.remove.map { "\(l.item.key) is no longer \(rel($0))." }
            return parts.joined(separator: " ")
        case .area(let l):
            let parts = l.add.map { "Add the area \(area($0)) to \(l.item.key)." } + l.remove.map { "Remove the area \(area($0)) from \(l.item.key)." }
            return parts.joined(separator: " ")
        }
    }
}
