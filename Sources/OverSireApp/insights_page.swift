import Cocoa
import OverSireCore

// CI over the last 7 days against the 7 days before, from the deploy log.
final class InsightsPage: Page {
    private var repo: String?

    // Pass rate of each day, oldest first. Nil for a day with no finished run. Pure, for the selftest.
    static func daily(_ recs: [DeployRecord], days: Int = 14, now: Date = Date()) -> [(day: Date, rate: Double?)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        return (0..<days).reversed().map { back in
            let start = cal.date(byAdding: .day, value: -back, to: today)!
            let end = cal.date(byAdding: .day, value: 1, to: start)!
            let s = computeWindow(recordsInWindow(recs, from: start, to: end))
            return (start, s.passRate)
        }
    }

    override func build(_ col: NSStackView) {
        var recs = DeployLog.shared.all()
        let repos = Array(Set(recs.map(\.repo))).sorted()
        if let repo { recs = recs.filter { $0.repo == repo } }
        let now = Date(), day = 86_400.0
        let thisR = recordsInWindow(recs, from: now.addingTimeInterval(-7 * day), to: now.addingTimeInterval(1))
        let tw = computeWindow(thisR)
        let lw = computeWindow(recordsInWindow(recs, from: now.addingTimeInterval(-14 * day), to: now.addingTimeInterval(-7 * day)))
        let insights = generateInsights(this: tw, last: lw)

        let filter = MenuChip(repo.map { $0.split(separator: "/").last.map(String.init) ?? $0 } ?? "All repos", symbol: "line.3.horizontal.decrease") { [weak self] in
            [MenuAction("All repos") { self?.repo = nil; self?.reload() }] + repos.map { r in MenuAction(r) { self?.repo = r; self?.reload() } }
        }
        let copy = ActionButton("Copy report for AI", symbol: "sparkles") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(buildAIReport(this: tw, last: lw, insights: insights, thisRecs: thisR), forType: .string)
        }
        col.addFull(PageHeader("Insights", caption: "Last 7 days against the 7 days before. OverSire logs each finished run it sees.", actions: [filter, copy]))
        guard !recs.isEmpty else {
            col.addFull(EmptyNote("No run history yet. Keep OverSire open, and look again after some runs finish.", symbol: "chart.bar"))
            return
        }

        func prev(_ v: String?) -> String { "was " + (v ?? "—") }
        let delta = (tw.passRate ?? 0) - (lw.passRate ?? 0)
        let passTone: Tone = abs(delta) < 0.01 ? .info : delta > 0 ? .ok : .bad
        col.addFull(Grid([
            Tile(tw.passRate.map(pct) ?? "—", "Pass rate · " + prev(lw.passRate.map(pct)), tone: passTone, onClick: nil),
            Tile(tw.avgDuration.map(fmtDuration) ?? "—", "Run time · " + prev(lw.avgDuration.map(fmtDuration)), tone: .info, onClick: nil),
            Tile("\(tw.total)", "Runs · was \(lw.total)", tone: .info, onClick: nil),
            Tile("\(tw.failure)", "Failed · was \(lw.failure)", tone: tw.failure > 0 ? .bad : .ok) { [weak self] in self?.go(.runs(.failed)) },
            Tile(tw.deployPassRate.map(pct) ?? "—", "Deploys · " + prev(lw.deployPassRate.map(pct)), tone: .info, onClick: nil),
        ], columns: 5))

        let days = InsightsPage.daily(recs)
        let chart = Card(title: "Daily pass rate, all workflows")
        chart.add(PassRateChart(days))
        col.addFull(chart)

        let wf = Card(title: "Pass rate by workflow, last 7 days", spacing: 10)
        for w in tw.byWorkflow.values.filter({ $0.success + $0.failure > 0 }).sorted(by: { $0.total > $1.total }).prefix(12) {
            let rate = Double(w.success) / Double(w.success + w.failure)
            wf.add(RateBar(w.workflow, rate: rate, note: "\(w.total) runs" + (w.avgDuration.map { " · " + fmtDuration($0) } ?? "")))
        }
        col.addFull(wf)

