import Cocoa
import OverSireCore

// ─── Plan › Timeline ─────────────────────────────────────────────────────────
// A Gantt chart of the open epics and their open items (OVERSIRE-482). The header and the label column stay in view
// when the chart scrolls. Each state has a glyph or a line style, so color is never the only signal.

enum GanttColor {
    private static func pair(_ dark: UInt32, _ light: UInt32) -> NSColor {
        NSColor(name: nil) { a in
            let v = Palette.isDark(a) ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        }
    }

    static let readyFill = pair(0x3A3D46, 0xE4E6EB)
    static let readyLine = pair(0x5A5E68, 0xA9ADB5)
    static let workFill = pair(0x2F6E93, 0xD2E7F5)
    static let inputFill = pair(0x3D3220, 0xFBEBCB)
    static let inputText = pair(0xF5D08A, 0x6B4700)
    static let epicRow = pair(0x17181C, 0xF6F7F9)
    static let rowLine = pair(0x222429, 0xECEDF0)
    static let weekendText = pair(0x6F737C, 0x9A9EA6)

    /// The fill, the line, the text color and a dashed line for an item bar.
    static func bar(_ s: PlanState) -> (fill: NSColor?, line: NSColor, text: NSColor, dashed: Bool) {
        switch s {
        case .working: return (workFill, Palette.run, Palette.fg, false)
        case .input: return (inputFill, Palette.warn, inputText, false)
        case .nospec: return (nil, Palette.dim, Palette.mut, true)
        default: return (readyFill, readyLine, Palette.fg, false)
        }
    }
}

/// Where the chart was: the scroll origin, under one zoom and one focus. The toolbar state keeps it, so a new build does not jump.
struct PlanGanttPlace: Equatable {
    var zoom: PlanGanttModel.Zoom
    var focus: PlanFocus?
    var origin: NSPoint
}

/// The chart. It is the document view of a scroll view and draws the sticky parts at the edges of the visible rect.
final class PlanGanttView: NSView {
    var model: PlanGanttModel {
        didSet {
            frame.size = fitSize
            needsDisplay = true
        }
    }
    private let plan: PlanModel
    var showCritical: Bool
    var selected: String? { didSet { if selected != oldValue { needsDisplay = true } } }
    var onSelect: (String?) -> Void = { _ in }
    var onFold: (EpicID) -> Void = { _ in }
    /// A row index to show a tip for, or nil. The bar rect is in the coordinates of this view.
    var onTip: (Int?) -> Void = { _ in }

    private var cursor: Int? { didSet { if cursor != oldValue { needsDisplay = true } } }
    private var hot: Int?
    private var tracking: NSTrackingArea?

    init(model: PlanGanttModel, plan: PlanModel, showCritical: Bool, selected: String?) {
        self.model = model
        self.plan = plan
        self.showCritical = showCritical
        self.selected = selected
        super.init(frame: NSRect(origin: .zero, size: model.size))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Timeline. Up and down move between the rows. Return selects an item or folds an epic.")
        focusRingType = .none
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// At least the visible size, so the shading reaches the edges.
    var fitSize: NSSize {
        let clip = enclosingScrollView?.contentView.bounds.size ?? .zero
        return NSSize(width: max(model.size.width, clip.width), height: max(model.size.height, clip.height))
    }

    private typealias M = PlanGanttModel

    // MARK: Scroll

    func scrollToToday() {
        guard let clip = enclosingScrollView?.contentView else { return }
        scroll(to: NSPoint(x: model.todayX - 420, y: clip.bounds.minY))
    }

    /// Selects the item and shows its bar.
    func focus(key: String) {
        guard let r = model.row(key: key) else { return }
        selected = r.key
        show(r)
    }

    func focus(epic: EpicID) {
        guard let r = model.rows.first(where: { $0.epic?.id == epic }) else { return }
        show(r)
    }

    private func show(_ r: PlanGanttModel.Row) {
        guard let clip = enclosingScrollView?.contentView, let bar = r.bar else { return }
        let v = clip.bounds
        var o = v.origin
        if bar.lowerBound < v.minX + M.label + 20 || bar.lowerBound > v.maxX - 60 { o.x = bar.lowerBound - M.label - 120 }
        if r.y < v.minY + M.head || r.y + r.height > v.maxY { o.y = r.y - M.head - 3 * M.itemRow }
        scroll(to: o)
    }

    func scroll(to p: NSPoint) {
        guard let s = enclosingScrollView else { return }
        let clip = s.contentView
        let maxX = max(0, frame.width - clip.bounds.width), maxY = max(0, frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: min(max(0, p.x), maxX), y: min(max(0, p.y), maxY)))
        s.reflectScrolledClipView(clip)
        needsDisplay = true
    }

