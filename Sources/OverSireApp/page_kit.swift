import Cocoa
import OverSireCore

// ─── View types of the window pages ──────────────────────────────────────────
// Pages use Auto Layout with stack views. Colors come from Palette and follow the appearance.

// A view with a fill, a border and round corners that follow light and dark.
class Box: NSView {
    var fill: NSColor? { didSet { needsDisplay = true } }
    var border: NSColor? { didSet { needsDisplay = true } }
    var radius: CGFloat = 10 { didSet { needsDisplay = true } }
    var borderWidth: CGFloat = 1

    init(fill: NSColor? = Palette.panel, border: NSColor? = Palette.line, radius: CGFloat = 10) {
        self.fill = fill; self.border = border; self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = fill?.cgColor
            layer?.borderColor = border?.cgColor
        }
        layer?.borderWidth = border == nil ? 0 : borderWidth
        layer?.cornerRadius = radius
    }
}

extension NSTextField {
    static func text(_ s: String, size: CGFloat = 13, weight: NSFont.Weight = .regular,
                     color: NSColor = Palette.fg, lines: Int = 1, mono: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.maximumNumberOfLines = lines
        f.lineBreakMode = lines == 1 ? .byTruncatingTail : .byWordWrapping
        f.cell?.truncatesLastVisibleLine = true
        f.translatesAutoresizingMaskIntoConstraints = false
        f.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if lines != 1 { f.preferredMaxLayoutWidth = 0 }
        return f
    }
}

extension NSStackView {
    convenience init(h views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .centerY) {
        self.init(views: views)
        orientation = .horizontal
        self.spacing = spacing
        alignment = align
        translatesAutoresizingMaskIntoConstraints = false
        detachesHiddenViews = true
    }

    convenience init(v views: [NSView], spacing: CGFloat = 8, align: NSLayoutConstraint.Attribute = .leading) {
        self.init(views: views)
        orientation = .vertical
        self.spacing = spacing
        alignment = align
        translatesAutoresizingMaskIntoConstraints = false
        detachesHiddenViews = true
    }

    // Adds a view that fills the width of a vertical stack.
    func addFull(_ v: NSView) {
        addArrangedSubview(v)
        v.widthAnchor.constraint(equalTo: widthAnchor, constant: -(edgeInsets.left + edgeInsets.right)).isActive = true
    }

    func clear() { arrangedSubviews.forEach { $0.removeFromSuperview() } }
}

// Flexible space in a horizontal stack.
final class Spacer: NSView {
    init(_ w: CGFloat? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if let w { widthAnchor.constraint(equalToConstant: w).isActive = true }
        else { setContentHuggingPriority(.init(1), for: .horizontal); setContentCompressionResistancePriority(.init(1), for: .horizontal) }
    }
    required init?(coder: NSCoder) { fatalError() }
}

// A tinted SF Symbol. The accessibility label is the word of the tone.
final class Glyph: NSImageView {
    init(_ symbol: String, color: NSColor = Palette.mut, size: CGFloat = 14, label: String? = nil) {
        super.init(frame: .zero)
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .medium)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(cfg)
        contentTintColor = color
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        if let label { setAccessibilityLabel(label); toolTip = label } else { setAccessibilityElement(false) }
    }
    convenience init(_ tone: Tone, size: CGFloat = 14) {
        self.init(tone.symbol, color: tone.color, size: size, label: tone.word)
        if tone.spins { startSpin() }
    }
    required init?(coder: NSCoder) { fatalError() }

    // A spinning glyph draws in a sublayer and turns only that layer. AppKit moves the backing layer
    // on each layout, so a turn of the backing layer goes off center.
    private var spin: CALayer?
    private var spinImage: NSImage?

    private func startSpin() {
        guard let img = image else { return }
        spinImage = img
        image = nil
        wantsLayer = true
        let l = CALayer()
        l.contentsGravity = .center
        layer?.addSublayer(l)
        spin = l
        paintSpin()
    }

    override var intrinsicContentSize: NSSize { spinImage?.size ?? super.intrinsicContentSize }

    private func paintSpin() {
        guard let l = spin, let img = spinImage else { return }
        let scale = window?.backingScaleFactor ?? 2
        var tinted: NSImage?
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = (contentTintColor ?? Palette.mut).usingColorSpace(.sRGB) ?? .gray
            tinted = img.withSymbolConfiguration(.init(paletteColors: [color]))
        }
        l.contentsScale = scale
        l.contents = tinted?.layerContents(forContentsScale: scale)
    }

    override func layout() {
        super.layout()
        guard let l = spin else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        l.bounds = bounds
        l.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paintSpin()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let l = spin else { return }
        paintSpin()
        l.removeAnimation(forKey: "spin")
        guard window != nil, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let a = CABasicAnimation(keyPath: "transform.rotation.z")
        a.fromValue = 0
        a.toValue = -2 * Double.pi
        a.duration = 3   // one turn in 3 s
        a.repeatCount = .infinity
        l.add(a, forKey: "spin")
    }
}

// A button that runs a closure. Styles: plain (bordered), primary (accent fill), link (text).
final class ActionButton: NSButton {
    enum Style { case plain, primary, link, danger }
    var onClick: (() -> Void)?
    var idle: (title: String, image: NSImage?, enabled: Bool)?   // set while busy

    init(_ title: String, symbol: String? = nil, style: Style = .plain, key: String? = nil, _ action: (() -> Void)? = nil) {
        onClick = action
        super.init(frame: .zero)
        self.title = title
        target = self
        self.action = #selector(fire)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil); imagePosition = title.isEmpty ? .imageOnly : .imageLeading }
        if let key { keyEquivalent = key }
        switch style {
        case .plain:
            bezelStyle = .rounded; controlSize = .regular
        case .primary:
            bezelStyle = .rounded; keyEquivalent = key ?? ""; bezelColor = Palette.acc
            if #available(macOS 14.0, *) {} else { contentTintColor = .white }
        case .danger:
            bezelStyle = .rounded; contentTintColor = Palette.bad
        case .link:
            isBordered = false
            attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: Palette.acc, .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)])
            contentTintColor = Palette.acc
        }
        if title.isEmpty, let symbol { setAccessibilityLabel(symbol); toolTip = toolTip ?? symbol }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func fire() { onClick?() }

    // A long title shrinks with an ellipsis, in place of a wider row. Below labels (250), so it shrinks first.
    func truncates() {
        setContentCompressionResistancePriority(.init(200), for: .horizontal)
        (cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        toolTip = toolTip ?? title
    }
    override func resetCursorRects() { if !isBordered { addCursorRect(bounds, cursor: .pointingHand) } }
}

// A small rounded label: "main", "FRITZ-17", "3 / 5". A click handler makes it a button.
class Chiplet: Box {
    var onClick: (() -> Void)?
    /// False: Tab skips the chip. A card that picks with keys sets it.
    var keyFocus = true
    private let label: NSTextField

    // `icon` takes the place of `symbol`, for a drawn glyph such as StatusGlyph.
    init(_ text: String, symbol: String? = nil, icon: NSView? = nil, color: NSColor = Palette.mut, fill: NSColor = Palette.raise,
         mono: Bool = false, onClick: (() -> Void)? = nil) {
        label = .text(text, size: 11.5, weight: .medium, color: color, mono: mono)
        self.onClick = onClick
        super.init(fill: fill, border: Palette.line, radius: 5)
        var views: [NSView] = []
        if let icon { views.append(icon) } else if let symbol { views.append(Glyph(symbol, color: color, size: 10.5)) }
        views.append(label)
        let s = NSStackView(h: views, spacing: 4)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        s.setHuggingPriority(.required, for: .horizontal)
        s.setHuggingPriority(.required, for: .vertical)
        setContentHuggingPriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(onClick == nil ? .staticText : .button)
        setAccessibilityLabel(text)
    }
    required init?(coder: NSCoder) { fatalError() }

