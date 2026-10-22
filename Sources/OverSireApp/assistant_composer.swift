import Cocoa
import UniformTypeIdentifiers
import OverSireCore
import OverSireAI

// ─── Assistant composer ──────────────────────────────────────────────────────
// The text box of the assistant panel: text, pasted or dropped files and images, item mentions,
// a screenshot, dictation, the engine and the send or stop button.
// ↵ sends, ⇧↵ makes a new line, esc stops a run. While a run goes on, ↵ queues the text.

final class AssistantComposer: NSView, NSTextViewDelegate {
    var onSend: ((String, [AssistantAttachment]) -> Void)?
    var onStop: (() -> Void)?
    var onEngine: ((EngineID) -> Void)?
    /// Opens the item picker. The panel calls `add(_:)` with the pick.
    var onMention: (() -> Void)?
    var onSnap: (() -> Void)?

    let textView = SessionTextView()
    private(set) var attachments: [AssistantAttachment] = []
    /// A larger file is not attached.
    static let maxBytes = 10_000_000

    private let box = ComposerBox()
    private let chipRow = NSStackView(h: [], spacing: 6)
    private let scroll = NSScrollView()
    private var textHeight: NSLayoutConstraint!
    private let hint = NSTextField.text("", size: 11, color: Palette.dim)
    private let cost = NSTextField.text("", size: 11, color: Palette.dim)
    private let send = SendButton()
    private lazy var micButton = IconButton("mic", label: "Dictate", tip: "Dictate") { [weak self] in self?.flipVoice() }
    private var engineHolder = NSStackView(h: [], spacing: 0)
    private let voice = SnapVoice()
    private var running = false
    private var engines: [AssistantEngine] = []
    private var engine: EngineID = .apiKey

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = Palette.fg
        textView.drawsBackground = false
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        textView.setAccessibilityLabel("Message to the assistant")
        textView.onFiles = { [weak self] in self?.addFiles($0) }
        textView.onImage = { [weak self] in self?.add(AssistantAttachment(kind: .image($0))) }
        textView.onFocus = { [weak self] on in self?.box.border = on ? Palette.acc : Palette.line }
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = textView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        textHeight = scroll.heightAnchor.constraint(equalToConstant: 34)

