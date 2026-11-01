import Cocoa
import OverSireCore

// ─── Work › Review ───────────────────────────────────────────────────────────
// The reviews of all machines (OVERSIRE-371): plans to approve, code to review, the reviews where the agent works,
// and the conflicts. Each row shows a glyph, a color and a word, so color is never the only signal.

/// The look of a state: a glyph, a color and a word.
struct ReviewMark: Hashable {
    let glyph: String
    let color: NSColor
    let word: String

    init(_ glyph: String, _ color: NSColor, _ word: String) {
        self.glyph = glyph
        self.color = color
        self.word = word
    }

    init(_ s: ReviewSummary) {
        switch s.state {
        case .ready: self.init("◆", Palette.warn, "Your turn")
        case .waiting: self.init("●", Palette.run, "Agent working")
        case .conflict: self.init("✕", Palette.bad, "Conflict")
        case .merged: self.init("✓", Palette.ok, "Merged")
        }
    }

    /// The merge of a repo into its base.
    init(_ r: ReviewRepo) {
        switch r.merge {
        case .fastForward: self.init("✓", Palette.ok, "\(r.base) fast-forward")
        case .rebase: self.init("▲", Palette.warn, "\(r.base) moved \(r.behind)")
        case .conflict: self.init("✕", Palette.bad, "Conflict with \(r.base)")
        }
    }

    func view(size: CGFloat = 12.5) -> NSTextField {
        let f = NSTextField.text(glyph, size: size, weight: .bold, color: color)
        f.setAccessibilityLabel(word)
        return f
    }

    /// The glyph and the word on one line.
    func line(_ text: String? = nil, size: CGFloat = 12) -> NSView {
        NSStackView(h: [view(size: size), NSTextField.text(text ?? word, size: size, color: Palette.fg)], spacing: 4)
    }
}

final class ReviewPage: Page {
    override var watches: DataDomains { [.reviews, .projects, .config] }

    override func sections() -> [PageSection]? {
        let book = REVIEWS
        let groups = book.groups
        let count = groups.reduce(0) { $0 + $1.rows.count }
        let machines = Set(book.rows.map(\.machine)).sorted()
        var caption = count == 0 ? "No reviews" : "\(count) review\(count == 1 ? "" : "s") · \(book.yourTurn) your turn"
        if !machines.isEmpty { caption += " · from the daemon on " + machines.joined(separator: ", ") }
        let top = WorkPage.header(self, tab: .review, caption: caption, extra: count, actions: {
            [ActionButton("Refresh", symbol: "arrow.clockwise") { Task { await REVIEWS.refresh() } }]
        })
        var rows: [PageRow] = []
        for (g, list) in groups {
            rows.append(StickyListCard.group(g.rawValue, g.title, count: list.count, extra: g.note) {
                [NSTextField.text(g.note, size: 12, color: Palette.dim)]
            })
            for s in list { rows.append(row(s)) }
        }
        var out = [PageSection("top", rows: top)]
        if rows.isEmpty {
            out.append(PageSection("empty", rows: [PageRow("empty", 0) {
                EmptyNote("Nothing to review. A row shows when an agent hands off a plan, or commits in a worktree group and stops.")
            }]))
        } else {
            out.append(PageSection("list", rows: [PageRow.list("table", rows: rows) { StickyListCard(header: nil, maxHeight: nil) }]))
        }
        let local = book.notPushed
        if !local.isEmpty { out.append(PageSection("local", rows: [notPushedRow(local)])) }
        out.append(PageSection("hint", rows: [PageRow("hint", 0) {
            NSTextField.text("A code row shows when an item has a worktree group with commits that its base does not have, and no session works in it. "
                             + "A plan row shows when a Plan session hands off. A conflict shows in its own group.", size: 12, color: Palette.dim, lines: 3)
        }]))
        return out
    }

    private func row(_ s: ReviewSummary) -> PageRow {
        let title = data.projectStore.item(key: s.key)?.item.title ?? s.title ?? s.key
        return PageRow(s.id, s, title) { [weak self] in ReviewRow(s, title: title) { self?.go($0) } }
    }

    private func notPushedRow(_ list: [(machine: String, item: NotPushed)]) -> PageRow {
        let multi = Set(list.map(\.machine)).count > 1
        return PageRow("notpushed", list.map { "\($0.machine) \($0.item.repo) \($0.item.base) \($0.item.ahead)" }) {
            let parts: [NSView] = list.map { m, n in
                Chiplet((multi ? "\(m) · " : "") + "\(n.repo) \(n.base) +\(n.ahead)", mono: true) as NSView
            }
            let line = NSStackView(h: [NSTextField.text("Merged, not pushed", size: 12.5, weight: .semibold)] + parts
                                   + [Spacer(), NSTextField.text("You push from the terminal.", size: 12, color: Palette.dim)], spacing: 8)
            let card = Card(padding: 10)
            card.add(line)
            card.setAccessibilityElement(true)
            card.setAccessibilityLabel("Merged, not pushed: " + list.map { "\($0.item.repo) \($0.item.base) \($0.item.ahead) commits" }.joined(separator: ", "))
            return card
        }
    }
}

