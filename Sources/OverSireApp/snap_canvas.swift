import Cocoa

// ─── Shot canvas ─────────────────────────────────────────────────────────────
// Shows the image and the marks. Mouse and keys change the model of the panel.
// All model rects are in pixels from the top-left corner. The view is flipped, so y goes down too.

final class SnapCanvasView: NSView {
    weak var panel: ShotEditorPanel?
    private let image: NSImage
    private let pixelHeight: CGFloat

    private enum Drag {
        case newMark(start: CGPoint)
        case move(mark: Int, start: CGPoint, from: SnapRect)
        case resize(mark: Int, corner: Int, from: SnapRect)
        case newCrop(start: CGPoint)
        case moveCrop(start: CGPoint, from: SnapRect)
        case resizeCrop(corner: Int, from: SnapRect)
    }
    private var drag: Drag?
    private var before: SnapEdit?
    private var draft: SnapRect?        // the new mark while the mouse is down

    init(image cg: CGImage) {
        image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        pixelHeight = CGFloat(cg.height)
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Shot")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var model: SnapEditorModel? { panel?.canvasModel }
    private func change(_ f: (inout SnapEditorModel) -> Void) {
        guard var m = panel?.canvasModel else { return }
        f(&m)
        panel?.canvasModel = m
    }

    // MARK: Transform

    /// The pixel rect in view: the crop, or the whole image while the crop mode is on.
    private var shown: SnapRect {
        guard let m = model else { return SnapRect(x: 0, y: 0, w: 1, h: 1) }
        return m.isCropping ? m.shot.full : m.shot.crop
    }

    private var k: CGFloat {
        let s = shown
        return max(0.01, min(bounds.width / CGFloat(s.w), bounds.height / CGFloat(s.h)))
    }

    private var origin: CGPoint {
        let s = shown
        return CGPoint(x: (bounds.width - CGFloat(s.w) * k) / 2, y: (bounds.height - CGFloat(s.h) * k) / 2)
    }

    func view(_ r: SnapRect) -> NSRect {
        let s = shown, o = origin, k = k
        return NSRect(x: o.x + CGFloat(r.x - s.x) * k, y: o.y + CGFloat(r.y - s.y) * k, width: CGFloat(r.w) * k, height: CGFloat(r.h) * k)
    }

    func pixel(_ p: CGPoint) -> CGPoint {
        let s = shown, o = origin, k = k
        return CGPoint(x: CGFloat(s.x) + (p.x - o.x) / k, y: CGFloat(s.y) + (p.y - o.y) / k)
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> SnapRect {
        SnapRect(x: Double(min(a.x, b.x)), y: Double(min(a.y, b.y)), w: Double(abs(a.x - b.x)), h: Double(abs(a.y - b.y)))
    }

    // MARK: Draw

    override func draw(_ dirty: NSRect) {
        guard let m = model else { return }
        let s = shown
        let target = view(s)
        image.draw(in: target, from: NSRect(x: s.x, y: Double(pixelHeight) - s.maxY, width: s.w, height: s.h),
                   operation: .copy, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high])

        for (i, mk) in m.shot.marks.enumerated() { drawMark(view(mk.rect), n: i + 1, selected: m.selected == i && !m.isCropping) }
        if let d = draft { drawMark(view(d), n: m.shot.marks.count + 1, selected: true) }
        if let c = m.crop { drawCrop(view(c), in: target) }

        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            bounds.insetBy(dx: 2, dy: 2).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private func drawMark(_ r: NSRect, n: Int, selected: Bool) {
        let halo = NSBezierPath(rect: r)
        halo.lineWidth = 5
        NSColor.white.withAlphaComponent(0.85).setStroke()
        halo.stroke()
        let line = NSBezierPath(rect: r)
        line.lineWidth = 2.5
        let red = NSColor(cgColor: SnapRenderer.vermillion)!
        (selected ? Palette.acc : red).setStroke()
        if selected { line.setLineDash([6, 3], count: 2, phase: 0) }
        line.stroke()

        let d: CGFloat = 20
        let disc = NSRect(x: r.minX - d / 2, y: r.minY - d / 2, width: d, height: d)
        NSColor.white.setFill()
        NSBezierPath(ovalIn: disc.insetBy(dx: -2, dy: -2)).fill()
        (selected ? Palette.acc : red).setFill()
        NSBezierPath(ovalIn: disc).fill()
        let t = "\(n)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.white]
        let z = t.size(withAttributes: attrs)
        t.draw(at: NSPoint(x: disc.midX - z.width / 2, y: disc.midY - z.height / 2), withAttributes: attrs)

        if selected { for h in handles(r) { drawHandle(h) } }
    }

    private func drawCrop(_ c: NSRect, in all: NSRect) {
        let outside = NSBezierPath(rect: all)
        outside.append(NSBezierPath(rect: c))
        outside.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.55).setFill()
        outside.fill()
        NSColor.white.withAlphaComponent(0.45).setStroke()
        for i in 1...2 {
            let f = CGFloat(i) / 3
            let v = NSBezierPath(); v.move(to: NSPoint(x: c.minX + c.width * f, y: c.minY)); v.line(to: NSPoint(x: c.minX + c.width * f, y: c.maxY))
            let h = NSBezierPath(); h.move(to: NSPoint(x: c.minX, y: c.minY + c.height * f)); h.line(to: NSPoint(x: c.maxX, y: c.minY + c.height * f))
            v.lineWidth = 1; h.lineWidth = 1
            v.stroke(); h.stroke()
        }
        let edge = NSBezierPath(rect: c)
        edge.lineWidth = 2
        NSColor.white.setStroke()
        edge.stroke()
        for h in handles(c) { drawHandle(h) }
    }

    private func drawHandle(_ p: NSPoint) {
        let r = NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)
        NSColor.white.setFill()
        r.fill()
        Palette.acc.setStroke()
        NSBezierPath(rect: r).stroke()
    }

