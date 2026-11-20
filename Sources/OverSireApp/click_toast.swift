import AppKit
import OverSireCore

// ─── Click toast ─────────────────────────────────────────────────────────────
// The result of a click on a client (OVERSIRE-528). One line at the bottom right. It hides after 6 s.

final class ClickToast: NSPanel {
    private(set) static var current: ClickToast?

    init(_ text: String, bad: Bool) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 40), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root = Box(fill: Palette.panel, border: Palette.line, radius: 9)
        contentView = root
        let row = NSStackView(h: [Glyph(bad ? .warning : .ok, size: 13), NSTextField.text(text, size: 12, color: Palette.fg, lines: 2)], spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 14)
        root.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: root.leadingAnchor), row.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            row.topAnchor.constraint(equalTo: root.topAnchor), row.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
        setAccessibilityLabel(text)
        row.layoutSubtreeIfNeeded()
        setContentSize(row.fittingSize)
    }

    /// Replaces the toast that shows.
    @MainActor static func show(_ text: String, bad: Bool) {
        current?.orderOut(nil)
        let t = ClickToast(text, bad: bad)
        current = t
        t.present()
    }

    private func present() {
        if let v = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame {
            setFrameOrigin(NSPoint(x: v.maxX - frame.width - 16, y: v.minY + 16))
        }
        orderFrontRegardless()
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: accessibilityLabel() ?? "", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        guard !UIShots.shooting else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.orderOut(nil) }
    }
}

/// The words of a read from the source app on a client.
enum ClientWords {
    /// The machine of the source app. The app sets it. Nil: Full mode.
    nonisolated(unsafe) static var source: (() -> String?)?

    static func loading(_ plain: String) -> String { source?().map { "Loading from \($0)…" } ?? plain }
    static func failed(_ plain: String) -> String { source?().map { "Could not load from \($0)." } ?? plain }
}