    // Show `text` for a short time, then the old text again.
    func flash(_ text: String) {
        let old = label.stringValue
        label.stringValue = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.label.stringValue = old }
    }

    override func mouseUp(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }

    // A chip with a click handler takes keyboard focus. Space or Return presses it.
    override var acceptsFirstResponder: Bool { onClick != nil }
    override var canBecomeKeyView: Bool { onClick != nil && keyFocus }
    override func keyDown(with event: NSEvent) {
        if onClick != nil, [36, 49, 76].contains(event.keyCode) { onClick?(); return }
        super.keyDown(with: event)
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

// A chip that stays on or off. An "on" chip shows a check mark, so the state does not rely on color.
final class ToggleChip: Chiplet {
    init(_ text: String, on: Bool, enabled: Bool = true, icon: NSView? = nil, _ flip: @escaping () -> Void) {
        super.init(text, symbol: on && icon == nil ? "checkmark" : nil, icon: icon, color: !enabled ? Palette.dim : on ? Palette.fg : Palette.mut,
                   fill: on ? Palette.acc.withAlphaComponent(enabled ? 0.18 : 0.08) : Palette.raise, onClick: enabled ? flip : nil)
        if on { border = enabled ? Palette.acc : Palette.line }
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(on ? 1 : 0)
        setAccessibilityValueDescription(on ? "on" : "off")
        setAccessibilityEnabled(enabled)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// A tone as a colored pill: symbol and word, so the state never relies on color alone.
final class Pill: Box {
    init(_ tone: Tone, text: String? = nil) {
        super.init(fill: tone.color.withAlphaComponent(0.16), border: nil, radius: 9)
        let s = NSStackView(h: [Glyph(tone.symbol, color: tone.color, size: 10),
                                NSTextField.text(text ?? tone.word, size: 11.5, weight: .semibold, color: tone.color)], spacing: 4)
        // The pill keeps its full text. The views around it give way.
        s.arrangedSubviews.last?.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            s.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text ?? tone.word)
    }
    required init?(coder: NSCoder) { fatalError() }
}

// A card: a panel with padding, an optional title line and a body stack.
class Card: Box {
    let body: NSStackView

    init(title: String? = nil, trailing: [NSView] = [], padding: CGFloat = 14, spacing: CGFloat = 8, fill: NSColor = Palette.panel,
         border: NSColor = Palette.line) {
        body = NSStackView(v: [], spacing: spacing)
        super.init(fill: fill, border: border, radius: 10)
        let outer = NSStackView(v: [], spacing: 10)
        if let title {
            let t = NSTextField.text(title, size: 13, weight: .semibold)
            let head = NSStackView(h: [t, Spacer()] + trailing, spacing: 8)
            outer.addArrangedSubview(head)
            head.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        }
        outer.addArrangedSubview(body)
        body.widthAnchor.constraint(equalTo: outer.widthAnchor).isActive = true
        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func add(_ v: NSView) { body.addFull(v) }
}

// A clickable row that takes keyboard focus. Space or Return opens it.
class Row: Box {
    var onClick: (() -> Void)?
    var menuItems: (() -> [NSMenuItem])?
    // Command-C and Shift-Command-C copy these while the row has focus.
    var copyID: String?
    var copyLink: String?
    let stack: NSStackView
    private var hover = false { didSet { updateFill() } }
    private var tracking: NSTrackingArea?
    private var scrollObserver: Any?
    var selected = false { didSet { updateFill() } }
    // Actions that show over the trailing edge while the pointer is on the row or the row has focus.
    private var overlay: Box?
    var hoverViews: [NSView] = [] {
        didSet {
            overlay?.removeFromSuperview()
            overlay = nil
            if !hoverViews.isEmpty {
                let o = Box(fill: Palette.sel, border: nil, radius: 6)
                let s = NSStackView(h: hoverViews, spacing: 6)
                o.addSubview(s)
                addSubview(o)
                NSLayoutConstraint.activate([
                    s.leadingAnchor.constraint(equalTo: o.leadingAnchor, constant: 10),
                    s.trailingAnchor.constraint(equalTo: o.trailingAnchor, constant: -10),
                    s.topAnchor.constraint(equalTo: o.topAnchor), s.bottomAnchor.constraint(equalTo: o.bottomAnchor),
                    o.trailingAnchor.constraint(equalTo: trailingAnchor),
                    o.topAnchor.constraint(equalTo: topAnchor), o.bottomAnchor.constraint(equalTo: bottomAnchor),
                ])
                overlay = o
            }
            updateFill()
        }
    }

    init(_ views: [NSView], height: CGFloat = 42, inset: CGFloat = 14, label: String? = nil, onClick: (() -> Void)? = nil) {
        stack = NSStackView(h: views, spacing: 10)
        self.onClick = onClick
        super.init(fill: nil, border: nil, radius: 6)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            heightAnchor.constraint(greaterThanOrEqualToConstant: height),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(onClick == nil ? .group : .button)
        if let label { setAccessibilityLabel(label) }
    }
    required init?(coder: NSCoder) { fatalError() }

    // Views in the row that show only on hover or focus. They keep their space.
    var revealViews: [NSView] = [] { didSet { updateFill() } }
    // The fill and border when the row has no hover, selection or focus. A card or a tile sets them.
    var restFill: NSColor? { didSet { updateFill() } }
    var restBorder: NSColor? { didSet { updateFill() } }

    private func updateFill() {
        fill = selected || (hover && onClick != nil) ? Palette.sel : restFill
        let focused = window?.firstResponder === self
        border = focused ? Palette.acc : restBorder
        overlay?.isHidden = !(hover || focused || hoverViews.contains { $0 is NSProgressIndicator })
        revealViews.forEach { $0.alphaValue = hover || focused ? 1 : 0 }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateFill()
        scrollObserver.map(NotificationCenter.default.removeObserver)
        scrollObserver = nil
        // A scroll moves the row under a still pointer, and AppKit sends no exit for it.
        guard window != nil, let clip = enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            guard let self, let w = self.window else { return }
            let inside = self.bounds.contains(self.convert(w.mouseLocationOutsideOfEventStream, from: nil))
            if inside != self.hover { self.hover = inside }
        }
    }
    deinit { scrollObserver.map(NotificationCenter.default.removeObserver) }
    override func mouseExited(with event: NSEvent) { hover = false }
    override func mouseUp(with event: NSEvent) {
        guard onClick != nil, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick?()
    }
    override func menu(for event: NSEvent) -> NSMenu? {
        guard let items = menuItems?(), !items.isEmpty else { return nil }
        let m = NSMenu()
        items.forEach { m.addItem($0) }
        return m
    }
    // Copy link, Copy ID and Open on hover, and the copy keys.
    func itemActions(url: String, key: String, tracker: String = "Plane") {
        copyID = key
        copyLink = url
        hoverViews = RowActions.item(url: url, key: key, tracker: tracker)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self, event.charactersIgnoringModifiers?.lowercased() == "c" else { return super.performKeyEquivalent(with: event) }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if mods == [.command, .shift], let copyLink { RowActions.copy(copyLink); return true }
        if mods == .command, let copyID { RowActions.copy(copyID); return true }
        return super.performKeyEquivalent(with: event)
    }
    override var acceptsFirstResponder: Bool { onClick != nil }
    override var canBecomeKeyView: Bool { onClick != nil }
    // A row that gets the focus by key comes into view. The margin keeps it clear of a pinned group row.
    override func becomeFirstResponder() -> Bool {
        DispatchQueue.main.async {
            self.updateFill()
            self.scrollToVisible(self.bounds.insetBy(dx: 0, dy: -36))
        }
        return true
    }
    override func resignFirstResponder() -> Bool { DispatchQueue.main.async { self.updateFill() }; return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 { onClick?(); return }
        // Shift-F10 or the menu key of a PC keyboard opens the row menu.
        let shiftF10 = event.keyCode == 109 && event.modifierFlags.contains(.shift)
        if shiftF10 || event.keyCode == 110, showMenu() { return }
        super.keyDown(with: event)
    }

    @discardableResult
    func showMenu() -> Bool {
        guard let items = menuItems?(), !items.isEmpty else { return false }
        let m = NSMenu()
        items.forEach { m.addItem($0) }
        m.popUp(positioning: nil, at: NSPoint(x: 16, y: isFlipped ? bounds.height - 4 : 4), in: self)
        return true
    }
    override func accessibilityPerformShowMenu() -> Bool { showMenu() }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
}

// Title above a subtitle. Use as the main column of a row.
final class TwoLine: NSStackView {
    convenience init(_ title: String, _ subtitle: String?, titleSize: CGFloat = 13, weight: NSFont.Weight = .medium,
                     titleColor: NSColor = Palette.fg, lines: Int = 1) {
        let sub = subtitle.flatMap { $0.isEmpty ? nil : NSTextField.text($0, size: 11.5, color: Palette.dim) }
        self.init(title, subView: sub, titleSize: titleSize, weight: weight, titleColor: titleColor, lines: lines)
    }

    /// A subtitle with a time in it. `subtitle` gets the relative time, for example "2m ago".
    convenience init(_ title: String, time: Date?, titleSize: CGFloat = 13, subtitle: @escaping (String) -> String) {
        self.init(title, subView: RelativeTimeLabel({ time }, format: subtitle), titleSize: titleSize)
    }

    init(_ title: String, subView: NSView?, titleSize: CGFloat = 13, weight: NSFont.Weight = .medium,
         titleColor: NSColor = Palette.fg, lines: Int = 1) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(NSTextField.text(title, size: titleSize, weight: weight, color: titleColor, lines: lines))
        if let subView { addArrangedSubview(subView) }
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }
    required init(coder: NSCoder) { fatalError() }
}

// A number tile on a dashboard. A click opens the matching page.
final class Tile: Row {
    /// `ring`: a wider border in this color, for a tile that asks for attention.
    init(_ value: String, _ caption: String, tone: Tone, ring: NSColor? = nil, onClick: (() -> Void)?) {
        let v = NSTextField.text(value, size: 22, weight: .semibold)
        v.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        let c = NSStackView(h: [Glyph(tone, size: 12), NSTextField.text(caption, size: 12, color: Palette.mut, lines: 2)], spacing: 5, align: .top)
        let col = NSStackView(v: [v, c], spacing: 2)
        super.init([col], height: 64, inset: 14, label: "\(value) \(caption)", onClick: onClick)
        if ring != nil { borderWidth = 2 }
        restFill = Palette.panel; restBorder = ring ?? Palette.line; radius = 10
    }
    required init?(coder: NSCoder) { fatalError() }
}

// A notice with a tone: info, warning, ok. Buttons go at the end.
final class Banner: Box {
    init(_ tone: Tone, title: String, body: String? = nil, actions: [NSView] = []) {
        super.init(fill: Palette.panel, border: tone.color.withAlphaComponent(0.55), radius: 10)
        let text = NSStackView(v: [NSTextField.text(title, size: 13, weight: .semibold, lines: 2)], spacing: 3)
        if let body { text.addArrangedSubview(NSTextField.text(body, size: 12, color: Palette.mut, lines: 4)) }
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        // Buttons do not push the title down to one letter on each line.
        let least = text.widthAnchor.constraint(greaterThanOrEqualToConstant: 160)
        least.priority = .init(800)
        least.isActive = true
        let row = NSStackView(h: [Glyph(tone, size: 15), text] + actions, spacing: 10, align: .top)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -11),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(tone.word): \(title)")
    }
    required init?(coder: NSCoder) { fatalError() }
}

