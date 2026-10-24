import Cocoa
import OverSireCore
import OverSireSync
import OverSireAssistant

// ─── Session chat ────────────────────────────────────────────────────────────
// The chat view of an `oversire` runtime session through the daemon of its machine (OVERSIRE-286).
// The turns merge by seq. Each turn is a row; the first row of each speaker shows "You" or "Agent" and the time.

final class SessionChatCard: Card, LiveSessionCard, NSTextFieldDelegate {
    /// The newest turns that the card shows. "Show earlier turns" adds more.
    static let page = 60

    let sessionID: String
    private let agent: String
    private let stream: SessionStream
    private let ctx = StreamContext()
    private let chips = NSStackView(h: [], spacing: 6)
    private var headChips: [NSView] = []
    private var since: Date?
    private let earlier = ActionButton("Show earlier turns", symbol: "chevron.up", style: .link)
    private lazy var earlierRow = NSStackView.cardRow([earlier, Spacer()], top: 6, bottom: 2)
    private let list = NSStackView(v: [], spacing: 0)
    private lazy var empty = NSStackView.cardRow([NSTextField.text("No turns yet.", size: 12, color: Palette.dim)], top: 12, bottom: 12)
    private let field = NSTextField()
    private let sendButton = ActionButton("Send", style: .primary)
    private let stopButton = ActionButton("Stop turn")
    private let note = NSTextField.text("", size: 11.5, color: Palette.dim, lines: 2)
    private let composer = Box(fill: Palette.raise, border: nil, radius: 0)
    private let ended = NSTextField.text("", size: 11.5, color: Palette.dim, lines: 2)
    private lazy var endedRow = NSStackView.cardRow([ended], top: 8, bottom: 8)
    private var listener: Task<Void, Never>?
    private(set) var book = TurnBook()
    private(set) var link = StreamLink.connecting { didSet { refresh() } }
    private var shown = SessionChatCard.page
    private var rendered: [Int: (turn: SessionTurn, first: Bool, view: NSView)] = [:]
    private var sending = false

