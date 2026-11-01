import Cocoa
import OverSireCore

// The recap parts of the Status panel (OVERSIRE-383): Where we are, Pending, Since you last looked, Your last words, You decided.
// Fixed slots, not a paragraph. Each mark has a glyph and a word; the color only repeats them.
struct RecapPanel {
    let catchUp: CatchUp
    let recap: Recap?
    let busy: Bool
    let open: (String) -> Void
    let confirm: (CatchUp.Line) -> Void
    let askWhy: (CatchUp.Line) -> Void
    var now = Date()

    static func color(_ m: CatchUp.Mark) -> NSColor {
        switch m {
        case .merged: return Palette.ok
        case .failed: return Palette.bad
        case .yours: return Palette.warn
        case .works: return Palette.run
        case .todo: return Palette.dim
        }
    }

    static func mark(_ m: CatchUp.Mark, size: CGFloat = 13) -> NSTextField {
        let t = NSTextField.text(m.rawValue, size: size, weight: .semibold, color: color(m))
        t.setAccessibilityLabel(m.word)
        return t
    }

    /// The Now line: glyph, who has the ball, since when, one button.
    static func nowLine(_ n: CatchUp.Now, now: Date = Date(), act: @escaping (CatchUp.Action, String) -> Void) -> NSView {
        let head = NSTextField.text(n.text, size: 14, weight: .semibold, lines: 2)
        let since = NSTextField.text("Since \(dayTime(n.since, now: now)) · \(spanText(now.timeIntervalSince(n.since)))", size: 12, color: Palette.dim)
        var row: [NSView] = [mark(n.mark, size: 15), NSStackView(v: [head, since], spacing: 2), Spacer()]
        if let a = n.action { row.append(ActionButton(a.rawValue, style: .primary) { act(a, n.key) }) }
        let v = NSStackView(h: row, spacing: 8, align: .top)
        v.setAccessibilityElement(false)
        return v
    }

    func add(to c: Card) {
        if !catchUp.board.isEmpty { c.add(board()) }
        let pend = pending()
        if !pend.isEmpty { c.add(section("Pending", nil, pend)) }
        if let s = catchUp.since { c.add(sinceSection(s)) }
        if let w = catchUp.lastWords { c.add(words(w)) }
        let decided = recap?.decided.isEmpty == false ? recap!.decided : catchUp.decided
        if !decided.isEmpty { c.add(section("You decided", nil, [Wrap(decided.map(chip))])) }
    }

    // MARK: Where we are

    private func board() -> NSView {
        let shipped = catchUp.shipped
        let note = "\(catchUp.merged) of \(catchUp.board.count) merged" + (shipped > 0 ? " · \(shipped) shipped" : "")
        var rows: [NSView] = [Strip(catchUp.board.map(\.mark))]
        for r in catchUp.board {
            var line: [NSView] = [Self.mark(r.mark), NSTextField.text(r.key, size: 12.5, weight: .medium, mono: true),
                                  NSTextField.text(r.title, size: 12.5), NSTextField.text(r.note, size: 12, color: Palette.dim)]
            line += r.ships.map { Chiplet("★ " + $0, color: Palette.acc) as NSView }
            line.append(Spacer())
            let key = r.key
            rows.append(Row(line, height: 28, inset: 4, label: "\(r.key) \(r.title), \(r.mark.word), \(r.note)") { open(key) })
        }
        return section("Where we are", note, rows)
    }

