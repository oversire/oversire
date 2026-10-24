import Cocoa
import SwiftTerm
import OverSireCore
import OverSireSync

// ─── Live terminal ───────────────────────────────────────────────────────────
// The terminal of a session through the daemon of its machine (OVERSIRE-285). SwiftTerm draws the screen.
// The card starts in view mode. "Take control" sends the keys and, on a live stream, the size of this view.

/// A card that shows a session through its stream. The page keeps it over reloads.
protocol LiveSessionCard: NSView {
    var sessionID: String { get }
    func stop()
    func setHead(_ views: [NSView], headline: String?, footer: NSView?)
}

/// The link of a stream, as the cards show it.
enum StreamLink: Equatable {
    case connecting
    case live(StreamAttached)
    case lost(String)
    case ended(String)

    var pill: NSView {
        switch self {
        case .connecting: return Pill(.running, text: "Connecting…")
        case .live(let a) where a.source == .poll:
            let p = Pill(.warning, text: "Text only")
            p.toolTip = a.reason
            return p
        case .live: return Pill(.ok, text: "Live")
        case .lost(let reason):
            let p = Pill(.bad, text: "Disconnected")
            p.toolTip = reason
            return p
        case .ended: return Pill(.idle, text: "Ended")
        }
    }

    /// The text under the card, or nil.
    var note: String? {
        switch self {
        case .lost(let reason): return reason + " OverSire connects again."
        case .ended(let reason): return reason
        case .connecting, .live: return nil
        }
    }

    var isLive: Bool { if case .live = self { return true }; return false }

    static func endText(_ reason: String) -> String {
        switch reason {
        case "exited": return "The session ended."
        case "closed": return "The runtime closed the terminal."
        default: return "The stream ended: \(reason)."
        }
    }
}

final class LiveTerminalCard: Card, TerminalViewDelegate, LiveSessionCard {
    let sessionID: String
    /// The parts of the page: the status chips, the headline and the reply row.
    private let head = NSStackView(h: [], spacing: 6)
    private let headline = NSTextField.text("", size: 12.5, color: Palette.mut, lines: 3)
    private let footer = NSStackView(h: [], spacing: 6)
    private let stream: SessionStream
    private let term: TerminalView
    private let scroll = NSScrollView()
    private let chips = NSStackView(h: [], spacing: 6)
    private let control = ActionButton("Take control", symbol: "keyboard")
    private let note = NSTextField.text("", size: 11.5, color: Palette.dim, lines: 2)
    private var listener: Task<Void, Never>?
    private(set) var link = StreamLink.connecting { didSet { refresh() } }
    private(set) var holder = LeaseHolder.none { didSet { refresh() } }
    private(set) var controlling = false { didSet { refresh() } }
    private var remote: (cols: Int, rows: Int)?

