import Cocoa

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