// Tabs over a page part. Arrow keys move, the selected tab has a line and bold text.
final class TabStrip: NSStackView {
    /// One tab: the title, an optional count, and views before and after the title.
    /// `label` is the accessibility label and the tooltip, for a tab whose views say more than its title.
    struct Tab {
        var title: String
        var count: Int?
        var lead: [NSView] = []
        var trail: [NSView] = []
        var label: String?
    }

    var onSelect: ((Int) -> Void)?
    private var cells: [TabCell] = []
    private let selected: Int
    // An arrow key rebuilds the page. The new strip then takes the focus back.
    private static var refocus = false

    convenience init(_ titles: [String], selected: Int, counts: [Int?] = []) {
        self.init(tabs: titles.enumerated().map { i, t in Tab(title: t, count: i < counts.count ? counts[i] : nil) }, selected: selected)
    }

    init(tabs: [Tab], selected: Int) {
        self.selected = selected
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .bottom
        spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        for (i, t) in tabs.enumerated() {
            let cell = TabCell(t, on: i == selected)
            cell.onTap = { [weak self] in self?.onSelect?(i) }
            addArrangedSubview(cell)
            cells.append(cell)
        }
        setAccessibilityRole(.tabGroup)
        setHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 123 || event.keyCode == 124 else { return super.keyDown(with: event) }
        let next = selected + (event.keyCode == 124 ? 1 : -1)
        guard cells.indices.contains(next) else { return }
        TabStrip.refocus = true
        onSelect?(next)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard TabStrip.refocus, let w = window, cells.indices.contains(selected) else { return }
        TabStrip.refocus = false
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            w.makeFirstResponder(self.cells[self.selected])
        }
    }
}

// One tab: a centered label row over a line at the bottom. The full cell takes the click, the focus and Space or Return.
private final class TabCell: NSView {
    static let height: CGFloat = 30
    var onTap: (() -> Void)?

    init(_ tab: TabStrip.Tab, on: Bool) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField.text(tab.title, size: 12.5, weight: on ? .semibold : .regular, color: on ? Palette.fg : Palette.mut)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        var views = tab.lead + [title]
        if let count = tab.count { views.append(NSTextField.text("\(count)", size: 12, color: Palette.dim)) }
        let row = NSStackView(h: views + tab.trail, spacing: 5)
        let line = Box(fill: on ? Palette.acc : .clear, border: nil, radius: 1)
        addSubview(row)
        addSubview(line)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: TabCell.height),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -1),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor), line.heightAnchor.constraint(equalToConstant: 2),
        ])
        // Else a tie with the page column can stretch one tab over the full width.
        setContentHuggingPriority(.required, for: .horizontal)
        focusRingType = .exterior
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(tab.label ?? (tab.count.map { "\(tab.title), \($0)" } ?? tab.title))
        setAccessibilityValue(on ? 1 : 0)
        toolTip = tab.label
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onTap?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 { onTap?(); return }
        super.keyDown(with: event)
    }
    override func accessibilityPerformPress() -> Bool { onTap?(); return true }
}

// Page title line: big title, a small caption, then actions on the right.
final class PageHeader: NSStackView {
    convenience init(_ title: String, caption: String? = nil, actions: [NSView] = []) {
        self.init(title, captionView: caption.map { NSTextField.text($0, size: 12, color: Palette.dim, lines: 2) }, actions: actions)
    }

    /// A caption with a time in it, for example "updated 2m ago". The text stays current with no new build.
    convenience init(_ title: String, updated: @escaping () -> Date?, caption: @escaping (String) -> String, actions: [NSView] = []) {
        self.init(title, captionView: RelativeTimeLabel(updated, size: 12, lines: 2, format: caption), actions: actions)
    }

    init(_ title: String, captionView: NSView?, actions: [NSView] = []) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        let t = NSStackView(v: [NSTextField.text(title, size: 20, weight: .semibold, lines: 2)], spacing: 2)
        if let captionView { t.addArrangedSubview(captionView) }
        t.setContentHuggingPriority(.init(1), for: .horizontal)
        addArrangedSubview(t)
        addArrangedSubview(Spacer())
        actions.forEach { addArrangedSubview($0) }
    }
    required init(coder: NSCoder) { fatalError() }
}

// A section title in a page, with an optional count and action.
final class SectionTitle: NSStackView {
    init(_ title: String, count: Int? = nil, action: NSView? = nil) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(NSTextField.text(title.uppercased(), size: 11, weight: .semibold, color: Palette.dim))
        if let count { addArrangedSubview(NSTextField.text("\(count)", size: 11, weight: .medium, color: Palette.dim)) }
        addArrangedSubview(Spacer())
        if let action { addArrangedSubview(action) }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(count.map { "\(title), \($0)" } ?? title)
    }
    required init(coder: NSCoder) { fatalError() }
}

// A terminal-style text block for log tails and agent output.
final class TermView: Box {
    let text: NSTextView
    private let scroll: NSScrollView

    init(lines: [String], height: CGFloat = 220, errors: Set<Int> = []) {
        scroll = NSScrollView()
        text = NSTextView()
        super.init(fill: Palette.term, border: Palette.line, radius: 8)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 10, height: 8)
        text.isVerticallyResizable = true
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        scroll.documentView = text
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: height),
        ])
        set(lines, errors: errors)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Log")
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ lines: [String], errors: Set<Int> = [], follow: Bool = true) {
        let s = NSMutableAttributedString()
        let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        for (i, l) in lines.enumerated() {
            let bad = errors.contains(i)
            s.append(NSAttributedString(string: (bad ? "✖ " : "  ") + l + "\n", attributes: [
                .font: font, .foregroundColor: bad ? Palette.bad : Palette.termFg]))
        }
        text.textStorage?.setAttributedString(s)
        if follow { text.scrollToEndOfDocument(nil) }
    }
}

// The scrolling column of a page. Rebuilds keep the scroll position.
// A page that fills the height does not scroll. Its last view takes the free height and scrolls on its own.
final class PageScroll: NSScrollView {
    private(set) var column: NSStackView
    private let maxWidth: CGFloat
    private var columnConstraints: [NSLayoutConstraint] = []
    private var fill: NSLayoutConstraint!
    private var fillHeight: [NSLayoutConstraint] = []

