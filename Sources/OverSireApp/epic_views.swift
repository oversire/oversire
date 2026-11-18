import Cocoa
import OverSireCore

// Drawn views of the epic pages. Shape and text carry each state, so color is never the only signal.

enum EpicColor {
    /// Okabe-Ito reddish purple. The light value is darker, for contrast on white.
    static let accent = NSColor(name: nil) { a in
        Palette.isDark(a) ? NSColor(srgbRed: 0xCC / 255.0, green: 0x79 / 255.0, blue: 0xA7 / 255.0, alpha: 1)
                          : NSColor(srgbRed: 0xA6 / 255.0, green: 0x4B / 255.0, blue: 0x7F / 255.0, alpha: 1)
    }

    static func word(_ s: EpicState) -> String {
        switch s {
        case .planned: return "Planned"
        case .active: return "In progress"
        case .paused: return "Paused"
        case .done: return "Done"
        case .canceled: return "Canceled"
        }
    }
}

/// The epic mark: dashed ring (planned), target rings (active), ring with bars (paused), check (done), slash (canceled).
/// A late epic has a small triangle at the corner.
final class EpicGlyph: NSView {
    let state: EpicState
    let late: Bool
    private let side: CGFloat

    init(_ state: EpicState, late: Bool = false, size: CGFloat = 18) {
        self.state = state
        self.late = late
        side = size
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: size), heightAnchor.constraint(equalToConstant: size)])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        toolTip = EpicColor.word(state) + (late ? ", late" : "")
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func ring(_ r: NSRect, _ width: CGFloat, _ color: NSColor, dash: [CGFloat]? = nil) {
        let p = NSBezierPath(ovalIn: r)
        p.lineWidth = width
        if let dash { p.setLineDash(dash, count: dash.count, phase: 0) }
        color.setStroke()
        p.stroke()
    }

    override func draw(_ dirtyRect: NSRect) {
        let c = EpicColor.accent
        let box = bounds.insetBy(dx: side * 0.08, dy: side * 0.08)
        let w = max(1.4, side * 0.09)
        switch state {
        case .planned:
            ring(box.insetBy(dx: w / 2, dy: w / 2), w, c, dash: [2.2, 2.2])
        case .active:
            ring(box.insetBy(dx: w / 2, dy: w / 2), w, c)
            ring(box.insetBy(dx: side * 0.22, dy: side * 0.22), w, c)
            let d = side * 0.2
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - d / 2, y: bounds.midY - d / 2, width: d, height: d)).fill()
        case .paused:
            ring(box.insetBy(dx: w / 2, dy: w / 2), w, c)
            c.setFill()
            let h = side * 0.36, bw = max(1.6, side * 0.1)
            NSRect(x: bounds.midX - bw * 1.4, y: bounds.midY - h / 2, width: bw, height: h).fill()
            NSRect(x: bounds.midX + bw * 0.4, y: bounds.midY - h / 2, width: bw, height: h).fill()
        case .done:
            Palette.ok.setFill()
            NSBezierPath(ovalIn: box).fill()
            let t = NSBezierPath()
            t.move(to: NSPoint(x: bounds.minX + side * 0.28, y: bounds.midY))
            t.line(to: NSPoint(x: bounds.minX + side * 0.44, y: bounds.minY + side * 0.3))
            t.line(to: NSPoint(x: bounds.minX + side * 0.74, y: bounds.minY + side * 0.68))
            t.lineWidth = max(1.6, side * 0.1)
            t.lineCapStyle = .round
            t.lineJoinStyle = .round
            NSColor.white.setStroke()
            t.stroke()
        case .canceled:
            ring(box.insetBy(dx: w / 2, dy: w / 2), w, Palette.dim)
            let s = NSBezierPath()
            s.move(to: NSPoint(x: bounds.minX + side * 0.25, y: bounds.minY + side * 0.25))
            s.line(to: NSPoint(x: bounds.maxX - side * 0.25, y: bounds.maxY - side * 0.25))
            s.lineWidth = w
            Palette.dim.setStroke()
            s.stroke()
        }
        if late {
            let t = side * 0.42
            let o = NSPoint(x: bounds.maxX - t, y: bounds.maxY - t)
            let tri = NSBezierPath()
            tri.move(to: NSPoint(x: o.x + t / 2, y: o.y + t))
            tri.line(to: NSPoint(x: o.x + t, y: o.y))
            tri.line(to: NSPoint(x: o.x, y: o.y))
            tri.close()
            Palette.bad.setFill()
            tri.fill()
        }
    }
}

