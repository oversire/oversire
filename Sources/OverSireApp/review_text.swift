import Cocoa
import OverSireCore

// ─── Changes › text selection ────────────────────────────────────────────────
// Each diff line is its own field, so the table keeps one selection across the lines (OVERSIRE-414).
// A copy gives the code only: no line numbers, no "+" or "−" marks. A split diff selects in one column.

/// The code of one diff line. The selection belongs to `DiffTableView`.
final class DiffText: NSTextField {
    weak var table: DiffTableView?
    var column = 0
    var row = 0
    /// The full line. The field can show a short form of a very long line.
    var code = ""
    var selection: NSRange? { didSet { if oldValue != selection { needsDisplay = true } } }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    override func mouseDown(with event: NSEvent) {
        guard let table else { return super.mouseDown(with: event) }
        table.track(from: self, event)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let r = selection, r.length > 0 {
            (window?.firstResponder === table ? NSColor.selectedTextBackgroundColor : NSColor.unemphasizedSelectedTextBackgroundColor).setFill()
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