    init(maxWidth: CGFloat = 1100) {
        self.maxWidth = maxWidth
        column = PageScroll.makeColumn()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        let doc = Flipped()
        doc.translatesAutoresizingMaskIntoConstraints = false
        documentView = doc
        // The fill is a constant that layout() sets to the visible width. It links to no outer view, so wide content
        // never pushes the sidebar or the window. At 760 it beats label compression (750): text wraps or truncates,
        // and only fixed widths, such as table columns, scroll sideways.
        // A link to the clip view stays below the split holding priorities (250), so it cannot size the pane.
        fill = doc.widthAnchor.constraint(equalToConstant: 0)
        fill.priority = .init(760)
        let atLeast = doc.widthAnchor.constraint(greaterThanOrEqualTo: contentView.widthAnchor)
        atLeast.priority = .init(240)
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            atLeast,
            fill,
            doc.topAnchor.constraint(equalTo: contentView.topAnchor),
        ])
        install(column)
        // A page taller than the window scrolls as a whole, so nothing is cut off.
        let atLeastHeight = doc.heightAnchor.constraint(greaterThanOrEqualTo: contentView.heightAnchor)
        atLeastHeight.priority = .init(760)
        let height = doc.heightAnchor.constraint(equalTo: contentView.heightAnchor)
        height.priority = .init(755)
        fillHeight = [atLeastHeight, height]
    }
    required init?(coder: NSCoder) { fatalError() }

    private(set) var fills = false

    override func layout() {
        super.layout()
        let w = contentView.bounds.width
        if fill.constant != w { fill.constant = w }
    }

    private static func makeColumn() -> NSStackView {
        let c = NSStackView(v: [], spacing: 16)
        c.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 28, right: 24)
        return c
    }

    private func install(_ c: NSStackView) {
        guard let doc = documentView else { return }
        doc.addSubview(c)
        let w = c.widthAnchor.constraint(equalTo: doc.widthAnchor)
        w.priority = .defaultHigh
        // Content wider than the page scrolls from the left edge. It does not overflow both sides of a centered column.
        columnConstraints = [
            doc.widthAnchor.constraint(greaterThanOrEqualTo: c.widthAnchor),
            c.topAnchor.constraint(equalTo: doc.topAnchor),
            c.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            c.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            c.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            w,
        ]
        NSLayoutConstraint.activate(columnConstraints)
    }

    // Builds into a new column and swaps it in. One swap is much cheaper than removing each old view from the stack.
    // `fills`: the column fills the visible height, and the view with the lowest vertical hugging takes the free height.
    func rebuild(fills: Bool = false, _ build: (NSStackView) -> Void) {
        reconciler = nil
        let y = contentView.bounds.origin.y
        let inner = PageScroll.kept(in: column).map { ($0.identifier, $0.contentView.bounds.origin.y) }
        let next = PageScroll.makeColumn()
        next.edgeInsets = column.edgeInsets
        next.spacing = column.spacing
        if fills {
            next.distribution = .fill
            next.setHuggingPriority(.init(1), for: .vertical)
        }
        build(next)
        if fills {
            // Takes the rest when the table is short. A view with hugging 1 and no fit (SidePane) wins over it.
            let rest = NSView()
            rest.setContentHuggingPriority(.init(2), for: .vertical)
            rest.setContentCompressionResistancePriority(.init(1), for: .vertical)
            next.addArrangedSubview(rest)
        }
        NSLayoutConstraint.deactivate(columnConstraints)
        column.removeFromSuperview()
        column = next
        install(next)
        self.fills = fills
        fillHeight.forEach { $0.isActive = fills }
        layoutSubtreeIfNeeded()
        let maxY = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
        reflectScrolledClipView(contentView)
        for s in PageScroll.kept(in: next) {
            guard let y = inner.first(where: { $0.0 == s.identifier })?.1, let doc = s.documentView else { continue }
            s.contentView.scroll(to: NSPoint(x: 0, y: min(y, max(0, doc.frame.height - s.contentView.bounds.height))))
            s.reflectScrolledClipView(s.contentView)
        }
    }

    private var reconciler: RowReconciler?
    private var base: (distribution: NSStackView.Distribution, hugging: NSLayoutConstraint.Priority) = (.gravityAreas, .defaultLow)

    /// Keeps the views with the same id, updates the rows whose hash changed, inserts and removes the others. No column swap.
    /// The first visible row keeps its place on screen.
    @discardableResult
    func apply(_ sections: [PageSection], fills: Bool = false) -> RowReconciler.Result {
        let r: RowReconciler
        if let rec = reconciler { r = rec } else {
            column.clear()
            r = RowReconciler(column)
            reconciler = r
            base = (column.distribution, column.huggingPriority(for: .vertical))
        }
        // A page with tabs can fill on one tab only.
        column.distribution = fills ? .fill : base.distribution
        column.setHuggingPriority(fills ? .init(1) : base.hugging, for: .vertical)
        var rows = PageSection.flatten(sections)
        if fills {
            // Takes the rest when the table is short. A view with hugging 1 and no fit (SidePane) wins over it.
            rows.append(PageRow("rest", hash: 0, full: false) {
                let rest = NSView()
                rest.translatesAutoresizingMaskIntoConstraints = false
                rest.setContentHuggingPriority(.init(2), for: .vertical)
                rest.setContentCompressionResistancePriority(.init(1), for: .vertical)
                return rest
            })
        }
        self.fills = fills
        fillHeight.forEach { $0.isActive = fills }
        return r.apply(rows)
    }

    // The inner scroll views that keep their position over a rebuild. Their identifier names them.
    static let keepPrefix = "keep."
    private static func kept(in v: NSView) -> [NSScrollView] {
        var out: [NSScrollView] = []
        if let s = v as? NSScrollView, s.identifier?.rawValue.hasPrefix(keepPrefix) == true { out.append(s) }
        for sub in v.subviews { out += kept(in: sub) }
        return out
    }

    func toTop() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
        for s in PageScroll.kept(in: column) {
            s.contentView.scroll(to: .zero)
            s.reflectScrolledClipView(s.contentView)
        }
    }

    func toEnd() {
        guard let doc = documentView else { return }
        contentView.scroll(to: NSPoint(x: 0, y: max(0, doc.frame.height - contentView.bounds.height)))
        reflectScrolledClipView(contentView)
    }
}

// An empty list: a symbol and one line.
final class EmptyNote: NSStackView {
    init(_ text: String, symbol: String = "checkmark.circle") {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        addArrangedSubview(Glyph(symbol, color: Palette.dim, size: 13))
        addArrangedSubview(NSTextField.text(text, size: 12.5, color: Palette.dim, lines: 2))
    }
    required init(coder: NSCoder) { fatalError() }
}

// A list of rows with a line between them.
protocol RowList: AnyObject {
    var list: NSStackView { get }
    /// Keeps the rows of `apply` in place.
    var reconciler: RowReconciler { get }
    func add(_ v: NSView)
    /// Runs after `apply`.
    func didApply()
}

extension RowList {
    var isEmpty: Bool { list.arrangedSubviews.isEmpty }
    func didApply() {}

    // Adds the first rows of a long list, and a "Show more" row for the rest. Each row costs layout time.
    func add<T>(_ items: [T], more: MoreRows, _ make: @escaping (T) -> NSView) { add(items, more: more, from: 0, make) }

    private func add<T>(_ items: [T], more: MoreRows, from: Int, _ make: @escaping (T) -> NSView) {
        let end = min(items.count, max(from, more.count))
        items[from..<end].forEach { add(make($0)) }
        guard end < items.count else { return }
        let left = items.count - end
        let b = ActionButton("Show \(min(left, MoreRows.step)) more", symbol: "chevron.down") { [weak self] in
            guard let self else { return }
            more.count = end + MoreRows.step
            // The button row and its line go. The next rows take their place.
            self.list.arrangedSubviews.suffix(2).forEach { $0.removeFromSuperview() }
            self.add(items, more: more, from: end, make)
        }
        let row = NSStackView(h: [b, NSTextField.text("\(left) more in the list", size: 11.5, color: Palette.dim), Spacer()], spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        add(row)
    }
}

// A list in a card: rows with a line between them.
final class ListCard: Box, RowList {
    let list: NSStackView
    private(set) lazy var reconciler = RowReconciler(list, separators: true)

    init() {
        list = NSStackView(v: [], spacing: 0)
        super.init(fill: Palette.panel, border: Palette.line, radius: 10)
        addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            list.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            list.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func add(_ v: NSView) {
        if !list.arrangedSubviews.isEmpty {
            let sep = Box(fill: Palette.line, border: nil, radius: 0)
            sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
            list.addFull(sep)
        }
        list.addFull(v)
    }
}

// How many rows of a long list show. The page keeps it, so a rebuild keeps the rows that the user opened.
final class MoreRows {
    static let step = 50
    var count: Int
    init(_ count: Int = MoreRows.step) { self.count = count }
}

// Views in rows that wrap to the next line when the width ends.
final class Wrap: NSView {
    private let items: [NSView]
    private let gap: CGFloat = 6

    init(_ items: [NSView]) {
        self.items = items
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        for v in items { v.translatesAutoresizingMaskIntoConstraints = true; addSubview(v) }
        // One line of items is the wanted width. A spacer gives way first, then the items wrap, then labels cut.
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.init(200), for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func place(width: CGFloat, apply: Bool) -> CGFloat {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        for v in items {
            let s = v.fittingSize
            if x > 0, x + s.width > width { x = 0; y += line + gap; line = 0 }
            if apply { v.frame = NSRect(x: x, y: y, width: s.width, height: s.height) }
            x += s.width + gap
            line = max(line, s.height)
        }
        return y + line
    }

    private var lineWidth: CGFloat { items.reduce(0) { $0 + $1.fittingSize.width } + gap * CGFloat(max(0, items.count - 1)) }

    override var intrinsicContentSize: NSSize {
        NSSize(width: lineWidth, height: place(width: bounds.width > 0 ? bounds.width : lineWidth, apply: false))
    }

    private var lastHeight: CGFloat = -1

    // A new width can change the line count. Ask for the new height in the same pass.
    override func setFrameSize(_ size: NSSize) {
        let old = frame.width
        super.setFrameSize(size)
        guard size.width != old, size.width > 0 else { return }
        let h = place(width: size.width, apply: false)
        if h != lastHeight { lastHeight = h; invalidateIntrinsicContentSize() }
    }

    override func layout() {
        super.layout()
        let h = place(width: bounds.width, apply: true)
        if h != lastHeight { lastHeight = h; invalidateIntrinsicContentSize() }
    }
}

// A grid of equal columns that wraps. Used for tiles and cards.
final class Grid: NSStackView {
    init(_ views: [NSView], columns: Int, spacing: CGFloat = 12) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        self.spacing = spacing
        translatesAutoresizingMaskIntoConstraints = false
        var i = 0
        while i < views.count {
            let slice = Array(views[i..<min(i + columns, views.count)])
            let fillers = (0..<(columns - slice.count)).map { _ in Spacer() as NSView }
            let row = NSStackView(h: slice + fillers, spacing: spacing, align: .top)
            row.distribution = .fillEqually
            addFull(row)
            i += columns
        }
    }
    required init(coder: NSCoder) { fatalError() }
}

// ─── Settings controls ───────────────────────────────────────────────────────
// Each control saves the config and posts a config change after a change.

func settingsChanged() {
    saveConfig()
    ChangeBus.shared.post(.config())
}

// A segmented control for one choice of a few.
final class Segmented: NSSegmentedControl {
    private let onPick: (Int) -> Void

