import Cocoa
import OverSireCore

// ─── Timeline graph ──────────────────────────────────────────────────────────
// The lane graph of the Timeline tab (OVERSIRE-384). One lane for each item, bars for agent time and waits,
// marks for the moments. Empty time folds into a cut. Hover or keyboard focus shows a tip; a click or Return pins it.

final class TimelineGraphView: NSView {
    /// A mark, a bar or a cut that has a tip.
    struct Target: Equatable {
        enum Kind: Hashable { case mark, bar, cut }
        var kind: Kind
        var id: String
        var rect: NSRect
        var title: String
        var detail: [String]
        var event: String?
    }

    /// For `--uishots`: the scale and the tip of a scene.
    struct Preset: Hashable {
        var real = false
        var hot: Target.Kind?
        init(scene: String) {
            real = scene == "real"
            hot = scene == "tip-mark" ? .mark : scene == "tip-bar" ? .bar : scene == "tip-cut" ? .cut : nil
        }
    }
    static var preset: Preset?

    static let labelWidth: CGFloat = 150
    static let axisHeight: CGFloat = 24
    static let laneHeight: CGFloat = 30
    static let barHeight: CGFloat = 10

    let model: TimelineModel
    let real: Bool
    let lastLook: Date?
    let now: Date
    let pinned: String?
    var onPin: (Target?) -> Void = { _ in }

    private var targets: [Target] = []
    private var scale: TimeScale?
    private var hot: Int? { didSet { if hot != oldValue { needsDisplay = true } } }
    private var tracking: NSTrackingArea?

    init(model: TimelineModel, real: Bool, lastLook: Date?, now: Date = Date(), pinned: String?) {
        self.model = model
        self.real = real
        self.lastLook = lastLook
        self.now = now
        self.pinned = pinned
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Self.axisHeight + CGFloat(model.lanes.count) * Self.laneHeight + 22).isActive = true
        setAccessibilityRole(.group)
        setAccessibilityLabel(real ? "Timeline graph, real time" : "Timeline graph, empty time cut")
        focusRingType = .exterior
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { !targets.isEmpty || !model.lanes.isEmpty }

    // MARK: Layout

    override func layout() {
        super.layout()
        let w = max(40, bounds.width - Self.labelWidth - 12)
        let s = real ? TimeScale.real(model, width: w) : TimeScale.cut(model, width: w)
        scale = s
        targets = buildTargets(s)
        if let p = Self.preset?.hot, hot == nil {
            hot = presetTarget(p)
        }
        needsDisplay = true
    }

    private func x(_ d: Date) -> CGFloat { Self.labelWidth + (scale?.x(d) ?? 0) }
    private func laneY(_ i: Int) -> CGFloat { Self.axisHeight + CGFloat(i) * Self.laneHeight + Self.laneHeight / 2 }