    init(sessionID: String, stream: SessionStream, trailing: [NSView], height: CGFloat = 360) {
        self.sessionID = sessionID
        self.stream = stream
        term = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: height),
                            font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular))
        super.init(title: "Terminal", trailing: trailing)
        term.terminalDelegate = self
        term.nativeBackgroundColor = Palette.term
        term.nativeForegroundColor = Palette.termFg
        term.optionAsMetaKey = false
        term.allowMouseReporting = false
        term.setAccessibilityLabel("Terminal of the session")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = TopClip()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Palette.term
        scroll.documentView = term
        scroll.heightAnchor.constraint(equalToConstant: height).isActive = true
        let frame = Box(fill: Palette.term, border: Palette.line, radius: 8)
        frame.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: frame.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: frame.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: frame.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: frame.bottomAnchor, constant: -6),
        ])
        control.onClick = { [weak self] in self?.toggleControl() }
        control.setAccessibilityLabel("Take control of the terminal")
        add(head)
        add(headline)
        add(NSStackView(h: [chips, Spacer(), control], spacing: 6))
        add(frame)
        add(note)
        add(footer)
        setHead([], headline: nil, footer: nil)
        refresh()
        listener = Task { [weak self, stream] in
            for await e in stream.events() {
                await MainActor.run { self?.handle(e) }
            }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { stop() }

    /// Closes the stream. The page calls it when the card goes away.
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
        case .connecting, .turns:
            // A lost link shows its reason until the stream attaches again.
            break
        case .attached(let a):
            link = .live(a)
            note.stringValue = a.source == .poll ? (a.reason ?? "The view is text only.") : ""
            if controlling && a.resizable {
                fitToView()
            } else if a.cols > 0, a.rows > 0 {
                show(cols: a.cols, rows: a.rows)
            }
        case .snapshot(let d):
            term.feed(text: "\u{1b}c")
            term.feed(byteArray: ArraySlice([UInt8](d)))
        case .output(let d):
            term.feed(byteArray: ArraySlice([UInt8](d)))
        case .resized(let cols, let rows):
            if !(controlling && holder == .you) { show(cols: cols, rows: rows) }
        case .lease(let h):
            holder = h
            if h != .you, controlling, case .live(let a) = link, a.resizable { controlling = false }
        case .ended(let reason):
            controlling = false
            link = .ended(StreamLink.endText(reason))
        case .failed(_, let message):
            note.stringValue = message
        case .disconnected(let reason, let stopped):
            controlling = false
            link = stopped ? .ended(reason) : .lost(reason)
        }
    }

    // MARK: Size

    /// View mode: the terminal has the size of the remote terminal. The scroll view scrolls when it is larger.
    private func show(cols: Int, rows: Int) {
        remote = (cols, rows)
        term.resize(cols: cols, rows: rows)
        term.setFrameSize(term.getOptimalFrameSize().size)
        refresh()
    }

    /// Control of a live stream: the terminal takes the size of the view, and the daemon gets that size.
    private func fitToView() {
        term.setFrameSize(scroll.contentSize)
        let t = term.getTerminal()
        Task { [stream] in await stream.control(cols: t.cols, rows: t.rows) }
        refresh()
    }

    func toggleControl() {
        guard case .live(let a) = link, a.writable else { return }
        if controlling {
            controlling = false
            if a.resizable {
                Task { [stream] in await stream.release() }
                if let r = remote { show(cols: r.cols, rows: r.rows) }
            }
            return
        }
        controlling = true
        if a.resizable { fitToView() }
        window?.makeFirstResponder(term)
    }

    // MARK: Chips

    private func refresh() {
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var views = [link.pill]
        var writable = false
        if case .live(let a) = link { writable = a.writable }
        if let n = link.note { note.stringValue = n }
        if controlling {
            views.append(Chiplet("You type", symbol: "keyboard", color: Palette.fg))
        } else {
            switch holder {
            case .other: views.append(Chiplet("Another viewer has the size", symbol: "person.2"))
            case .desktop: views.append(Chiplet("The desktop has the size", symbol: "desktopcomputer"))
            case .you, .none: views.append(Chiplet("View mode", symbol: "eye"))
            }
        }
        let t = term.getTerminal()
        views.append(Chiplet("\(t.cols)×\(t.rows)", mono: true))
        views.forEach { chips.addArrangedSubview($0) }
        control.title = controlling ? "Give back" : "Take control"
        control.image = NSImage(systemSymbolName: controlling ? "hand.raised" : "keyboard", accessibilityDescription: nil)
        control.setAccessibilityLabel(controlling ? "Give back control of the terminal" : "Take control of the terminal")
        control.isEnabled = writable
        note.isHidden = note.stringValue.isEmpty
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard controlling else {
            note.stringValue = "View mode. Click Take control to type in the session."
            note.isHidden = false
            return
        }
        let d = Data(data)
        Task { [stream] in await stream.input(d) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        refresh()
        guard controlling, case .live(let a) = link, a.resizable else { return }
        Task { [stream] in await stream.control(cols: newCols, rows: newRows) }
    }

    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

    func clipboardCopy(source: TerminalView, content: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: content, as: UTF8.self), forType: .string)
    }

    override func layout() {
        super.layout()
        if controlling, case .live(let a) = link, a.resizable, term.frame.size != scroll.contentSize { fitToView() }
    }
}

/// Keeps a small terminal at the top left of the scroll view.
private final class TopClip: NSClipView {
    override var isFlipped: Bool { true }
}

/// The terminal of one session in its own window. Each window has its own stream.
final class LiveTerminalWindow: NSWindowController, NSWindowDelegate {
    private static var open: [String: LiveTerminalWindow] = [:]
    private let card: LiveTerminalCard

    static func show(sessionID: String, title: String, stream: SessionStream) {
        if let w = open[sessionID] { w.window?.makeKeyAndOrderFront(nil); return }
        let w = LiveTerminalWindow(sessionID: sessionID, title: title, stream: stream)
        open[sessionID] = w
        w.showWindow(nil)
    }

    private init(sessionID: String, title: String, stream: SessionStream) {
        card = LiveTerminalCard(sessionID: sessionID, stream: stream, trailing: [], height: 560)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = title
        win.isReleasedWhenClosed = false
        let root = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            card.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            card.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
        ])
        win.contentView = root
        win.center()
        super.init(window: win)
        win.delegate = self
    }
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        card.stop()
        Self.open = Self.open.filter { $0.value !== self }
    }
}