    init(_ labels: [String], selected: Int, label: String, enabled: Bool = true, onPick: @escaping (Int) -> Void) {
        self.onPick = onPick
        super.init(frame: .zero)
        segmentCount = labels.count
        for (i, l) in labels.enumerated() { setLabel(l, forSegment: i) }
        trackingMode = .selectOne
        selectedSegment = selected
        controlSize = .small
        font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        isEnabled = enabled
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setAccessibilityLabel(label)
        target = self
        action = #selector(picked)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func picked() {
        onPick(selectedSegment)
        settingsChanged()
    }
}

// A wrapping row of on and off chips, for a short list of switches.
final class ChipGroup: NSStackView {
    struct Chip {
        let title: String
        let on: Bool
        let flip: (Bool) -> Void
        init(_ title: String, on: Bool, _ flip: @escaping (Bool) -> Void) { self.title = title; self.on = on; self.flip = flip }
    }

    init(_ chips: [Chip], label: String, enabled: Bool = true, note: String? = nil) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        let wrap = Wrap(chips.map { c in
            ToggleChip(c.title, on: c.on, enabled: enabled) { c.flip(!c.on); settingsChanged() } as NSView
        })
        addFull(wrap)
        if let note { addArrangedSubview(NSTextField.text(note, size: 11.5, color: Palette.dim, lines: 2)) }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
    }
    required init(coder: NSCoder) { fatalError() }
}

// One view that fills the width of a card, with row padding. For chip groups and text boxes.
final class Padded: NSStackView {
    init(_ v: NSView, vertical: CGFloat = 12, side: CGFloat = 14) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        translatesAutoresizingMaskIntoConstraints = false
        edgeInsets = NSEdgeInsets(top: vertical, left: side, bottom: vertical, right: side)
        addFull(v)
    }
    required init(coder: NSCoder) { fatalError() }
}

// A row with a chevron that shows or hides a group of rows. The window keeps the state until the app quits.
final class Disclosure: NSStackView {
    private static var open: Set<String> = []
    private let id: String
    private let content = NSStackView(v: [], spacing: 0)
    private var head: Row!
    private let chevron = Glyph("chevron.right", color: Palette.acc, size: 10)
    private let title: String

    var isOpen: Bool { Disclosure.open.contains(id) }

    init(_ title: String, id: String) {
        self.id = id
        self.title = title
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false
        head = Row([chevron, NSTextField.text(title, size: 12.5, weight: .medium, color: Palette.acc), Spacer()], height: 36, label: title) { [weak self] in
            self?.toggle()
        }
        head.setAccessibilityRole(.disclosureTriangle)
        addFull(head)
        addFull(content)
        apply()
    }
    required init(coder: NSCoder) { fatalError() }

    // Adds a row to the hidden group, with a line above it.
    func add(_ v: NSView) {
        let sep = Box(fill: Palette.line, border: nil, radius: 0)
        sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
        content.addFull(sep)
        content.addFull(v)
    }

    func toggle() {
        if isOpen { Disclosure.open.remove(id) } else { Disclosure.open.insert(id) }
        apply()
    }

    private func apply() {
        content.isHidden = !isOpen
        chevron.image = NSImage(systemSymbolName: isOpen ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        head.setAccessibilityValue(isOpen ? 1 : 0)
        head.setAccessibilityExpanded(isOpen)
    }
}

// The counts of a health bar: for example 48 live, 2 missing, 1 failed.
struct HealthCounts: Equatable {
    enum Kind: Equatable { case ok, warning, failure }
    struct Part: Equatable {
        let count: Int
        let kind: Kind
        let word: String
    }
    let parts: [Part]

    init(_ parts: [Part]) { self.parts = parts }

    var total: Int { parts.reduce(0) { $0 + max(0, $1.count) } }
    // The share of each part, 0 to 1. All parts are 0 when the total is 0.
    var fractions: [Double] { parts.map { total == 0 ? 0 : Double(max(0, $0.count)) / Double(total) } }
    var label: String {
        let shown = parts.filter { $0.count > 0 }.map { "\($0.count) \($0.word)" }
        return shown.isEmpty ? "None" : shown.joined(separator: ", ")
    }
}

extension HealthCounts.Kind {
    var symbol: String {
        switch self {
        case .ok: return "checkmark"
        case .warning: return "exclamationmark.triangle"
        case .failure: return "xmark"
        }
    }
    var color: NSColor {
        switch self {
        case .ok: return Palette.ok
        case .warning: return Palette.warn
        case .failure: return Palette.bad
        }
    }
}

// A stacked bar and a legend with check, triangle and cross shapes.
final class HealthBar: NSStackView {
    private final class Bar: NSView {
        let counts: HealthCounts
        init(_ c: HealthCounts) { counts = c; super.init(frame: .zero); translatesAutoresizingMaskIntoConstraints = false }
        required init?(coder: NSCoder) { fatalError() }

        override func draw(_ dirtyRect: NSRect) {
            effectiveAppearance.performAsCurrentDrawingAppearance {
                let clip = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
                Palette.raise.setFill()
                clip.fill()
                clip.addClip()
                var x: CGFloat = 0
                for (part, f) in zip(counts.parts, counts.fractions) where f > 0 {
                    let w = bounds.width * f
                    part.kind.color.setFill()
                    NSRect(x: x, y: 0, width: w, height: bounds.height).fill()
                    x += w
                }
            }
        }
    }

    init(_ counts: HealthCounts, trailing: [NSView] = []) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        let bar = Bar(counts)
        bar.heightAnchor.constraint(equalToConstant: 8).isActive = true
        addFull(bar)
        let legend = NSStackView(h: counts.parts.map { p in
            NSStackView(h: [Glyph(p.kind.symbol, color: p.kind.color, size: 10.5),
                            NSTextField.text("\(p.count) \(p.word)", size: 12, color: Palette.mut)], spacing: 5) as NSView
        } + [Spacer()] + trailing, spacing: 16)
        addFull(legend)
        bar.setAccessibilityElement(true)
        bar.setAccessibilityRole(.image)
        bar.setAccessibilityLabel(counts.label)
    }
    required init(coder: NSCoder) { fatalError() }
}

// A list card with a fixed header and a body that scrolls. The header of the group at the top stays in place.
// With no `maxHeight`, the card takes the free height of a page that fills the window (a table page).
final class StickyListCard: Box, RowList {
    let scroll: NSScrollView = OverlayScroll()
    let list = NSStackView(v: [], spacing: 0)
    private(set) lazy var reconciler = RowReconciler(list, separators: true)
    private var pinnedHashes: [Int] = []
    private var groups: [(head: NSView, pinned: NSView, top: NSLayoutConstraint)] = []
    private var observer: Any?

