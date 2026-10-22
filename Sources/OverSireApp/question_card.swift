import Cocoa
import OverSireCore

// ─── Question card ───────────────────────────────────────────────────────────
// One question of the board. The card keeps the draft answer when the board changes.

/// Where the session of a question runs: "Orca · this Mac", "OverSire runner · mba".
struct QuestionPlace: Equatable {
    var runtime: String
    var host: String
    var local = true
    /// The runner is offline. The hub keeps a sent answer for 60 min.
    var offline = false

    var text: String { "\(runtime) · \(host)" }
}

/// The answer that the user builds on a card.
struct QuestionDraft: Equatable {
    var choices: [String: [String]] = [:]
    var others: [String: String] = [:]

    /// A multi item toggles the label. A single item keeps one choice and drops its free text.
    mutating func pick(_ label: String, in item: QuestionItem) {
        switch item.kind {
        case .multi:
            var c = choices[item.id] ?? []
            if let i = c.firstIndex(of: label) { c.remove(at: i) } else { c.append(label) }
            choices[item.id] = c
        case .single, .approve:
            choices[item.id] = choices[item.id] == [label] ? [] : [label]
            others[item.id] = nil
        case .free:
            break
        }
    }

    /// A free text on a single item takes the place of its choice.
    mutating func write(_ text: String, in item: QuestionItem) {
        others[item.id] = text
        if item.kind == .single, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { choices[item.id] = [] }
    }

    func picked(_ label: String, in item: QuestionItem) -> Bool { choices[item.id]?.contains(label) == true }

    func answer(_ q: SessionQuestion) -> QuestionAnswer {
        QuestionAnswer(question: q.id, items: q.items.map { item in
            let other = others[item.id]?.trimmingCharacters(in: .whitespacesAndNewlines)
            return .init(id: item.id, choices: choices[item.id] ?? [], other: other?.isEmpty == false ? other : nil)
        })
    }

    func isValid(_ q: SessionQuestion) -> Bool { (try? q.validate(answer(q))) != nil }
}

final class QuestionCard: Card, NSTextFieldDelegate {
    struct Actions {
        var send: (QuestionAnswer) -> Void = { _ in }
        var reveal: (() -> Void)?
        var dismiss: () -> Void = {}
        var stop: (() -> Void)?
        /// Each change of the draft, so a page rebuild keeps it.
        var draft: (QuestionDraft) -> Void = { _ in }
    }

    /// After this time the card shows an amber "Waits n min".
    static let waitsLong: TimeInterval = 30 * 60

    private(set) var entry: QuestionBoard.Entry
    private(set) var draft = QuestionDraft()
    private let place: QuestionPlace
    private let actions: Actions
    private let now: () -> Date
    private var checkedAt: Date?
    private var checked: NSTextField?
    private(set) var sendButton: ActionButton?
    private var optionRows: [String: NSStackView] = [:]
    private var fields: [String: NSTextField] = [:]
    private let dash = CAShapeLayer()