    // MARK: Draw

    private var visible: NSRect { visibleRect.isEmpty ? bounds : visibleRect }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            drawBody()
            drawArrows()
            drawBars()
            drawLabels()
            drawHeader()
        }
    }

    private func fill(_ r: NSRect, _ c: NSColor) {
        c.setFill()
        r.fill()
    }

    private func vline(_ x: CGFloat, _ y0: CGFloat, _ y1: CGFloat, _ c: NSColor, width: CGFloat = 1) {
        c.setStroke()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: x, y: y0))
        p.line(to: NSPoint(x: x, y: y1))
        p.lineWidth = width
        p.stroke()
    }

    private func drawBody() {
        let h = bounds.height
        fill(bounds, Palette.bg)
        for r in model.rows where r.epic != nil { fill(NSRect(x: 0, y: r.y, width: bounds.width, height: r.height), GanttColor.epicRow) }
        for w in model.weekends { fill(NSRect(x: w.lowerBound, y: M.head, width: w.upperBound - w.lowerBound, height: h - M.head), Palette.fg.withAlphaComponent(0.03)) }
        for m in model.mondays { vline(m + 0.5, M.head, h, Palette.line) }
        for r in model.rows { fill(NSRect(x: 0, y: r.y + r.height - 1, width: bounds.width, height: 1), GanttColor.rowLine) }
        if cursor != nil, window?.firstResponder === self, let r = model.rows[safe: cursor!] {
            fill(NSRect(x: 0, y: r.y, width: bounds.width, height: r.height - 1), Palette.acc.withAlphaComponent(0.08))
        }
        fill(NSRect(x: model.todayX, y: M.head, width: 2, height: h - M.head), Palette.acc.withAlphaComponent(0.7))
    }

    private func drawArrows() {
        for a in model.arrows where a.points.count > 1 {
            let crit = a.critical && showCritical
            let color = crit ? PlanColor.critical : Palette.dim.withAlphaComponent(0.8)
            color.setStroke()
            let p = NSBezierPath()
            p.move(to: a.points[0])
            for q in a.points.dropFirst() { p.line(to: q) }
            p.lineWidth = crit ? 2 : 1.25
            p.lineJoinStyle = .round
            p.stroke()
            let end = a.points[a.points.count - 1], prev = a.points[a.points.count - 2]
            let dx = end.x - prev.x, dy = end.y - prev.y, len = max(1, hypot(dx, dy))
            let ux = dx / len, uy = dy / len, s: CGFloat = 5
            let head = NSBezierPath()
            head.move(to: end)
            head.line(to: NSPoint(x: end.x - ux * s - uy * s * 0.8, y: end.y - uy * s + ux * s * 0.8))
            head.line(to: NSPoint(x: end.x - ux * s + uy * s * 0.8, y: end.y - uy * s - ux * s * 0.8))
            head.close()
            color.setFill()
            head.fill()
        }
    }

    private func text(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor, mono: Bool = false) -> NSAttributedString {
        let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight) : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: Self.truncating])
    }

    private static let truncating: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    private func drawBars() {
        for (i, r) in model.rows.enumerated() {
            guard let rect = r.barRect else { continue }
            switch r.kind {
            case .epic(let e): drawEpic(e, rect, row: r)
            case .item(let it): drawItem(it, rect, hot: hot == i)
            }
        }
    }

    private func drawEpic(_ e: PlanGanttModel.Epic, _ rect: NSRect, row: PlanGanttModel.Row) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5)
        if e.planned {
            EpicColor.accent.setStroke()
            let p = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4.5, yRadius: 4.5)
            p.setLineDash([4, 2.5], count: 2, phase: 0)
            p.lineWidth = 1
            p.stroke()
        } else {
            EpicColor.accent.withAlphaComponent(0.32).setFill()
            path.fill()
        }
        if e.doneFraction > 0 {
            NSGraphicsContext.saveGraphicsState()
            path.addClip()
            fill(NSRect(x: rect.minX, y: rect.minY, width: round(rect.width * e.doneFraction), height: rect.height), EpicColor.accent)
            NSGraphicsContext.restoreGraphicsState()
        }
        let lateColor = e.late != nil ? Palette.bad : Palette.mut
        if let d = e.dueX {
            let c = NSPoint(x: d - 0.5, y: rect.midY)
            let diamond = NSBezierPath()
            diamond.move(to: NSPoint(x: c.x, y: c.y - 6))
            diamond.line(to: NSPoint(x: c.x + 6, y: c.y))
            diamond.line(to: NSPoint(x: c.x, y: c.y + 6))
            diamond.line(to: NSPoint(x: c.x - 6, y: c.y))
            diamond.close()
            lateColor.setFill()
            diamond.fill()
        }
        guard !e.text.isEmpty else { return }
        let t = text(e.text, size: 11, color: e.late != nil ? Palette.bad : Palette.dim)
        // Next to the bar, or after the diamond when the diamond is in the way.
        var x0 = rect.maxX + 8
        if let d = e.dueX, d + 7 > x0 - 4, d - 7 < x0 + t.size().width { x0 = max(x0, d + 10) }
        t.draw(at: NSPoint(x: x0, y: row.y + 9))
    }

    private func drawItem(_ it: PlanGanttModel.Item, _ rect: NSRect, hot: Bool) {
        let style = GanttColor.bar(it.state)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        if it.critical && showCritical {
            PlanColor.critical.setStroke()
            let ring = NSBezierPath(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), xRadius: 5.5, yRadius: 5.5)
            ring.lineWidth = 2
            ring.stroke()
        }
        if let f = style.fill {
            f.setFill()
            path.fill()
        }
        (hot ? Palette.fg : style.line).setStroke()
        if style.dashed { path.setLineDash([3, 2], count: 2, phase: 0) }
        path.lineWidth = 1
        path.stroke()
        if selected == it.key {
            Palette.acc.setStroke()
            let o = NSBezierPath(roundedRect: rect.insetBy(dx: -4, dy: -4), xRadius: 6, yRadius: 6)
            o.lineWidth = 2
            o.stroke()
        }
        // The title, else the number, else only the state glyph.
        let room = rect.width - 9
        let short = it.state.glyph + " " + plan.short(it.key)
        let label = rect.width > 70 ? it.state.glyph + " " + plan.title(it.key)
            : text(short, size: 10.5, color: style.text).size().width <= room ? short : it.state.glyph
        text(label, size: 10.5, color: style.text).draw(in: NSRect(x: rect.minX + 5, y: rect.minY + 2, width: room + 2, height: rect.height - 3))
    }

    private func drawLabels() {
        let v = visible, x0 = v.minX, h = bounds.height
        fill(NSRect(x: x0, y: M.head, width: M.label, height: h - M.head), Palette.bg)
        for (i, r) in model.rows.enumerated() {
            guard r.y + r.height >= v.minY, r.y <= v.maxY else { continue }
            let box = NSRect(x: x0, y: r.y, width: M.label, height: r.height - 1)
            switch r.kind {
            case .epic(let e):
                fill(box, GanttColor.epicRow)
                text(e.folded ? "▸" : "▾", size: 11, color: Palette.mut).draw(at: NSPoint(x: x0 + 11, y: r.y + 9))
                let sub = text(e.sub, size: 11, color: e.late != nil ? Palette.bad : Palette.dim)
                let sw = ceil(sub.size().width)
                let name = text(r.label, size: 13, weight: .bold, color: Palette.fg)
                let nw = min(ceil(name.size().width), M.label - 32 - 10 - sw - 6)
                name.draw(in: NSRect(x: x0 + 32, y: r.y + 8, width: nw, height: 18))
                sub.draw(at: NSPoint(x: x0 + 32 + nw + 6, y: r.y + 10))
            case .item(let it):
                let key = text(plan.short(it.key), size: 10.5, color: Palette.dim, mono: true)
                key.draw(at: NSPoint(x: x0 + 32, y: r.y + 8))
                let kw = ceil(key.size().width) + 6
                text(r.label, size: 12, color: Palette.fg).draw(in: NSRect(x: x0 + 32 + kw, y: r.y + 7, width: M.label - 42 - kw, height: 17))
            }
            if cursor == i, window?.firstResponder === self {
                Palette.acc.setStroke()
                let p = NSBezierPath(roundedRect: box.insetBy(dx: 3, dy: 3), xRadius: 4, yRadius: 4)
                p.lineWidth = 2
                p.stroke()
            }
        }
        fill(NSRect(x: x0 + M.label - 1, y: M.head, width: 1, height: h - M.head), Palette.line)
    }

    private func drawHeader() {
        let v = visible, y0 = v.minY
        fill(NSRect(x: v.minX, y: y0, width: v.width, height: M.head), Palette.side)
        fill(NSRect(x: v.minX, y: y0 + M.head - 1, width: v.width, height: 1), Palette.line)
        let dw = model.zoom.dayW
        let tag = text("Today", size: 10, weight: .bold, color: Palette.bg)
        let tagSize = tag.size()
        let tagY = model.zoom == .days ? y0 + 4 : y0 + 24
        let tagRect = NSRect(x: model.todayX + 5, y: tagY, width: ceil(tagSize.width) + 10, height: ceil(tagSize.height) + 2)
        for w in model.weeks {
            let a = text(w.text, size: 11, weight: .semibold, color: Palette.mut)
            let r = NSRect(x: w.x + 4, y: y0 + 5, width: ceil(a.size().width), height: 15)
            if model.zoom == .days, r.intersects(tagRect.insetBy(dx: -4, dy: 0)) { continue }
            a.draw(at: r.origin)
        }
        for d in model.dayNumbers {
            let color = d.today ? Palette.acc : d.weekend ? GanttColor.weekendText : Palette.dim
            let a = text(d.text, size: 10, weight: d.today ? .bold : .regular, color: color)
            let w = a.size().width
            a.draw(at: NSPoint(x: d.x + (dw - w) / 2, y: y0 + 25))
        }
        Palette.acc.setFill()
        NSBezierPath(roundedRect: tagRect, xRadius: 3, yRadius: 3).fill()
        tag.draw(at: NSPoint(x: tagRect.minX + 5, y: tagRect.minY + 1))
        // The corner stays at the top left.
        fill(NSRect(x: v.minX, y: y0, width: M.label, height: M.head - 1), Palette.side)
        fill(NSRect(x: v.minX + M.label - 1, y: y0, width: 1, height: M.head), Palette.line)
        let cap = NSAttributedString(string: "EPIC · ITEM", attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Palette.dim, .kern: 0.5])
        cap.draw(at: NSPoint(x: v.minX + 14, y: y0 + 15))
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
    }

    private enum Hit { case label(Int), bar(Int) }

    private func hit(_ p: NSPoint) -> Hit? {
        let v = visible
        guard p.y >= v.minY + M.head else { return nil }
        if p.x < v.minX + M.label {
            return model.rows.firstIndex { p.y >= $0.y && p.y < $0.y + $0.height }.map(Hit.label)
        }
        return model.rows.firstIndex { $0.barRect?.insetBy(dx: -2, dy: -4).contains(p) == true }.map(Hit.bar)
    }

    override func mouseMoved(with event: NSEvent) {
        var bar: Int?
        if case .bar(let i)? = hit(convert(event.locationInWindow, from: nil)) { bar = i }
        guard bar != hot else { return }
        hot = bar
        needsDisplay = true
        onTip(bar)
    }

    override func mouseExited(with event: NSEvent) {
        guard hot != nil else { return }
        hot = nil
        needsDisplay = true
        onTip(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        switch hit(convert(event.locationInWindow, from: nil)) {
        case .label(let i)?, .bar(let i)?:
            cursor = i
            activate(i, fromBar: { if case .bar = hit(convert(event.locationInWindow, from: nil)) { return true }; return false }())
        case nil: break
        }
    }

    override func resetCursorRects() {
        let v = visible, body = NSRect(x: v.minX + M.label, y: v.minY + M.head, width: v.width - M.label, height: v.height - M.head)
        let column = NSRect(x: v.minX, y: v.minY + M.head, width: M.label, height: v.height - M.head)
        for r in model.rows {
            var rects = [NSRect(x: v.minX, y: r.y, width: M.label, height: r.height).intersection(column)]
            if let b = r.barRect, r.key != nil { rects.append(b.intersection(body)) }
            for c in rects where !c.isNull && !c.isEmpty { addCursorRect(c, cursor: .pointingHand) }
        }
    }

    /// An item row selects. An epic label folds; an epic bar does nothing.
    private func activate(_ i: Int, fromBar: Bool = false) {
        guard let r = model.rows[safe: i] else { return }
        switch r.kind {
        case .item(let it):
            selected = it.key
            onSelect(it.key)
        case .epic(let e):
            if !fromBar { onFold(e.id) }
        }
    }

    // MARK: Keys

    override func becomeFirstResponder() -> Bool {
        if cursor == nil { cursor = model.rows.firstIndex { $0.key != nil && $0.key == selected } ?? (model.rows.isEmpty ? nil : 0) }
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        onTip(nil)
        return true
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: move(1)                                          // down
        case 126: move(-1)                                         // up
        case 36, 76, 49: if let c = cursor { activate(c) }         // Return, Enter, space
        case 53: onTip(nil)                                        // Escape
        default: super.keyDown(with: event)
        }
    }

    private func move(_ d: Int) {
        guard !model.rows.isEmpty else { return }
        let c = min(max(0, (cursor ?? (d > 0 ? -1 : model.rows.count)) + d), model.rows.count - 1)
        cursor = c
        let r = model.rows[c]
        if let clip = enclosingScrollView?.contentView {
            let v = clip.bounds
            if r.y < v.minY + M.head { scroll(to: NSPoint(x: v.minX, y: r.y - M.head)) }
            else if r.y + r.height > v.maxY { scroll(to: NSPoint(x: v.minX, y: r.y + r.height - v.height)) }
        }
        onTip(r.barRect == nil ? nil : c)
    }

    // MARK: Accessibility

    /// "OVERSIRE-426 Keyboard review, ready, Nov 18 to Nov 20, critical".
    func spoken(_ r: PlanGanttModel.Row) -> String {
        switch r.kind {
        case .item(let it):
            let n = plan.graph.nodes[it.key]
            let state = n.map { plan.state($0.key).text.drop { !$0.isLetter } } ?? ""
            var s = "\(it.key) \(r.label), \(state), \(plan.date(it.start)) to \(plan.date(it.end - 1))"
            if it.critical && showCritical { s += ", critical" }
            if selected == it.key { s += ", selected" }
            return s
        case .epic(let e):
            var s = "Epic \(r.label), \(e.done) of \(e.total) done"
            if let t = plan.epic(e.id)?.targetDate { s += ", due \(EpicBoard.day(t))" }
            if !e.text.isEmpty { s += ", forecast " + e.text.replacingOccurrences(of: "▲ ", with: "") }
            return s + (e.planned ? ", planned" : "") + (e.folded ? ", folded" : "")
        }
    }

    override func accessibilityChildren() -> [Any]? {
        guard let w = window else { return nil }
        let v = visible
        return model.rows.enumerated().compactMap { i, r -> Any? in
            let rect = NSRect(x: v.minX, y: r.y, width: v.width, height: r.height)
            guard rect.intersects(v) else { return nil }
            let el = PressElement { [weak self] in self?.activate(i) }
            el.setAccessibilityRole(.button)
            el.setAccessibilityLabel(spoken(r))
            el.setAccessibilityFrame(w.convertToScreen(convert(rect, to: nil)))
            el.setAccessibilityParent(self)
            return el
        }
    }
}