    init(header: NSView?, maxHeight: CGFloat? = 520, inset: NSEdgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14), keep: String = "list") {
        super.init(fill: Palette.panel, border: Palette.line, radius: 10)
        layer?.masksToBounds = true
        let doc = Flipped()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(list)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.identifier = NSUserInterfaceItemIdentifier(PageScroll.keepPrefix + keep)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        addSubview(scroll)
        var top = topAnchor
        if let header {
            let head = Box(fill: Palette.raise, border: nil, radius: 0)
            head.addSubview(header)
            header.translatesAutoresizingMaskIntoConstraints = false
            let sep = Box(fill: Palette.line, border: nil, radius: 0)
            addSubview(head)
            addSubview(sep)
            NSLayoutConstraint.activate([
                header.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: inset.left),
                header.trailingAnchor.constraint(equalTo: head.trailingAnchor, constant: -inset.right),
                header.topAnchor.constraint(equalTo: head.topAnchor, constant: inset.top),
                header.bottomAnchor.constraint(equalTo: head.bottomAnchor, constant: -inset.bottom),
                head.leadingAnchor.constraint(equalTo: leadingAnchor), head.trailingAnchor.constraint(equalTo: trailingAnchor),
                head.topAnchor.constraint(equalTo: topAnchor),
                sep.leadingAnchor.constraint(equalTo: leadingAnchor), sep.trailingAnchor.constraint(equalTo: trailingAnchor),
                sep.topAnchor.constraint(equalTo: head.bottomAnchor), sep.heightAnchor.constraint(equalToConstant: 1),
            ])
            top = sep.bottomAnchor
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: top), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            list.leadingAnchor.constraint(equalTo: doc.leadingAnchor), list.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            list.topAnchor.constraint(equalTo: doc.topAnchor), list.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
        ])
        if let maxHeight {
            let fit = scroll.heightAnchor.constraint(equalTo: doc.heightAnchor)
            fit.priority = .defaultHigh
            NSLayoutConstraint.activate([scroll.heightAnchor.constraint(lessThanOrEqualToConstant: maxHeight), fit])
        } else {
            setContentHuggingPriority(.init(1), for: .vertical)
            setContentCompressionResistancePriority(.init(1), for: .vertical)
            // Below `PageScroll.fillHeight`: a long table fills the page, a short one fits its rows.
            // Below the window size (500), so a long table cannot make the window taller.
            let fit = scroll.heightAnchor.constraint(equalTo: doc.heightAnchor)
            fit.priority = .init(490)
            NSLayoutConstraint.activate([scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 44), fit])
        }
        scroll.contentView.postsBoundsChangedNotifications = true
        observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) {
            [weak self] _ in self?.pin()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    // A row with no group, or a row of the last group.
    func add(_ v: NSView) {
        if !list.arrangedSubviews.isEmpty {
            let sep = Box(fill: Palette.line, border: nil, radius: 0)
            sep.heightAnchor.constraint(equalToConstant: 1).isActive = true
            list.addFull(sep)
        }
        list.addFull(v)
    }

    // A group header. `make` runs twice: once for the list, once for the pinned copy.
    func addGroup(_ make: () -> NSView) {
        let head = make()
        add(head)
        pin(head, copy: make())
    }

    // The pinned copies of the group rows of `apply`. They change only when a group header changes.
    func didApply() {
        let now = reconciler.groups
        let same = now.count == groups.count && zip(now, groups).allSatisfy { $0.view === $1.head } && now.map(\.hash) == pinnedHashes
        guard !same else { return }
        groups.forEach { $0.pinned.removeFromSuperview() }
        groups = []
        for g in now { pin(g.view, copy: g.make()) }
        pinnedHashes = now.map(\.hash)
        needsLayout = true
    }

    private func pin(_ head: NSView, copy content: NSView) {
        let pinned = Box(fill: (head as? Row)?.restFill ?? Palette.side, border: nil, radius: 0)
        content.translatesAutoresizingMaskIntoConstraints = false
        pinned.addSubview(content)
        let line = Box(fill: Palette.line, border: nil, radius: 0)
        pinned.addSubview(line)
        pinned.isHidden = true
        addSubview(pinned)
        let top = pinned.topAnchor.constraint(equalTo: scroll.topAnchor)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: pinned.leadingAnchor), content.trailingAnchor.constraint(equalTo: pinned.trailingAnchor),
            content.topAnchor.constraint(equalTo: pinned.topAnchor), content.bottomAnchor.constraint(equalTo: pinned.bottomAnchor),
            line.leadingAnchor.constraint(equalTo: pinned.leadingAnchor), line.trailingAnchor.constraint(equalTo: pinned.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: pinned.bottomAnchor), line.heightAnchor.constraint(equalToConstant: 1),
            pinned.leadingAnchor.constraint(equalTo: scroll.leadingAnchor), pinned.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            top,
        ])
        groups.append((head, pinned, top))
    }

    // Removes the rows and the groups, and keeps the header.
    func clear() {
        list.clear()
        groups.forEach { $0.pinned.removeFromSuperview() }
        groups = []
    }

    // Shows the pinned header of the group at the top. The next header pushes it up.
    private func pin() {
        guard let doc = scroll.documentView else { return }
        let y = scroll.contentView.bounds.minY
        let tops = groups.map { $0.head.convert($0.head.bounds, to: doc).minY }
        let active = tops.lastIndex { $0 < y }
        for (i, g) in groups.enumerated() {
            g.pinned.isHidden = i != active
            guard i == active else { continue }
            let h = g.head.bounds.height
            let next = i + 1 < tops.count ? tops[i + 1] - y : .greatestFiniteMagnitude
            g.top.constant = min(0, next - h)
        }
    }

    override func layout() {
        super.layout()
        pin()
    }
}

extension StickyListCard {
    // The table of a table page: the column header stays at the top, the rows take the free height and scroll.
    static func table(_ layout: ColumnLayout?) -> StickyListCard {
        StickyListCard(header: layout.map { TableHeader($0) }, maxHeight: nil, inset: NSEdgeInsets(top: 3, left: 0, bottom: 3, right: 0), keep: "table")
    }

    // A group row: a title and a count. It stays at the top while its rows scroll.
    func addGroup(_ title: String, count: Int, lead: @escaping () -> [NSView] = { [] }, trailing: @escaping () -> [NSView] = { [] }) {
        addGroup { StickyListCard.groupHead(title, count: count, lead: lead, trailing: trailing) }
    }

    static func groupHead(_ title: String, count: Int, fold: GroupFold? = nil, lead: () -> [NSView] = { [] }, trailing: () -> [NSView] = { [] }) -> Row {
        let head = GroupHead(fold: fold)
        head.show(groupViews(title, count: count, fold: fold, lead: lead(), trailing: trailing()), title: title, count: count)
        return head
    }

    private static func groupViews(_ title: String, count: Int, fold: GroupFold?, lead: [NSView], trailing: [NSView]) -> [NSView] {
        let chevron = fold.map { [Glyph($0.expanded ? "chevron.down" : "chevron.right", color: Palette.mut, size: 10)] } ?? []
        return chevron + lead + [NSTextField.text(title, size: 12.5, weight: .semibold), NSTextField.text("\(count)", size: 12, color: Palette.dim), Spacer()] + trailing
    }

    /// The group row of `apply`. Its hash is the title and the count, plus `extra` for the views of `lead` and `trailing`.
    /// With `fold`, the row folds the group. A change updates the row in place, so it keeps the focus.
    static func group(_ id: String, _ title: String, count: Int, extra: AnyHashable = 0, fold: GroupFold? = nil,
                      lead: @escaping () -> [NSView] = { [] }, trailing: @escaping () -> [NSView] = { [] }) -> PageRow {
        var r = PageRow("group." + id, title, count, extra, fold?.expanded, update: { v in
            guard let head = v as? GroupHead else { return }
            head.fold = fold
            head.show(groupViews(title, count: count, fold: fold, lead: lead(), trailing: trailing()), title: title, count: count)
        }) { StickyListCard.groupHead(title, count: count, fold: fold, lead: lead, trailing: trailing) }
        r.group = true
        return r
    }
}

/// The fold state of a group row, and the action that changes it.
struct GroupFold {
    let expanded: Bool
    let toggle: () -> Void
}

// A group row. With a fold, a click, Space or Return folds or opens the group. Left folds, right opens.
final class GroupHead: Row {
    var fold: GroupFold? { didSet { applyFold() } }

    init(fold: GroupFold?) {
        self.fold = fold
        super.init([], height: 32)
        restFill = Palette.raise
        applyFold()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func applyFold() {
        onClick = fold?.toggle
        setAccessibilityRole(fold == nil ? .group : .disclosureTriangle)
        setAccessibilityValue(fold.map { $0.expanded ? 1 : 0 })
        setAccessibilityDisclosed(fold?.expanded ?? false)
    }

    func show(_ views: [NSView], title: String, count: Int) {
        stack.setViews(views, in: .leading)
        let state = fold.map { $0.expanded ? ", expanded" : ", folded" } ?? ""
        setAccessibilityLabel("\(title), \(count)\(state)")
    }

    override func keyDown(with event: NSEvent) {
        if let fold, event.keyCode == 123 || event.keyCode == 124 {
            if fold.expanded == (event.keyCode == 123) { fold.toggle() }
            return
        }
        super.keyDown(with: event)
    }
}

// Scrollers over the rows, in all scroller settings. A scroller at the side would move the columns away from the header.
// A fixed side column and a body that scrolls on its own. It takes the free page height (`Page.fillsHeight`).
final class SidePane: NSView {
    let pane: NSScrollView = OverlayScroll()

    init(side: NSView, body: NSView, sideWidth: CGFloat, keep: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.init(1), for: .vertical)
        setContentCompressionResistancePriority(.init(1), for: .vertical)
        let doc = Flipped()
        [doc, body, side, pane].forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        doc.addSubview(body)
        pane.identifier = NSUserInterfaceItemIdentifier(PageScroll.keepPrefix + keep)
        pane.drawsBackground = false
        pane.hasVerticalScroller = true
        pane.autohidesScrollers = true
        pane.documentView = doc
        addSubview(side)
        addSubview(pane)
        // Not required: a narrow page scrolls sideways.
        let fit = doc.widthAnchor.constraint(equalTo: pane.contentView.widthAnchor)
        fit.priority = .defaultHigh
        NSLayoutConstraint.activate([
            side.leadingAnchor.constraint(equalTo: leadingAnchor), side.topAnchor.constraint(equalTo: topAnchor),
            side.widthAnchor.constraint(equalToConstant: sideWidth), side.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            pane.leadingAnchor.constraint(equalTo: side.trailingAnchor, constant: 16), pane.trailingAnchor.constraint(equalTo: trailingAnchor),
            pane.topAnchor.constraint(equalTo: topAnchor), pane.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 200),
            doc.leadingAnchor.constraint(equalTo: pane.contentView.leadingAnchor), doc.topAnchor.constraint(equalTo: pane.contentView.topAnchor),
            fit, doc.widthAnchor.constraint(greaterThanOrEqualTo: pane.contentView.widthAnchor),
            body.leadingAnchor.constraint(equalTo: doc.leadingAnchor), body.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            body.topAnchor.constraint(equalTo: doc.topAnchor), body.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -16),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        if let doc = pane.documentView, Self.fitLabels(doc) { doc.needsLayout = true }
    }