        box.onDrop = { [weak self] pb in self?.take(pb) ?? false }
        box.onHover = { [weak self] _ in self?.syncHint() }
        chipRow.isHidden = true
        send.onClick = { [weak self] in self?.sendOrStop() }
        let bar = NSStackView(h: [
            IconButton("plus", label: "Attach files", tip: "Attach files") { [weak self] in self?.pickFiles() },
            IconButton("camera.viewfinder", label: "Snap a screenshot", tip: "Snap a screenshot") { [weak self] in self?.onSnap?() },
            micButton,
            IconButton("at", label: "Mention an item", tip: "Mention an item (@)") { [weak self] in self?.onMention?() },
            engineHolder, Spacer(), send,
        ], spacing: 4)
        let inner = NSStackView(v: [chipRow, scroll, bar], spacing: 4)
        box.addSubview(inner)
        let foot = NSStackView(h: [hint, Spacer(), cost], spacing: 8)
        addSubview(box)
        addSubview(foot)
        NSLayoutConstraint.activate([
            textHeight,
            inner.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 8), inner.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            inner.topAnchor.constraint(equalTo: box.topAnchor, constant: 8), inner.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -6),
            scroll.widthAnchor.constraint(equalTo: inner.widthAnchor), bar.widthAnchor.constraint(equalTo: inner.widthAnchor),
            chipRow.widthAnchor.constraint(equalTo: inner.widthAnchor),
            box.leadingAnchor.constraint(equalTo: leadingAnchor), box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor),
            foot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4), foot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            foot.topAnchor.constraint(equalTo: box.bottomAnchor, constant: 6), foot.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        hint.setContentCompressionResistancePriority(.init(200), for: .horizontal)
        sync()
    }
    required init?(coder: NSCoder) { fatalError() }

    func focus() { window?.makeFirstResponder(textView) }

    /// The drop look, for uishots.
    func showDrop(_ on: Bool) { box.showDrop(on) }

    func set(running: Bool, engines: [AssistantEngine], current: EngineID) {
        self.running = running
        self.engines = engines
        engine = current
        let label = engines.first { $0.id == current }?.label ?? current.rawValue
        engineHolder.clear()
        let chip = Chiplet(label, symbol: "sparkles", color: AI_COLOR, fill: AI_COLOR.withAlphaComponent(0.1)) { [weak self] in self?.pickEngine() }
        chip.setAccessibilityLabel("AI source: \(label). Change")
        chip.toolTip = "The AI source of this chat"
        engineHolder.addArrangedSubview(chip)
        cost.stringValue = current == .apiKey ? "Uses your API key" : "Free · runs on your own source"
        sync()
    }

    // MARK: Attachments

    /// Takes a paste or a drop. False: the pasteboard holds only text.
    @discardableResult
    func take(_ pb: NSPasteboard) -> Bool {
        switch PasteContent(pb) {
        case .files(let urls): addFiles(urls); return true
        case .image(let png): add(AssistantAttachment(kind: .image(png))); return true
        case .text: return false
        }
    }

    func add(_ a: AssistantAttachment) {
        if case .mention(let ref, _) = a.kind, attachments.contains(where: { if case .mention(ref, _) = $0.kind { return true }; return false }) { return }
        attachments.append(a)
        syncChips()
    }

    func addFiles(_ urls: [URL]) {
        var skipped = false
        for u in urls {
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &dir), !dir.boolValue,
                  let d = try? Data(contentsOf: u), d.count <= Self.maxBytes else { skipped = true; continue }
            if UTType(filenameExtension: u.pathExtension)?.conforms(to: .image) == true, let png = Self.png(d) {
                attachments.append(AssistantAttachment(kind: .image(png)))
            } else {
                attachments.append(AssistantAttachment(kind: .file(name: u.lastPathComponent, data: d)))
            }
        }
        if skipped { NSSound.beep() }
        syncChips()
    }

    private static func png(_ d: Data) -> Data? {
        guard let tiff = NSImage(data: d)?.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
    }

    private func remove(_ id: UUID) {
        attachments.removeAll { $0.id == id }
        syncChips()
        focus()
    }

    private func syncChips() {
        chipRow.clear()
        var items: [NSView] = []
        for a in attachments {
            let x = IconButton("xmark", label: "Remove", tip: "Remove") { [weak self] in self?.remove(a.id) }
            switch a.kind {
            case .image(let d):
                let img = NSImageView(image: NSImage(data: d) ?? NSImage())
                img.imageScaling = .scaleProportionallyUpOrDown
                img.wantsLayer = true
                img.layer?.cornerRadius = 6
                img.layer?.masksToBounds = true
                img.translatesAutoresizingMaskIntoConstraints = false
                img.setAccessibilityLabel("Image")
                NSLayoutConstraint.activate([img.widthAnchor.constraint(equalToConstant: 64), img.heightAnchor.constraint(equalToConstant: 44)])
                x.setAccessibilityLabel("Remove the image")
                items.append(NSStackView(h: [img, x], spacing: 0, align: .top))
            case .file(let name, let d):
                let size = ByteCountFormatter.string(fromByteCount: Int64(d.count), countStyle: .file)
                x.setAccessibilityLabel("Remove \(name)")
                items.append(NSStackView(h: [Chiplet("\(name) \(size)", symbol: "doc"), x], spacing: 0))
            case .mention(_, let key):
                x.setAccessibilityLabel("Remove \(key)")
                items.append(NSStackView(h: [Chiplet(key, symbol: "smallcircle.filled.circle", color: AI_COLOR,
                                                                   fill: AI_COLOR.withAlphaComponent(0.1)), x], spacing: 0))
            }
        }
        // A long list wraps. It never makes the panel wider.
        if !items.isEmpty { chipRow.addArrangedSubview(Wrap(items)) }
        chipRow.isHidden = attachments.isEmpty
        sync()
    }

    private func pickFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        guard let w = window else { return }
        p.beginSheetModal(for: w) { [weak self] r in if r == .OK { self?.addFiles(p.urls) } }
    }

    // MARK: Engine and voice

    private func pickEngine() {
        guard !engines.isEmpty else { return }
        let m = NSMenu()
        for e in engines {
            let i = SnapMenuItem(title: e.label) { [weak self] in self?.onEngine?(e.id) }
            i.state = e.id == engine ? .on : .off
            m.addItem(i)
        }
        m.popUp(positioning: nil, at: NSPoint(x: engineHolder.bounds.minX, y: engineHolder.bounds.maxY + 4), in: engineHolder)
    }

    private func flipVoice() {
        if voice.isRecording { voice.stop(); syncVoice(); return }
        voice.start(level: { _ in }, done: { [weak self] result in
            guard let self else { return }
            if case .success(let t) = result, !t.isEmpty {
                let s = self.textView.string
                self.textView.string = s.isEmpty ? t : s + (s.hasSuffix(" ") || s.hasSuffix("\n") ? "" : " ") + t
            }
            self.syncVoice()
            self.sync()
        })
        syncVoice()
    }

    private func syncVoice() {
        let on = voice.isRecording
        micButton.image = NSImage(systemSymbolName: on ? "mic.fill" : "mic", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12.5, weight: .medium))
        micButton.contentTintColor = on ? Palette.bad : Palette.mut
        micButton.setAccessibilityLabel(on ? "Stop dictation" : "Dictate")
        micButton.toolTip = on ? "Stop dictation" : "Dictate"
    }

    // MARK: Send

    private var text: String { textView.string.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func sendOrStop() {
        if running && text.isEmpty && attachments.isEmpty { onStop?(); return }
        submit()
    }

    func submit() {
        guard !text.isEmpty || !attachments.isEmpty else { return }
        if voice.isRecording { voice.stop(); syncVoice() }
        onSend?(text, attachments)
        clear()
    }

    /// Removes the text and the attachments.
    func clear() {
        textView.string = ""
        attachments = []
        syncChips()
    }

    private func sync() {
        textView.placeholder = running ? "Add to the chat while it works…" : "Ask, or tell OverSire what to do…"
        textView.needsDisplay = true
        let empty = text.isEmpty && attachments.isEmpty
        send.show(running && empty ? .stop : empty ? .off : .send)
        syncHint()
        grow()
    }

    private func syncHint() {
        if box.dropping { hint.stringValue = "Drop files to attach · ↵ to send" }
        else if running { hint.stringValue = "↵ adds it after this step · esc stops" }
        else { hint.stringValue = "↵ to send · ⇧↵ for a new line" }
    }

    private func grow() {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        lm.ensureLayout(for: tc)
        let h = lm.usedRect(for: tc).height + textView.textContainerInset.height * 2
        textHeight.constant = min(140, max(34, ceil(h)))
    }

    // MARK: Text view

    func textDidChange(_ n: Notification) { sync() }

    func textView(_ v: NSTextView, shouldChangeTextIn range: NSRange, replacementString s: String?) -> Bool {
        guard s == "@" else { return true }
        let ns = v.string as NSString
        let before = range.location == 0 ? " " : ns.substring(with: NSRange(location: range.location - 1, length: 1))
        guard before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, onMention != nil else { return true }
        onMention?()
        return false
    }

    func textView(_ v: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.insertNewline(_:)):
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { v.insertNewlineIgnoringFieldEditor(nil); return true }
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            if voice.isRecording { voice.stop(); syncVoice(); return true }
            if running { onStop?(); return true }
            return false
        default:
            return false
        }
    }
}