private final class PressElement: NSAccessibilityElement {
    private let press: () -> Void
    init(_ press: @escaping () -> Void) {
        self.press = press
        super.init()
    }
    override func accessibilityPerformPress() -> Bool { press(); return true }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// The Timeline segment: the chart in a framed scroll view, the legend and the selected item.
final class PlanGanttSegment: NSStackView {
    private let plan: PlanModel
    private let controls: PlanControls
    private weak var host: PlanHost?
    private let scroll = NSScrollView()
    private let frameBox = Box(fill: Palette.bg, border: Palette.line, radius: 10)
    private var chart: PlanGanttView!
    private lazy var tips = PlanTipPresenter(container: frameBox)
    private let epics: [Epic]
    private let forecasts: [EpicID: EpicForecast]
    private let range: (firstDay: PlanDay, days: Int)
    private let panel = PlanItemPanel()
    private var placed = false
    private var clipWatch: NSObjectProtocol?

    init(_ plan: PlanModel, controls: PlanControls, host: PlanHost) {
        self.plan = plan
        self.controls = controls
        self.host = host
        let shown = Set(PlanMap.lanes(plan.graph, schedule: plan.schedule, epics: plan.graph.epics, mode: controls.mode).map(\.epic))
        epics = plan.graph.epics.filter { shown.contains($0.id) }
        forecasts = Dictionary(plan.graph.epics.map { ($0.id, plan.schedule.forecast($0, in: plan.graph, today: plan.today)) }, uniquingKeysWith: { a, _ in a })
        range = PlanGanttModel.range(schedule: plan.schedule, epics: epics, forecasts: forecasts, today: plan.today, calendar: .current)
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 10
        translatesAutoresizingMaskIntoConstraints = false
        setHuggingPriority(.init(1), for: .vertical)

        if controls.focus?.segment == .timeline, let k = controls.focus?.key { PlanSelection.keys[plan.ident] = k.uppercased() }
        let selected = PlanSelection.keys[plan.ident]
        chart = PlanGanttView(model: build(days: range.days), plan: plan, showCritical: controls.critical, selected: selected)
        chart.onSelect = { [weak self] k in self?.select(k) }
        chart.onFold = { [weak self] id in self?.fold(id) }
        chart.onTip = { [weak self] i in self?.tip(i) }

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = chart
        scroll.contentView.postsBoundsChangedNotifications = true
        frameBox.layer?.masksToBounds = true
        frameBox.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: frameBox.leadingAnchor, constant: 1),
            scroll.trailingAnchor.constraint(equalTo: frameBox.trailingAnchor, constant: -1),
            scroll.topAnchor.constraint(equalTo: frameBox.topAnchor, constant: 1),
            scroll.bottomAnchor.constraint(equalTo: frameBox.bottomAnchor, constant: -1),
            frameBox.heightAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        frameBox.setContentHuggingPriority(.init(1), for: .vertical)
        frameBox.setContentCompressionResistancePriority(.init(1), for: .vertical)
        addFull(frameBox)
        addFull(legend())
        panel.onJump = { [weak self] k in self?.jump(k) }
        panel.onOpen = { [weak self] k in self?.host?.go(.item(k, .overview)) }
        panel.show(key: selected, model: plan, showCritical: controls.critical)
        addFull(panel)
        clipWatch = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.scrolled()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { clipWatch.map(NotificationCenter.default.removeObserver) }