    private func buildTargets(_ s: TimeScale) -> [Target] {
        var out: [Target] = []
        let keys = model.lanes.map(\.key)
        func short(_ i: Int) -> String { keys.indices.contains(i) ? Self.short(keys[i]) : "" }
        for (i, b) in model.bars.enumerated() {
            let x0 = x(b.start), x1 = max(x(b.end), x0 + 3)
            let r = NSRect(x: x0, y: laneY(b.lane) - Self.barHeight / 2, width: x1 - x0, height: Self.barHeight)
            let word = b.kind == .wait ? "Waits for you" : b.kind == .fix ? "Agent fixes" : "Agent works"
            let span = "\(dayTime(b.start, now: now)) – " + (b.open ? "now" : Self.clock(b.end)) + " (\(spanText(b.end.timeIntervalSince(b.start))))"
            out.append(Target(kind: .bar, id: "b\(i)", rect: r, title: "\(word) · \(short(b.lane))", detail: [span, b.note], event: b.ids.first))
        }
        for (i, m) in model.marks.enumerated() {
            let c = NSPoint(x: x(m.at), y: laneY(m.lane))
            let e = m.event
            var detail = ["\(dayTime(m.at, now: now)) · \(Self.who(e))", e.summary]
            if e.isPrivate { detail[1] = "Private: " + e.summary }
            out.append(Target(kind: .mark, id: "m\(i):\(e.id)", rect: NSRect(x: c.x - 7, y: c.y - 8, width: 14, height: 16),
                              title: "\(m.kind.rawValue) \(m.kind.word) · \(short(m.lane))", detail: detail, event: e.id))
        }
        for (i, (seg, r)) in s.frames().enumerated() where seg.isCut {
            let rect = NSRect(x: Self.labelWidth + r.lowerBound, y: Self.axisHeight - 2, width: r.upperBound - r.lowerBound,
                              height: CGFloat(model.lanes.count) * Self.laneHeight + 2)
            out.append(Target(kind: .cut, id: "c\(i)", rect: rect, title: "\(spanText(seg.length)) with no work, folded",
                              detail: ["\(dayTime(seg.start, now: now)) – \(dayTime(seg.end, now: now))", "Turn on Real time to see it at full length."]))
        }
        // Keyboard order: left to right, top to bottom. Marks win over the bar under them on hover.
        return out.sorted { ($0.rect.minX, $0.rect.minY) < ($1.rect.minX, $1.rect.minY) }
    }

    private func presetTarget(_ k: Target.Kind) -> Int? {
        switch k {
        case .mark: return targets.firstIndex { $0.kind == .mark && $0.title.hasPrefix("✕") } ?? targets.firstIndex { $0.kind == .mark }
        case .bar: return targets.firstIndex { $0.kind == .bar && $0.title.hasPrefix("Agent fixes") } ?? targets.firstIndex { $0.kind == .bar }
        case .cut: return targets.indices.filter { targets[$0].kind == .cut }.max { targets[$0].title.count < targets[$1].title.count }
        }
    }

    static func short(_ k: String) -> String { k.split(separator: "-").last.map(String.init) ?? k }
    static func clock(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }

    static func who(_ e: Event) -> String {
        switch e.actorType {
        case .human: return e.actor == MY_EMAIL ? "you" : e.actor
        case .agent: return "agent " + e.actor
        case .system: return e.actor
        case .provider: return e.provider ?? e.actor
        }
    }

    // MARK: Draw

    static func color(_ k: TimelineModel.Mark.Kind) -> NSColor {
        switch k {
        case .steer: return Palette.acc
        case .decide: return Palette.warn
        case .handoff: return Palette.run
        case .ciPass, .merged: return Palette.ok
        case .ciFail: return Palette.bad
        case .released: return Palette.intake
        case .created: return Palette.dim
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let s = scale else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let bottom = Self.axisHeight + CGFloat(model.lanes.count) * Self.laneHeight
            drawLanes(bottom)
            drawCuts(s, bottom)
            drawAxis(s)
            for m in model.releases { dashed(x(m.at), from: Self.axisHeight, to: bottom, color: Palette.intake, label: nil) }
            if let l = lastLook, l > model.start, l < now { dashed(x(l), from: Self.axisHeight, to: bottom + 4, color: Palette.acc, label: "you looked") }
            line(x(now), from: Self.axisHeight, to: bottom + 4, color: Palette.fg, label: "now")
            drawBars()
            drawMarks()
            if let p = pinned, let t = targets.first(where: { $0.id == p }) { ring(t.rect) }
            if let h = hot, targets.indices.contains(h) { tip(targets[h]) }
        }
    }

