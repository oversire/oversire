import Cocoa
import OverSireCore
import OverSireAI

// ─── Groom panel ─────────────────────────────────────────────────────────────
// The run, the review list and the result of Apply for one project, above the Intake list (OVERSIRE-340).

extension Tone {
    static let groom = Tone(symbol: "rectangle.on.rectangle", color: Palette.intake, word: "Groom")
}

extension GroomResult.Kind {
    /// The tag of a line: a symbol and a word, so the kind never relies on color alone.
    var tag: (mark: String, word: String, color: NSColor) {
        switch self {
        case .merge: return ("⇉", "Merge", Palette.intake)
        case .done: return ("✓", "Done", Palette.ok)
        case .obsolete: return ("⊘", "Obsolete", Palette.bad)
        case .fold: return ("↳", "Fold", Palette.run)
        case .relate: return ("↔", "Relate", Palette.mut)
        case .vague: return ("✦", "Vague", Palette.warn)
        default: return ("•", rawValue.capitalized, Palette.mut)
        }
    }

    /// The note on the group head.
    var groupNote: String {
        switch self {
        case .merge: return "items about the same problem become one"
        case .done: return "the code already does it"
        case .obsolete: return "the item is no longer valid"
        case .fold: return "becomes a sub-item"
        case .relate: return "a link in Plane"
        case .vague: return "the items stay and get Enhance after Apply"
        default: return ""
        }
    }
}

final class GroomPanel: Card {
    /// The filter of each project: nil shows all kinds.
    static var filter: [String: GroomResult.Kind] = [:]

    private let agent: GroomAgent
    private let pk: String
    private let projectID: String
    private let title: (String) -> String?
    private let enhance: EnhanceAgent
    private var lines: [GroomLine] = []