    init(sessionID: String, agent: String, stream: SessionStream, trailing: [NSView]) {
        self.sessionID = sessionID
        self.agent = agent
        self.stream = stream
        super.init(padding: 0, spacing: 0)
        list.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        list.setAccessibilityElement(true)
        list.setAccessibilityRole(.list)
        list.setAccessibilityLabel("Turns of the session")
        earlier.onClick = { [weak self] in
            guard let self else { return }
            self.shown += Self.page
            self.render()
        }
        field.placeholderString = "Message the session. Return sends, Shift+Return adds a line."
        field.setAccessibilityLabel("Message to the session")
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 6
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: 12.5)
        field.delegate = self
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        sendButton.onClick = { [weak self] in self?.sendText() }
        stopButton.onClick = { [weak self] in self?.interrupt() }
        stopButton.setAccessibilityLabel("Stop the current turn")
        note.setContentHuggingPriority(.init(1), for: .horizontal)
        let inner = NSStackView(v: [field, NSStackView(h: [note, stopButton, sendButton], spacing: 8)], spacing: 6)
        inner.arrangedSubviews.forEach { $0.widthAnchor.constraint(equalTo: inner.widthAnchor, constant: -28).isActive = true }
        inner.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        inner.translatesAutoresizingMaskIntoConstraints = false
        composer.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: composer.leadingAnchor), inner.trailingAnchor.constraint(equalTo: composer.trailingAnchor),
            inner.topAnchor.constraint(equalTo: composer.topAnchor), inner.bottomAnchor.constraint(equalTo: composer.bottomAnchor),
        ])
        let title = NSTextField.text("Session", size: 13, weight: .semibold)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        add(NSStackView.cardRow([title, chips, Spacer()] + trailing))
        add(CardRule())
        add(earlierRow)
        add(list)
        add(empty)
        add(CardRule())
        add(composer)
        add(endedRow)
        render()
        listener = Task { [weak self, stream] in
            for await e in stream.events() {
                await MainActor.run { self?.handle(e) }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { stop() }

    func stop() {
        listener?.cancel()
        listener = nil
        Task { [stream] in await stream.stop() }
    }

    func setHead(_ views: [NSView], since: Date?) {
        headChips = views
        self.since = since
        refresh()
    }

    // MARK: Stream events

    func handle(_ e: SessionStream.Event) {
        switch e {
        case .attached(let a):
            note.stringValue = ""
            link = .live(a)
        case .turns(let ts):
            if book.merge(ts) { render() }
        case .ended(let reason):
            link = .ended(StreamLink.endText(reason))
        case .failed(_, let message):
            note.stringValue = message
            refresh()
        case .disconnected(let reason, let stopped):
            link = stopped ? .ended(reason) : .lost(reason)
        case .connecting, .snapshot, .output, .resized, .lease:
            break
        }
    }

    // MARK: Turns

    private func render() {
        let turns = Array(book.turns.suffix(shown))
        var next: [Int: (turn: SessionTurn, first: Bool, view: NSView)] = [:]
        let views = turns.enumerated().map { i, t -> NSView in
            let first = i == 0 || (turns[i - 1].role == .user) != (t.role == .user)
            let v = rendered[t.seq].flatMap { $0.turn == t && $0.first == first ? $0.view : nil } ?? row(t, first: first, rule: i > 0)
            next[t.seq] = (t, first, v)
            return v
        }
        rendered = next
        // Keep the views that stay at the top, so the Markdown views do not load again.
        let current = list.arrangedSubviews
        var same = 0
        while same < min(current.count, views.count), current[same] === views[same] { same += 1 }
        current[same...].forEach { $0.removeFromSuperview() }
        views[same...].forEach { list.addFull($0) }
        earlierRow.isHidden = book.turns.count <= shown
        empty.isHidden = !book.turns.isEmpty
        refresh()
    }

    /// One turn. first: the first turn of a speaker, with the name and the time, and a line above it.
    private func row(_ t: SessionTurn, first: Bool, rule: Bool) -> NSView {
        let you = t.role == .user
        let who = NSStackView(v: [], spacing: 1)
        if first {
            who.addArrangedSubview(NSTextField.text(you ? "You" : "Agent", size: 12, weight: .semibold))
            who.addArrangedSubview(NSTextField.text(Self.clock.string(from: t.at), size: 11.5, color: Palette.dim))
        }
        who.widthAnchor.constraint(equalToConstant: 74).isActive = true
        let content: NSView
        switch t.role {
        case .user:
            let text = NSTextField.text(t.text, size: 12.5, lines: 0)
            text.isSelectable = true
            content = text
        case .assistant:
            let md = MarkdownBlock(ctx: ctx)
            md.show(t.text)
            content = md
        case .tool:
            content = ToolLine(t.tool ?? TurnTool(name: "Tool", status: .done))
        case .system:
            let text = NSTextField.text(t.text, size: 12, color: Palette.mut, lines: 0)
            text.isSelectable = true
            content = NSStackView(h: [Glyph("info.circle", color: Palette.dim, size: 11), text, Spacer()], spacing: 6)
        }
        content.setContentHuggingPriority(.init(1), for: .horizontal)
        let line = NSStackView(h: [who, content], spacing: 12, align: .top)
        line.edgeInsets = NSEdgeInsets(top: first ? 10 : 2, left: 14, bottom: 4, right: 14)
        line.translatesAutoresizingMaskIntoConstraints = false
        let box = Box(fill: you ? Palette.acc.withAlphaComponent(0.05) : nil, border: nil, radius: 0)
        box.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: box.leadingAnchor), line.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            line.topAnchor.constraint(equalTo: box.topAnchor), line.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel("\(you ? "You" : agent): \(t.tool.map { "\($0.name) \($0.input ?? "")" } ?? t.text)")
        guard first && rule else { return box }
        let v = NSStackView(v: [], spacing: 0)
        v.addFull(CardRule())
        v.addFull(box)
        return v
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    // MARK: Composer

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.insertNewline(_:)) else { return false }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertNewlineIgnoringFieldEditor(nil)
        } else {
            sendText()
        }
        return true
    }

    private func sendText() {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !sending, link.isLive else { return }
        sending = true
        refresh()
        Task { [weak self, stream] in
            var failure: String?
            do { try await stream.send(text: text) } catch { failure = (error as? ProviderError)?.message ?? error.localizedDescription }
            await MainActor.run {
                guard let self else { return }
                self.sending = false
                if let failure { self.note.stringValue = "Could not send: \(failure)" } else { self.field.stringValue = "" }
                self.refresh()
            }
        }
    }

    private func interrupt() {
        Task { [weak self, stream] in
            var failure: String?
            do { try await stream.interrupt() } catch { failure = (error as? ProviderError)?.message ?? error.localizedDescription }
            await MainActor.run {
                guard let self else { return }
                self.note.stringValue = failure.map { "Could not stop the turn: \($0)" } ?? "The agent stops the turn."
                self.refresh()
            }
        }
    }

    private func refresh() {
        var views = [link.chip] + headChips
        var drop: [NSView] = headChips.reversed()
        if let a = book.turns.suffix(shown).first?.seq, let b = book.turns.last?.seq {
            views.append(NSTextField.text("turns \(a)–\(b)", size: 11.5, color: Palette.dim))
            drop.insert(views[views.count - 1], at: 0)
        }
        if let since {
            views.append(sinceLabel(since))
            drop.insert(views[views.count - 1], at: 0)
        }
        chips.setChips(views, drop: drop)
        var open = false
        if case .live(let a) = link { open = a.writable }
        field.isEnabled = open
        stopButton.isEnabled = open
        if sending {
            sendButton.busy("Sending…")
        } else {
            sendButton.done()
            sendButton.isEnabled = open
        }
        var gone: String?
        if let n = link.note { gone = n == book.turns.last?.text ? nil : n }
        if case .ended = link {
            composer.isHidden = true
            ended.stringValue = gone ?? ""
        } else {
            composer.isHidden = false
            ended.stringValue = ""
            if let gone { note.stringValue = gone }
        }
        endedRow.isHidden = ended.stringValue.isEmpty
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }
}

