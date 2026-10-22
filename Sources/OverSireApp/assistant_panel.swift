import Cocoa
import OverSireCore
import OverSireAI
import OverSireAssistant

// ─── Assistant panel ─────────────────────────────────────────────────────────
// The assistant, docked at the right of the window. ⌘J shows and hides it.
// Header: chats, title, Follow along, new chat, close. Body: the chat and the composer, or the chat list.
// With no controller, the panel tells the user to set up the assistant.

final class AssistantPanel: NSViewController {
    let controller: AssistantController?
    weak var owner: AppWindow?
    /// Hides the panel.
    var onClose: (() -> Void)?

    let stream = AssistantStream()
    let composer = AssistantComposer()
    let chats = AssistantChats()
    private let titleLabel = NSTextField.text("Assistant", size: 13, weight: .semibold)
    private let followHolder = NSStackView(h: [], spacing: 0)
    private let body = NSView()
    private(set) var showsChats = false
    private lazy var capturer = SnapCapturer(guess: { SnapProjectGuess([]) }) { [weak self] _, png, _ in
        self?.owner?.show()
        self?.composer.add(AssistantAttachment(kind: .image(png)))
    }

    init(controller: AssistantController?, owner: AppWindow?) {
        self.controller = controller
        self.owner = owner
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = PanelView(fill: Palette.bg, border: nil, radius: 0)
        v.panel = self
        let line = Box(fill: Palette.line, border: nil, radius: 0)
        let head = NSStackView(h: [
            IconButton("sidebar.left", label: "Chats", tip: "Chats") { [weak self] in self?.flipChats() },
            Glyph("sparkles", color: AI_COLOR, size: 12), titleLabel, Spacer(), followHolder,
            IconButton("square.and.pencil", label: "New chat", tip: "New chat (⌘N)") { [weak self] in self?.newChat() },
            IconButton("xmark", label: "Close the assistant", tip: "Close (⌘J)") { [weak self] in self?.onClose?() },
        ], spacing: 6)
        head.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 10)
        titleLabel.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        let edge = Box(fill: Palette.line, border: nil, radius: 0)
        body.translatesAutoresizingMaskIntoConstraints = false
        for s in [head, line, body, edge] as [NSView] { v.addSubview(s) }
        NSLayoutConstraint.activate([
            edge.leadingAnchor.constraint(equalTo: v.leadingAnchor), edge.widthAnchor.constraint(equalToConstant: 1),
            edge.topAnchor.constraint(equalTo: v.topAnchor), edge.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            head.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 1), head.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            head.topAnchor.constraint(equalTo: v.safeAreaLayoutGuide.topAnchor), head.heightAnchor.constraint(equalToConstant: 40),
            line.leadingAnchor.constraint(equalTo: v.leadingAnchor), line.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            line.topAnchor.constraint(equalTo: head.bottomAnchor), line.heightAnchor.constraint(equalToConstant: 1),
            body.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 1), body.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            body.topAnchor.constraint(equalTo: line.bottomAnchor), body.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        v.setAccessibilityElement(true)
        v.setAccessibilityRole(.group)
        v.setAccessibilityLabel("Assistant")
        view = v
        wire()
        place()
        render()
    }

    // MARK: Wiring

    private func wire() {
        let ctx = stream.ctx
        guard let c = controller else { return }
        c.onChange = { [weak self] in self?.render() }
        c.onNavigate = { [weak self] path, _ in
            guard let r = Route(path: path) else { return }
            self?.owner?.router.go(r)
        }
        ctx.answer = { c.answer($0, $1) }
        ctx.goBack = { [weak self] path in if let r = Route(path: path) { self?.owner?.router.go(r) } }
        ctx.stopFollow = { c.setFollow(false) }
        ctx.reply = { c.send($0) }
        ctx.retry = { c.send(c.messages.last { $0.role == .user }?.text ?? "Try again.") }
        ctx.openSettings = { [weak self] in self?.owner?.router.go(.settings(.ai)) }
        ctx.blob = { await c.blob($0) }
        composer.onSend = { text, files in c.send(text, files) }
        composer.onStop = { c.stop() }
        composer.onEngine = { c.setEngine($0) }
        composer.onSnap = { [weak self] in self?.capturer.start() }
        composer.onMention = { [weak self] in self?.pickMention() }
        chats.onOpen = { [weak self] id in
            c.open(id)
            self?.showChats(false)
        }
        chats.onPin = { c.pin($0, $1) }
        chats.onDelete = { c.delete($0) }
    }

    private func place() {
        body.subviews.forEach { $0.removeFromSuperview() }
        var c: [NSLayoutConstraint] = []
        func sides(_ v: NSView, _ inset: CGFloat) {
            body.addSubview(v)
            c += [v.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: inset),
                  v.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -inset)]
        }
        if showsChats {
            sides(chats, 0)
            c += [chats.topAnchor.constraint(equalTo: body.topAnchor), chats.bottomAnchor.constraint(equalTo: body.bottomAnchor)]
        } else if controller == nil {
            let card = SetupCard { [weak self] in self?.owner?.router.go(.settings(.ai)) }
            body.addSubview(card)
            c += [card.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 14),
                  card.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -14),
                  card.topAnchor.constraint(equalTo: body.topAnchor, constant: 14)]
        } else {
            sides(composer, 12)
            sides(stream, 0)
            c += [composer.bottomAnchor.constraint(equalTo: body.bottomAnchor, constant: -10),
                  stream.topAnchor.constraint(equalTo: body.topAnchor),
                  stream.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -8)]
        }
        NSLayoutConstraint.activate(c)
    }

    // MARK: State

    func render() {
        guard isViewLoaded else { return }
        let c = controller
        titleLabel.stringValue = showsChats ? "Chats" : c?.thread?.title ?? "Assistant"
        followHolder.clear()
        if let c, !showsChats {
            let on = c.follows
            let chip = Chiplet("Follow along", symbol: on ? "eye.fill" : "eye.slash", color: on ? AI_COLOR : Palette.mut,
                               fill: on ? AI_COLOR.withAlphaComponent(0.14) : Palette.raise) { c.setFollow(!on) }
            chip.setAccessibilityRole(.checkBox)
            chip.setAccessibilityValue(on ? 1 : 0)
            chip.toolTip = on ? "The window opens what the assistant shows. Click to stop." : "Click to open what the assistant shows."
            followHolder.addArrangedSubview(chip)
        }
        guard let c else { return }
        if showsChats {
            chats.show(c.threads, current: c.thread?.id, running: { c.runs($0) }, label: { c.label($0) })
            return
        }
        stream.show(c) { [weak self] in
            AssistantHello(page: c.page) { text in
                self?.composer.textView.string = ""
                c.send(text)
            }
        }
        composer.set(running: c.isRunning, engines: c.engines, current: c.currentEngine)
    }

    func showChats(_ on: Bool) {
        guard showsChats != on else { return }
        showsChats = on
        if on { Task { await controller?.reloadThreads(); render() } }
        place()
        render()
        if on { view.window?.makeFirstResponder(chats.search) } else { focusComposer() }
    }

    private func flipChats() { showChats(!showsChats) }

    func newChat() {
        controller?.newChat()
        showChats(false)
        focusComposer()
    }

    func focusComposer() {
        guard controller != nil, !showsChats else { return }
        view.window?.makeFirstResponder(composer.textView)
    }

    var hasFocus: Bool {
        guard let r = view.window?.firstResponder as? NSView else { return false }
        return r.isDescendant(of: view)
    }

    private func pickMention() {
        guard let owner else { return }
        let taken = Set(composer.attachments.compactMap { a -> String? in if case .mention(_, let k) = a.kind { return k }; return nil })
        CommandPalette.pickItem(over: owner, prompt: "Mention an item", exclude: taken) { [weak self, weak owner] key in
            guard let found = owner?.data.projectStore.item(key: key),
                  let ref = found.item.ref(in: found.snap.summary.ref) else { return }
            self?.composer.add(AssistantAttachment(kind: .mention(.item(ref), key: ref.key)))
            self?.focusComposer()
        }
    }

    // MARK: Keys

    /// ⌘N: a new chat. ⌘↵: approve the focused card, or the only card.
    fileprivate func key(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection([.command, .control, .option, .shift])
        guard mods == .command, hasFocus else { return false }
        if e.charactersIgnoringModifiers?.lowercased() == "n" { newChat(); return true }
        if [36, 76].contains(e.keyCode) {
            let cards = stream.askCards.filter { $0.answered == nil }
            guard let card = cards.first(where: \.hasFocus) ?? (cards.count == 1 ? cards.first : nil) else { return false }
            card.approve()
            return true
        }
        return false
    }
}

private final class PanelView: Box {
    weak var panel: AssistantPanel?
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if panel?.key(e) == true { return true }
        return super.performKeyEquivalent(with: e)
    }
    override func cancelOperation(_ sender: Any?) {
        if panel?.controller?.isRunning == true { panel?.controller?.stop() } else { panel?.onClose?() }
    }
}

/// The panel with no assistant: a link to Settings › AI.
private final class SetupCard: Box {
    init(_ open: @escaping () -> Void) {
        super.init(fill: Palette.panel, border: Palette.line, radius: 10)
        let s = NSStackView(v: [
            NSStackView(h: [Glyph("sparkles", color: AI_COLOR, size: 14, label: "Assistant"),
                            NSTextField.text("Set up the assistant in Settings › AI", size: 13, weight: .semibold, lines: 2)], spacing: 6),
            NSTextField.text("The assistant needs an AI source: Claude Code, another agent CLI or an API key.", size: 12, color: Palette.mut, lines: 0),
            ActionButton("Open Settings › AI", symbol: "gearshape", style: .primary, open),
        ], spacing: 8)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14), s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 12), s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Set up the assistant in Settings › AI")
    }
    required init?(coder: NSCoder) { fatalError() }
}