    /// The corners in this order: top-left, top-right, bottom-right, bottom-left.
    private func handles(_ r: NSRect) -> [NSPoint] {
        [NSPoint(x: r.minX, y: r.minY), NSPoint(x: r.maxX, y: r.minY), NSPoint(x: r.maxX, y: r.maxY), NSPoint(x: r.minX, y: r.maxY)]
    }

    private func corner(at p: NSPoint, of r: NSRect) -> Int? {
        handles(r).firstIndex { abs($0.x - p.x) <= 7 && abs($0.y - p.y) <= 7 }
    }

    /// Moves one corner. The opposite corner stays. The result is at least 4 px.
    static func resize(_ r: SnapRect, corner: Int, to p: CGPoint, in bounds: SnapRect) -> SnapRect {
        let x = min(max(Double(p.x), bounds.x), bounds.maxX), y = min(max(Double(p.y), bounds.y), bounds.maxY)
        let fixX = corner == 0 || corner == 3 ? r.maxX : r.x
        let fixY = corner <= 1 ? r.maxY : r.y
        return SnapRect(x: min(x, fixX), y: min(y, fixY), w: max(4, abs(x - fixX)), h: max(4, abs(y - fixY)))
    }

    // MARK: Mouse

    override func mouseDown(with e: NSEvent) {
        window?.makeFirstResponder(self)
        guard let m = model else { return }
        let v = convert(e.locationInWindow, from: nil)
        let p = pixel(v)
        before = m.shot.edit
        if let c = m.crop {
            let cr = view(c)
            if let h = corner(at: v, of: cr) { drag = .resizeCrop(corner: h, from: c) } else if cr.contains(v) { drag = .moveCrop(start: p, from: c) } else { drag = .newCrop(start: p) }
            return
        }
        if let i = m.selected, m.shot.marks.indices.contains(i), let h = corner(at: v, of: view(m.shot.marks[i].rect)) {
            drag = .resize(mark: i, corner: h, from: m.shot.marks[i].rect)
            return
        }
        if let i = m.shot.marks.indices.reversed().first(where: { view(m.shot.marks[$0].rect).insetBy(dx: -3, dy: -3).contains(v) }) {
            change { $0.selected = i; $0.lastNote = i }
            drag = .move(mark: i, start: p, from: m.shot.marks[i].rect)
            panel?.canvasChanged(full: false)
            if e.clickCount == 2 { panel?.editNote(of: i) }
            return
        }
        change { $0.selected = nil }
        drag = .newMark(start: p)
        panel?.canvasChanged(full: false)
    }

