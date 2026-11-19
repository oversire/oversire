import Cocoa
import OverSireCore

/// The facts of one plan item, for the tip and the selected item panel. The text follows Map.dc.html.
struct PlanItemFacts {
    struct Link {
        let key: String
        /// "426 Keyboard review"
        let label: String
        /// "Cloud store · ○ ready". The epic shows only when it is not the epic of the item.
        let sub: String
    }

    let key: String
    let epic: EpicID?
    let epicName: String?
    let title: String
    let summary: String?
    let stateText: String
    let stateColor: NSColor
    let dates: String
    let question: String?
    let waits: [Link]
    let blocks: [Link]
    let why: String
    /// Nil when the item is not on the critical path, or the toolbar hides the path.
    let critical: String?
    let epicWhy: String?

    init?(key raw: String, model m: PlanModel, showCritical: Bool) {
        let k = raw.uppercased()
        guard let n = m.graph.nodes[k] else { return nil }
        let slot = m.schedule.slots[k]
        let deps = m.graph.dependents(of: k)
        key = k
        epic = n.epic
        epicName = n.epic.map(m.name)
        title = n.title
        summary = m.gists[k]
        (stateText, stateColor) = Self.state(n, m)

        if let slot {
            let d = slot.days, span = "\(d) day\(d == 1 ? "" : "s")"
            dates = n.started ? "Started \(m.date(slot.start)) · ends \(m.date(slot.end - 1)) · \(span)"
                              : "\(m.date(slot.start)) → \(m.date(slot.end - 1)) · \(span)"
        } else {
            dates = n.state == .done ? "Done" : "Not scheduled"
        }
        question = n.state == .input ? m.signals.input[k].flatMap { $0.isEmpty ? nil : $0 } : nil

        func link(_ x: String) -> Link {
            let other = m.graph.nodes[x]?.epic
            let ep = other != nil && other != n.epic ? m.name(other!) + " · " : (other == nil ? "other project · " : "")
            let title = m.graph.nodes[x]?.title
            return Link(key: x, label: m.short(x) + (title.map { " " + $0 } ?? ""), sub: ep + (other == nil ? "open" : m.state(x).text))
        }
        waits = (n.blockers + n.external).map(link)
        blocks = deps.map(link)

        let epics = Set(deps.compactMap { m.graph.nodes[$0]?.epic })
        var why = deps.isEmpty ? "Nothing waits on it."
            : "It unblocks \(deps.count) item\(deps.count == 1 ? "" : "s")" + (epics.count > 1 ? " in \(epics.count) epics." : ".")
        if let slot {
            why += slot.critical ? " No slack." : " It can slip \(slot.slack) day\(slot.slack == 1 ? "" : "s") with no delay to the end."
        }
        self.why = why

        let end = m.date(m.schedule.end - 1)
        if showCritical, let slot, slot.critical {
            if !n.started && n.blockers.isEmpty {
                let planned = n.epic.flatMap(m.epic)?.state == .planned
                critical = "Start of the critical path." + (planned ? " Its epic is planned, but start this item now." : " Start it first.")
            } else if deps.isEmpty {
                critical = "End of the critical path. It sets the end date: \(end)."
            } else {
                critical = "On the critical path. Each day of delay here moves the end (\(end)) by 1 day."
            }
        } else {
            critical = nil
        }
        epicWhy = n.epic.map { id in
            m.name(id) + ": " + (m.status(id) ?? "No goal yet.")
                + (deps.contains { m.graph.nodes[$0]?.epic != id } ? " Other epics need this item too." : "")
        }
    }

    /// The long state text: "● Working · claude", "⏸ Waits for 421, 440", "◌ No spec yet. Plan it first."
    private static func state(_ n: PlanNode, _ m: PlanModel) -> (String, NSColor) {
        let color = m.state(n.key).color
        switch n.state {
        case .done: return ("✓ Done", color)
        case .working: return ("● Working" + (m.signals.working[n.key].map { " · " + $0 } ?? ""), color)
        case .input: return ("▲ Needs your answer", color)
        default: break
        }
        if n.hasOpenBlocker { return ("⏸ Waits for " + (n.blockers + n.external).map(m.short).joined(separator: ", "), color) }
        return n.state == .nospec ? ("◌ No spec yet. Plan it first.", color) : ("○ Ready to start", color)
    }
}

/// The key of an item with a copy word: "OVERSIRE-421 Copy". A click copies the key and shows "Copied ✓".
final class PlanKeyButton: Box {
    private let key: String
    private let word = NSTextField.text("Copy", size: 10.5, color: Palette.dim)