    /// `title` gives the title of a key. `retry` opens the start sheet again.
    init(_ state: GroomAgent.State, projectKey pk: String, identifier: String, agent: GroomAgent, enhance: EnhanceAgent, questions: QuestionHub,
         title: @escaping (String) -> String?, retry: @escaping () -> Void, undo: @escaping () -> Void) {
        self.agent = agent
        self.pk = pk
        self.projectID = identifier
        self.title = title
        self.enhance = enhance
        super.init(title: nil, padding: 14, spacing: 10, fill: Palette.raise, border: Palette.intake.withAlphaComponent(0.45))
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Groom \(identifier)")

        var head: [NSView] = [Glyph(Tone.groom.symbol, color: Palette.intake, size: 13),
                              NSTextField.text("Groom \(identifier)" + (state.review != nil ? " · review" : ""), size: 13.5, weight: .semibold)]
        if let r = state.review {
            head.append(Chiplet(r.scope == .intake ? "intake" : "intake + backlog"))
            if r.rounds > 1 { head.append(Chiplet("\(r.rounds) rounds")) }
            head.append(Chiplet("\(max(1, Int(r.worked / 60)))m of work"))
        } else {
            head.append(Chiplet(agent.place))
            head.append(Chiplet("key \(StartKey.groomPrefix)\(identifier)", mono: true))
        }
        if let p = agent.pill(pk) { head.append(Pill(p.tone, text: p.text)) }
        add(NSStackView(h: head + [Spacer()], spacing: 8))
        if state.review == nil { GroomBody.forget(pk) }

        let open: [NSView] = agent.canReveal ? [ActionButton("Open session ↗") { agent.reveal(pk) }] : []
        switch state {
        case .starting(let step):
            add(NSStackView(h: [Spinner(), NSTextField.text(step, size: 12.5, color: Palette.mut)], spacing: 8))
        case .grooming(let run):
            add(NSTextField.text("The agent reads \(run.keys.count) items and the code of the project. It asks here when the code cannot tell. "
                                 + "Nothing goes to Plane before you click Apply.", size: 12.5, color: Palette.mut, lines: 2))
            add(foot(open + [ActionButton("Stop", style: .ghost) { agent.discard(pk) }],
                     note: "The work continues while you answer. The time counts only the work."))
        case .asking(let run, _):
            let asked = run.session.map { questions.open(session: $0) } ?? []
            for e in asked { add(questions.card(e)) }
            if asked.isEmpty { add(NSTextField.text("The agent asks in the session. Open it to answer.", size: 12.5, color: Palette.mut)) }
            add(foot(open + [ActionButton("Stop", style: .ghost) { agent.discard(pk) }],
                     note: "The work continues while you answer. The time counts only the work."))
        case .ready(let review, let run):
            self.review(review, run: run, open: open)
        case .applying(let review, let n, let of):
            add(NSStackView(h: [Spinner(), NSTextField.text("Groom writes \(n) of \(of) changes to Plane, one item at a time.", size: 12.5, color: Palette.mut)],
                            spacing: 8))
            add(NSTextField.text("\(review.changes.count) lines in the review.", size: 12, color: Palette.dim))
        case .applied(let review, let out):
            applied(review, out, undo: undo)
        case .failed(let msg, let kept):
            add(NSTextField.text(msg, size: 12.5, color: Palette.mut, lines: 3))
            if let kept, !kept.isEmpty { add(TermView(lines: kept.components(separatedBy: "\n"), height: 96)) }
            add(foot([ActionButton("Try again") { retry() }] + open + [ActionButton("Dismiss", style: .ghost) { agent.dismiss(pk) }]))
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func foot(_ views: [NSView], note: String? = nil) -> NSView {
        let line = Box(fill: Palette.line, border: nil, radius: 0)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        var row = views + [Spacer()]
        if let note { row.append(NSTextField.text(note, size: 11.5, color: Palette.dim)) }
        let v = NSStackView(v: [line, NSStackView(h: row, spacing: 8)], spacing: 10)
        v.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true }
        return v
    }

    // MARK: Review

    private func review(_ review: GroomAgent.Review, run: GroomAgent.Run?, open: [NSView]) {
        let picked = agent.selected[pk] ?? []
        let changes = review.changes
        let after = review.result.openAfter(review.open, selected: picked)
        let filter = Self.filter[pk]

        let big = NSTextField.text("\(review.open) → \(after)", size: 24, weight: .semibold)
        big.font = .monospacedDigitSystemFont(ofSize: 24, weight: .semibold)
        big.setAccessibilityLabel("\(review.open) open items now, \(after) after Apply")
        var chips: [NSView] = [ToggleChip("All \(changes.count + review.vague.count)", on: filter == nil) { [weak self] in self?.show(nil) }]
        for k in GroomResult.Kind.all {
            let n = (k == .vague ? review.vague : changes.filter { $0.kind == k }).count
            guard n > 0 else { continue }
            let t = k.tag
            let chip = ToggleChip("\(t.mark) \(t.word) \(n)", on: filter == k) { [weak self] in self?.show(k) }
            chip.setAccessibilityLabel("Show \(t.word): \(n) lines")
            chips.append(chip)
        }
        let sum = Card(title: nil, padding: 12, spacing: 6, fill: Palette.panel)
        sum.add(NSStackView(h: [big, NSTextField.text("open items after Apply", size: 12, color: Palette.mut), Spacer()], spacing: 8, align: .lastBaseline))
        sum.add(NSStackView(h: chips + [Spacer()], spacing: 6))
        add(sum)

        let list = NSStackView(v: [], spacing: 0)
        for k in GroomResult.Kind.all where filter == nil || filter == k {
            let group = k == .vague ? review.vague : changes.filter { $0.kind == k }
            guard !group.isEmpty else { continue }
            list.addFull(groupHead(k, group))
            for p in group {
                let line = GroomLine(p, checked: k == .vague ? nil : picked.contains(p.id), member: title, panel: self)
                line.onClick = k == .vague ? nil : { [weak self] in self?.toggle(p) }
                lines.append(line)
                list.addFull(line)
            }
        }
        if changes.isEmpty && review.vague.isEmpty {
            list.addFull(Padded(NSTextField.text("Groom found nothing to merge or close. The items stay as they are.", size: 12.5, color: Palette.mut)))
        }
        let left = Card(title: nil, padding: 0, spacing: 0, fill: Palette.bg)
        left.add(list)
        let boxes = sideBoxes(review)
        boxes.forEach { $0.widthAnchor.constraint(equalToConstant: 290).isActive = true }
        let side = NSStackView(v: boxes, spacing: 10)
        side.setContentHuggingPriority(.required, for: .horizontal)
        add(GroomBody(NSStackView(h: [left, side], spacing: 14, align: .top), keep: pk + ".review"))

        let n = changes.filter { picked.contains($0.id) }.count
        let apply = ActionButton("Apply \(n) change\(n == 1 ? "" : "s")", style: .primary) { [agent, pk] in agent.apply(pk) }
        apply.keyEquivalent = "\r"
        apply.keyEquivalentModifierMask = .command
        apply.isEnabled = n > 0
        var acts: [NSView] = [apply]
        if !review.vague.isEmpty && enhance.available {
            acts.append(ActionButton("Apply, then Enhance \(review.vague.count) vague") { [agent, pk] in agent.apply(pk, enhance: true) })
        }
        if run?.session != nil { acts.append(ActionButton("Ask again") { [agent, pk] in agent.askAgain(pk) }) }
        acts += open
        acts.append(ActionButton("Discard", style: .ghost) { [agent, pk] in agent.discard(pk) })
        add(foot(acts, note: "Plane changes go one item at a time. A failed line stays in the list."))
    }

    private func groupHead(_ k: GroomResult.Kind, _ group: [GroomResult.Proposal]) -> NSView {
        let t = k.tag
        var note = k.groupNote
        if k == .merge {
            let items = group.reduce(0) { $0 + $1.keys.count }
            note = "\(group.count) group\(group.count == 1 ? "" : "s") · \(items) items become \(group.count)"
        }
        return lineBox([NSTextField.text(t.mark, size: 12.5, weight: .semibold, color: t.color), NSTextField.text(t.word, size: 12, weight: .semibold),
                        NSTextField.text(note, size: 12, color: Palette.dim), Spacer()], label: "\(t.word): \(note)", fill: Palette.raise)
    }

    private func sideBoxes(_ review: GroomAgent.Review) -> [NSView] {
        func box(_ title: String, _ lines: [String]) -> NSView {
            let c = Card(title: nil, padding: 12, spacing: 5, fill: Palette.panel)
            c.add(NSTextField.text(title.uppercased(), size: 10.5, weight: .semibold, color: Palette.dim))
            for l in lines { c.add(NSTextField.text("• " + l, size: 12, color: Palette.mut, lines: 4)) }
            return c
        }
        var out = [
            box("What Apply writes to Plane", [
                "Merge: the kept item gets the new description. Each other item gets \"Merged into KEY\", the duplicate relation and the Cancelled state.",
                "Done: the Done state and a comment with the evidence.",
                "Obsolete: the Cancelled state and a comment with the reason.",
                "Fold: the parent.",
                "Relate: the relation.",
                "Vague: nothing. Enhance starts on these items.",
            ]),
            box("Keys", ["Space: select or clear a line", "↑ ↓: move between lines", "→: open the new description", "⌘↩: Apply"]),
        ]
        if !review.skipped.isEmpty {
            let n = review.skipped.count
            out.append(box("Not in this run", ["\(n) item\(n == 1 ? " has" : "s have") a live session, a lane or a started state. Groom does not change \(n == 1 ? "it" : "them")."]))
        }
        return out
    }

    private func show(_ k: GroomResult.Kind?) {
        Self.filter[pk] = k
        NotificationCenter.default.post(name: GroomAgent.changed, object: agent)
    }

    private func toggle(_ p: GroomResult.Proposal) { agent.toggle(pk, p) }

    /// The line after or before `line`, for the arrow keys.
    func move(from line: GroomLine, by d: Int) {
        guard let i = lines.firstIndex(where: { $0 === line }) else { return }
        guard lines.indices.contains(i + d) else { return }
        let next = lines[i + d]
        window?.makeFirstResponder(next)
        next.scrollToVisible(next.bounds)
    }

    // MARK: After Apply

    private func applied(_ review: GroomAgent.Review, _ out: GroomOutcome, undo: @escaping () -> Void) {
        let all = out.written.count + out.failed.count
        let lines = review.changes.filter { out.written.contains($0.id) || out.failed[$0.id] != nil }
        let closed = lines.filter { out.written.contains($0.id) }.reduce(0) { $0 + $1.closes }
        var info = "\(projectID), \(review.scope == .intake ? "intake" : "intake and backlog"): \(review.open) → \(max(0, review.open - closed)) open items."
        let waiting = agent.handoff[pk]?.count ?? 0
        if waiting > 0 { info += " \(waiting) Enhance session\(waiting == 1 ? "" : "s") wait for a slot." }
        var acts: [NSView] = []
        if agent.undoable.contains(pk) { acts.append(ActionButton("Undo last Groom") { undo() }) }
        acts.append(ActionButton("Dismiss", style: .ghost) { [agent, pk] in agent.dismiss(pk) })
        add(Banner(out.failed.isEmpty ? .ok : .warning, title: "Groom wrote \(out.written.count) of \(all) change\(all == 1 ? "" : "s").", body: info, actions: acts))

        let list = NSStackView(v: [], spacing: 0)
        for p in lines {
            let failed = out.failed[p.id]
            let key = p.keep ?? p.keys.first ?? ""
            let mark = NSTextField.text(failed == nil ? "✓" : "✕", size: 13, weight: .semibold, color: failed == nil ? Palette.ok : Palette.bad)
            let text = failed.map { "\(Self.failWord(p)) not written: \($0)" } ?? Self.doneText(p)
            var row: [NSView] = [mark, Chiplet(key, mono: true), NSTextField.text(text, size: 12.5, color: Palette.mut), Spacer()]
            if failed != nil { row.append(ActionButton("Try again") { [agent, pk] in agent.apply(pk, only: [p.id]) }) }
            list.addFull(lineBox(row, label: (failed == nil ? "Written: " : "Failed: ") + "\(key). \(text)"))
        }
        for key in out.vague {
            var row: [NSView] = [NSTextField.text("✦", size: 13, color: Palette.warn), Chiplet(key, mono: true),
                                 NSTextField.text("Kept as vague", size: 12.5, color: Palette.mut), Spacer()]
            if let t = enhance.find(key)?.target, let p = enhance.pill(t) {
                row.append(Pill(p.tone, text: p.text))
            } else if agent.handoff[pk]?.contains(where: { enhance.find(key)?.target == $0 }) == true {
                row.append(Pill(.queued, text: "Enhance queued"))
            }
            list.addFull(lineBox(row, label: "\(key): kept as vague"))
        }
        if !list.arrangedSubviews.isEmpty {
            let c = Card(title: nil, padding: 0, spacing: 0, fill: Palette.bg)
            c.add(list)
            add(GroomBody(c, keep: pk + ".applied"))
        }
        add(NSTextField.text("\"Undo last Groom\" puts back the states and descriptions that Groom changed, while no other change came after it. The comments stay.",
                             size: 12, color: Palette.dim, lines: 2))
    }

    private func lineBox(_ views: [NSView], label: String, fill: NSColor? = nil) -> NSView {
        let pad = Padded(NSStackView(h: views, spacing: 10), vertical: 7)
        let box = Box(fill: fill, border: nil, radius: 0)
        box.addSubview(pad)
        NSLayoutConstraint.activate([pad.leadingAnchor.constraint(equalTo: box.leadingAnchor), pad.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                                     pad.topAnchor.constraint(equalTo: box.topAnchor), pad.bottomAnchor.constraint(equalTo: box.bottomAnchor)])
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.staticText)
        box.setAccessibilityLabel(label)
        return box
    }