/// The progress bar of an epic: done, then in progress, then the track for the rest. The counts are next to it in text.
final class EpicBar: NSView {
    private let done: Int, started: Int, total: Int
    private let barHeight: CGFloat

    init(done: Int, started: Int, total: Int, height: CGFloat = 6) {
        self.done = done
        self.started = started
        self.total = total
        barHeight = height
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let text = total == 0 ? "No items" : "\(done) of \(total) done" + (started > 0 ? ", \(started) in progress" : "")
        toolTip = text
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(text)
        setContentHuggingPriority(.init(1), for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: barHeight) }

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds, xRadius: barHeight / 2, yRadius: barHeight / 2)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
        track.fill()
        guard total > 0 else { return }
        track.addClip()
        let unit = bounds.width / CGFloat(total)
        let d = unit * CGFloat(done)
        let s = unit * CGFloat(min(started, total - done))
        Palette.ok.setFill()
        NSRect(x: 0, y: 0, width: d, height: bounds.height).fill()
        // A gap between the parts, so the edge shows without color.
        Palette.run.setFill()
        NSRect(x: d + (d > 0 && s > 0 ? 1.5 : 0), y: 0, width: max(0, s - (d > 0 ? 1.5 : 0)), height: bounds.height).fill()
    }
}

/// The burn-up chart: scope (dashed, square marks), done (solid, round marks) and the target date (dotted line).
final class BurnUpChart: NSView {
    static let days = 21
    private let burn: EpicBurnUp
    private let now: Date
    private let calendar = Calendar.current

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("d MMM")
        return f
    }()

    init(_ burn: EpicBurnUp, now: Date = Date()) {
        self.burn = burn
        self.now = now
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let last = burn.points.last
        var label = "Burn-up chart, last \(Self.days / 7) weeks. Scope \(last?.scope ?? 0), done \(last?.done ?? 0)"
        if let t = burn.target { label += ", target \(Self.dayFormat.string(from: t))" }
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(label)
        toolTip = label
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 150) }

    private var start: Date { calendar.date(byAdding: .day, value: -Self.days, to: now) ?? now }

    // The x range ends at today, or at the target date when it is up to 7 days ahead.
    private var end: Date {
        guard let t = burn.target, t > now, t < now.addingTimeInterval(7 * 86400) else { return now }
        return t
    }

    private func value(_ at: Date, _ pick: (EpicBurnUp.Point) -> Int) -> Int {
        burn.points.last { $0.at <= at }.map(pick) ?? 0
    }

    override func draw(_ dirtyRect: NSRect) {
        let maxValue = max(1, burn.points.map(\.scope).max() ?? 1)
        let plot = NSRect(x: 26, y: 12, width: bounds.width - 26 - 74, height: bounds.height - 12 - 22)
        guard plot.width > 20, plot.height > 20 else { return }
        let span = max(1, end.timeIntervalSince(start))
        func x(_ d: Date) -> CGFloat { plot.minX + plot.width * CGFloat(min(max(d.timeIntervalSince(start) / span, 0), 1)) }
        func y(_ v: Int) -> CGFloat { plot.maxY - plot.height * CGFloat(v) / CGFloat(maxValue) }

        let small: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: Palette.dim]
        for v in Set([0, maxValue / 2, maxValue]).sorted() {
            let line = NSBezierPath()
            line.move(to: NSPoint(x: plot.minX, y: y(v)))
            line.line(to: NSPoint(x: plot.maxX, y: y(v)))
            line.lineWidth = 0.5
            Palette.line.setStroke()
            line.stroke()
            let s = NSAttributedString(string: "\(v)", attributes: small)
            s.draw(at: NSPoint(x: plot.minX - 6 - s.size().width, y: y(v) - s.size().height / 2))
        }
        NSAttributedString(string: Self.dayFormat.string(from: start), attributes: small).draw(at: NSPoint(x: plot.minX, y: plot.maxY + 5))
        let today = NSAttributedString(string: "Today", attributes: small)
        today.draw(at: NSPoint(x: x(now) - today.size().width / 2, y: plot.maxY + 5))

        if let t = burn.target, t >= start, t <= end {
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x(t), y: plot.minY))
            p.line(to: NSPoint(x: x(t), y: plot.maxY))
            p.lineWidth = 1.4
            p.setLineDash([1.5, 3], count: 2, phase: 0)
            p.lineCapStyle = .round
            EpicColor.accent.setStroke()
            p.stroke()
            let label = NSAttributedString(string: "Target", attributes: [.font: NSFont.systemFont(ofSize: 9.5, weight: .semibold), .foregroundColor: EpicColor.accent])
            // Low and left of the line, where the series are far away.
            label.draw(at: NSPoint(x: x(t) - label.size().width - 4, y: plot.maxY - label.size().height - 2))
        }

        let scope = series(x: x, y: y, pick: \.scope, color: Palette.acc, dashed: true)
        let done = series(x: x, y: y, pick: \.done, color: Palette.ok, dashed: false)
        // The labels sit at the line ends. When the ends are close, the Done label goes below.
        let a = label("Scope \(scope.value)", Palette.acc, at: scope.tip)
        let low = done.tip.y - scope.tip.y < a.height + 1 && done.tip.y >= scope.tip.y - 2
        _ = label("Done \(done.value)", Palette.ok, at: NSPoint(x: done.tip.x, y: low ? scope.tip.y + a.height + 1 : done.tip.y))
    }

    private func label(_ text: String, _ color: NSColor, at p: NSPoint) -> NSSize {
        let t = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: color])
        t.draw(at: NSPoint(x: p.x + 8, y: p.y - t.size().height / 2))
        return t.size()
    }

    private func series(x: (Date) -> CGFloat, y: (Int) -> CGFloat, pick: (EpicBurnUp.Point) -> Int, color: NSColor, dashed: Bool) -> (tip: NSPoint, value: Int) {
        let inside = burn.points.filter { $0.at > start && $0.at <= now }
        let path = NSBezierPath()
        var last = value(start, pick)
        path.move(to: NSPoint(x: x(start), y: y(last)))
        var marks: [NSPoint] = []
        for p in inside {
            let v = pick(p)
            guard v != last else { continue }
            path.line(to: NSPoint(x: x(p.at), y: y(last)))
            path.line(to: NSPoint(x: x(p.at), y: y(v)))
            marks.append(NSPoint(x: x(p.at), y: y(v)))
            last = v
        }
        let tip = NSPoint(x: x(now), y: y(last))
        path.line(to: tip)
        path.lineWidth = 1.8
        path.lineJoinStyle = .round
        if dashed { path.setLineDash([5, 3], count: 2, phase: 0) }
        color.setStroke()
        path.stroke()
        color.setFill()
        // Few changes get a mark each. The end mark always shows. Scope has squares, done has circles.
        for m in marks.count <= 12 ? marks : [] { mark(at: m, square: dashed, r: 2.6) }
        mark(at: tip, square: dashed, r: 3.6)
        return (tip, last)
    }

    private func mark(at p: NSPoint, square: Bool, r: CGFloat) {
        let rect = NSRect(x: p.x - r, y: p.y - r, width: r * 2, height: r * 2)
        (square ? NSBezierPath(rect: rect) : NSBezierPath(ovalIn: rect)).fill()
    }
}
