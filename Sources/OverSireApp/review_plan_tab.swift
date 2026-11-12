import Cocoa
import OverSireCore

// ─── Item › Plan ─────────────────────────────────────────────────────────────
// The plan review of an item (OVERSIRE-372): the blocks of the plan comment, each with a + for a comment,
// and the sub-items in order. Approve sets the item and its sub-items to Todo, so the queue can take them.

final class ReviewPlanTab {
    var reload: () -> Void = {}
    var window: () -> NSWindow? = { nil }
    private var threads: [String: ReviewThreads] = [:]

    func threads(_ desk: ReviewDesk) -> ReviewThreads {
        if let t = threads[desk.id] { return t }
        let t = ReviewThreads(desk)
        t.reload = { [weak self] in self?.reload() }
        t.window = { [weak self] in self?.window() }
        t.jump = { [weak self, weak desk] c in
            guard let desk, case .plan(let b) = c.anchor else { return }
            desk.block = b
            desk.pick = nil
            self?.reload()
        }
        threads[desk.id] = t
        return t
    }

    func rows(_ desk: ReviewDesk) -> [PageRow] {
        let t = threads(desk)
        let s = desk.summary
        var out: [PageRow] = []
        let read = desk.review.state
        let part = desk.review.part(id: "review", title: "Plan review of \(s.key)")
        if desk.detail == nil, case .failed = read {
            out.append(PageRow("error", read, desk.review.last.retry(now: Date())) {
                ReadNote("The daemon on \(s.machine) did not give the review.", part: part)
            })
        }
        guard let detail = desk.detail else {
            guard !read.didFail else { return out }
            out.append(PageRow("loading", desk.loading) {
                let c = ListCard()
                c.add(LoadingNote("Loading the plan review of \(s.key)"))
                return c
            })
            return out
        }
        guard let plan = detail.plan else {
            out.append(PageRow("noplan", s.key) { EmptyNote("The agent did not hand off a plan comment for \(s.key) yet.") })
            return out
        }
        out.append(PageRow("head", plan.version, s.state, s.note, s.machine, read) {
            let mark = ReviewMark(s)
            var parts: [NSView] = [mark.view(size: 13),
                                   NSTextField.text("Plan comment on \(plan.key) · version \(plan.version)", size: 12.5, weight: .semibold),
                                   NSTextField.text("· Click + on a section to comment on it", size: 12, color: Palette.dim), Spacer()]
            if let note = s.note { parts.append(NSTextField.text("Agent: " + note, size: 12, color: Palette.mut)) }
            parts.append(ReadAccessory(part))
            return NSStackView(h: parts, spacing: 6)
        })
        out.append(PageRow("rounds", desk.rounds, s.round, desk.pending.count) { t.rounds() })
        for b in plan.blocks {
            let notes = desk.comments(block: b.id)
            out.append(PageRow("block-" + b.id, b, notes, desk.block == b.id, t.hash) { [unowned self] in self.block(desk, b, notes: notes, threads: t) })
        }
        if let subs = plan.subitems, !subs.isEmpty {
            out.append(PageRow("subitems", subs) {
                let card = Card(title: "Sub-items in order", padding: 12, spacing: 4)
                for (i, sub) in subs.enumerated() {
                    let key = NSTextField.text(sub.key ?? "new", size: 11.5, color: sub.key == nil ? Palette.ok : Palette.mut, mono: true)
                    key.widthAnchor.constraint(equalToConstant: 110).isActive = true
                    let line = NSStackView(h: [NSTextField.text("\(i + 1).", size: 12, color: Palette.dim, mono: true), key,
                                               NSTextField.text(sub.title, size: 12.5, lines: 2), Spacer()], spacing: 8)
                    line.setAccessibilityElement(true)
                    line.setAccessibilityLabel("Sub-item \(i + 1): \(sub.key ?? "new item"), \(sub.title)")
                    card.add(line)
                }
                return card
            })
        }
        out.append(PageRow("pending", desk.pending, t.hash) { t.pendingList() })
        out.append(PageRow("batch", desk.pending.count, desk.error, t.hash, s.round) { t.batchBar() })
        return out
    }

    private func block(_ desk: ReviewDesk, _ b: PlanBlock, notes: [ReviewComment], threads t: ReviewThreads) -> NSView {
        let open = desk.block == b.id
        let card = Card(padding: 12, spacing: 6, border: open ? Palette.acc : Palette.line)
        let plus = ActionButton("+", style: .ghost) { [weak self] in
            desk.block = b.id
            desk.pick = nil
            self?.reload()
        }
        plus.setAccessibilityLabel("Comment on the section \(b.heading)")
        plus.toolTip = "Comment on this section"
        let pend = notes.filter { $0.state == .pending }.count
        var head: [NSView] = [NSTextField.text(b.heading, size: 13, weight: .semibold, lines: 2), Spacer()]
        if pend > 0 { head.append(NSTextField.text("✎\(pend)", size: 11.5, weight: .semibold, color: Palette.warn)) }
        head.append(plus)
        card.add(NSStackView(h: head, spacing: 8))
        card.add(Self.markdown(b.markdown))
        if !notes.isEmpty { card.add(t.thread(notes)) }
        if open { card.add(t.composer(.plan(block: b.id), label: "section \"\(b.heading)\"")) }
        return card
    }

    /// Inline Markdown in a label. A plan block is short, so no web view.
    static func markdown(_ md: String) -> NSTextField {
        let f = NSTextField.text("", size: 12.5, lines: 0)
        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let a = try? NSMutableAttributedString(markdown: md, options: opts) {
            a.addAttribute(.foregroundColor, value: Palette.fg, range: NSRange(location: 0, length: a.length))
            a.enumerateAttribute(.font, in: NSRange(location: 0, length: a.length)) { v, r, _ in
                let traits = (v as? NSFont)?.fontDescriptor.symbolicTraits ?? []
                var font = NSFont.systemFont(ofSize: 12.5, weight: traits.contains(.bold) ? .semibold : .regular)
                if traits.contains(.monoSpace) { font = .monospacedSystemFont(ofSize: 11.5, weight: .regular) }
                a.addAttribute(.font, value: font, range: r)
            }
            f.attributedStringValue = a
        } else {
            f.stringValue = md
        }
        return f
    }
}