    private func build(days: Int) -> PlanGanttModel {
        PlanGanttModel.build(graph: plan.graph, schedule: plan.schedule, epics: epics, forecasts: forecasts, folded: controls.folded,
                             zoom: controls.zoom, firstDay: range.firstDay, days: days, today: plan.today, calendar: .current)
    }

    override func layout() {
        super.layout()
        let clip = scroll.contentView.bounds.size
        guard clip.width > 0 else { return }
        // Enough days to fill the width.
        let need = Int(ceil((clip.width - PlanGanttModel.label) / controls.zoom.dayW))
        if chart.model.dayCount < need {
            chart.model = build(days: (need + 6) / 7 * 7)
        }
        if chart.frame.size != chart.fitSize { chart.frame.size = chart.fitSize }
        if !placed {
            placed = true
            place()
        }
    }

    /// The last place under the same zoom and focus, else the focus, else today.
    private func place() {
        let focus = controls.focus?.segment == .timeline ? controls.focus : nil
        if let p = controls.timelinePlace, p.zoom == controls.zoom, p.focus == focus {
            chart.scroll(to: p.origin)
        } else if let k = focus?.key, chart.model.row(key: k) != nil {
            chart.scrollToToday()
            chart.focus(key: k)
        } else if let e = focus?.epic {
            chart.scrollToToday()
            chart.focus(epic: e)
        } else {
            chart.scrollToToday()
        }
        if UIShots.shooting, let k = focus?.key {
            tips.pinned = true
            DispatchQueue.main.async { [weak self] in self?.tip(self?.chart.model.rows.firstIndex { $0.key == k.uppercased() }) }
        }
        remember()
    }