/// One review. Return opens the review tab of the item. The up and down arrows move to the next row.
final class ReviewRow: Row {
    init(_ s: ReviewSummary, title: String, go: @escaping (Route) -> Void) {
        let mark = ReviewMark(s)
        let target = ReviewRow.route(s)
        let place = [s.key, s.kind == .plan ? "plan" : s.subitems.isEmpty ? "single item" : "\(s.subitems.count) sub-items",
                     s.round > 0 ? "round \(s.round + (s.state == .ready ? 1 : 0))" : nil, s.machine].compactMap { $0 }.joined(separator: " · ")
        let name = TwoLine(title, place)
        name.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        var main: [NSView] = [name]
        if !s.subitems.isEmpty {
            main.append(NSStackView(h: s.subitems.prefix(6).map { k in
                Chiplet(k.split(separator: "-").last.map(String.init) ?? k, mono: true) as NSView
            }, spacing: 4))
        }
        let left = NSStackView(v: main, spacing: 3)
        left.alignment = .leading
        left.setHuggingPriority(.init(1), for: .horizontal)
        left.setContentCompressionResistancePriority(.init(1), for: .horizontal)

        // The cells after the title have fixed widths, so the columns line up across rows.
        let glyph = mark.view(size: 14)
        glyph.widthAnchor.constraint(equalToConstant: 16).isActive = true
        var cells: [NSView] = [glyph, left]
        if s.kind == .code {
            let repos = s.repos.map(\.name).joined(separator: " ")
            cells.append(ReviewRow.cell(repos, "\(s.repos.count) repo\(s.repos.count == 1 ? "" : "s") · \(s.commitCount) commit\(s.commitCount == 1 ? "" : "s")", width: 150))
            cells.append(ReviewRow.cell("\(s.fileCount) file\(s.fileCount == 1 ? "" : "s") +\(s.added) −\(s.removed)", ReviewRow.comments(s), width: 150))
            let worst = s.repos.first { $0.merge == s.merge }
            let base = worst.map { ReviewMark($0) } ?? ReviewMark("✓", Palette.ok, "Nothing to merge")
            let line = NSStackView(v: [base.line(), NSTextField.text(relativeTime(ReviewBook.since(s)), size: 11.5, color: Palette.dim)], spacing: 2)
            line.widthAnchor.constraint(equalToConstant: 150).isActive = true
            cells.append(line)
        } else {
            cells.append(ReviewRow.cell("Plan", ReviewRow.comments(s), width: 150))
            cells.append(ReviewRow.cell(relativeTime(ReviewBook.since(s)), s.note, width: 150))
        }
        let pill = NSStackView(v: [mark.line(), NSTextField.text(ReviewRow.state(s), size: 11.5, color: Palette.dim)], spacing: 2)
        pill.widthAnchor.constraint(equalToConstant: 140).isActive = true
        cells.append(pill)
        let open = ActionButton(ReviewRow.action(s), style: s.state == .ready ? .primary : .plain) { go(target) }
        open.keyEquivalent = ""
        let slot = NSStackView(h: [Spacer(), open])
        slot.widthAnchor.constraint(equalToConstant: 116).isActive = true
        cells.append(slot)
        super.init(cells, height: 56, label: "\(mark.word): \(title), \(place)") { go(target) }
    }
    required init?(coder: NSCoder) { fatalError() }

    static func route(_ s: ReviewSummary) -> Route {
        if s.kind == .plan { return .item(s.key, .plan) }
        return s.state == .waiting ? .item(s.key, .session) : .item(s.key, .changes)
    }

    static func action(_ s: ReviewSummary) -> String {
        switch s.state {
        case .waiting: return "Session"
        case .conflict: return "Open"
        default: return s.kind == .plan ? "Review plan" : "Review code"
        }
    }

    static func comments(_ s: ReviewSummary) -> String {
        if s.pending > 0 { return "\(s.pending) pending comment\(s.pending == 1 ? "" : "s")" }
        if s.unanswered > 0 { return "\(s.unanswered) not answered" }
        return "No pending comments"
    }

    static func state(_ s: ReviewSummary) -> String {
        switch s.state {
        case .ready: return s.round > 0 ? "agent answered round \(s.round)" : "agent handed off"
        case .waiting: return s.session?.state == .working ? "same session" : "the agent starts"
        case .conflict: return "Fix with agent"
        case .merged: return "merged"
        }
    }

    private static func cell(_ top: String, _ bottom: String?, width: CGFloat) -> NSView {
        let s = NSStackView(v: [NSTextField.text(top, size: 12), NSTextField.text(bottom ?? "", size: 11.5, color: Palette.dim)], spacing: 2)
        s.widthAnchor.constraint(equalToConstant: width).isActive = true
        return s
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: move(1)
        case 126: move(-1)
        default: super.keyDown(with: event)
        }
    }

    private func move(_ d: Int) {
        guard let root = window?.contentView else { return }
        var all: [ReviewRow] = []
        func walk(_ v: NSView) {
            if let r = v as? ReviewRow { all.append(r) }
            v.subviews.forEach(walk)
        }
        walk(root)
        all.sort { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        guard let i = all.firstIndex(where: { $0 === self }), all.indices.contains(i + d) else { return }
        window?.makeFirstResponder(all[i + d])
    }
}