/// The composer frame. It takes dropped files and images, and shows a dashed border while they hover.
final class ComposerBox: Box {
    var onDrop: ((NSPasteboard) -> Bool)?
    var onHover: ((Bool) -> Void)?
    private(set) var dropping = false { didSet { syncDash(); onHover?(dropping) } }
    private let dash = CAShapeLayer()

    init() {
        super.init(fill: Palette.raise, border: Palette.line, radius: 12)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        dash.fillColor = nil
        dash.lineWidth = 1.5
        dash.lineDashPattern = [5, 4]
        dash.isHidden = true
        layer?.addSublayer(dash)
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func syncDash() {
        effectiveAppearance.performAsCurrentDrawingAppearance { dash.strokeColor = AI_COLOR.cgColor }
        dash.isHidden = !dropping
        borderWidth = dropping ? 0 : 1
        fill = dropping ? AI_COLOR.withAlphaComponent(0.06) : Palette.raise
    }

    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { dropping = true; return .copy }
    override func draggingExited(_ s: NSDraggingInfo?) { dropping = false }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        dropping = false
        return onDrop?(s.draggingPasteboard) ?? false
    }

    /// For the uishots: the drop look with no drag.
    func showDrop(_ on: Bool) { dropping = on }
}

/// The round send button. It turns into Stop while a run goes on.
final class SendButton: NSButton {
    enum Mode { case send, stop, off }
    var onClick: (() -> Void)?
    private(set) var mode = Mode.off

    init() {
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        wantsLayer = true
        layer?.cornerRadius = 14
        target = self
        action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 28).isActive = true
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { if mode != .off { onClick?() } }

    func show(_ m: Mode) {
        mode = m
        let symbol = m == .stop ? "stop.fill" : "arrow.up"
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12, weight: .bold))
        isEnabled = m != .off
        let label = m == .stop ? "Stop (esc)" : "Send (↵)"
        toolTip = label
        setAccessibilityLabel(m == .stop ? "Stop" : "Send")
        needsDisplay = true
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch mode {
            case .send: layer?.backgroundColor = Palette.acc.cgColor; contentTintColor = .white
            case .stop: layer?.backgroundColor = Palette.fg.cgColor; contentTintColor = Palette.bg
            case .off: layer?.backgroundColor = Palette.line.cgColor; contentTintColor = Palette.dim
            }
        }
    }
}