/// One tool call of the agent: status, name and input, and the start of the result on the right.
final class ToolLine: Box {
    init(_ tool: TurnTool) {
        super.init(fill: Palette.raise, border: Palette.line, radius: 6)
        let status: NSView
        let word: String
        switch tool.status {
        case .done: status = Glyph("checkmark", color: Palette.ok, size: 10); word = "done"
        case .failed: status = Glyph("xmark", color: Palette.bad, size: 10); word = "failed"
        case .running: status = Glyph("circle.dotted", color: Palette.run, size: 10); word = "running"
        }
        let input = tool.input?.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        let call = NSTextField.text(input.isEmpty ? tool.name : "\(tool.name) \(input)", size: 11.5, color: Palette.mut, mono: true)
        call.lineBreakMode = .byTruncatingTail
        call.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let result = tool.summary?.split(separator: "\n", maxSplits: 1).first.map { String($0.prefix(48)) } ?? ""
        let stat = NSTextField.text(result, size: 11.5, color: tool.status == .failed ? Palette.bad : Palette.dim)
        stat.lineBreakMode = .byTruncatingTail
        let row = NSStackView(h: [status, call, Spacer(), stat], spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 3, left: 8, bottom: 3, right: 8)
        row.setHuggingPriority(.required, for: .vertical)
        [call, stat].forEach { $0.setContentCompressionResistancePriority(.required, for: .vertical) }
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor), row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor), row.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        toolTip = [tool.input, tool.summary].compactMap { $0 }.joined(separator: "\n\n")
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(tool.name) \(input), \(word). \(result)")
    }
    required init?(coder: NSCoder) { fatalError() }
}
