import Cocoa
import OverSireCore

// ─── Changes › text selection ────────────────────────────────────────────────
// Each diff line is its own field, so the body keeps one selection across the lines (OVERSIRE-414).
// A copy gives the code only: no line numbers, no "+" or "−" marks. A split diff selects in one column.

/// The code of one diff line. The selection belongs to `DiffBody`.
final class DiffText: NSTextField {
    weak var body: DiffBody?
    var column = 0
    var order = 0
    /// The full line. The field can show a short form of a very long line.
    var code = ""
    var selection: NSRange? { didSet { if oldValue != selection { needsDisplay = true } } }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    override func mouseDown(with event: NSEvent) {
        guard let body else { return super.mouseDown(with: event) }
        body.track(from: self, event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let r = selection, r.length > 0 {
            (window?.firstResponder === body ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
            rects(r).forEach { $0.fill() }
        }
        super.draw(dirtyRect)
    }

    var length: Int { (stringValue as NSString).length }

    /// The text of a range. A range to the end of a short form gives the rest of the full line.
    func piece(_ r: NSRange) -> String {
        if code.isEmpty { return "" }
        let shown = stringValue as NSString, full = code as NSString
        if shown as String != code, NSMaxRange(r) >= shown.length, r.location <= full.length { return full.substring(from: r.location) }
        return shown.substring(with: NSIntersectionRange(r, NSRange(location: 0, length: shown.length)))
    }

    /// The word at a character, for a double-click.
    func word(at i: Int) -> NSRange {
        guard length > 0 else { return NSRange(location: 0, length: 0) }
        return attributedStringValue.doubleClick(at: min(i, length - 1))
    }

    // MARK: Layout

    /// The layout manager keeps only a weak reference to its storage, so the storage stays here.
    private var lay: (width: CGFloat, text: NSAttributedString, storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer, origin: NSPoint)?

    private func layout() -> (manager: NSLayoutManager, container: NSTextContainer, origin: NSPoint) {
        let rect = cell?.drawingRect(forBounds: bounds) ?? bounds
        let text = attributedStringValue
        if let l = lay, l.width == rect.width, l.text == text { return (l.manager, l.container, l.origin) }
        let storage = NSTextStorage(attributedString: text)
        let manager = NSLayoutManager()
        let wraps = maximumNumberOfLines != 1
        let container = NSTextContainer(size: NSSize(width: wraps ? rect.width : .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 2
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let origin = NSPoint(x: rect.minX, y: isFlipped ? rect.minY : rect.maxY)
        lay = (rect.width, text, storage, manager, container, origin)
        return (manager, container, origin)
    }

    /// The character under a point of this view.
    func index(at p: NSPoint) -> Int {
        let (m, c, o) = layout()
        let local = NSPoint(x: p.x - o.x, y: isFlipped ? p.y - o.y : o.y - p.y)
        var fraction: CGFloat = 0
        let g = m.glyphIndex(for: local, in: c, fractionOfDistanceThroughGlyph: &fraction)
        guard g < m.numberOfGlyphs else { return length }
        let line = m.lineFragmentUsedRect(forGlyphAt: g, effectiveRange: nil)
        if local.x >= line.maxX { return NSMaxRange(m.characterRange(forGlyphRange: m.glyphRange(forBoundingRect: line, in: c), actualGlyphRange: nil)) }
        return min(length, m.characterIndexForGlyph(at: g) + (fraction > 0.5 ? 1 : 0))
    }

    private func rects(_ r: NSRange) -> [NSRect] {
        let (m, c, o) = layout()
        let glyphs = m.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var out: [NSRect] = []
        m.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: glyphs, in: c) { rect, _ in
            out.append(NSRect(x: rect.minX + o.x, y: self.isFlipped ? rect.minY + o.y : o.y - rect.maxY, width: max(rect.width, 3), height: rect.height))
        }
        return out
    }
}

/// The body of a diff. It owns the selection across its `DiffText` lines and copies it.
final class DiffBody: NSStackView {
    private var columns: [[DiffText]] = [[], []]
    private var anchor: (column: Int, order: Int, at: Int)?
    private var head: (order: Int, at: Int)?

    func adopt(_ t: DiffText, column: Int) {
        t.body = self
        t.column = column
        t.order = columns[column].count
        columns[column].append(t)
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { redraw(); return true }
    override func resignFirstResponder() -> Bool { redraw(); return true }

    /// A click starts a selection, a drag extends it, Shift-click extends the last one.
    /// A double-click picks a word, a triple-click the line.
    func track(from t: DiffText, _ event: NSEvent) {
        window?.makeFirstResponder(self)
        let at = t.index(at: t.convert(event.locationInWindow, from: nil))
        if event.clickCount >= 2 {
            let r = event.clickCount == 2 ? t.word(at: at) : NSRange(location: 0, length: t.length)
            anchor = (t.column, t.order, r.location)
            select(to: (t.order, NSMaxRange(r)))
            return
        }
        if !(event.modifierFlags.contains(.shift) && anchor?.column == t.column) { anchor = (t.column, t.order, at) }
        select(to: (t.order, at))
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if e.type == .leftMouseUp { break }
            guard let w = window else { break }
            let p = w.mouseLocationOutsideOfEventStream
            if e.type == .periodic, let drag = NSEvent.mouseEvent(with: .leftMouseDragged, location: p, modifierFlags: [], timestamp: e.timestamp,
                                                                    windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                autoscroll(with: drag)
            }
            if let h = hit(p, column: t.column) { select(to: h) }
        }
    }

    /// The line and the character under a window point. A point between lines takes the start of the next line.
    private func hit(_ p: NSPoint, column: Int) -> (order: Int, at: Int)? {
        let lines = columns[column]
        guard let last = lines.last else { return nil }
        for l in lines {
            let r = l.convert(l.bounds, to: nil)
            if p.y > r.maxY { return (l.order, 0) }
            if p.y >= r.minY { return (l.order, l.index(at: l.convert(p, from: nil))) }
        }
        return (last.order, last.length)
    }

    private func select(to h: (order: Int, at: Int)) {
        guard let a = anchor else { return }
        head = h
        let x: (Int, Int) = (a.order, a.at), y: (Int, Int) = (h.order, h.at)
        let (from, to) = x <= y ? (x, y) : (y, x)
        for (c, lines) in columns.enumerated() {
            for l in lines {
                guard c == a.column, l.order >= from.0, l.order <= to.0 else { l.selection = nil; continue }
                let start = l.order == from.0 ? from.1 : 0, end = l.order == to.0 ? to.1 : l.length
                l.selection = NSRange(location: start, length: max(0, end - start))
            }
        }
    }

    /// For `--uishots`: a selection with no mouse.
    func show(from: (order: Int, at: Int), to: (order: Int, at: Int)) {
        anchor = (0, from.order, from.at)
        select(to: to)
        window?.makeFirstResponder(self)
    }

    private func redraw() { columns.joined().forEach { if $0.selection != nil { $0.needsDisplay = true } } }

    /// The selected code, one line for each selected line.
    var selected: String? {
        guard let a = anchor, let h = head, (a.order, a.at) != (h.order, h.at) else { return nil }
        return columns[a.column].compactMap { l in l.selection.map(l.piece) }.joined(separator: "\n")
    }

    @objc func copy(_ sender: Any?) {
        guard let s = selected else { return NSSound.beep() }
        RowActions.copy(s)
    }

    @objc override func selectAll(_ sender: Any?) {
        let c = anchor?.column ?? (columns[1].isEmpty ? 0 : 1)
        guard let last = columns[c].last else { return }
        anchor = (c, 0, 0)
        select(to: (last.order, last.length))
    }

}

extension DiffBody: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(copy(_:)) ? selected != nil : true
    }
}

/// The path in the header of a diff. It is selectable. A copy button shows on hover or focus.
/// A click copies the path, an Option-click the path on the disk of the machine.
final class PathHead: NSStackView {
    /// A button that tells when it gets or loses the focus.
    private final class FocusButton: NSButton {
        var focus: () -> Void = {}
        override func becomeFirstResponder() -> Bool { DispatchQueue.main.async { self.focus() }; return super.becomeFirstResponder() }
        override func resignFirstResponder() -> Bool { DispatchQueue.main.async { self.focus() }; return super.resignFirstResponder() }
    }