    override func mouseDragged(with e: NSEvent) {
        guard let m = model, let d = drag else { return }
        let p = pixel(convert(e.locationInWindow, from: nil))
        let crop = m.shot.crop, full = m.shot.full
        switch d {
        case .newMark(let s):
            let a = CGPoint(x: min(max(s.x, CGFloat(crop.x)), CGFloat(crop.maxX)), y: min(max(s.y, CGFloat(crop.y)), CGFloat(crop.maxY)))
            let b = CGPoint(x: min(max(p.x, CGFloat(crop.x)), CGFloat(crop.maxX)), y: min(max(p.y, CGFloat(crop.y)), CGFloat(crop.maxY)))
            draft = rect(a, b)
        case .move(let i, let s, let from):
            change { $0.shot.marks[i].rect = from; $0.shot.move(mark: i, by: CGVector(dx: p.x - s.x, dy: p.y - s.y)) }
        case .resize(let i, let c, let from):
            change { $0.shot.marks[i].rect = Self.resize(from, corner: c, to: p, in: crop) }
        case .newCrop(let s):
            let r = rect(s, p)
            change { $0.crop = r.intersection(full) ?? $0.crop }
        case .moveCrop(let s, let from):
            var r = from
            r.x += Double(p.x - s.x); r.y += Double(p.y - s.y)
            change { $0.crop = r.clamped(to: full) }
        case .resizeCrop(let c, let from):
            change { $0.crop = Self.resize(from, corner: c, to: p, in: full) }
        }
        panel?.canvasChanged(full: false)
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = nil; draft = nil; before = nil }
        guard let m = model, let d = drag else { return }
        if case .newMark(let s) = d {
            var r = draft ?? SnapRect(x: Double(s.x), y: Double(s.y), w: 0, h: 0)
            if view(r).width < 6 || view(r).height < 6 {
                // A click makes a 64 × 36 pt box around the spot.
                let w = 64 * m.shot.scale, h = 36 * m.shot.scale
                r = SnapRect(x: Double(s.x) - w / 2, y: Double(s.y) - h / 2, w: w, h: h)
            }
            guard m.shot.crop.contains(CGPoint(x: s.x, y: s.y)) else { return panel?.canvasChanged(full: true) ?? () }
            var i = 0
            change { i = $0.addMark(r) }
            panel?.markAdded(i)
            return
        }
        if let b = before, case .move = d {
            change { $0.record(b) }
        } else if let b = before, case .resize = d {
            change { $0.record(b) }
        }
        panel?.canvasChanged(full: true)
    }

    // MARK: Keys

    override func keyDown(with e: NSEvent) {
        guard let m = model else { return }
        let shift = e.modifierFlags.contains(.shift)
        let step: CGFloat = shift ? 10 : 1
        switch e.keyCode {
        case 51, 117:
            if let i = m.selected, !m.isCropping { panel?.deleteMark(i) } else { NSSound.beep() }
        case 123, 124, 125, 126:
            let d: CGVector = [123: CGVector(dx: -step, dy: 0), 124: CGVector(dx: step, dy: 0),
                               125: CGVector(dx: 0, dy: step), 126: CGVector(dx: 0, dy: -step)][e.keyCode]!
            if m.isCropping {
                change { m in
                    guard var c = m.crop else { return }
                    c.x += Double(d.dx); c.y += Double(d.dy)
                    m.crop = c.clamped(to: m.shot.full)
                }
                panel?.canvasChanged(full: false)
            } else if let i = m.selected {
                change { $0.nudge(i, by: d) }
                panel?.canvasChanged(full: true)
            } else if !m.shot.marks.isEmpty {
                // Arrows with no selection walk through the marks.
                let n = m.shot.marks.count
                change { $0.selected = e.keyCode == 123 || e.keyCode == 126 ? n - 1 : 0 }
                panel?.canvasChanged(full: false)
            }
        case 36, 76:
            if m.isCropping { panel?.applyCrop() } else if let i = m.selected { panel?.editNote(of: i) }
        case 48:
            shift ? window?.selectPreviousKeyView(nil) : window?.selectNextKeyView(nil)
        default:
            switch e.charactersIgnoringModifiers?.lowercased() {
            case "c" where !m.isCropping: panel?.startCrop()
            case "v": panel?.toggleVoice()
            default: super.keyDown(with: e)
            }
        }
    }

    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    // MARK: Accessibility

    /// One child for each mark, so VoiceOver can read the marks and their notes.
    func updateAccessibility() {
        guard let m = model else { return }
        let n = m.shot.marks.count
        setAccessibilityLabel("Shot, \(Int(m.shot.crop.w)) by \(Int(m.shot.crop.h)) pixels, \(n) mark\(n == 1 ? "" : "s")")
        setAccessibilityHelp("Drag to mark an area. C crops. Delete removes the selected mark. Arrows move it.")
        setAccessibilityChildren(m.shot.marks.enumerated().map { i, mk in
            NSAccessibilityElement.element(withRole: .staticText, frame: window?.convertToScreen(convert(view(mk.rect), to: nil)) ?? .zero,
                                           label: "Mark \(i + 1), note: \(mk.note.isEmpty ? "none" : mk.note)", parent: self) as Any
        })
    }
}

private extension SnapRect {
    func contains(_ p: CGPoint) -> Bool { Double(p.x) >= x && Double(p.x) <= maxX && Double(p.y) >= y && Double(p.y) <= maxY }
}