    private func remember() {
        let focus = controls.focus?.segment == .timeline ? controls.focus : nil
        controls.timelinePlace = PlanGanttPlace(zoom: controls.zoom, focus: focus, origin: scroll.contentView.bounds.origin)
    }

    private func scrolled() {
        chart.needsDisplay = true
        chart.window?.invalidateCursorRects(for: chart)
        if placed { remember() }
        if !tips.pinned { tips.hide() }
    }

    private func select(_ key: String?) {
        PlanSelection.keys[plan.ident] = key
        panel.show(key: key, model: plan, showCritical: controls.critical)
    }

    private func fold(_ id: EpicID) {
        if controls.folded.contains(id) { controls.folded.remove(id) } else { controls.folded.insert(id) }
        remember()
        host?.planChanged()
    }

    private func jump(_ key: String) {
        guard chart.model.row(key: key) != nil else { host?.go(.item(key.uppercased(), .overview)); return }
        chart.focus(key: key)
        select(key.uppercased())
    }

    // MARK: Tip

    private func tip(_ index: Int?) {
        guard let i = index, let r = chart.model.rows[safe: i], let bar = r.barRect else { tips.release(); return }
        let rect = chart.convert(bar, to: frameBox)
        switch r.kind {
        case .item(let it):
            tips.show(.item(it.key), model: plan, showCritical: controls.critical, near: rect) { [weak self] k in self?.jump(k) }
        case .epic(let e):
            let f = forecasts[e.id]
            let ep = plan.epic(e.id)
            let title = e.late.map { "Late by \($0) day\($0 == 1 ? "" : "s")" } ?? (f?.end == nil ? "All done" : "On time")
            let due = ep?.targetDate.map { "Due " + EpicBoard.day($0) } ?? "No due date"
            let fc = plan.endText(f?.end).map { "forecast " + $0 } ?? "all done"
            tips.show(.group(epic: r.label, progress: "\(e.done) of \(e.total) done", title: title,
                             body: plan.status(e.id).map { "Why: " + $0 } ?? "",
                             row: "Dates", value: due + " · " + fc, valueColor: e.late != nil ? Palette.bad : Palette.fg),
                      model: plan, showCritical: controls.critical, near: rect) { [weak self] k in self?.jump(k) }
        }
    }

