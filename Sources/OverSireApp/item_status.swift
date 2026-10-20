import Cocoa
import OverSireCore
import OverSireAI

// The status of one item key, the same in each place. Source order: the AI status while it holds,
// else the screen state, else the runtime phase. No session: nil, and the places show "—".
struct ItemStatus {
    enum Source: Equatable { case ai, screen, phase }

    let source: Source
    let tone: Tone
    let text: String              // "Blocked on you", "Working 50m"
    var byAI = false              // written by the AI engine: the pill shows ✦
    var at: Date?                 // when the status job read the session
    var headline = ""
    var needsYou: [String] = []
    var next: [String] = []
    var blockedBy: [String] = []
    var facts: [String] = []      // "Session done at 14:02", "1 terminal", "Read at the turn end"

    /// The pill text with the AI mark: "Blocked on you ✦".
    var label: String { byAI ? text + " ✦" : text }

    /// "AI status, 1h ago", "no AI status yet".
    var origin: String {
        switch source {
        case .ai: return (byAI ? "AI status" : "From the last message") + (at.map { ", " + relativeAgo($0) } ?? "")
        case .screen, .phase: return "no AI status yet"
        }
    }

    /// The headline for a native tooltip.
    var tip: String { headline.isEmpty ? text : headline }

    static func resolve(status: SessionStatus?, outOfDate: String?, state: SessionState?, stateText: String?,
                        agent: AgentSession?, terminals: Int?, screen: String?, idleNote: String?, now: Date = Date()) -> ItemStatus? {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        var facts: [String] = []
        if let st = state, let a = agent {
            facts.append(st.ended || st == .closed ? "\(st.label) at \(clock.string(from: a.since))" : stateText ?? st.label)
        } else if let a = agent {
            facts.append(a.label(now: now))
        }
        if let n = terminals { facts.append("\(n) terminal\(n == 1 ? "" : "s")") }
        if let s = status, outOfDate == nil {
            let r = s.reply
            return ItemStatus(source: .ai, tone: Tone(s.state), text: s.word, byAI: s.byAI, at: s.at, headline: r.headline,
                              needsYou: r.needsYou.map(\.text), next: r.next, blockedBy: r.blockedBy,
                              facts: facts + ["Read " + s.cause])
        }
        if let st = state {
            let head = [screen.map { "The screen: \($0)." }, outOfDate].compactMap { $0 }.joined(separator: " ")
            return ItemStatus(source: .screen, tone: Tone(st), text: stateText ?? st.label, headline: head,
                              facts: facts + (idleNote.map { [$0] } ?? []))
        }
        guard let a = agent else { return nil }
        return ItemStatus(source: .phase, tone: Tone(a.phase), text: a.label(now: now),
                          headline: a.phase == .failed ? a.message ?? "" : "", facts: [])
    }
}

extension StatusJob {
    /// The status of the item key in all places.
    func item(_ key: String) -> ItemStatus? {
        let k = key.uppercased()
        let s = status(k)
        return ItemStatus.resolve(status: s, outOfDate: s.flatMap(outOfDate), state: agents.state(k), stateText: agents.pillText(k),
                                  agent: agents.agent(k), terminals: agents.facts(k)?.liveTerminals,
                                  screen: agents.state(k) == nil ? nil : agents.screenText(k),
                                  idleNote: on ? "Next status after \(Int(AGENTS.quietMinutes)) min idle" : nil, now: now())
    }
}

// The summary of an item status: the state word and its age, the headline, Needs you, Next, Blocked by and the facts.
final class StatusSummaryView: NSStackView {
    static let width: CGFloat = 360