    init(_ key: String) {
        self.key = key
        super.init(fill: Palette.sel, border: Palette.line, radius: 5)
        let k = NSTextField.text(key, size: 11, color: Palette.fg, mono: true)
        k.setContentCompressionResistancePriority(.required, for: .horizontal)
        word.setContentCompressionResistancePriority(.required, for: .horizontal)
        let s = NSStackView(h: [k, word], spacing: 6)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7), s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 2), s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Copy \(key)")
        toolTip = "Copy \(key)"
    }
    required init?(coder: NSCoder) { fatalError() }

    func copyKey() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(key, forType: .string)
        word.stringValue = "Copied ✓"
        word.textColor = Palette.ok
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.word.stringValue = "Copy"
            self?.word.textColor = Palette.dim
        }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { copyKey() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { copyKey(); return true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { copyKey() } else { super.keyDown(with: event) }
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// The parts that the tip and the panel share.
enum PlanItemKit {
    static func epicChip(_ name: String) -> NSView {
        let c = Chiplet(name, symbol: "circle.fill", color: EpicColor.accent, fill: EpicColor.accent.withAlphaComponent(0.14))
        c.border = nil
        c.radius = 9
        return c
    }

    /// A label of 64 points and a value: "State  ● Working · claude".
    static func row(_ label: String, _ value: NSView, width: CGFloat) -> NSView {
        let l = NSTextField.text(label, size: 12, color: Palette.dim)
        l.widthAnchor.constraint(equalToConstant: 64).isActive = true
        value.widthAnchor.constraint(equalToConstant: width - 72).isActive = true
        return NSStackView(h: [l, value], spacing: 8, align: .top)
    }

    static func wrap(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = Palette.fg, width: CGFloat) -> NSTextField {
        let t = NSTextField.text(s, size: size, weight: weight, color: color, lines: 0)
        t.preferredMaxLayoutWidth = width
        t.setContentCompressionResistancePriority(.required, for: .vertical)
        return t
    }

    /// The ◆ box or the ▲ box: a glyph and the text on a tint.
    static func callout(_ glyph: String, _ text: String, color: NSColor, width: CGFloat) -> NSView {
        let box = Box(fill: color.withAlphaComponent(0.12), border: nil, radius: 6)
        let g = NSTextField.text(glyph, size: 12, color: color)
        g.setContentCompressionResistancePriority(.required, for: .horizontal)
        let t = wrap(text, size: 12, color: color, width: width - 16 - 18)
        let s = NSStackView(h: [g, t], spacing: 6, align: .top)
        box.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), s.trailingAnchor.constraint(lessThanOrEqualTo: box.trailingAnchor, constant: -8),
            s.topAnchor.constraint(equalTo: box.topAnchor, constant: 6), s.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
        ])
        box.widthAnchor.constraint(equalToConstant: width).isActive = true
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.staticText)
        box.setAccessibilityLabel(text)
        return box
    }

    /// The Waits for or Blocks list. A click on a link jumps to that item.
    static func links(_ links: [PlanItemFacts.Link], none: String, width: CGFloat, jump: @escaping (String) -> Void) -> NSView {
        guard !links.isEmpty else { return wrap(none, size: 12, color: Palette.mut, width: width) }
        let col = NSStackView(v: [], spacing: 2)
        for l in links {
            let b = ActionButton(l.label, style: .link) { jump(l.key) }
            let t = NSMutableAttributedString(string: l.label + " ", attributes: [.foregroundColor: Palette.acc, .font: NSFont.systemFont(ofSize: 12)])
            t.append(NSAttributedString(string: l.sub, attributes: [.foregroundColor: Palette.dim, .font: NSFont.systemFont(ofSize: 12)]))
            b.attributedTitle = t
            b.truncates()
            b.alignment = .left
            b.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            b.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
            b.setAccessibilityLabel("Go to \(l.key) \(l.label), \(l.sub)")
            col.addArrangedSubview(b)
        }
        return col
    }
}

/// The tip of a plan item or a group (the done items, an epic bar). It stays open while the pointer is on it.
final class PlanItemTip: Box {
    enum Content: Equatable {
        case item(String)
        /// An epic chip, a progress text, a title, a body and one labeled row.
        case group(epic: String, progress: String, title: String, body: String, row: String, value: String, valueColor: NSColor)
    }

    static let width: CGFloat = 300
    let content: Content
    var onHover: (Bool) -> Void = { _ in }
    private var tracking: NSTrackingArea?