    static func doneText(_ p: GroomResult.Proposal) -> String {
        switch p.kind {
        case .merge:
            let n = p.merged.count
            return "Kept. \(n) item\(n == 1 ? "" : "s") merged into it." + (p.description?.isEmpty == false ? " New description." : "")
        case .done: return "Done" + (p.evidence.first.map { ", with \($0)" } ?? "")
        case .obsolete: return "Cancelled: obsolete. \(p.reason)"
        case .fold: return "A sub-item of \(p.parent ?? "")"
        case .relate: return "\(GroomLine.relationWord(p.relation?.kind ?? "")) \(p.relation?.key ?? "")"
        default: return p.reason
        }
    }

    static func failWord(_ p: GroomResult.Proposal) -> String {
        switch p.kind {
        case .merge: return "Merge"
        case .done, .obsolete: return "Close"
        case .fold: return "Parent"
        case .relate: return "Relation"
        default: return "Change"
        }
    }
}

/// One line of the review. Space or a click selects or clears it. The arrow keys move between lines.
final class GroomLine: Row {
    private weak var panel: GroomPanel?
    private var desc: Disclosure?

    init(_ p: GroomResult.Proposal, checked: Bool?, member title: @escaping (String) -> String?, panel: GroomPanel) {
        self.panel = panel
        let t = p.kind.tag
        let body = NSStackView(v: [], spacing: 4)
        var first: [NSView] = [Chiplet("\(t.mark) \(t.word)" + (p.kind == .merge ? " \(p.keys.count)" : ""), color: t.color,
                                       fill: t.color.withAlphaComponent(0.14))]
        switch p.kind {
        case .merge:
            first.append(NSTextField.text(p.title ?? title(p.keep ?? "") ?? "", size: 12.5, weight: .semibold))
        case .relate:
            first += [Chiplet(p.keys.first ?? "", mono: true), NSTextField.text(Self.relationWord(p.relation?.kind ?? "").lowercased(), size: 12, color: Palette.dim),
                      Chiplet(p.relation?.key ?? "", mono: true)]
        default:
            let key = p.keys.first ?? ""
            first += [Chiplet(key, mono: true), NSTextField.text(title(key) ?? "", size: 12.5, weight: .semibold)]
        }
        if p.keys.count > 1 && p.kind != .merge { first.append(NSTextField.text("+\(p.keys.count - 1) more", size: 12, color: Palette.dim)) }
        body.addArrangedSubview(NSStackView(h: first, spacing: 6))
        if p.kind == .merge, let keep = p.keep {
            for k in [keep] + p.merged {
                let role = NSTextField.text(k == keep ? "KEEPS" : "MERGES", size: 10, weight: .semibold, color: k == keep ? Palette.intake : Palette.dim)
                role.widthAnchor.constraint(equalToConstant: 52).isActive = true
                body.addArrangedSubview(NSStackView(h: [role, Chiplet(k, mono: true), NSTextField.text(title(k) ?? "", size: 12, color: Palette.mut)], spacing: 8))
            }
        }
        if p.kind == .fold, let parent = p.parent {
            body.addArrangedSubview(NSTextField.text("A sub-item of \(parent)" + (title(parent).map { ": \($0)" } ?? "") + ". It stays open.",
                                                     size: 12, color: Palette.mut))
        }
        body.addArrangedSubview(NSTextField.text(p.reason, size: 12, color: Palette.mut, lines: 4))
        if !p.evidence.isEmpty {
            body.addArrangedSubview(NSStackView(h: p.evidence.prefix(4).map { Chiplet($0, mono: true) }, spacing: 6))
        }
        var disclosure: Disclosure?
        if p.kind == .merge, let text = p.description, !text.isEmpty, let keep = p.keep {
            let d = Disclosure("New description of \(keep)", id: "groom:" + p.id)
            d.add(Padded(NSTextField.text(text, size: 12, lines: 30)))
            body.addArrangedSubview(d)
            disclosure = d
        }
        let box: NSView
        if let checked {
            let g = Glyph(checked ? "checkmark.square.fill" : "square", color: checked ? Palette.intake : Palette.dim, size: 14)
            box = g
        } else {
            box = NSView()
            box.widthAnchor.constraint(equalToConstant: 14).isActive = true
        }
        let conf = NSTextField.text(p.confidence == .sure ? "sure ▮▮▮" : "maybe ▮▮▯", size: 11, color: Palette.dim, mono: true)
        let row = NSStackView(h: [box, body, Spacer(), conf], spacing: 10, align: .top)
        super.init([row], height: 36, inset: 14, label: nil, onClick: nil)
        desc = disclosure
        restFill = Palette.bg
        alphaValue = checked == false ? 0.6 : 1
        let words = "\(t.word): " + (p.kind == .merge ? "keep \(p.keep ?? ""), merge \(p.merged.joined(separator: ", "))" : p.keys.joined(separator: ", "))
        setAccessibilityLabel("\(words). \(p.reason). \(p.confidence == .sure ? "Sure" : "Maybe").")
        if let checked {
            setAccessibilityRole(.checkBox)
            setAccessibilityValue(checked ? 1 : 0)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    // A vague line has no click, but it takes the focus for the arrow keys.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 125: panel?.move(from: self, by: 1)
        case 126: panel?.move(from: self, by: -1)
        case 124: desc?.toggle()
        default: super.keyDown(with: event)
        }
    }