    // Some views find their height only in a second pass. Run it on the next turn, not on the next event.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.settle() }
    }

    func settle() {
        guard let doc = pane.documentView else { return }
        Self.fitLabels(doc)
        layoutSubtreeIfNeeded()
        pane.reflectScrolledClipView(pane.contentView)
    }

    // A wrapped label measures its height at its real width. True when a width changed.
    @discardableResult
    static func fitLabels(_ v: NSView) -> Bool {
        var changed = false
        if let f = v as? NSTextField, f.maximumNumberOfLines != 1, !f.isEditable, f.frame.width > 0, f.preferredMaxLayoutWidth != f.frame.width {
            f.preferredMaxLayoutWidth = f.frame.width
            f.invalidateIntrinsicContentSize()
            changed = true
        }
        for sub in v.subviews where fitLabels(sub) { changed = true }
        return changed
    }
}

private final class OverlayScroll: NSScrollView {
    override var scrollerStyle: NSScroller.Style { get { .overlay } set {} }
}

// A provider card: icon, name, a detail line, a status pill and actions.
final class ServiceCard: Box {
    init(icon: NSView, name: String, detail: String, status: NSView?, actions: [NSView], dashed: Bool = false, onClick: (() -> Void)? = nil) {
        super.init(fill: dashed ? nil : Palette.panel, border: Palette.line, radius: 10)
        let text = TwoLine(name, detail, weight: .semibold)
        if let status { status.widthAnchor.constraint(equalToConstant: ceil(status.fittingSize.width)).isActive = true }
        let top = NSStackView(h: [icon, text] + (status.map { [$0] } ?? []), spacing: 10)
        let col = NSStackView(v: [top], spacing: 10)
        top.widthAnchor.constraint(equalTo: col.widthAnchor).isActive = true
        if !actions.isEmpty { col.addArrangedSubview(NSStackView(h: actions, spacing: 6)) }
        addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            col.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            col.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            col.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        if dashed { wantsLayer = true; borderWidth = 1 }
        self.onClick = onClick
        setAccessibilityElement(onClick != nil)
        setAccessibilityRole(onClick == nil ? .group : .button)
        setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var onClick: (() -> Void)?
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
    override var acceptsFirstResponder: Bool { onClick != nil }
    override var canBecomeKeyView: Bool { onClick != nil }
    override func keyDown(with event: NSEvent) {
        if onClick != nil, [36, 49, 76].contains(event.keyCode) { onClick?(); return }
        super.keyDown(with: event)
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill() }
    override var focusRingMaskBounds: NSRect { bounds }

    // A square with a letter, or a symbol for a dashed card.
    static func icon(_ text: String, color: NSColor?) -> NSView {
        let b = Box(fill: color, border: color == nil ? Palette.line : nil, radius: 7)
        let l = NSTextField.text(text, size: 12, weight: .bold, color: color == nil ? Palette.dim : .white)
        l.alignment = .center
        b.addSubview(l)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: 28), b.heightAnchor.constraint(equalToConstant: 28),
            l.centerXAnchor.constraint(equalTo: b.centerXAnchor), l.centerYAnchor.constraint(equalTo: b.centerYAnchor),
        ])
        return b
    }
}

// Cards in equal columns. The column count follows the width: each column is at least `minWidth` wide.
final class CardGrid: NSStackView {
    private let items: [NSView]
    private let minWidth: CGFloat
    private var columns = 0

    init(_ items: [NSView], minWidth: CGFloat = 220, gap: CGFloat = 12) {
        self.items = items
        self.minWidth = minWidth
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = gap
        translatesAutoresizingMaskIntoConstraints = false
        regroup(2)
    }
    required init(coder: NSCoder) { fatalError() }

    override func setFrameSize(_ size: NSSize) {
        super.setFrameSize(size)
        let n = max(1, min(items.count, Int((size.width + spacing) / (minWidth + spacing))))
        if n != columns { regroup(n) }
    }

    private func regroup(_ n: Int) {
        columns = n
        clear()
        for start in stride(from: 0, to: items.count, by: n) {
            let slice = Array(items[start..<min(start + n, items.count)])
            let fillers = (0..<(n - slice.count)).map { _ in Spacer() as NSView }
            let row = NSStackView(h: slice + fillers, spacing: spacing, align: .top)
            row.distribution = .fillEqually
            addFull(row)
        }
    }
}

// ─── Tables with resizable columns ───────────────────────────────────────────

struct TableColumn {
    let id: String
    let title: String
    var width: CGFloat
    let min: CGFloat
    var flexible = false        // takes the remaining width (title column)
    var optional = false        // the user can hide it
}

// A view whose column widths follow a ColumnLayout.
protocol ColumnFollower: AnyObject {
    func columnsChanged()
    func cellWidth(_ col: String) -> CGFloat?
}

// The column widths of one table, shared by the header and all rows. Saved in UserDefaults.
final class ColumnLayout {
    let id: String
    let columns: [TableColumn]
    private let defaults: UserDefaults
    private var widths: [String: CGFloat]
    private let followers = NSHashTable<AnyObject>.weakObjects()
    var hidden: Set<String> {
        didSet {
            defaults.set(Array(hidden).sorted(), forKey: "table.\(id).hidden")
            notify()
        }
    }

    init(id: String, columns: [TableColumn], defaults: UserDefaults = .standard) {
        self.id = id
        self.columns = columns
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: "table.\(id).widths") as? [String: Double] ?? [:]
        widths = Dictionary(uniqueKeysWithValues: columns.map { c in (c.id, max(c.min, saved[c.id].map { CGFloat($0) } ?? c.width)) })
        let known = Set(columns.filter(\.optional).map(\.id))
        hidden = Set(defaults.stringArray(forKey: "table.\(id).hidden") ?? []).intersection(known)
    }

    // The header sets the room. Fixed columns shrink together toward their minimum to fit it,
    // so the header and all rows stay aligned. Only a table wider than its minimums scrolls.
    private var room: CGFloat = .greatestFiniteMagnitude
    private var trailing: CGFloat = 0
    private var shrink: CGFloat = 0

    func column(_ col: String) -> TableColumn? { columns.first { $0.id == col } }
    func width(_ col: String) -> CGFloat {
        guard let w = widths[col], let c = column(col), !c.flexible else { return widths[col] ?? 0 }
        return (w - (w - c.min) * shrink).rounded(.down)
    }

    func fit(room r: CGFloat) {
        guard abs(r - room) >= 1 else { return }
        room = r
        refit()
    }

    // The widest trailing views of a row, such as buttons.
    func reserve(_ w: CGFloat) {
        guard w > trailing else { return }
        trailing = w
        refit()
    }

    private func refit() {
        let shown = columns.filter { isVisible($0.id) }
        let fixed = shown.filter { !$0.flexible }
        let need = shown.reduce(0) { $0 + ($1.flexible ? $1.min : widths[$1.id] ?? 0) } + trailing + CGFloat(shown.count + 1) * 10
        let slack = fixed.reduce(0) { $0 + (widths[$1.id] ?? 0) - $1.min }
        let s = need <= room || slack <= 0 ? 0 : min(1, (need - room) / slack)
        guard abs(s - shrink) > 0.001 else { return }
        shrink = s
        notify()
    }
    func isVisible(_ col: String) -> Bool { !hidden.contains(col) }

    func setWidth(_ col: String, _ w: CGFloat) {
        guard let c = column(col), !c.flexible else { return }
        let v = max(c.min, w.rounded())
        guard v != widths[col] else { return }
        widths[col] = v
        save()
        notify()
    }

    // The widest cell of the column, header title included.
    func fit(_ col: String) {
        let cells = followers.allObjects.compactMap { ($0 as? ColumnFollower)?.cellWidth(col) }
        guard let w = cells.max() else { return }
        setWidth(col, w)
    }

    func reset() {
        widths = Dictionary(uniqueKeysWithValues: columns.map { ($0.id, $0.width) })
        defaults.removeObject(forKey: "table.\(id).widths")
        hidden = []
    }

    func follow(_ f: ColumnFollower) { followers.add(f) }

    // The header menu: show or hide optional columns, reset the widths.
    func menuItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = columns.filter(\.optional).map { c in
            let i = MenuAction(c.title) { [weak self] in
                guard let self else { return }
                if self.hidden.contains(c.id) { self.hidden.remove(c.id) } else { self.hidden.insert(c.id) }
            }.item
            i.state = hidden.contains(c.id) ? .off : .on
            return i
        }
        if !items.isEmpty { items.append(.separator()) }
        items.append(MenuAction("Reset column widths") { [weak self] in self?.reset() }.item)
        return items
    }

    private func save() {
        let changed = widths.filter { k, v in column(k).map { $0.width != v } ?? false }
        defaults.set(changed.mapValues { Double($0) }, forKey: "table.\(id).widths")
    }

    private func notify() { followers.allObjects.forEach { ($0 as? ColumnFollower)?.columnsChanged() } }
}