    /// One segment for each sub-item, in board order.
    final class Strip: NSView {
        let marks: [CatchUp.Mark]
        init(_ m: [CatchUp.Mark]) {
            marks = m
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: 6).isActive = true
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            guard !marks.isEmpty else { return }
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let gap: CGFloat = 3, w = (bounds.width - gap * CGFloat(marks.count - 1)) / CGFloat(marks.count)
                for (i, m) in marks.enumerated() {
                    let r = NSRect(x: CGFloat(i) * (w + gap), y: 0, width: w, height: bounds.height)
                    (m == .todo ? Palette.raise : RecapPanel.color(m)).setFill()
                    NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
                }
            }
        }
    }

    // MARK: Pending

    private func pending() -> [NSView] {
        var out: [NSView] = catchUp.pending.map { p in
            let glyph = p.kind == .notPushed ? "○" : p.kind == .question ? "?" : "◆"
            var line: [NSView] = [NSTextField.text(glyph, size: 13, weight: .semibold, color: p.kind == .notPushed ? Palette.dim : Palette.warn),
                                  NSTextField.text(p.text, size: 12.5, lines: 2), Spacer()]
            if p.yours { line.append(Chiplet("you", color: Palette.warn)) }
            if let k = p.key { return Row(line, height: 28, inset: 4, label: p.text) { open(k) } }
            return NSStackView(h: line, spacing: 6)
        }
        for ch in recap?.choices ?? [] {
            out.append(NSStackView(h: [NSTextField.text("?", size: 13, weight: .semibold, color: Palette.acc),
                                       NSTextField.text("Agent choice not confirmed: " + ch.text, size: 12.5, lines: 2), Spacer(),
                                       ActionButton("Confirm") { confirm(ch) }, ActionButton("Ask why", style: .link) { askWhy(ch) }], spacing: 6))
        }
        return out
    }

    // MARK: Since you last looked

    private func sinceSection(_ s: Date) -> NSView {
        let c = catchUp.counts
        let fails = c.ciFails == 0 ? "0 CI fails" : "\(c.ciFails) CI fail\(c.ciFails == 1 ? "" : "s")" + (c.ciFixed == c.ciFails ? ", fixed" : c.ciFixed > 0 ? ", \(c.ciFixed) fixed" : "")
        let counts: [(Int, String)] = [(c.commits, "\(c.commits) commit\(c.commits == 1 ? "" : "s")"), (c.ciFails, fails),
                                       (c.releases, "\(c.releases) release\(c.releases == 1 ? "" : "s")"),
                                       (c.merges, "\(c.merges) merge\(c.merges == 1 ? "" : "s")"),
                                       (c.questions, "\(c.questions) question\(c.questions == 1 ? "" : "s")")]
        var rows: [NSView] = [Wrap(counts.map { CountChip($0.1, zero: $0.0 == 0) })]
        let ai = recap?.lines ?? []
        let lines = ai.isEmpty ? catchUp.lines : ai
        for l in lines {
            rows.append(NSStackView(h: [NSTextField.text(l.mark, size: 12.5, weight: .semibold, color: Self.lineColor(l.mark)),
                                        NSTextField.text(l.text, size: 12.5, lines: 2), Spacer(),
                                        NSTextField.text(l.at.map { dayTime($0, now: now) } ?? "", size: 11.5, color: Palette.dim)], spacing: 6, align: .top))
        }
        if busy { rows.append(InlineSpinner("The AI writes the recap…")) }
        let note = "\(dayTime(s, now: now)) · \(spanText(now.timeIntervalSince(s)))"
        return section("Since you last looked", note, rows)
    }

    static func lineColor(_ mark: String) -> NSColor {
        switch mark {
        case "✕": return Palette.bad
        case "◆": return Palette.warn
        case "★": return Palette.acc
        case "◉", "✓": return Palette.ok
        default: return Palette.mut
        }
    }

    // MARK: Your words

    private func words(_ w: CatchUp.Words) -> NSView {
        let what = w.kind == .reviewSubmitted ? "review" : w.kind == .commentCreated ? "comment" : "prompt"
        let t = NSTextField.text("“\(w.text)”", size: 12.5, color: Palette.fg, lines: 3)
        let meta = NSTextField.text("\(what) on \(w.key), \(dayTime(w.at, now: now))", size: 11.5, color: Palette.dim)
        return section("Your last words", nil, [t, meta])
    }

    private func chip(_ l: CatchUp.Line) -> NSView {
        let c = Chiplet("◆ " + l.text, color: Palette.fg)
        if let r = l.reason {
            c.toolTip = r
            c.setAccessibilityHelp(r)
        }
        return c
    }

    private func section(_ title: String, _ note: String?, _ rows: [NSView]) -> NSView {
        var head: [NSView] = [NSTextField.text(title.uppercased(), size: 11, weight: .semibold, color: Palette.dim)]
        if let note { head.append(NSTextField.text(note, size: 11.5, color: Palette.dim)) }
        head.append(Spacer())
        let v = NSStackView(v: [], spacing: 5)
        v.addFull(NSStackView(h: head, spacing: 8))
        rows.forEach { v.addFull($0) }
        return v
    }
}

/// A count chip. A zero count has a dashed border and dim text, so "nothing failed" is also an answer.
final class CountChip: NSView {
    private let zero: Bool
    private let label: NSTextField

    init(_ text: String, zero: Bool) {
        self.zero = zero
        label = .text(text, size: 11.5, weight: .medium, color: zero ? Palette.dim : Palette.fg)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        label.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3), label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
            if !zero {
                Palette.raise.setFill()
                p.fill()
            }
            Palette.line.setStroke()
            if zero { p.setLineDash([3, 2], count: 2, phase: 0) }
            p.lineWidth = 1
            p.stroke()
        }
    }
}
