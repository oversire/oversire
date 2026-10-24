import Cocoa
import SwiftTerm
import OverSireCore
import OverSireSync

// ─── Live terminal ───────────────────────────────────────────────────────────
// The terminal of a session through the daemon of its machine (OVERSIRE-285). SwiftTerm draws the screen.
// Keys go to the session while the terminal has focus. "Take control" gives the session the size of this view.
// A text only source takes text from the "Send text" row.

/// A card that shows a session through its stream. The page keeps it over reloads.
protocol LiveSessionCard: NSView {
    var sessionID: String { get }
    func stop()
    /// The chips after the link chip: the agent and the place. The card adds "since <time>".
    func setHead(_ chips: [NSView], since: Date?)
}

/// The link of a stream, as the cards show it.
enum StreamLink: Equatable {
    case connecting
    case live(StreamAttached)
    case lost(String)
    case ended(String)

    var chip: NSView {
        switch self {
        case .connecting: return Chiplet("Connecting…", symbol: "circle.dotted", color: Palette.run)
        case .live(let a) where a.source == .poll:
            let c = Chiplet("Text only · every 1 s", symbol: "circle.dashed", color: Palette.warn)
            c.toolTip = a.reason
            return c
        case .live: return Chiplet("Live", symbol: "circle.fill", color: Palette.ok)
        case .lost(let reason):
            let c = Chiplet("Disconnected", symbol: "exclamationmark.triangle", color: Palette.bad)
            c.toolTip = reason
            return c
        case .ended: return Chiplet("Ended", symbol: "stop.circle", color: Palette.dim)
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

// MARK: Card parts

/// A line across a card with no padding.
final class CardRule: Box {
    init() {
        super.init(fill: Palette.line, border: nil, radius: 0)
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// A key and what it does: "⌘. leaves the terminal".
final class KeyHint: NSStackView {
    init(_ key: String, _ text: String) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
        let cap = Chiplet(key, color: Palette.mut, mono: true)
        addArrangedSubview(cap)
        addArrangedSubview(NSTextField.text(text, size: 11.5, color: Palette.dim))
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(key) \(text)")
    }
    required init?(coder: NSCoder) { fatalError() }
}

extension NSStackView {
    /// A row of a card with no padding: 14 points at the sides.
    static func cardRow(_ views: [NSView], spacing: CGFloat = 8, top: CGFloat = 9, bottom: CGFloat = 9) -> NSStackView {
        let s = NSStackView(h: views, spacing: spacing)
        s.edgeInsets = NSEdgeInsets(top: top, left: 14, bottom: bottom, right: 14)
        return s
    }

    /// Sets the chips of a card head. In a narrow row the stack drops the views of `drop` first, in that order.
    func setChips(_ views: [NSView], drop: [NSView]) {
        arrangedSubviews.forEach { removeArrangedSubview($0); $0.removeFromSuperview() }
        views.forEach { addArrangedSubview($0) }
        for (i, v) in drop.enumerated() { setVisibilityPriority(.init(Float(100 + i * 50)), for: v) }
        setClippingResistancePriority(.defaultLow, for: .horizontal)
    }
}

/// "since 10:52".
func sinceLabel(_ d: Date) -> NSTextField {
    let f = DateFormatter()
    f.timeStyle = .short
    f.dateStyle = .none
    return NSTextField.text("since " + f.string(from: d), size: 11.5, color: Palette.dim)
}

// MARK: Terminal card

final class LiveTerminalCard: Card, TerminalViewDelegate, LiveSessionCard {
    let sessionID: String
    /// The Machines page.
    var onDetails: (() -> Void)?
    /// Asks the daemon to connect the live view again.
    var onRetry: (() -> Void)?
    private let runtime: String
    private let place: String
    private let popped: Bool
    private let maxHeight: CGFloat
    private let stream: SessionStream
    private let term: SessionTerminal
    private let scroll = NSScrollView()
    private var scrollHeight: NSLayoutConstraint!
    private let chips = NSStackView(h: [], spacing: 6)
    private var headChips: [NSView] = []
    private var since: Date?
    private let take = ActionButton("Take control", symbol: "arrow.up.left.and.arrow.down.right")
    private let give = ActionButton("Give back", style: .primary)
    private let details = ActionButton("Machine details", symbol: "desktopcomputer")
    private let banner = Box(fill: Palette.panel, border: nil, radius: 0)
    private let bannerText = NSTextField.text("", size: 12.5, color: Palette.fg, lines: 0)
    private let retry = ActionButton("Retry")
    private let bannerRule = CardRule()
    private let footer = NSStackView.cardRow([], spacing: 10, top: 7, bottom: 7)
    private let textField = NSTextField()
    private var observer: NSKeyValueObservation?
    private var listener: Task<Void, Never>?
    private var failure: String?
    private var fittedWidth: CGFloat = 0
    private(set) var link = StreamLink.connecting { didSet { refresh() } }
    private(set) var holder = LeaseHolder.none { didSet { refresh() } }
    private(set) var controlling = false { didSet { refresh() } }
    private var focused = false { didSet { if focused != oldValue { refresh() } } }
    private var remote: (cols: Int, rows: Int)?

    /// runtime and place name the source: "Orca", "this Mac". popped: the card fills its own window.
    init(sessionID: String, stream: SessionStream, runtime: String, place: String, trailing: [NSView], maxHeight: CGFloat = 480, popped: Bool = false) {
        self.sessionID = sessionID
        self.stream = stream
        self.runtime = runtime
        self.place = place
        self.popped = popped
        self.maxHeight = maxHeight
        term = SessionTerminal(frame: NSRect(x: 0, y: 0, width: 640, height: 300),
                               font: NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular))
        super.init(padding: 0, spacing: 0)
        term.terminalDelegate = self
        term.optionAsMetaKey = false
        term.allowMouseReporting = false
        term.setAccessibilityLabel("Terminal of the session")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.contentView = TopClip()
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.documentView = term
        scrollHeight = scroll.heightAnchor.constraint(equalToConstant: 300)
        scrollHeight.isActive = true
        applyTheme()

        take.onClick = { [weak self] in self?.toggleControl() }
        take.setAccessibilityLabel("Take control of the terminal size")
        give.onClick = { [weak self] in self?.toggleControl() }
        give.setAccessibilityLabel("Give back the terminal size")
        details.onClick = { [weak self] in self?.onDetails?() }
        retry.onClick = { [weak self] in self?.onRetry?() }
        let title = NSTextField.text("Terminal", size: 13, weight: .semibold)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        let head = NSStackView.cardRow([title, chips, Spacer(), take, give, details] + trailing)
        bannerText.setContentHuggingPriority(.init(1), for: .horizontal)
        let bannerRow = NSStackView.cardRow([bannerText, retry], spacing: 10, top: 9, bottom: 9)
        bannerRow.alignment = .top
        bannerRow.translatesAutoresizingMaskIntoConstraints = false
        banner.addSubview(bannerRow)
        NSLayoutConstraint.activate([
            bannerRow.leadingAnchor.constraint(equalTo: banner.leadingAnchor), bannerRow.trailingAnchor.constraint(equalTo: banner.trailingAnchor),
            bannerRow.topAnchor.constraint(equalTo: banner.topAnchor), bannerRow.bottomAnchor.constraint(equalTo: banner.bottomAnchor),
        ])
        textField.placeholderString = "Text for the session, sent with Return"
        textField.setAccessibilityLabel("Text for the session")
        textField.target = self
        textField.action = #selector(sendText)
        textField.setContentHuggingPriority(.init(1), for: .horizontal)
        term.onLeave = { [weak self] in self?.window?.makeFirstResponder(nil) }
        add(head)
        add(CardRule())
        add(banner)
        add(bannerRule)
        add(scroll)
        add(CardRule())
        add(footer)
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

    func setHead(_ views: [NSView], since: Date?) {
        headChips = views
        self.since = since
        refresh()
    }

    private var attached: StreamAttached? { if case .live(let a) = link { return a }; return nil }
    private var isPoll: Bool { attached?.source == .poll }
    /// Keys from the terminal go to the session.
    private var typable: Bool { (attached?.writable ?? false) && !isPoll }

    // MARK: Stream events

    func handle(_ e: SessionStream.Event) {
        switch e {
        case .connecting, .turns:
            // A lost link shows its reason until the stream attaches again.
            break
        case .attached(let a):
            failure = nil
            link = .live(a)
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
            if h != .you, controlling, attached?.resizable == true { controlling = false }
        case .ended(let reason):
            controlling = false
            link = .ended(StreamLink.endText(reason))
        case .failed(_, let message):
            failure = message
            refresh()
        case .disconnected(let reason, let stopped):
            controlling = false
            link = stopped ? .ended(reason) : .lost(reason)
        }
    }

    // MARK: Size

    /// View mode: the terminal has the size of the remote terminal. It shrinks to fit the width of the card.
    private func show(cols: Int, rows: Int) {
        remote = (cols, rows)
        term.resize(cols: cols, rows: rows)
        term.setFrameSize(term.getOptimalFrameSize().size)
        fittedWidth = 0
        fit()
    }

    /// The zoom that fits the columns into the width. Control and a narrow terminal use 1.
    private var zoom: CGFloat {
        guard !controlling, term.frame.width > 0, scroll.frame.width > 0 else { return 1 }
        return max(0.5, min(1, scroll.frame.width / term.frame.width))
    }

    private func fit() {
        fittedWidth = scroll.frame.width
        let z = zoom
        if abs(scroll.magnification - z) > 0.001 { scroll.magnification = z }
        let h = controlling ? maxHeight : term.frame.height * z + 2
        scrollHeight.constant = min(maxHeight, max(120, h))
        refresh()
    }

    /// Control of a live stream: the terminal takes the size of the view, and the daemon gets that size.
    private func fitToView() {
        scroll.magnification = 1
        scrollHeight.constant = maxHeight
        layoutSubtreeIfNeeded()
        term.setFrameSize(scroll.contentSize)
        let t = term.getTerminal()
        Task { [stream] in await stream.control(cols: t.cols, rows: t.rows) }
        refresh()
    }

    func toggleControl() {
        guard let a = attached, a.resizable else { return }
        if controlling {
            controlling = false
            Task { [stream] in await stream.release() }
            if let r = remote { show(cols: r.cols, rows: r.rows) }
            return
        }
        controlling = true
        fitToView()
        window?.makeFirstResponder(term)
    }

    // MARK: Text only

    @objc private func sendText() {
        let text = textField.stringValue
        guard !text.isEmpty, attached?.writable == true else { return }
        textField.stringValue = ""
        Task { [stream] in await stream.input(Data((text + "\r").utf8)) }
    }

    private func interrupt() {
        Task { [stream] in await stream.input(Data([0x03])) }
    }

    // MARK: Chips, banner and footer

    private func refresh() {
        let a = attached
        var views = [link.chip]
        var drop: [NSView] = []
        if controlling {
            views.append(Chiplet("You control the size", symbol: "arrow.up.left.and.arrow.down.right", color: Palette.acc))
        } else if a?.resizable == true {
            switch holder {
            case .other: views.append(Chiplet("Another viewer has the size", symbol: "person.2"))
            case .desktop: views.append(Chiplet("The desktop has the size", symbol: "desktopcomputer"))
            case .you, .none: break
            }
            if views.count > 1 { drop.append(views[1]) }
        }
        views += headChips
        if a != nil {
            let t = term.getTerminal()
            views.append(Chiplet("\(t.cols) × \(t.rows)" + (zoom < 0.999 ? " · fit" : ""), mono: false))
            drop.append(views[views.count - 1])
        }
        if let since {
            views.append(sinceLabel(since))
            drop.insert(views[views.count - 1], at: 0)
        }
        chips.setChips(views, drop: drop + headChips.reversed())

        take.isHidden = controlling || a?.resizable != true || a?.writable != true
        give.isHidden = !controlling
        details.isHidden = !isPoll || onDetails == nil

        if controlling {
            bannerText.attributedStringValue = Self.banner("The terminal on \(place) now has the size of this window.",
                                                           "OverSire gives the size back when you click Give back, when you close the view, or after 10 min with no key.")
            banner.fill = Palette.acc.withAlphaComponent(0.08)
            retry.isHidden = true
        } else if isPoll {
            let why = a?.reason.map { ": " + $0.trimmingCharacters(in: CharacterSet(charactersIn: ".")) } ?? ""
            bannerText.attributedStringValue = Self.banner("No live stream from \(runtime) on \(place)\(why).",
                                                           "The daemon on \(place) reads the screen as text each second: no color, no cursor, and keys go as text plus Return.")
            banner.fill = Palette.warn.withAlphaComponent(0.09)
            retry.isHidden = onRetry == nil
        }
        banner.isHidden = !(controlling || isPoll)
        bannerRule.isHidden = banner.isHidden

        footer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let text = { (s: String) in NSTextField.text(s, size: 11.5, color: Palette.dim, lines: 2) }
        if let n = link.note ?? failure {
            footer.addArrangedSubview(text(n))
        } else if a == nil {
            footer.addArrangedSubview(text("OverSire connects to the daemon on \(place)."))
        } else if isPoll {
            textField.isEnabled = a?.writable == true
            let send = ActionButton("Send", style: .primary) { [weak self] in self?.sendText() }
            let stop = ActionButton("Interrupt") { [weak self] in self?.interrupt() }
            stop.setAccessibilityLabel("Interrupt the session: Ctrl+C")
            send.isEnabled = textField.isEnabled
            stop.isEnabled = textField.isEnabled
            [text("Send text"), textField, send, stop].forEach { footer.addArrangedSubview($0) }
        } else {
            if typable {
                footer.addArrangedSubview(text(focused ? "Typing goes to the session." : "Click the terminal to type."))
                footer.addArrangedSubview(KeyHint("⌘.", "leaves the terminal"))
                footer.addArrangedSubview(KeyHint("⌘V", "pastes as one block"))
            } else {
                footer.addArrangedSubview(text("View only."))
            }
            footer.addArrangedSubview(Spacer())
            let cols = term.getTerminal().cols
            let size: String
            if controlling {
                size = popped ? "The terminal follows the size of this window." : "Pop out gives a bigger window, and the terminal follows its size."
            } else {
                size = "\(runtime) keeps the size." + (zoom < 0.999 ? " The font shrinks to fit \(cols) columns." : "")
            }
            footer.addArrangedSubview(text(size))
        }
    }

    private static func banner(_ bold: String, _ rest: String) -> NSAttributedString {
        let s = NSMutableAttributedString(string: bold + " ", attributes: [.font: NSFont.systemFont(ofSize: 12.5, weight: .semibold), .foregroundColor: Palette.fg])
        s.append(NSAttributedString(string: rest, attributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: Palette.fg]))
        return s
    }

    // MARK: Theme

    private func applyTheme() {
        var bg = NSColor.black, fg = NSColor.white
        effectiveAppearance.performAsCurrentDrawingAppearance {
            bg = Palette.term.usingColorSpace(.sRGB) ?? bg
            fg = Palette.termFg.usingColorSpace(.sRGB) ?? fg
        }
        term.nativeBackgroundColor = bg
        term.nativeForegroundColor = fg
        term.installColors(Palette.isDark(effectiveAppearance) ? Self.dark : Self.light)
        scroll.backgroundColor = bg
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    /// The 16 ANSI colors on a dark and on a light background.
    private static let dark = ansi([0x2E3037, 0xE2703A, 0x4CC28E, 0xE9A21A, 0x6CB0EC, 0xB98AD6, 0x5AB8EC, 0xD9DBE0,
                                   0x737883, 0xF08A5F, 0x6FD8A6, 0xF2C04D, 0x8EC4F2, 0xCDA5E3, 0x86CDF2, 0xFFFFFF])
    private static let light = ansi([0x1E2024, 0xB5532A, 0x1F8A5B, 0x8A6200, 0x2A6FB0, 0x8A55AE, 0x1D7FB8, 0x6B7079,
                                    0x8A8F98, 0xC2510A, 0x00855F, 0xA86F00, 0x0B6BB3, 0x7A3FA0, 0x0E6E9E, 0x9EA2AA])

    private static func ansi(_ v: [UInt32]) -> [SwiftTerm.Color] {
        v.map { SwiftTerm.Color(red: UInt16(($0 >> 16) & 0xFF) * 257, green: UInt16(($0 >> 8) & 0xFF) * 257, blue: UInt16($0 & 0xFF) * 257) }
    }

    // MARK: Focus

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observer = window?.observe(\.firstResponder, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async { self?.focused = w.firstResponder === self?.term }
        }
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        guard typable else { return }
        let d = Data(data)
        Task { [stream] in await stream.input(d) }
    }

    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        refresh()
        guard controlling, attached?.resizable == true else { return }
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
        if controlling, attached?.resizable == true, term.frame.size != scroll.contentSize {
            fitToView()
        } else if !controlling, abs(scroll.frame.width - fittedWidth) > 0.5 {
            fit()
        }
    }
}

/// The terminal view of a session. Command-period leaves it.
private final class SessionTerminal: TerminalView {
    var onLeave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "." {
            onLeave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
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

    static func show(sessionID: String, title: String, stream: SessionStream, runtime: String, place: String) {
        if let w = open[sessionID] { w.window?.makeKeyAndOrderFront(nil); return }
        let w = LiveTerminalWindow(sessionID: sessionID, title: title, stream: stream, runtime: runtime, place: place)
        open[sessionID] = w
        w.showWindow(nil)
    }

    private init(sessionID: String, title: String, stream: SessionStream, runtime: String, place: String) {
        card = LiveTerminalCard(sessionID: sessionID, stream: stream, runtime: runtime, place: place, trailing: [], maxHeight: 560, popped: true)
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
