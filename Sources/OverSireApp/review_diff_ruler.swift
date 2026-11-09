import Cocoa

// ─── Changes › ruler ─────────────────────────────────────────────────────────
// A thin bar at the right of the diff (OVERSIRE-442). It shows where each change is in the file
// and which part of the file is on the screen. Green is added, orange (the color of a removed line) is removed, half and half is both.

/// The ruler of the changes of a diff. A click on a mark goes to its change; a click on other space scrolls there.
final class DiffRuler: NSView {
    static let width: CGFloat = 12
    weak var table: DiffTable?
    var onChange: (Int) -> Void = { _ in }
    private var elements: [Mark] = []

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Changes of the file")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The rect of each mark, in the ruler.
    func rects() -> [(mark: DiffMark, rect: NSRect)] {
        guard let t = table, t.view.frame.height > 0, bounds.height > 0 else { return [] }
        let k = bounds.height / max(t.view.frame.height, t.scroll.contentView.bounds.height)
        return t.changeMarks.compactMap { m in
            guard let r = t.rect(ofChange: m.change) else { return nil }
            let h = max(3, r.height * k)
            return (m, NSRect(x: 2, y: min(r.minY * k, bounds.height - h), width: bounds.width - 4, height: h))
        }
    }

    /// The part of the file on the screen, in the ruler.
    func thumb() -> NSRect? {
        guard let t = table, t.view.frame.height > t.scroll.contentView.bounds.height else { return nil }
        let k = bounds.height / t.view.frame.height
        let clip = t.scroll.contentView.bounds
        return NSRect(x: 0, y: clip.minY * k, width: bounds.width, height: clip.height * k)
    }

    /// New marks: the tooltips and the accessibility buttons follow them.
    func refresh() {
        removeAllToolTips()
        let rs = rects()
        elements = rs.map { Mark($0.mark, ruler: self) }
        for (m, r) in rs { addToolTip(r, owner: m.label as NSString, userData: nil) }
        setAccessibilityChildren(elements)
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        refresh()
    }

    override func draw(_ dirtyRect: NSRect) {
        Palette.raise.withAlphaComponent(0.6).setFill()
        bounds.fill()
        Palette.line.setFill()
        NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        if let t = thumb() {
            let p = NSBezierPath(roundedRect: t.insetBy(dx: 1.5, dy: 0.5), xRadius: 3, yRadius: 3)
            Palette.mut.withAlphaComponent(0.3).setFill()
            p.fill()
            Palette.mut.withAlphaComponent(0.6).setStroke()
            p.lineWidth = 1
            p.stroke()
        }
        let current = table?.change
        for (m, r) in rects() {
            if m.added > 0, m.removed > 0 {
                Palette.ok.setFill()
                NSRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height).fill()
                Palette.bad.setFill()
                NSRect(x: r.midX, y: r.minY, width: r.width / 2, height: r.height).fill()
            } else {
                (m.added > 0 ? Palette.ok : Palette.bad).setFill()
                r.fill()
            }
            if m.change == current {
                Palette.fg.setStroke()
                let p = NSBezierPath(rect: r.insetBy(dx: -1.5, dy: -1.5))
                p.lineWidth = 1.5
                p.stroke()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let hit = rects().first(where: { $0.rect.insetBy(dx: -2, dy: -2).contains(p) }) { return onChange(hit.mark.change) }
        guard let t = table, bounds.height > 0 else { return }
        let clip = t.scroll.contentView
        let y = p.y / bounds.height * t.view.frame.height - clip.bounds.height / 2
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: max(0, min(y, t.view.frame.height - clip.bounds.height))))
        t.scroll.reflectScrolledClipView(clip)
    }

    /// A mark as a button for VoiceOver.
    private final class Mark: NSAccessibilityElement {
        let mark: DiffMark
        weak var ruler: DiffRuler?

        init(_ mark: DiffMark, ruler: DiffRuler) {
            self.mark = mark
            self.ruler = ruler
            super.init()
            setAccessibilityRole(.button)
            setAccessibilityLabel(mark.label)
            setAccessibilityParent(ruler)
        }

        override func accessibilityFrame() -> NSRect {
            guard let r = ruler, let rect = r.rects().first(where: { $0.mark == mark })?.rect, let w = r.window else { return .zero }
            return w.convertToScreen(r.convert(rect, to: nil))
        }

        override func accessibilityPerformPress() -> Bool {
            ruler?.onChange(mark.change)
            return true
        }
    }
}