    private func drawLanes(_ bottom: CGFloat) {
        for (i, l) in model.lanes.enumerated() {
            let y = laneY(i)
            if i % 2 == 1 {
                Palette.panel.setFill()
                NSRect(x: 0, y: y - Self.laneHeight / 2, width: bounds.width, height: Self.laneHeight).fill()
            }
            let key = NSAttributedString(string: Self.short(l.key), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold),
                                                                                 .foregroundColor: l.dim ? Palette.dim : Palette.fg])
            key.draw(at: NSPoint(x: 4, y: y - 7))
            let title = NSAttributedString(string: l.title, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.dim,
                                                                         .paragraphStyle: Self.truncating])
            title.draw(in: NSRect(x: 40, y: y - 7, width: Self.labelWidth - 46, height: 15))
            Palette.line.setStroke()
            let p = NSBezierPath()
            p.move(to: NSPoint(x: Self.labelWidth, y: y))
            p.line(to: NSPoint(x: bounds.width - 8, y: y))
            p.lineWidth = 0.5
            p.stroke()
        }
        _ = bottom
    }

    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    private func drawCuts(_ s: TimeScale, _ bottom: CGFloat) {
        for (seg, r) in s.frames() where seg.isCut {
            let x0 = Self.labelWidth + r.lowerBound, x1 = Self.labelWidth + r.upperBound
            let band = NSRect(x: x0 + 4, y: Self.axisHeight, width: x1 - x0 - 8, height: bottom - Self.axisHeight)
            Palette.bg.setFill()
            band.fill()
            Palette.dim.setStroke()
            for edge in [band.minX, band.maxX] {
                let z = NSBezierPath()
                var y = band.minY, left = true
                z.move(to: NSPoint(x: edge, y: y))
                while y < band.maxY {
                    y = min(band.maxY, y + 5)
                    left.toggle()
                    z.line(to: NSPoint(x: edge + (left ? -2.5 : 2.5), y: y))
                }
                z.lineWidth = 1
                z.stroke()
            }
            let label = NSAttributedString(string: spanText(seg.length), attributes: [.font: NSFont.monospacedSystemFont(ofSize: 10, weight: .medium),
                                                                                       .foregroundColor: Palette.dim])
            let sz = label.size()
            label.draw(at: NSPoint(x: (x0 + x1 - sz.width) / 2, y: Self.axisHeight + 2))
        }
    }

    private func drawAxis(_ s: TimeScale) {
        var lastEnd: CGFloat = -1
        let font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        func label(_ text: String, at px: CGFloat) {
            let a = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: Palette.dim])
            let w = a.size().width
            guard px > lastEnd + 6, px + w < bounds.width else { return }
            a.draw(at: NSPoint(x: px, y: 4))
            lastEnd = px + w
        }
        if real {
            // A tick at each midnight.
            let c = Calendar.current
            var d = c.startOfDay(for: s.segments[0].start)
            while d < s.segments[0].end {
                if d >= s.segments[0].start {
                    tick(x(d))
                    label(Self.weekday(d), at: x(d) + 2)
                }
                d = c.date(byAdding: .day, value: 1, to: d)!
            }
        } else {
            for (seg, r) in s.frames() where !seg.isCut {
                let px = Self.labelWidth + r.lowerBound
                tick(px)
                label(dayTime(seg.start.addingTimeInterval(TimeScale.pad), now: now), at: px + 2)
            }
        }
    }

    private static func weekday(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE d"
        return f.string(from: d)
    }

    private func tick(_ px: CGFloat) {
        Palette.line.setStroke()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: px, y: Self.axisHeight - 6))
        p.line(to: NSPoint(x: px, y: Self.axisHeight + CGFloat(model.lanes.count) * Self.laneHeight))
        p.lineWidth = 0.5
        p.stroke()
    }

    private func dashed(_ px: CGFloat, from y0: CGFloat, to y1: CGFloat, color: NSColor, label: String?) {
        color.setStroke()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: px, y: y0))
        p.line(to: NSPoint(x: px, y: y1))
        p.setLineDash([3, 3], count: 2, phase: 0)
        p.lineWidth = 1
        p.stroke()
        if let label { flag(label, px, color) }
    }

    private func line(_ px: CGFloat, from y0: CGFloat, to y1: CGFloat, color: NSColor, label: String) {
        color.withAlphaComponent(0.7).setStroke()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: px, y: y0))
        p.line(to: NSPoint(x: px, y: y1))
        p.lineWidth = 1.5
        p.stroke()
        flag(label, px, color)
    }

    private func flag(_ text: String, _ px: CGFloat, _ color: NSColor) {
        let a = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: color])
        let w = a.size().width
        // Under the lanes, clear of the axis labels.
        a.draw(at: NSPoint(x: min(max(Self.labelWidth, px - w / 2), bounds.width - w - 2), y: Self.axisHeight + CGFloat(model.lanes.count) * Self.laneHeight + 4))
    }

    private func drawBars() {
        for t in targets where t.kind == .bar {
            guard let i = Int(t.id.dropFirst()), model.bars.indices.contains(i) else { continue }
            let b = model.bars[i]
            let dim = model.lanes[b.lane].dim
            let path = NSBezierPath(roundedRect: t.rect, xRadius: 3, yRadius: 3)
            switch b.kind {
            case .work:
                Palette.acc.withAlphaComponent(dim ? 0.4 : 1).setFill()
                path.fill()
            case .fix:
                Palette.run.withAlphaComponent(dim ? 0.2 : 0.45).setFill()
                path.fill()
                Palette.run.setStroke()
                path.lineWidth = 1
                path.stroke()
            case .wait:
                Palette.warn.withAlphaComponent(0.15).setFill()
                path.fill()
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                Palette.warn.withAlphaComponent(dim ? 0.4 : 0.85).setStroke()
                var x0 = t.rect.minX - t.rect.height
                while x0 < t.rect.maxX {
                    let h = NSBezierPath()
                    h.move(to: NSPoint(x: x0, y: t.rect.maxY))
                    h.line(to: NSPoint(x: x0 + t.rect.height, y: t.rect.minY))
                    h.lineWidth = 1
                    h.stroke()
                    x0 += 5
                }
                NSGraphicsContext.restoreGraphicsState()
            }
            if b.open {
                // An open bar fades to its end: still going.
                Palette.fg.setFill()
                NSBezierPath(ovalIn: NSRect(x: t.rect.maxX - 3, y: t.rect.midY - 3, width: 6, height: 6)).fill()
            }
        }
    }

    private func drawMarks() {
        for t in targets where t.kind == .mark {
            guard let i = Int(t.id.dropFirst().prefix { $0 != ":" }), model.marks.indices.contains(i) else { continue }
            let m = model.marks[i]
            let dim = model.lanes[m.lane].dim
            Palette.bg.setFill()
            NSBezierPath(ovalIn: t.rect.insetBy(dx: 0, dy: 1)).fill()
            let a = NSAttributedString(string: m.kind.rawValue, attributes: [.font: NSFont.systemFont(ofSize: 12, weight: .bold),
                                                                              .foregroundColor: Self.color(m.kind).withAlphaComponent(dim ? 0.5 : 1)])
            let sz = a.size()
            a.draw(at: NSPoint(x: t.rect.midX - sz.width / 2, y: t.rect.midY - sz.height / 2))
        }
    }

    private func ring(_ r: NSRect) {
        Palette.fg.setStroke()
        let p = NSBezierPath(roundedRect: r.insetBy(dx: -3, dy: -3), xRadius: 4, yRadius: 4)
        p.lineWidth = 1.5
        p.stroke()
    }

    private func tip(_ t: Target) {
        ring(t.rect)
        let text = NSMutableAttributedString(string: t.title, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold), .foregroundColor: Palette.fg])
        for d in t.detail where !d.isEmpty {
            text.append(NSAttributedString(string: "\n" + d, attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: Palette.mut]))
        }
        let maxW: CGFloat = 280
        let size = text.boundingRect(with: NSSize(width: maxW, height: 200), options: [.usesLineFragmentOrigin]).size
        let w = ceil(size.width) + 16, h = ceil(size.height) + 12
        let anchor = t.kind == .cut ? NSPoint(x: t.rect.midX, y: Self.axisHeight + 14) : NSPoint(x: t.rect.midX, y: t.rect.maxY)
        var x0 = anchor.x - w / 2
        x0 = min(max(4, x0), bounds.width - w - 4)
        var y0 = anchor.y + 6
        if y0 + h > bounds.height - 2 { y0 = max(2, (t.kind == .cut ? anchor.y : t.rect.minY) - h - 6) }
        let r = NSRect(x: x0, y: y0, width: w, height: h)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 6
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.set()
        Palette.raise.setFill()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).fill()
        NSGraphicsContext.restoreGraphicsState()
        Palette.line.setStroke()
        NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6).stroke()
        text.draw(with: r.insetBy(dx: 8, dy: 6), options: [.usesLineFragmentOrigin])
    }

    // MARK: Mouse and keys

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    /// The target under the point: a mark, then a bar, then a cut.
    private func hit(_ p: NSPoint) -> Int? {
        for k in [Target.Kind.mark, .bar, .cut] {
            if let i = targets.firstIndex(where: { $0.kind == k && $0.rect.insetBy(dx: -2, dy: k == .bar ? -4 : -2).contains(p) }) { return i }
        }
        return nil
    }

    // A preset tip stays: the real mouse can pass over the `--uishots` window.
    override func mouseMoved(with event: NSEvent) { if Self.preset?.hot == nil { hot = hit(convert(event.locationInWindow, from: nil)) } }
    override func mouseExited(with event: NSEvent) { if window?.firstResponder !== self, Self.preset?.hot == nil { hot = nil } }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let h = hit(convert(event.locationInWindow, from: nil))
        hot = h
        onPin(h.map { targets[$0] })
    }

    override func becomeFirstResponder() -> Bool {
        if hot == nil, !targets.isEmpty { hot = 0 }
        return true
    }

    override func resignFirstResponder() -> Bool {
        if Self.preset?.hot == nil { hot = nil }
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: hot = max(0, (hot ?? 1) - 1)                                   // left
        case 124: hot = min(targets.count - 1, (hot ?? -1) + 1)                  // right
        case 36, 49: if let h = hot { onPin(targets[h]) }                        // Return, space
        case 53: hot = nil; onPin(nil)                                           // Escape
        default: super.keyDown(with: event)
        }
    }

    override func drawFocusRingMask() { NSBezierPath(rect: bounds).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        guard let w = window else { return nil }
        return targets.map { t in
            let r = w.convertToScreen(convert(t.rect, to: nil))
            return NSAccessibilityElement.element(withRole: .staticText, frame: r, label: ([t.title] + t.detail).joined(separator: ". "), parent: self)
        }
    }
}

// The legend under the graph: shape and word for each color.
enum TimelineLegend {
    static func view() -> NSView {
        let items: [(String, NSColor, String)] = [
            ("▬", Palette.acc, "agent works"), ("▬", Palette.run, "agent fixes"), ("▨", Palette.warn, "waits for you"),
            ("▲", Palette.acc, "you steer"), ("◆", Palette.warn, "you decide"), ("▶", Palette.run, "hand-off"),
            ("✓", Palette.ok, "CI passed"), ("✕", Palette.bad, "CI failed"), ("◉", Palette.ok, "merged"), ("★", Palette.intake, "released"),
            ("○", Palette.dim, "created"),
        ]
        let parts: [NSView] = items.map { g, c, w in
            NSStackView(h: [NSTextField.text(g, size: 11, weight: .bold, color: c), NSTextField.text(w, size: 11, color: Palette.dim)], spacing: 3)
        }
        return Wrap(parts)
    }
}
