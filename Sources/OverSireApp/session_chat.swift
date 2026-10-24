import Cocoa
import OverSireCore
import OverSireSync
import OverSireAssistant

// ─── Session chat ────────────────────────────────────────────────────────────
// The chat view of an `oversire` runtime session through the daemon of its machine (OVERSIRE-286).
// The turns merge by seq. Consecutive tool turns fold into one group.

final class SessionChatCard: Card, LiveSessionCard, NSTextFieldDelegate {
    /// The newest turns that the card shows. "Show earlier turns" adds more.
    static let page = 60

    let sessionID: String
    var onStop: (() -> Void)?
    private let agent: String
    private let stream: SessionStream
    private let ctx = StreamContext()
    private let head = NSStackView(h: [], spacing: 6)
    private let headline = NSTextField.text("", size: 12.5, color: Palette.mut, lines: 3)
    private let chips = NSStackView(h: [], spacing: 6)
    private let earlier = ActionButton("Show earlier turns", symbol: "chevron.up", style: .link)
    private let list = NSStackView(v: [], spacing: 10)
    private let empty = NSTextField.text("No turns yet.", size: 12, color: Palette.dim)
    private let field = NSTextField()
    private let sendButton = ActionButton("Send", style: .primary)
    private let stopButton = ActionButton("Stop", symbol: "stop.circle")
    private lazy var composer = NSStackView(h: [field, sendButton, stopButton], spacing: 6)
    private let note = NSTextField.text("", size: 11.5, color: Palette.dim, lines: 2)
    private let footer = NSStackView(h: [], spacing: 6)
    private var listener: Task<Void, Never>?
    private(set) var book = TurnBook()
    private(set) var link = StreamLink.connecting { didSet { refresh() } }
    private var shown = SessionChatCard.page
    private var rendered: [String: (block: Block, view: NSView)] = [:]
    private var sending = false

    private enum Block: Hashable {
        case turn(SessionTurn)
        case tools([SessionTurn])

        var key: String {
            switch self {
            case .turn(let t): return "t\(t.seq)"
            case .tools(let ts): return "g\(ts.first?.seq ?? 0)"
            }
        }
    }

    init(sessionID: String, agent: String, stream: SessionStream, trailing: [NSView]) {
        self.sessionID = sessionID
        self.agent = agent
        self.stream = stream
        super.init(title: "Chat", trailing: trailing)
        list.setAccessibilityElement(true)
        list.setAccessibilityRole(.list)
        list.setAccessibilityLabel("Turns of the session")
        earlier.onClick = { [weak self] in
            guard let self else { return }
            self.shown += Self.page
            self.render()
        }
        field.placeholderString = "Send to the session… Return sends, Shift-Return adds a line."
        field.setAccessibilityLabel("Message to the session")
        field.usesSingleLineMode = false
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 6
        field.delegate = self
        sendButton.onClick = { [weak self] in self?.sendText() }
        stopButton.onClick = { [weak self] in self?.onStop?() }
        stopButton.setAccessibilityLabel("Stop the session")
        add(head)
        add(headline)
        add(chips)
        // Not full width: the button hugs at 1000.
        body.addArrangedSubview(earlier)
        add(list)
        add(empty)
        add(composer)
        add(note)
        add(footer)
        setHead([], headline: nil, footer: nil)
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

    func setHead(_ views: [NSView], headline text: String?, footer row: NSView?) {
        head.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach { head.addArrangedSubview($0) }
        head.isHidden = views.isEmpty
        headline.stringValue = text ?? ""
        headline.isHidden = headline.stringValue.isEmpty
        footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let row { footer.addArrangedSubview(row) }
        footer.isHidden = row == nil
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
        var blocks: [Block] = []
        for t in book.turns.suffix(shown) {
            if t.role == .tool, t.tool != nil {
                if case .tools(let ts)? = blocks.last {
                    blocks[blocks.count - 1] = .tools(ts + [t])
                } else {
                    blocks.append(.tools([t]))
                }
            } else {
                blocks.append(.turn(t))
            }
        }
        var next: [String: (block: Block, view: NSView)] = [:]
        let views = blocks.map { b -> NSView in
            let v = rendered[b.key].flatMap { $0.block == b ? $0.view : nil } ?? make(b)
            next[b.key] = (b, v)
            return v
        }
        rendered = next
        // Keep the views that stay at the top, so the Markdown views do not load again.
        let current = list.arrangedSubviews
        var same = 0
        while same < min(current.count, views.count), current[same] === views[same] { same += 1 }
        current[same...].forEach { $0.removeFromSuperview() }
        views[same...].forEach { list.addFull($0) }
        earlier.isHidden = book.turns.count <= shown
        empty.isHidden = !book.turns.isEmpty
        refresh()
    }

    private func make(_ b: Block) -> NSView {
        switch b {
        case .tools(let ts):
            return ToolGroupView(ts.map(Self.chip), ctx: ctx, canRetry: false)
        case .turn(let t):
            switch t.role {
            case .user:
                return UserBubble([.text(t.text)], caption: nil, ctx: ctx)
            case .assistant:
                let md = MarkdownBlock(ctx: ctx)
                md.show(t.text)
                let who = NSStackView(h: [Glyph("cpu", color: Palette.dim, size: 11), NSTextField.text(agent, size: 11.5, weight: .medium, color: Palette.mut),
                                          NSTextField.text(Self.clock.string(from: t.at), size: 11, color: Palette.dim), Spacer()], spacing: 5)
                let v = NSStackView(v: [], spacing: 4)
                v.addFull(who)
                v.addFull(md)
                v.setAccessibilityElement(true)
                v.setAccessibilityRole(.group)
                v.setAccessibilityLabel("\(agent): \(t.text)")
                return v
            case .system, .tool:
                let text = NSTextField.text(t.text, size: 12, color: Palette.mut, lines: 0)
                text.isSelectable = true
                return NSStackView(h: [Glyph("info.circle", color: Palette.dim, size: 11), text, Spacer()], spacing: 6)
            }
        }
    }

    static func chip(_ t: SessionTurn) -> ToolChip {
        let tool = t.tool ?? TurnTool(name: "Tool", status: .done)
        let state: ToolChip.State
        switch tool.status {
        case .running: state = .running
        case .done: state = .ok
        case .failed: state = .failed
        }
        let input = tool.input ?? ""
        let line = input.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
        return ToolChip(id: "turn-\(t.seq)", state: state, source: tool.name, line: line, time: nil, input: input, output: tool.summary)
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

    private func refresh() {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chips.addArrangedSubview(link.pill)
        chips.addArrangedSubview(Chiplet("\(book.turns.count) turns", symbol: "text.bubble", mono: false))
        chips.addArrangedSubview(Spacer())
        if let n = link.note { note.stringValue = n == book.turns.last?.text ? "" : n }
        note.isHidden = note.stringValue.isEmpty
        var open = false
        if case .live(let a) = link { open = a.writable }
        field.isEnabled = open
        if sending {
            sendButton.busy("Sending…")
        } else {
            sendButton.done()
            sendButton.isEnabled = open
        }
        if case .ended = link { composer.isHidden = true } else { stopButton.isHidden = onStop == nil }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }
}