    // MARK: Legend and panel

    private func legend() -> NSView {
        let parts: [NSView] = [
            LegendSwatch.bar(GanttColor.workFill, Palette.run, "working"),
            LegendSwatch.bar(GanttColor.inputFill, Palette.warn, "needs you"),
            LegendSwatch.bar(GanttColor.readyFill, GanttColor.readyLine, "ready"),
            LegendSwatch.bar(nil, Palette.dim, "no spec", dashed: true),
            LegendSwatch.bar(GanttColor.readyFill, PlanColor.critical, "critical path", ring: true),
            LegendSwatch.epic(),
            LegendSwatch.diamond(),
            NSTextField.text("Forecast: each item starts when its blockers end. Items without dates count \(PlanGraph.defaultDays) days. Slots are not counted yet.",
                             size: 12, color: Palette.dim),
        ]
        return Wrap(parts)
    }
}

/// One legend entry: a small drawn shape and a word.
private final class LegendSwatch: NSView {
    enum Shape { case bar(fill: NSColor?, line: NSColor, dashed: Bool, ring: Bool), epic, diamond }
    private let shape: Shape

    private init(_ shape: Shape) {
        self.shape = shape
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 14))
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 14).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private static func entry(_ shape: Shape, _ word: String) -> NSView {
        let s = NSStackView(h: [LegendSwatch(shape), NSTextField.text(word, size: 12, color: Palette.mut)], spacing: 6)
        s.setAccessibilityElement(true)
        s.setAccessibilityRole(.staticText)
        s.setAccessibilityLabel("Legend: " + word)
        return s
    }

    static func bar(_ fill: NSColor?, _ line: NSColor, _ word: String, dashed: Bool = false, ring: Bool = false) -> NSView {
        entry(.bar(fill: fill, line: line, dashed: dashed, ring: ring), word)
    }
    static func epic() -> NSView { entry(.epic, "epic: done part solid, planned dashed") }
    static func diamond() -> NSView { entry(.diamond, "due date") }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch shape {
            case let .bar(fill, line, dashed, ring):
                let r = NSRect(x: 2, y: 2.5, width: 18, height: 9)
                let p = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
                if let fill { fill.setFill(); p.fill() }
                (ring ? GanttColor.readyLine : line).setStroke()
                if dashed { p.setLineDash([3, 2], count: 2, phase: 0) }
                p.stroke()
                if ring {
                    line.setStroke()
                    let o = NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: 4, yRadius: 4)
                    o.lineWidth = 2
                    o.stroke()
                }
            case .epic:
                let r = NSRect(x: 1, y: 3, width: 20, height: 8)
                let p = NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4)
                EpicColor.accent.withAlphaComponent(0.32).setFill()
                p.fill()
                EpicColor.accent.setFill()
                NSBezierPath(roundedRect: NSRect(x: 1, y: 3, width: 9, height: 8), xRadius: 4, yRadius: 4).fill()
            case .diamond:
                let c = NSPoint(x: 11, y: 7)
                let d = NSBezierPath()
                d.move(to: NSPoint(x: c.x, y: c.y - 5))
                d.line(to: NSPoint(x: c.x + 5, y: c.y))
                d.line(to: NSPoint(x: c.x, y: c.y + 5))
                d.line(to: NSPoint(x: c.x - 5, y: c.y))
                d.close()
                Palette.mut.setFill()
                d.fill()
            }
        }
    }
}
