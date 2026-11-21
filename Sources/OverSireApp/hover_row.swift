import Cocoa

// Base of the popover rows: hover fill, click to toggle, Return and Space, open URL.
class HoverRow: NSView {
    let urlStr: String
    let expanded: Bool
    var onToggle: (() -> Void)?
    private var trackingArea: NSTrackingArea?

    init(urlStr: String, expanded: Bool, frame: NSRect) {
        self.urlStr = urlStr
        self.expanded = expanded
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = restingColor
    }
    required init?(coder: NSCoder) { fatalError() }

    var restingColor: CGColor? {
        expanded ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.1).cgColor : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        trackingArea = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(trackingArea!)
    }
    // Scrolling moves rows under a still pointer, so hover follows the real pointer position.
    override func mouseEntered(with event: NSEvent) { animateHover() }
    override func mouseExited(with event: NSEvent) { animateHover() }
    func animateHover() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15; ctx.allowsImplicitAnimation = true; syncHover()
        }
    }
    override func mouseDown(with event: NSEvent) {
        layer?.backgroundColor = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor
    }
    override func mouseUp(with event: NSEvent) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15; ctx.allowsImplicitAnimation = true; layer?.backgroundColor = restingColor
        }
        let loc = convert(event.locationInWindow, from: nil)
        guard bounds.contains(loc) else { return }
        for sub in subviews where sub is NSButton { if sub.frame.contains(loc) { return } }
        onToggle?()
    }

    func syncHover() {
        guard let win = window else { return }
        // visibleRect can extend past the row, so intersect it with bounds.
        let inside = bounds.intersection(visibleRect).contains(convert(win.mouseLocationOutsideOfEventStream, from: nil))
        layer?.backgroundColor = inside ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).cgColor : restingColor
    }

    // Keyboard accessibility
    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .exterior }
        set {}
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onToggle?() }  // Return or Space
        else { super.keyDown(with: event) }
    }

    @objc func openURL() { if let u = URL(string: urlStr) { NSWorkspace.shared.open(u) } }
}
