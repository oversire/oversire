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
    convenience init(_ tone: Tone, size: CGFloat = 14) { self.init(tone.symbol, color: tone.color, size: size, label: tone.word) }
    required init?(coder: NSCoder) { fatalError() }
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
    override func resetCursorRects() { if !isBordered { addCursorRect(bounds, cursor: .pointingHand) } }
}

// A small rounded label: "main", "FRITZ-17", "3 / 5". A click handler makes it a button.
class Chiplet: Box {
    var onClick: (() -> Void)?
    private let label: NSTextField

    init(_ text: String, symbol: String? = nil, color: NSColor = Palette.mut, fill: NSColor = Palette.raise,
         mono: Bool = false, onClick: (() -> Void)? = nil) {
        label = .text(text, size: 11.5, weight: .medium, color: color, mono: mono)
        self.onClick = onClick
        super.init(fill: fill, border: Palette.line, radius: 5)
        var views: [NSView] = []
        if let symbol { views.append(Glyph(symbol, color: color, size: 10.5)) }
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

    override func mouseUp(with event: NSEvent) { onClick?() }
    override func resetCursorRects() { if onClick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
}

// A tone as a colored pill: symbol and word, so the state never relies on color alone.
final class Pill: Box {
    init(_ tone: Tone, text: String? = nil) {
        super.init(fill: tone.color.withAlphaComponent(0.16), border: nil, radius: 9)
        let s = NSStackView(h: [Glyph(tone.symbol, color: tone.color, size: 10),
                                NSTextField.text(text ?? tone.word, size: 11.5, weight: .semibold, color: tone.color)], spacing: 4)
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

    private func updateFill() {
        fill = selected || (hover && onClick != nil) ? Palette.sel : nil
        let focused = window?.firstResponder === self
        border = focused ? Palette.acc : nil
        overlay?.isHidden = !(hover || focused || hoverViews.contains { $0 is NSProgressIndicator })
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
    override func becomeFirstResponder() -> Bool { DispatchQueue.main.async { self.updateFill() }; return true }
    override func resignFirstResponder() -> Bool { DispatchQueue.main.async { self.updateFill() }; return true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76 { onClick?() } else { super.keyDown(with: event) }
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
}

// Title above a subtitle. Use as the main column of a row.
final class TwoLine: NSStackView {
    init(_ title: String, _ subtitle: String?, titleSize: CGFloat = 13, weight: NSFont.Weight = .medium,
         titleColor: NSColor = Palette.fg, lines: Int = 1) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        addArrangedSubview(NSTextField.text(title, size: titleSize, weight: weight, color: titleColor, lines: lines))
        if let subtitle, !subtitle.isEmpty { addArrangedSubview(NSTextField.text(subtitle, size: 11.5, color: Palette.dim)) }
        setContentHuggingPriority(.init(1), for: .horizontal)
        setContentCompressionResistancePriority(.init(1), for: .horizontal)
    }
    required init(coder: NSCoder) { fatalError() }
}

// A number tile on a dashboard. A click opens the matching page.
final class Tile: Row {
    init(_ value: String, _ caption: String, tone: Tone, onClick: (() -> Void)?) {
        let v = NSTextField.text(value, size: 22, weight: .semibold)
        v.font = .monospacedDigitSystemFont(ofSize: 22, weight: .semibold)
        let c = NSStackView(h: [Glyph(tone, size: 12), NSTextField.text(caption, size: 12, color: Palette.mut)], spacing: 5)
        let col = NSStackView(v: [v, c], spacing: 2)
        super.init([col], height: 64, inset: 14, label: "\(value) \(caption)", onClick: onClick)
        fill = Palette.panel; border = Palette.line; radius = 10
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
    var onSelect: ((Int) -> Void)?
    private var buttons: [NSButton] = []

    init(_ titles: [String], selected: Int, counts: [Int?] = []) {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 2
        translatesAutoresizingMaskIntoConstraints = false
        for (i, t) in titles.enumerated() {
            let count = i < counts.count ? counts[i] : nil
            let b = NSButton(title: t, target: self, action: #selector(pick(_:)))
            b.isBordered = false
            b.tag = i
            let on = i == selected
            var s = t
            if let count { s += "  \(count)" }
            b.attributedTitle = NSAttributedString(string: s, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: on ? .semibold : .regular),
                .foregroundColor: on ? Palette.fg : Palette.mut])
            b.setAccessibilityRole(.radioButton)
            b.setAccessibilityValue(on ? 1 : 0)
            let wrap = NSStackView(v: [b, Box(fill: on ? Palette.acc : .clear, border: nil, radius: 1)], spacing: 6, align: .centerX)
            let line = wrap.arrangedSubviews[1]
            line.heightAnchor.constraint(equalToConstant: 2).isActive = true
            line.widthAnchor.constraint(equalTo: wrap.widthAnchor).isActive = true
            wrap.edgeInsets = NSEdgeInsets(top: 4, left: 8, bottom: 0, right: 8)
            addArrangedSubview(wrap)
            buttons.append(b)
        }
        setAccessibilityRole(.tabGroup)
        setHuggingPriority(.required, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pick(_ b: NSButton) { onSelect?(b.tag) }
}

// Page title line: big title, a small caption, then actions on the right.
final class PageHeader: NSStackView {
    init(_ title: String, caption: String? = nil, actions: [NSView] = []) {
        super.init(frame: .zero)
        orientation = .horizontal
        alignment = .centerY
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        let t = NSStackView(v: [NSTextField.text(title, size: 20, weight: .semibold, lines: 2)], spacing: 2)
        if let caption { t.addArrangedSubview(NSTextField.text(caption, size: 12, color: Palette.dim, lines: 2)) }
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
final class PageScroll: NSScrollView {
    let column: NSStackView

    init(maxWidth: CGFloat = 1100) {
        column = NSStackView(v: [], spacing: 16)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = false
        let doc = Flipped()
        doc.translatesAutoresizingMaskIntoConstraints = false
        documentView = doc
        column.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 28, right: 24)
        doc.addSubview(column)
        let w = column.widthAnchor.constraint(equalTo: doc.widthAnchor)
        w.priority = .defaultHigh
        NSLayoutConstraint.activate([
            doc.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            doc.topAnchor.constraint(equalTo: contentView.topAnchor),
            column.topAnchor.constraint(equalTo: doc.topAnchor),
            column.bottomAnchor.constraint(equalTo: doc.bottomAnchor),
            column.centerXAnchor.constraint(equalTo: doc.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: maxWidth),
            w,
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func rebuild(_ build: (NSStackView) -> Void) {
        let y = contentView.bounds.origin.y
        column.clear()
        build(column)
        layoutSubtreeIfNeeded()
        let maxY = max(0, (documentView?.frame.height ?? 0) - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: min(y, maxY)))
        reflectScrolledClipView(contentView)
    }

    func toTop() {
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
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

// A list in a card: rows with a line between them.
final class ListCard: Box {
    let list: NSStackView

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

    var isEmpty: Bool { list.arrangedSubviews.isEmpty }
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

    func column(_ col: String) -> TableColumn? { columns.first { $0.id == col } }
    func width(_ col: String) -> CGFloat { widths[col] ?? 0 }
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
                box = NSStackView(h: [v], spacing: 0)
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