    private let button = FocusButton()
    private var tracking: NSTrackingArea?
    private var copied = false
    private let path: String
    private let absolute: String

    init(_ shown: String, path: String, absolute: String) {
        self.path = path
        self.absolute = absolute
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 4
        alignment = .centerY
        translatesAutoresizingMaskIntoConstraints = false
        let field = NSTextField.text(shown, size: 12, weight: .semibold, mono: true)
        field.isSelectable = true
        field.lineBreakMode = .byTruncatingMiddle
        // Above the spacer of the header, so the spacer gives its width first.
        field.setContentCompressionResistancePriority(.init(2), for: .horizontal)
        button.isBordered = false
        button.imagePosition = .imageLeading
        button.target = self
        button.action = #selector(copyPath)
        button.focus = { [weak self] in self?.reveal() }
        button.toolTip = "Copy path. Option-click copies the full path."
        button.setAccessibilityLabel("Copy path")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 22).isActive = true
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        show(copied: false)
        addArrangedSubview(field)
        addArrangedSubview(button)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func show(copied: Bool) {
        self.copied = copied
        let symbol = copied ? "checkmark" : "doc.on.doc"
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 11.5, weight: .medium))
        button.contentTintColor = copied ? Palette.ok : Palette.mut
        button.attributedTitle = NSAttributedString(string: copied ? "Copied" : "", attributes: [.font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: Palette.ok])
        reveal()
    }

    private var hover = false { didSet { reveal() } }

    private func reveal() {
        button.alphaValue = hover || copied || window?.firstResponder === button ? 1 : 0
    }

    /// For `--uishots`: the hover look with no mouse.
    func showButton() { hover = true }

    @objc private func copyPath() {
        RowActions.copy(NSApp.currentEvent?.modifierFlags.contains(.option) == true ? absolute : path)
        show(copied: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.show(copied: false) }
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { hover = true }
    override func mouseExited(with event: NSEvent) { hover = false }
}