    static func relationWord(_ kind: String) -> String {
        ["blocked_by": "Blocked by", "blocks": "Blocks", "relates_to": "Relates to", "duplicate": "Duplicate of"][kind] ?? kind
    }
}

// The lines of a review or a result. They scroll above `cap`. The fit is below the window size (500) and above
// the Intake table (490): the table gets smaller first, and a long review cannot make the window taller.
// A rebuild (a toggle) keeps the position.
private final class GroomBody: NSScrollView {
    private static var offsets: [String: CGFloat] = [:]
    private let keep: String
    private var restored = false
    private var observer: Any?

    override var scrollerStyle: NSScroller.Style { get { .overlay } set {} }

    init(_ body: NSView, keep: String, cap: CGFloat = 320) {
        self.keep = keep
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        drawsBackground = false
        hasVerticalScroller = true
        autohidesScrollers = true
        let doc = Flipped()
        doc.translatesAutoresizingMaskIntoConstraints = false
        body.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(body)
        documentView = doc
        let fit = heightAnchor.constraint(equalTo: doc.heightAnchor)
        fit.priority = .init(495)
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), doc.widthAnchor.constraint(equalTo: contentView.widthAnchor),
            doc.topAnchor.constraint(equalTo: contentView.topAnchor),
            body.leadingAnchor.constraint(equalTo: doc.leadingAnchor), body.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            body.topAnchor.constraint(equalTo: doc.topAnchor), body.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            heightAnchor.constraint(lessThanOrEqualToConstant: cap), heightAnchor.constraint(greaterThanOrEqualToConstant: min(cap, 120)), fit,
        ])
        contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) {
            [weak self] _ in
            guard let self, self.restored else { return }
            GroomBody.offsets[self.keep] = self.contentView.bounds.minY
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// A new run starts at the top.
    static func forget(_ pk: String) { offsets = offsets.filter { !$0.key.hasPrefix(pk + ".") } }

    override func layout() {
        super.layout()
        guard !restored, let doc = documentView, contentView.bounds.height > 0 else { return }
        restored = true
        let y = min(GroomBody.offsets[keep] ?? 0, max(0, doc.frame.height - contentView.bounds.height))
        guard y > 0 else { return }
        contentView.scroll(to: NSPoint(x: 0, y: y))
        reflectScrolledClipView(contentView)
    }
}