        let notes = Card(title: "What changed")
        for i in insights { notes.add(NSStackView(h: [Glyph("lightbulb", color: Palette.warn, size: 12), NSTextField.text(i, size: 12.5, lines: 0)], spacing: 8, align: .top)) }
        col.addFull(notes)
    }
}

// A bar with the rate as text. The bar color and a glyph give the state, so it does not depend on color only.
final class RateBar: NSStackView {
    init(_ title: String, rate: Double, note: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 10
        translatesAutoresizingMaskIntoConstraints = false
        let tone: Tone = rate >= 0.9 ? .ok : rate >= 0.8 ? .warning : .bad
        let name = TwoLine(title, note)
        name.widthAnchor.constraint(equalToConstant: 260).isActive = true
        let track = Box(fill: Palette.raise, border: nil, radius: 4)
        let bar = Box(fill: tone.color, border: nil, radius: 4)
        track.addSubview(bar)
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 9),
            bar.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            bar.topAnchor.constraint(equalTo: track.topAnchor), bar.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            bar.widthAnchor.constraint(equalTo: track.widthAnchor, multiplier: max(0.01, rate)),
        ])
        track.setContentHuggingPriority(.init(1), for: .horizontal)
        let value = NSTextField.text(pct(rate), size: 12.5, weight: .medium)
        value.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .medium)
        value.alignment = .right
        value.widthAnchor.constraint(equalToConstant: 44).isActive = true
        [name, track, Glyph(tone, size: 12), value].forEach(addArrangedSubview)
        setAccessibilityElement(true)
        setAccessibilityLabel("\(title): \(pct(rate)) passed, \(note)")
    }
    required init(coder: NSCoder) { fatalError() }
}

// A line chart of the daily pass rate, 0–100 %.
final class PassRateChart: NSView {
    private let days: [(day: Date, rate: Double?)]

    init(_ days: [(day: Date, rate: Double?)]) {
        self.days = days
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 180).isActive = true
        let known = days.compactMap(\.rate)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(known.isEmpty ? "Pass rate: no data" :
            "Pass rate over \(days.count) days, from \(pct(known.first!)) to \(pct(known.last!))")
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let left: CGFloat = 40, bottom: CGFloat = 22, top: CGFloat = 8, right: CGFloat = 8
        let w = bounds.width - left - right, h = bounds.height - bottom - top
        func x(_ i: Int) -> CGFloat { left + CGFloat(i) * w / CGFloat(max(1, days.count - 1)) }
        func y(_ v: Double) -> CGFloat { bottom + CGFloat(v) * h }
        let font = NSFont.systemFont(ofSize: 10.5)
        let label: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: Palette.dim]
        for v in [0.0, 0.5, 1.0] {
            Palette.line.setStroke()
            let p = NSBezierPath(); p.move(to: NSPoint(x: left, y: y(v))); p.line(to: NSPoint(x: left + w, y: y(v))); p.lineWidth = 1; p.stroke()
            let s = NSAttributedString(string: pct(v), attributes: label)
            s.draw(at: NSPoint(x: left - 6 - s.size().width, y: y(v) - s.size().height / 2))
        }
        let f = DateFormatter(); f.dateFormat = "MMM d"
        if let first = days.first, let last = days.last {
            NSAttributedString(string: f.string(from: first.day), attributes: label).draw(at: NSPoint(x: left, y: 2))
            let e = NSAttributedString(string: f.string(from: last.day), attributes: label)
            e.draw(at: NSPoint(x: left + w - e.size().width, y: 2))
        }
        // One segment for each run of days with data. A day with no runs makes a gap.
        let line = NSBezierPath(); line.lineWidth = 2; line.lineJoinStyle = .round
        var open = false
        for (i, d) in days.enumerated() {
            guard let r = d.rate else { open = false; continue }
            let pt = NSPoint(x: x(i), y: y(r))
            if open { line.line(to: pt) } else { line.move(to: pt); open = true }
        }
        Palette.acc.setStroke(); line.stroke()
        for (i, d) in days.enumerated() {
            guard let r = d.rate else { continue }
            let dot = NSBezierPath(ovalIn: NSRect(x: x(i) - 3, y: y(r) - 3, width: 6, height: 6))
            (r < 0.8 ? Palette.bad : Palette.acc).setFill(); dot.fill()
        }
    }
}