    init(_ s: ItemStatus) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 7
        translatesAutoresizingMaskIntoConstraints = false
        edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        let word = NSTextField.text(s.text, size: 12.5, weight: .semibold, color: s.tone.color)
        word.setContentCompressionResistancePriority(.required, for: .horizontal)
        var head: [NSView] = [Glyph(s.tone.symbol, color: s.tone.color, size: 11), word]
        if s.byAI { head.append(NSTextField.text("✦", size: 11, color: Palette.intake)) }
        head += [NSTextField.text("· " + s.origin, size: 12, color: Palette.dim), Spacer()]
        addFull(NSStackView(h: head, spacing: 5))
        if !s.headline.isEmpty { addFull(NSTextField.text(s.headline, size: 12, color: Palette.mut, lines: 0)) }
        list(s.needsYou.isEmpty ? nil : "Needs you · \(s.needsYou.count)", s.needsYou)
        list("Next", s.next)
        list("Blocked by", s.blockedBy)
        if !s.facts.isEmpty {
            let line = Box(fill: Palette.line, border: nil, radius: 0)
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            addFull(line)
            addFull(NSTextField.text(s.facts.joined(separator: " · "), size: 11.5, color: Palette.dim, lines: 0))
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(([s.text, s.origin, s.headline] + s.needsYou + s.next + s.facts).filter { !$0.isEmpty }.joined(separator: ". "))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func list(_ title: String?, _ lines: [String]) {
        guard let title, !lines.isEmpty else { return }
        addFull(NSTextField.text(title.uppercased(), size: 10.5, weight: .semibold, color: Palette.dim))
        for l in lines.prefix(6) { addFull(NSTextField.text("• " + l, size: 12, color: Palette.mut, lines: 3)) }
        if lines.count > 6 { addFull(NSTextField.text("\(lines.count - 6) more", size: 11.5, color: Palette.dim)) }
    }
}

// Shows the summary of a status in a popover while the pointer is on a view, or while the view has keyboard focus.
final class HoverSummary: NSObject {
    private static weak var shown: HoverSummary?
    private static let popover: NSPopover = {
        let p = NSPopover()
        p.behavior = .semitransient
        p.animates = false
        return p
    }()

    private weak var view: NSView?
    private let status: ItemStatus
    private var timer: Timer?

    init(_ status: ItemStatus, on view: NSView) {
        self.status = status
        self.view = view
        super.init()
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    static var windowNumber: Int? { popover.isShown ? popover.contentViewController?.view.window?.windowNumber : nil }
    static func dismiss() { popover.close(); shown = nil }

    @objc func mouseEntered(with event: NSEvent) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in self?.show() }
    }

    @objc func mouseExited(with event: NSEvent) {
        timer?.invalidate()
        timer = nil
        hide()
    }

    func show() {
        guard let view, view.window != nil else { return }
        let vc = NSViewController()
        vc.view = StatusSummaryView(status)
        let p = Self.popover
        p.contentViewController = vc
        Self.shown = self
        NSApp.withPinnedAppearance { p.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY) }
    }

    func hide() {
        guard Self.shown === self else { return }
        Self.popover.close()
        Self.shown = nil
    }
}

// The status pill of an item: the tone, the text and ✦ for an AI status. Hover or focus shows the summary.
final class StatusPill: Box {
    var onClick: (() -> Void)?
    private(set) var hover: HoverSummary?
    let status: ItemStatus

    init(_ s: ItemStatus, onClick: (() -> Void)? = nil) {
        status = s
        self.onClick = onClick
        super.init(fill: s.tone.color.withAlphaComponent(0.16), border: nil, radius: 9)
        var views: [NSView] = [Glyph(s.tone.symbol, color: s.tone.color, size: 10),
                               NSTextField.text(s.text, size: 11.5, weight: .semibold, color: s.tone.color)]
        if s.byAI { views.append(NSTextField.text("✦", size: 10, color: Palette.intake)) }
        let stack = NSStackView(h: views, spacing: 4)
        for v in views.dropFirst() { v.setContentCompressionResistancePriority(.required, for: .horizontal) }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        hover = HoverSummary(s, on: self)
        setAccessibilityElement(true)
        setAccessibilityRole(onClick == nil ? .staticText : .button)
        setAccessibilityLabel(s.byAI ? "\(s.text), AI status" : s.text)
        setAccessibilityHelp(s.headline.isEmpty ? nil : s.headline)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A pill for a key with a session, else "—".
    static func or(_ s: ItemStatus?, onClick: (() -> Void)? = nil) -> NSView {
        s.map { StatusPill($0, onClick: onClick) } ?? NSTextField.text("—", size: 12, color: Palette.dim)
    }

    override func mouseUp(with event: NSEvent) { if let onClick { onClick() } else { super.mouseUp(with: event) } }
    override func mouseDown(with event: NSEvent) { if onClick == nil { super.mouseDown(with: event) } }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }

    // The pill takes keyboard focus, so the summary opens without a pointer.
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func becomeFirstResponder() -> Bool { hover?.show(); return true }
    override func resignFirstResponder() -> Bool { hover?.hide(); return true }
    override func keyDown(with event: NSEvent) {
        if let onClick, [36, 49, 76].contains(event.keyCode) { onClick(); return }
        super.keyDown(with: event)
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}