    init(_ content: Content, model: PlanModel, showCritical: Bool, jump: @escaping (String) -> Void) {
        self.content = content
        super.init(fill: Palette.raise, border: Palette.line, radius: 10)
        translatesAutoresizingMaskIntoConstraints = true
        shadow = {
            let s = NSShadow()
            s.shadowBlurRadius = 16
            s.shadowOffset = NSSize(width: 0, height: -6)
            s.shadowColor = NSColor.black.withAlphaComponent(0.45)
            return s
        }()
        let w = Self.width - 28
        let col = NSStackView(v: [], spacing: 8)
        switch content {
        case .item(let key):
            guard let f = PlanItemFacts(key: key, model: model, showCritical: showCritical) else { break }
            var head: [NSView] = [PlanKeyButton(f.key)]
            if let e = f.epicName { head.append(PlanItemKit.epicChip(e)) }
            col.addArrangedSubview(NSStackView(h: head + [Spacer()], spacing: 8))
            col.addArrangedSubview(PlanItemKit.wrap(f.title, size: 14, weight: .bold, width: w))
            if let s = f.summary { col.addArrangedSubview(PlanItemKit.wrap(s, size: 12, color: Palette.mut, width: w)) }
            col.addArrangedSubview(PlanItemKit.row("State", PlanItemKit.wrap(f.stateText, size: 12, color: f.stateColor, width: w - 72), width: w))
            col.addArrangedSubview(PlanItemKit.row("Dates", PlanItemKit.wrap(f.dates, size: 12, width: w - 72), width: w))
            if let q = f.question { col.addArrangedSubview(PlanItemKit.callout("▲", q, color: Palette.warn, width: w)) }
            col.addArrangedSubview(PlanItemKit.row("Waits for", PlanItemKit.links(f.waits, none: "Nothing. It can start now.", width: w - 72, jump: jump), width: w))
            col.addArrangedSubview(PlanItemKit.row("Blocks", PlanItemKit.links(f.blocks, none: "Nothing.", width: w - 72, jump: jump), width: w))
            col.addArrangedSubview(PlanItemKit.row("Why", PlanItemKit.wrap(f.why, size: 12, width: w - 72), width: w))
            if let c = f.critical { col.addArrangedSubview(PlanItemKit.callout("◆", c, color: PlanColor.critical, width: w)) }
            let rule = Box(fill: Palette.line, border: nil, radius: 0)
            rule.heightAnchor.constraint(equalToConstant: 1).isActive = true
            rule.widthAnchor.constraint(equalToConstant: w).isActive = true
            col.addArrangedSubview(rule)
            col.addArrangedSubview(PlanItemKit.wrap("Click the key to copy it. Click a link to go to that item.", size: 11, color: Palette.dim, width: w))
            setAccessibilityLabel("\(f.key), \(f.title). \(f.stateText). \(f.why)")
        case let .group(epic, progress, title, body, row, value, valueColor):
            col.addArrangedSubview(NSStackView(h: [PlanItemKit.epicChip(epic), NSTextField.text(progress, size: 11, color: Palette.dim), Spacer()], spacing: 8))
            col.addArrangedSubview(PlanItemKit.wrap(title, size: 14, weight: .bold, width: w))
            if !body.isEmpty { col.addArrangedSubview(PlanItemKit.wrap(body, size: 12, color: Palette.mut, width: w)) }
            col.addArrangedSubview(PlanItemKit.row(row, PlanItemKit.wrap(value, size: 12, color: valueColor, width: w - 72), width: w))
            setAccessibilityLabel("\(epic), \(title). \(body)")
        }
        addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), col.widthAnchor.constraint(equalToConstant: w),
            col.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])
        layoutSubtreeIfNeeded()
        frame.size = NSSize(width: Self.width, height: ceil(col.fittingSize.height) + 24)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityRoleDescription("tip")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }
    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}

/// Shows one PlanItemTip in a container view, near a target rect in container points. The tip stays while the pointer
/// is on the target or on the tip, and goes 0.22 s after the pointer leaves both.
final class PlanTipPresenter {
    private weak var container: NSView?
    private(set) var tip: PlanItemTip?
    private var hideWork: DispatchWorkItem?
    /// A shot keeps its tip: the real pointer can pass over the window.
    var pinned = false

    init(container: NSView) { self.container = container }

    var content: PlanItemTip.Content? { tip?.content }

    func show(_ content: PlanItemTip.Content, model: PlanModel, showCritical: Bool, near rect: NSRect, jump: @escaping (String) -> Void) {
        guard let c = container else { return }
        hold()
        if tip?.content != content {
            tip?.removeFromSuperview()
            let t = PlanItemTip(content, model: model, showCritical: showCritical, jump: jump)
            t.onHover = { [weak self] inside in inside ? self?.hold() : self?.release() }
            c.addSubview(t, positioned: .above, relativeTo: nil)
            tip = t
        }
        guard let t = tip else { return }
        let size = t.frame.size, b = c.bounds
        // Top of the target, measured from the top of the container.
        let top = c.isFlipped ? rect.minY : b.height - rect.maxY
        let bottom = top + rect.height
        var y = top < b.height * 0.48 ? bottom + 8 : top - 8 - size.height
        y = min(max(4, y), max(4, b.height - size.height - 4))
        let x = min(max(4, rect.minX - 4), max(4, b.width - size.width - 4))
        t.frame.origin = NSPoint(x: x, y: c.isFlipped ? y : b.height - y - size.height)
    }

    func hold() {
        hideWork?.cancel()
        hideWork = nil
    }

    func release() {
        guard !pinned else { return }
        hideWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.hide() }
        hideWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: w)
    }

    func hide() {
        hideWork?.cancel()
        hideWork = nil
        tip?.removeFromSuperview()
        tip = nil
    }
}