    init(_ e: QuestionBoard.Entry, place: QuestionPlace, checkedAt: Date?, draft: QuestionDraft = QuestionDraft(), now: @escaping () -> Date = Date.init,
         actions: Actions) {
        entry = e
        self.draft = draft
        self.place = place
        self.checkedAt = checkedAt
        self.now = now
        self.actions = actions
        super.init(spacing: 12)
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [5, 3]
        layer?.addSublayer(dash)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    var question: SessionQuestion { entry.question }

    /// Send is on when the question is open and each item has a valid answer.
    /// True while a text field of the card has the focus. A page does not rebuild then.
    var isTyping: Bool {
        guard let t = window?.firstResponder as? NSText, let f = t.delegate as? NSView else { return false }
        return f.isDescendant(of: self)
    }

    var canSend: Bool { entry.state == .open && question.answerable && draft.isValid(question) }

    /// A new entry redraws the card. The same entry only moves the "Checked" time.
    func update(_ e: QuestionBoard.Entry, checkedAt: Date?) {
        self.checkedAt = checkedAt
        guard e != entry else {
            checked?.stringValue = checkedText
            return
        }
        entry = e
        render()
    }

    func pick(_ index: Int, of itemID: String) {
        guard entry.state == .open, question.answerable, let item = question.items.first(where: { $0.id == itemID }),
              item.kind != .free, index < item.options.count else { return }
        draft.pick(item.options[index].label, in: item)
        actions.draft(draft)
        if item.kind != .multi { fields[item.id]?.stringValue = "" }
        if item.kind == .approve, canSend { send(); return }
        fillOptions(item)
        refreshSend()
    }

    func write(_ text: String, in itemID: String) {
        guard let item = question.items.first(where: { $0.id == itemID }) else { return }
        draft.write(text, in: item)
        actions.draft(draft)
        fillOptions(item)
        refreshSend()
    }

    func send() {
        guard canSend else { return }
        actions.send(draft.answer(question))
    }

    // MARK: Drawing

    private var isForm: Bool { !question.answerable }
    private var askedWord: String { question.origin.isIntake ? "Enhance asks" : "The session asks" }

    private func render() {
        body.clear()
        optionRows = [:]
        fields = [:]
        sendButton = nil
        checked = nil
        style()
        add(header())
        switch entry.state {
        case .open, .sending:
            if entry.stale {
                add(NSTextField.text("OverSire cannot reach \(place.text). The card shows the last read.", size: 12, color: Palette.warn, lines: 2))
            }
            if isForm {
                add(NSTextField.text("The session shows its own form in \(place.runtime). OverSire shows the questions, but cannot answer them.",
                                     size: 12, color: Palette.mut, lines: 2))
            }
            for (i, item) in question.items.enumerated() { add(block(item, index: i)) }
            if let error = entry.error { add(NSTextField.text("Could not send: \(error)", size: 12, color: Palette.bad, lines: 3)) }
            add(footer())
        case .answeredHere(let a, _):
            add(result(Tone(symbol: "checkmark.circle.fill", color: Palette.ok, word: "Answered"), title: "You answered",
                       lines: lines(a), pill: place.offline ? Pill(.queued, text: "Sent, the runner is offline") : Pill(.working, text: "Session works"),
                       dismiss: false))
        case .answeredElsewhere(let a, _):
            let missing = place.local ? "OverSire cannot read the answer."
                : "OverSire cannot read the answer on a remote \(place.runtime) server."
            add(result(Tone(symbol: "checkmark.circle", color: Palette.ok, word: "Answered"), title: "Answered in \(place.runtime)",
                       lines: a.map(lines) ?? [missing], pill: nil, dismiss: true))
        case .raced:
            add(result(.warning, title: "Already answered in \(place.runtime). OverSire did not send your answer.", lines: [], pill: nil, dismiss: true))
        case .gone:
            add(result(Tone(symbol: "minus.circle", color: Palette.dim, word: "Gone"),
                       title: "The question is gone. The session stopped, or you pressed Esc in \(place.runtime).", lines: [], pill: nil, dismiss: true))
        }
        let n = question.items.count
        setAccessibilityLabel("\(askedWord), \(n) question\(n == 1 ? "" : "s"), \(stateWord)")
    }

    private var stateWord: String {
        switch entry.state {
        case .open: return isForm ? "answer in \(place.runtime)" : "open"
        case .sending: return "sending"
        case .answeredHere: return "answered"
        case .answeredElsewhere: return "answered in \(place.runtime)"
        case .raced: return "already answered"
        case .gone: return "gone"
        }
    }

    private func style() {
        let open = entry.state == .open || entry.state == .sending
        fill = open ? Palette.panel : Palette.panel.withAlphaComponent(0.6)
        switch entry.state {
        case .open, .sending: border = isForm ? nil : entry.stale ? Palette.warn.withAlphaComponent(0.6) : Palette.acc.withAlphaComponent(0.6)
        case .raced: border = Palette.warn.withAlphaComponent(0.6)
        default: border = Palette.line
        }
        borderWidth = open && !isForm ? 1.5 : 1
        dash.isHidden = !(open && isForm)
        needsDisplay = true
    }

    override func updateLayer() {
        super.updateLayer()
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
        effectiveAppearance.performAsCurrentDrawingAppearance { dash.strokeColor = Palette.mut.cgColor }
    }

    // A wrapped label measures its height at its real width. Else the first narrow pass leaves a gap.
    override func layout() {
        super.layout()
        var changed = false
        func walk(_ v: NSView) {
            if let f = v as? NSTextField, f.maximumNumberOfLines != 1, !f.isEditable, f.frame.width > 0, f.preferredMaxLayoutWidth != f.frame.width {
                f.preferredMaxLayoutWidth = f.frame.width
                changed = true
            }
            v.subviews.forEach(walk)
        }
        walk(self)
        if changed { super.layout() }
        needsDisplay = true
    }

    private func header() -> NSView {
        let title = NSTextField.text(askedWord, size: 13, weight: .semibold)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        var views: [NSView] = [Glyph("sparkles", color: Palette.acc, size: 13), title,
                               Chiplet(place.text, symbol: place.local ? "desktopcomputer" : "network")]
        views.append(Chiplet(wayWord, symbol: isForm ? "rectangle.and.pencil.and.ellipsis" : "bubble.left.and.bubble.right"))
        if question.round > 1 { views.append(Chiplet("Round \(question.round)")) }
        views.append(Spacer())
        let waited = now().timeIntervalSince(question.askedAt)
        if entry.state == .open, waited >= Self.waitsLong {
            views.append(Pill(Tone(symbol: "clock.fill", color: Palette.warn, word: "Waits"), text: "Waits \(Self.span(waited))"))
        } else {
            let age = NSTextField.text(Self.span(waited) == "now" ? "now" : "\(Self.span(waited)) ago", size: 11.5, color: Palette.dim)
            age.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(age)
        }
        if entry.state == .open || entry.state == .sending, checkedAt != nil {
            let c = NSTextField.text(checkedText, size: 11.5, color: Palette.dim)
            checked = c
            views.append(c)
        }
        return NSStackView(h: views, spacing: 6)
    }

    private var wayWord: String {
        switch question.via {
        case .askReply: return "ask/reply"
        case .form: return "form in \(place.runtime)"
        case .runnerInput: return "runner"
        case .permission: return "permission"
        }
    }

    private var checkedText: String {
        guard let checkedAt else { return "" }
        let s = max(0, Int(now().timeIntervalSince(checkedAt)))
        return s < 60 ? "· Checked \(s) s ago" : "· Checked \(s / 60) min ago"
    }

    /// "now", "4 min", "1 h 5 min".
    static func span(_ t: TimeInterval) -> String {
        let m = Int(t / 60)
        if m < 1 { return "now" }
        if m < 60 { return "\(m) min" }
        return m % 60 == 0 ? "\(m / 60) h" : "\(m / 60) h \(m % 60) min"
    }

    private func block(_ item: QuestionItem, index: Int) -> NSView {
        let b = ItemBlock()
        b.pick = { [weak self] i in self?.pick(i, of: item.id) }
        b.send = { [weak self] in self?.send() }
        let col = NSStackView(v: [], spacing: 6)
        var head: [NSView] = []
        if question.items.count > 1 { head.append(NSTextField.text("\(index + 1)/\(question.items.count)", size: 11.5, weight: .semibold, color: Palette.dim)) }
        if let h = item.header, !h.isEmpty { head.append(Chiplet(h)) }
        if !head.isEmpty { col.addArrangedSubview(NSStackView(h: head + [Spacer()], spacing: 6)) }
        col.addFull(NSTextField.text(item.text, size: 13, weight: .medium, lines: 0))
        if let why = item.why, !why.isEmpty { col.addFull(NSTextField.text(why, size: 12, color: Palette.dim, lines: 0)) }
        if item.kind != .free && item.kind != .approve {
            let row = NSStackView(h: [], spacing: 6)
            optionRows[item.id] = row
            col.addFull(row)
            fillOptions(item)
        }
        if item.kind == .approve, let e = question.expiresAt {
            let m = max(0, Int((e.timeIntervalSince(now()) / 60).rounded(.up)))
            col.addFull(NSTextField.text(m == 0 ? "The time limit is reached." : "No answer in \(m) min is a deny.", size: 12, color: Palette.dim))
        }
        if item.kind == .free || item.allowsOther {
            let f = NSTextField(string: draft.others[item.id] ?? "")
            f.placeholderString = item.kind == .free ? "Your answer" : "Other: write your own answer"
            f.font = .systemFont(ofSize: 12.5)
            f.translatesAutoresizingMaskIntoConstraints = false
            f.delegate = self
            f.identifier = NSUserInterfaceItemIdentifier(item.id)
            f.isEnabled = entry.state == .open && !isForm
            f.setAccessibilityLabel(item.kind == .free ? "Answer to \(item.text)" : "Other answer to \(item.text)")
            fields[item.id] = f
            col.addFull(f)
        }
        b.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 8),
            col.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -8),
            col.topAnchor.constraint(equalTo: b.topAnchor, constant: 6),
            col.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -6),
        ])
        b.setAccessibilityElement(true)
        b.setAccessibilityRole(.group)
        b.setAccessibilityLabel("Question \(index + 1) of \(question.items.count): \(item.text)")
        b.setAccessibilityHelp(isForm ? nil : item.kind == .free ? "Write the answer, then press Return." : "Press 1 to \(min(9, item.options.count)) to pick an option.")
        return b
    }

    private func fillOptions(_ item: QuestionItem) {
        guard let row = optionRows[item.id] else { return }
        row.clear()
        let enabled = entry.state == .open && !isForm
        let n = item.options.count
        // Long labels go one under the other.
        row.orientation = item.options.map(\.label.count).reduce(0, +) > 70 ? .vertical : .horizontal
        row.alignment = row.orientation == .vertical ? .leading : .centerY
        for (i, o) in item.options.enumerated() {
            let on = draft.picked(o.label, in: item)
            let chip = ToggleChip(i < 9 ? "\(i + 1)  \(o.label)" : o.label, on: on, enabled: enabled) { [weak self] in self?.pick(i, of: item.id) }
            chip.keyFocus = false
            chip.toolTip = o.detail
            chip.setAccessibilityLabel("Option \(i + 1) of \(n): \(o.label)")
            chip.setAccessibilityHelp(o.detail)
            row.addArrangedSubview(chip)
        }
        if row.orientation == .horizontal { row.addArrangedSubview(Spacer()) }
    }

    private func footer() -> NSView {
        var views: [NSView] = []
        let sending = entry.state == .sending
        if isForm {
            if let reveal = actions.reveal { views.append(ActionButton("Answer in \(place.runtime) ↗", style: .primary) { reveal() }) }
            views.append(Spacer())
        } else if question.items.count == 1, let item = question.items.first, item.kind == .approve {
            let allow = ActionButton(QuestionItem.allow, style: .primary) { [weak self] in self?.pick(0, of: item.id) }
            let deny = ActionButton(QuestionItem.deny) { [weak self] in self?.pick(1, of: item.id) }
            if sending { allow.busy("Sending…"); deny.isEnabled = false }
            views += [allow, deny]
            if let reveal = actions.reveal { views.append(ActionButton("Open in \(place.runtime) ↗") { reveal() }) }
            views.append(Spacer())
        } else {
            let s = ActionButton("Send answers", style: .primary) { [weak self] in self?.send() }
            sendButton = s
            if sending { s.busy("Sending…") }
            views.append(s)
            if let reveal = actions.reveal {
                let o = ActionButton("Open in \(place.runtime) ↗") { reveal() }
                o.isEnabled = !sending
                views.append(o)
            }
            if let stop = actions.stop {
                let b = ActionButton("Stop", style: .danger) { stop() }
                b.isEnabled = !sending
                views.append(b)
            }
            views.append(Spacer())
            views.append(NSTextField.text(hint, size: 11.5, color: Palette.dim))
        }
        refreshSend()
        return NSStackView(h: views, spacing: 8)
    }

    private var hint: String {
        question.items.allSatisfy { $0.kind == .free } ? "Return sends" : "1–9 picks an option · Return sends"
    }

    private func refreshSend() {
        guard let s = sendButton, entry.state == .open else { return }
        s.isEnabled = canSend
        s.setAccessibilityHelp(canSend ? nil : "Answer each question first.")
    }

    private func result(_ tone: Tone, title: String, lines: [String], pill: Pill?, dismiss: Bool) -> NSView {
        let box = Box(fill: tone.color.withAlphaComponent(0.1), border: tone.color.withAlphaComponent(0.4), radius: 8)
        let col = NSStackView(v: [], spacing: 5)
        let t = NSTextField.text(title, size: 12.5, weight: .semibold, lines: 0)
        col.addFull(NSStackView(h: [Glyph(tone), t, Spacer()] + (pill.map { [$0] } ?? []), spacing: 6))
        for l in lines { col.addFull(NSTextField.text(l, size: 12.5, color: Palette.mut, lines: 0)) }
        if dismiss { col.addArrangedSubview(ActionButton("Dismiss", style: .link) { [weak self] in self?.actions.dismiss() }) }
        box.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10),
            col.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            col.topAnchor.constraint(equalTo: box.topAnchor, constant: 8),
            col.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        return box
    }

    /// One line for each item: "Which store? SQLite".
    private func lines(_ a: QuestionAnswer) -> [String] {
        var out = question.items.compactMap { item -> String? in
            guard let given = a.items.first(where: { $0.id == item.id }) else { return nil }
            let words = (given.choices + [given.other].compactMap { $0 }).joined(separator: ", ")
            return "\(item.header ?? item.text): \(words)"
        }
        if let n = a.note, !n.isEmpty { out.append("Note: \(n)") }
        return out
    }

    // MARK: Text fields

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField, let id = f.identifier?.rawValue else { return }
        write(f.stringValue, in: id)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        send()
        return true
    }
}

/// One item of a card. It takes focus: 1 to 9 pick an option, Return sends.
private final class ItemBlock: Box {
    var pick: (Int) -> Void = { _ in }
    var send: () -> Void = {}

    init() { super.init(fill: nil, border: nil, radius: 6) }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        if mods.isEmpty, let c = event.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) {
            pick(n - 1)
            return
        }
        if [36, 76].contains(event.keyCode) {
            send()
            return
        }
        super.keyDown(with: event)
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

extension SessionQuestion.Origin {
    var isIntake: Bool { if case .intake = self { return true } else { return false } }
}