// Wraps the cells of a table line. Width constraints follow the layout in place, without a page rebuild.
final class ColumnCells {
    let layout: ColumnLayout
    private(set) var boxes: [String: NSView] = [:]
    private var constraints: [String: NSLayoutConstraint] = [:]
    private var content: [String: NSView] = [:]

    init(_ layout: ColumnLayout, _ cells: [String: NSView]) {
        self.layout = layout
        content = cells
    }

    // The views in column order, for a horizontal stack.
    func views() -> [NSView] {
        layout.columns.map { c in
            let v = content[c.id] ?? NSView()
            v.translatesAutoresizingMaskIntoConstraints = false
            let box: NSView
            if c.flexible {
                let s = NSStackView(h: [v], spacing: 0)
                // The stack's own hugging (250) ties with the row stack; without this the column does not always stretch.
                s.setHuggingPriority(.init(1), for: .horizontal)
                box = s
                box.setContentHuggingPriority(.init(1), for: .horizontal)
                box.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                let min = box.widthAnchor.constraint(greaterThanOrEqualToConstant: c.min)
                min.priority = .defaultHigh
                min.isActive = true
            } else {
                box = NSStackView(h: [v, Spacer()], spacing: 0)
                v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                let w = box.widthAnchor.constraint(equalToConstant: layout.width(c.id))
                w.isActive = true
                constraints[c.id] = w
            }
            box.isHidden = !layout.isVisible(c.id)
            boxes[c.id] = box
            return box
        }
    }

    func update() {
        for (id, w) in constraints { w.constant = layout.width(id) }
        for (id, b) in boxes { b.isHidden = !layout.isVisible(id) }
    }

    // A label in a fixed-width box can fit smaller, so its own text width counts first.
    func fittingWidth(_ col: String) -> CGFloat? {
        content[col].map { v in
            let w = v.intrinsicContentSize.width
            return ceil(w > 0 ? w : v.fittingSize.width)
        }
    }
}

// A table line: cells keyed by column id.
class TableRow: Row, ColumnFollower {
    let cells: ColumnCells

    init(_ layout: ColumnLayout, cells: [String: NSView], trailing: [NSView] = [], height: CGFloat = 38, label: String? = nil,
         onClick: (() -> Void)? = nil) {
        self.cells = ColumnCells(layout, cells)
        let fill: [NSView] = layout.columns.contains(where: \.flexible) ? [] : [Spacer()]
        super.init(self.cells.views() + fill + trailing, height: height, label: label, onClick: onClick)
        layout.follow(self)
        if !trailing.isEmpty { layout.reserve(trailing.reduce(0) { $0 + ceil($1.fittingSize.width) + 10 }) }
    }
    required init?(coder: NSCoder) { fatalError() }

    func columnsChanged() { cells.update() }
    func cellWidth(_ col: String) -> CGFloat? { cells.fittingWidth(col) }
}

// The header of a table: titles, drag handles, double-click to fit, right-click menu.
final class TableHeader: Row, ColumnFollower {
    private let cells: ColumnCells

    init(_ layout: ColumnLayout) {
        var titles: [String: NSView] = [:]
        for c in layout.columns { titles[c.id] = HeaderCell(c, layout: layout) }
        cells = ColumnCells(layout, titles)
        let fill: [NSView] = layout.columns.contains(where: \.flexible) ? [] : [Spacer()]
        super.init(cells.views() + fill, height: 28)
        stack.edgeInsets = .init()
        layout.follow(self)
        menuItems = { layout.menuItems() }
        setAccessibilityRole(.group)
        setAccessibilityLabel("Column headers")
    }
    required init?(coder: NSCoder) { fatalError() }

    func columnsChanged() { cells.update() }
    func cellWidth(_ col: String) -> CGFloat? { cells.fittingWidth(col) }

    // The visible page width, not the own width: a table wider than the page must not raise its own room.
    override func layout() {
        super.layout()
        guard let scroll = enclosingScrollView, let doc = scroll.documentView else { return }
        let x = convert(NSPoint.zero, to: doc).x
        cells.layout.fit(room: min(bounds.width, scroll.contentView.bounds.width - 2 * x) - 28)
    }
}

// One header title. A resizable column has a handle on its trailing edge, and takes keyboard focus:
// Option-Left and Option-Right change the width by 10 pt.
final class HeaderCell: NSView {
    private let column: TableColumn
    private weak var layout: ColumnLayout?
    private let label: NSTextField

    init(_ c: TableColumn, layout: ColumnLayout) {
        column = c
        self.layout = layout
        label = .text(c.title.uppercased(), size: 10.5, weight: .semibold, color: Palette.dim)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if !c.flexible {
            let h = ResizeHandle(column: c.id, layout: layout)
            addSubview(h)
            NSLayoutConstraint.activate([
                h.widthAnchor.constraint(equalToConstant: 10),
                h.centerXAnchor.constraint(equalTo: trailingAnchor),
                h.topAnchor.constraint(equalTo: topAnchor, constant: -4),
                h.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 4),
            ])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(c.title.isEmpty ? c.id : c.title)
        if !c.flexible { setAccessibilityHelp("Option-Left and Option-Right change the width") }
    }
    required init?(coder: NSCoder) { fatalError() }

    // The header title is narrower than the cells. It counts for "fit" only when no row is wider.
    override var fittingSize: NSSize { NSSize(width: label.fittingSize.width + 12, height: label.fittingSize.height) }

    override var acceptsFirstResponder: Bool { !column.flexible }
    override var canBecomeKeyView: Bool { !column.flexible }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds.insetBy(dx: -3, dy: -2), xRadius: 4, yRadius: 4).fill() }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: -3, dy: -2) }

    override func keyDown(with event: NSEvent) {
        guard let layout, event.modifierFlags.contains(.option), event.keyCode == 123 || event.keyCode == 124 else { return super.keyDown(with: event) }
        layout.setWidth(column.id, layout.width(column.id) + (event.keyCode == 124 ? 10 : -10))
    }
}

// The drag area between two header titles. A double-click fits the column to its widest cell.
final class ResizeHandle: NSView {
    private let column: String
    private weak var layout: ColumnLayout?
    private var start: (x: CGFloat, w: CGFloat)?
    private var hover = false { didSet { needsDisplay = true } }

    init(column: String, layout: ColumnLayout) {
        self.column = column
        self.layout = layout
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        toolTip = "Drag to resize. Double-click to fit."
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let w: CGFloat = hover || start != nil ? 2 : 1
        (hover || start != nil ? Palette.acc : Palette.line).setFill()
        NSRect(x: (bounds.width - w) / 2, y: bounds.midY - 7, width: w, height: 14).fill()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }

    override func mouseDown(with event: NSEvent) {
        guard let layout else { return }
        if event.clickCount == 2 { layout.fit(column); return }
        start = (event.locationInWindow.x, layout.width(column))
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start, let layout else { return }
        layout.setWidth(column, start.w + event.locationInWindow.x - start.x)
    }
    override func mouseUp(with event: NSEvent) { start = nil; needsDisplay = true }
}

// Small icon buttons that show on a row while the pointer is on it.
enum RowActions {
    // Copy link, Copy ID, Open in the tracker.
    static func item(url: String, key: String, tracker: String = "Plane") -> [NSView] {
        [IconButton("link", label: "Copy link of \(key)", tip: "Copy link (⇧⌘C)", copy: url),
         IconButton("number", label: "Copy ID \(key)", tip: "Copy ID (⌘C)", copy: key),
         IconButton("arrow.up.right.square", label: "Open \(key) in \(tracker)", tip: "Open in \(tracker)") {
             if let u = URL(string: url) { NSWorkspace.shared.open(u) }
         }]
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

// A borderless symbol button. A copy button shows a check for 1 s after the copy.
final class IconButton: NSButton {
    private let symbol: String
    private let run: () -> Void
    private let copies: Bool

    init(_ symbol: String, label: String, tip: String, copy text: String? = nil, _ run: (() -> Void)? = nil) {
        self.symbol = symbol
        copies = text != nil
        self.run = run ?? { text.map(RowActions.copy) }
        super.init(frame: .zero)
        isBordered = false
        imagePosition = .imageOnly
        target = self
        action = #selector(fire)
        toolTip = tip
        setAccessibilityLabel(label)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 24).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
        show(symbol, Palette.mut)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func show(_ s: String, _ c: NSColor) {
        image = NSImage(systemSymbolName: s, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 12.5, weight: .medium))
        contentTintColor = c
    }

    @objc private func fire() {
        run()
        guard copies else { return }
        show("checkmark", Palette.ok)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.show(self.symbol, Palette.mut)
        }
    }
}
