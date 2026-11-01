import Cocoa
import OverSireCore

// ─── Review threads ──────────────────────────────────────────────────────────
// The comment parts that the Changes tab and the Plan tab share (OVERSIRE-372): the threads, the composer,
// the pending list, the rounds strip and the batch bar. Each comment goes into the pending batch on the daemon.
// Only Submit review sends the batch. One batch is one round.

/// A checkbox that runs a closure.
final class CheckBox: NSButton {
    var onFlip: ((Bool) -> Void)?

    init(_ title: String, on: Bool, label: String? = nil, _ flip: ((Bool) -> Void)? = nil) {
        onFlip = flip
        super.init(frame: .zero)
        setButtonType(.switch)
        self.title = title
        state = on ? .on : .off
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        if let label { setAccessibilityLabel(label) }
    }
    required init?(coder: NSCoder) { fatalError() }

    var isOn: Bool { state == .on }

    @objc private func fire() { onFlip?(isOn) }
}

/// A text field for a comment. Return adds it, Option-Return makes a new line.
final class CommentField: NSTextField {
    init(_ text: String, placeholder: String, label: String) {
        super.init(frame: .zero)
        stringValue = text
        placeholderString = placeholder
        setAccessibilityLabel(label)
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        lineBreakMode = .byWordWrapping
        font = .systemFont(ofSize: 12.5)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(greaterThanOrEqualToConstant: 54).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// The comment parts of one review tab. Main thread only.
final class ReviewThreads {
    let desk: ReviewDesk
    var reload: () -> Void = {}
    var window: () -> NSWindow? = { nil }
    /// Shows the place of a comment: its file, or its plan block.
    var jump: (ReviewComment) -> Void = { _ in }
    /// The route after an approve: the merge sheet for code.
    var approved: () -> Void = {}
    private weak var composerField: CommentField?
    private weak var editField: CommentField?
    private var busy = false

    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    init(_ desk: ReviewDesk) { self.desk = desk }

    /// A hash of all that the comment parts show.
    var hash: AnyHashable { [desk.detail?.comments, desk.detail?.rounds, desk.summary.round, desk.editing, desk.unfolded, desk.pick, desk.block, busy] as [AnyHashable?] }

    private func act(_ op: @escaping () async -> Bool) {
        guard !busy else { return }
        busy = true
        reload()
        Task { @MainActor [weak self] in
            _ = await op()
            self?.busy = false
            self?.reload()
        }
    }

    // MARK: Rounds strip

    func rounds() -> NSView {
        var parts: [NSView] = [NSTextField.text("Rounds", size: 12, weight: .semibold, color: Palette.mut)]
        for r in desk.rounds {
            let (mark, word) = Self.state(r)
            let text = "Round \(r.n) · \(r.count) comment\(r.count == 1 ? "" : "s") · \(Self.time.string(from: r.submittedAt))"
            let chip = Chiplet(text + " · " + word, icon: mark.view(size: 11))
            chip.setAccessibilityLabel("\(text), \(word)" + (r.error.map { ", \($0)" } ?? ""))
            chip.toolTip = r.error ?? r.summary
            parts.append(chip)
        }
        let n = desk.pending.count
        parts.append(Chiplet("Round \(desk.nextRound) · \(n) pending", color: n > 0 ? Palette.warn : Palette.dim))
        if desk.rounds.isEmpty { parts.insert(NSTextField.text("No round yet.", size: 12, color: Palette.dim), at: 1) }
        return NSStackView(h: parts + [Spacer()], spacing: 6)
    }

    /// The glyph and the word of a round.
    static func state(_ r: ReviewRound) -> (ReviewMark, String) {
        if r.error != nil { return (ReviewMark("✕", Palette.bad, "Not sent"), "not sent") }
        if r.answeredAt != nil { return (ReviewMark("✓", Palette.ok, "Answered"), "answered") }
        switch r.delivery {
        case .none: return (ReviewMark("✓", Palette.ok, "Approved"), r.verdict == .approve ? "approved" : "no prompt")
        case .queued where r.deliveredAt == nil: return (ReviewMark("●", Palette.run, "Waits"), "waits for the end of the turn")
        default: return (ReviewMark("●", Palette.run, "Agent working"), "agent working")
        }
    }

    // MARK: Threads

    /// The comments of one place, oldest first.
    func thread(_ list: [ReviewComment]) -> NSView {
        let s = NSStackView(v: list.sorted { $0.createdAt < $1.createdAt }.map(comment), spacing: 6)
        return s
    }

    func comment(_ c: ReviewComment) -> NSView {
        let place = c.anchor.placeLabel
        if c.state == .answered, !desk.unfolded.contains(c.id) {
            let b = ActionButton("✓ Round \(c.round) · answered by the agent · \(place) · show", style: .ghost) { [weak self] in
                self?.desk.unfolded.insert(c.id)
                self?.reload()
            }
            b.setAccessibilityLabel("Round \(c.round), answered by the agent, \(place). Show the comment.")
            return NSStackView(h: [b, Spacer()])
        }
        let card = Card(padding: 10, spacing: 6, fill: Palette.raise)
        let who: String
        switch c.state {
        case .pending: who = "You · Pending · \(place)"
        case .submitted: who = "You · Round \(c.round) · \(place) · sent, not answered yet"
        case .answered: who = "You · Round \(c.round) · \(place)"
        }
        var head: [NSView] = [NSTextField.text(who, size: 11.5, weight: .semibold, color: c.state == .pending ? Palette.warn : Palette.mut), Spacer()]
        if ReviewDesk.canEdit(c), desk.editing != c.id {
            head.append(ActionButton("Edit", style: .link) { [weak self] in self?.desk.editing = c.id; self?.reload() })
            head.append(ActionButton("Delete", style: .link) { [weak self] in
                guard let self else { return }
                self.act { await self.desk.delete(c) }
            })
        }
        if c.state == .answered {
            head.append(ActionButton("Hide", style: .link) { [weak self] in self?.desk.unfolded.remove(c.id); self?.reload() })
        }
        card.add(NSStackView(h: head, spacing: 8))
        if desk.editing == c.id {
            let f = CommentField(editField?.stringValue ?? c.text, placeholder: "What should the agent change here?", label: "Edit the comment")
            f.target = self
            f.action = #selector(saveEdit)
            editField = f
            card.add(f)
            card.add(NSStackView(h: [Spacer(), ActionButton("Cancel") { [weak self] in self?.desk.editing = nil; self?.reload() },
                                     ActionButton("Save", style: .primary) { [weak self] in self?.saveEdit() }], spacing: 8))
            DispatchQueue.main.async { [weak f] in f?.window?.makeFirstResponder(f) }
        } else {
            card.add(NSTextField.text(c.text, size: 12.5, lines: 0))
        }
        if let reply = c.reply {
            let r = Card(padding: 8, spacing: 4, fill: Palette.panel)
            r.add(NSStackView(h: [ReviewMark("✓", Palette.ok, "Answered").view(size: 11),
                                  NSTextField.text("Agent · Answered", size: 11.5, weight: .semibold, color: Palette.mut), Spacer()], spacing: 4))
            r.add(NSTextField.text(reply, size: 12.5, lines: 0))
            card.add(r)
        }
        card.setAccessibilityElement(true)
        card.setAccessibilityLabel("\(who): \(c.text)" + (c.reply.map { ". Agent: \($0)" } ?? ""))
        return card
    }

    @objc private func saveEdit() {
        guard let id = desk.editing, let c = desk.comments.first(where: { $0.id == id }), let f = editField else { return }
        let text = f.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        act { await self.desk.edit(c, text: text) }
    }

    // MARK: Composer

    /// The new comment for a place. Return adds it to the pending batch.
    func composer(_ anchor: ReviewAnchor, label: String) -> NSView {
        let card = Card(padding: 10, spacing: 6, fill: Palette.raise, border: Palette.acc)
        card.add(NSTextField.text("New comment · \(label)", size: 11.5, weight: .semibold, color: Palette.acc))
        let f = CommentField(composerField?.stringValue ?? desk.draft, placeholder: "What should the agent change here?", label: "New comment, \(label)")
        f.target = self
        f.action = #selector(addDraft)
        composerField = f
        card.add(f)
        let add = ActionButton(busy ? "Adding…" : "Add to review", style: .primary) { [weak self] in self?.addDraft() }
        add.isEnabled = !busy
        card.add(NSStackView(h: [NSTextField.text("Option-Return makes a new line.", size: 11.5, color: Palette.dim), Spacer(),
                                 ActionButton("Cancel") { [weak self] in self?.cancelDraft() }, add], spacing: 8))
        DispatchQueue.main.async { [weak f] in if f?.window?.firstResponder is NSTextView == false { f?.window?.makeFirstResponder(f) } }
        return card
    }

    @objc private func addDraft() {
        let anchor: ReviewAnchor?
        if let p = desk.pick { anchor = p.anchor } else { anchor = desk.block.map { .plan(block: $0) } }
        guard let anchor, let f = composerField else { return }
        let text = f.stringValue
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        desk.draft = text
        act { await self.desk.add(anchor, text: text) }
    }

    private func cancelDraft() {
        desk.pick = nil
        desk.block = nil
        desk.draft = ""
        composerField?.stringValue = ""
        reload()
    }

    // MARK: Pending list

    func pendingList() -> NSView {
        let list = desk.pending
        let card = Card(title: "Pending · round \(desk.nextRound)", padding: 10, spacing: 4)
        if list.isEmpty {
            card.add(NSTextField.text("No pending comments.", size: 12, color: Palette.dim))
            return card
        }
        for c in list {
            let place = ReviewDesk.place(c, plan: desk.detail?.plan)
            let row = Row([NSStackView(v: [NSTextField.text(place, size: 11, color: Palette.dim, mono: true),
                                            NSTextField.text(c.text, size: 12, lines: 2)], spacing: 2)],
                          height: 36, inset: 6, label: "Pending comment on \(place): \(c.text)") { [weak self] in self?.jump(c) }
            card.add(row)
        }
        return card
    }

    // MARK: Batch bar

    func batchBar() -> NSView {
        let n = desk.pending.count
        let text = n == 0 ? "No pending comments. You can still approve."
            : "\(n) pending comment\(n == 1 ? "" : "s") · round \(desk.nextRound) · not sent yet"
        var views: [NSView] = [NSTextField.text(n == 0 ? "○" : "◆", size: 13, weight: .bold, color: n == 0 ? Palette.dim : Palette.warn),
                               NSTextField.text(text, size: 12.5, weight: .medium), Spacer()]
        if let e = desk.error { views.insert(NSTextField.text(e, size: 12, color: Palette.bad, lines: 2), at: 2) }
        if n > 0 {
            views.append(ActionButton("Discard all", style: .danger) { [weak self] in self?.discardAll() })
        }
        let submit = ActionButton(n > 0 ? "Submit review · \(n)" : "Submit review", style: .primary) { [weak self] in self?.submit() }
        submit.isEnabled = !busy && desk.detail != nil
        views.append(submit)
        let bar = Box(fill: Palette.panel, border: n > 0 ? Palette.warn : Palette.line, radius: 8)
        let s = NSStackView(h: views, spacing: 10)
        bar.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 12), s.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -12),
            s.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8), s.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -8),
        ])
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.group)
        bar.setAccessibilityLabel(text)
        return bar
    }

    private func discardAll() {
        let n = desk.pending.count
        AlertConfirm.ask("Discard \(n) pending comment\(n == 1 ? "" : "s")?", info: "The agent never sees them.", button: "Discard all",
                         critical: true, in: window()) { [weak self] in
            guard let self else { return }
            self.act { await self.desk.discardAll() }
        }
    }

    func submit() {
        ReviewSubmitSheet(desk: desk, done: { [weak self] verdict in
            self?.reload()
            if verdict == .approve, self?.desk.kind == .code { self?.approved() }
        }).present(over: window())
    }
}

extension ReviewAnchor {
    /// "line 798", "lines 227–228" or "Plan section".
    var placeLabel: String {
        switch self {
        case .plan: return "Plan section"
        case .code(_, _, let line, let from, let side):
            let lines = from.map { $0 == line ? "line \(line)" : "lines \($0)–\(line)" } ?? "line \(line)"
            return side == .old ? lines + " (old)" : lines
        }
    }
}
