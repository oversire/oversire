import Cocoa
import CoreImage
import OverSireCore
import ScreenCaptureKit

// ─── Snap capture ────────────────────────────────────────────────────────────
// The shortcut opens a dim overlay on each screen. A click takes the window under the pointer.
// A drag takes an area. ⎋ cancels. Space switches between window and area.

/// Guesses the project of a shot from the window title and the app name.
struct SnapProjectGuess {
    struct Candidate {
        var key: String        // "OVERSIRE"
        var names: [String]    // the key, the title, the repo names, the Orca folder name
    }

    let candidates: [Candidate]

    init(_ candidates: [Candidate]) { self.candidates = candidates }

    init(projects: [ProjectSummary], cfg: ProjectsConfig) {
        self.init(projects.filter { !$0.closed }.map { p in
            let l = cfg.local(p.identifier)
            let repos = l.github.compactMap { $0.split(separator: "/").last.map(String.init) }
            let root = cfg.orcaRoot(p).map { URL(fileURLWithPath: $0).lastPathComponent }
            return Candidate(key: p.identifier, names: [p.identifier, p.title] + repos + (root.map { [$0] } ?? []))
        })
    }

    /// The project whose longest name is a word in the text. A name needs 3 letters.
    func guess(app: String, title: String) -> String? {
        let text = " " + (title + " " + app).lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " } + " "
        var best: (key: String, len: Int)?
        for c in candidates {
            for n in c.names {
                let w = n.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
                let name = String(w).trimmingCharacters(in: .whitespaces)
                guard name.count >= 3, text.contains(" \(name) "), name.count > (best?.len ?? 0) else { continue }
                best = (c.key, name.count)
            }
        }
        return best?.key
    }
}

/// Point and pixel math. Cocoa global points have the origin at the bottom-left of the main screen.
/// Window list bounds and PNG pixels have it at the top-left.
enum SnapGeometry {
    /// A rect in Cocoa global points as pixels of the display image, from the top-left corner.
    static func pixels(_ r: CGRect, display: CGRect, scale: CGFloat) -> SnapRect {
        let r = r.intersection(display)
        return SnapRect(x: Double((r.minX - display.minX) * scale), y: Double((display.maxY - r.maxY) * scale),
                        w: Double(r.width * scale), h: Double(r.height * scale)).rounded()
    }

    /// A window list rect (top-left origin) in Cocoa global points.
    static func cocoa(_ r: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The display that holds the center of the rect, else the one with the most overlap.
    static func display(for r: CGRect, in frames: [CGRect]) -> Int? {
        let c = CGPoint(x: r.midX, y: r.midY)
        if let i = frames.firstIndex(where: { $0.contains(c) }) { return i }
        let areas = frames.map { f -> CGFloat in let i = f.intersection(r); return i.isNull ? 0 : i.width * i.height }
        guard let m = areas.max(), m > 0 else { return nil }
        return areas.firstIndex(of: m)
    }
}

private extension SnapRect {
    func rounded() -> SnapRect { SnapRect(x: x.rounded(), y: y.rounded(), w: w.rounded(), h: h.rounded()) }
}

/// One on-screen window from the window list, front to back.
struct SnapWindow {
    var id: CGWindowID
    var pid: pid_t
    var app: String
    var title: String
    var frame: CGRect      // Cocoa global points

    static func onScreen() -> [SnapWindow] {
        let main = NSScreen.screens.first?.frame.height ?? 0
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { d in
            guard (d[kCGWindowLayer as String] as? Int) == 0, let pid = d[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let id = d[kCGWindowNumber as String] as? CGWindowID,
                  let b = d[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b),
                  r.width > 40, r.height > 40 else { return nil }
            return SnapWindow(id: id, pid: pid, app: d[kCGWindowOwnerName as String] as? String ?? "",
                              title: d[kCGWindowName as String] as? String ?? "", frame: SnapGeometry.cocoa(r, mainHeight: main))
        }
    }
}

final class SnapCapturer {
    enum Mode { case window, area }

    private let onShot: (SnapShot, Data) -> Void
    private let guess: () -> SnapProjectGuess
    private var overlays: [SnapOverlay] = []
    private var windows: [SnapWindow] = []
    private(set) var mode = Mode.window
    private var previousApp: NSRunningApplication?

    var isActive: Bool { !overlays.isEmpty }

    init(guess: @escaping () -> SnapProjectGuess, onShot: @escaping (SnapShot, Data) -> Void) {
        self.guess = guess
        self.onShot = onShot
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Asks macOS for the permission and opens the Screen Recording page of System Settings.
    static func requestPermission() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func start() {
        guard !isActive else { return cancel() }
        guard Self.hasPermission else { return askPermission() }
        previousApp = NSWorkspace.shared.frontmostApplication
        windows = SnapWindow.onScreen()
        mode = .window
        overlays = NSScreen.screens.map { SnapOverlay(screen: $0, capturer: self) }
        NSApp.activate(ignoringOtherApps: true)
        overlays.forEach { $0.orderFrontRegardless() }
        let mouse = NSEvent.mouseLocation
        (overlays.first { $0.frame.contains(mouse) } ?? overlays.first)?.makeKey()
        hover(at: mouse)
    }

    private func askPermission() {
        let a = NSAlert()
        a.messageText = "Turn on Screen Recording"
        a.informativeText = "OverSire needs the Screen Recording permission to take snaps. Turn it on for OverSire, then open OverSire again."
        a.addButton(withTitle: "Turn on…")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn { Self.requestPermission() }
    }

    func cancel() {
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        previousApp?.activate()
        previousApp = nil
    }

    func toggleMode(at p: CGPoint) {
        mode = mode == .window ? .area : .window
        hover(at: p)
    }

    func window(at p: CGPoint) -> SnapWindow? { windows.first { $0.frame.contains(p) } }

    func hover(at p: CGPoint) {
        let hit = mode == .window ? window(at: p)?.frame : nil
        overlays.forEach { $0.show(highlight: hit, selection: nil, mode: mode) }
    }

    func drag(_ r: CGRect) { overlays.forEach { $0.show(highlight: nil, selection: r, mode: mode) } }

    func click(at p: CGPoint) {
        guard mode == .window, let w = window(at: p) else { return }
        finish { try await self.captureWindow(w) }
    }

    func select(_ r: CGRect) {
        guard r.width >= 8, r.height >= 8 else { return hover(at: CGPoint(x: r.midX, y: r.midY)) }
        let under = window(at: CGPoint(x: r.midX, y: r.midY))
        finish { try await self.captureArea(r, under: under) }
    }

    private func finish(_ capture: @escaping () async throws -> (SnapShot, Data)) {
        overlays.forEach { $0.orderOut(nil) }
        overlays = []
        Task { @MainActor in
            do {
                let (shot, png) = try await capture()
                self.onShot(shot, png)
            } catch {
                log.error("Snap capture failed: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    // MARK: Capture

    private func screen(for r: CGRect) -> NSScreen? {
        SnapGeometry.display(for: r, in: NSScreen.screens.map(\.frame)).map { NSScreen.screens[$0] }
    }

    func captureWindow(_ w: SnapWindow) async throws -> (SnapShot, Data) {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let sw = content.windows.first(where: { $0.windowID == w.id }) else { throw SnapCaptureError.gone }
        let scale = screen(for: w.frame)?.backingScaleFactor ?? 2
        let cfg = Self.config(width: w.frame.width * scale, height: w.frame.height * scale)
        let img = try await Self.image(SCContentFilter(desktopIndependentWindow: sw), cfg)
        return try shot(img, kind: .window, app: w.app, title: w.title, scale: scale)
    }

    func captureArea(_ r: CGRect, under: SnapWindow?) async throws -> (SnapShot, Data) {
        guard let scr = screen(for: r), let num = scr.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { throw SnapCaptureError.gone }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == num }) else { throw SnapCaptureError.gone }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let scale = scr.backingScaleFactor
        let full = try await Self.image(filter, Self.config(width: scr.frame.width * scale, height: scr.frame.height * scale))
        let px = SnapGeometry.pixels(r, display: scr.frame, scale: scale)
        guard let img = full.cropping(to: CGRect(x: px.x, y: px.y, width: px.w, height: px.h)) else { throw SnapCaptureError.gone }
        return try shot(img, kind: .area, app: under?.app ?? "", title: under?.title ?? "", scale: scale)
    }

    private func shot(_ img: CGImage, kind: SnapShot.Kind, app: String, title: String, scale: CGFloat) throws -> (SnapShot, Data) {
        guard let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else { throw SnapCaptureError.encode }
        let project = guess().guess(app: app, title: title) ?? PROJECTS_CFG.capture.snap.lastProject ?? ""
        let s = SnapShot(project: project, kind: kind, app: app, windowTitle: title,
                         pixelSize: CGSize(width: img.width, height: img.height), scale: Double(scale))
        return (s, png)
    }

    private static func config(width: CGFloat, height: CGFloat) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.width = Int(width.rounded())
        c.height = Int(height.rounded())
        c.showsCursor = false
        c.pixelFormat = kCVPixelFormatType_32BGRA
        if #available(macOS 14.0, *) { c.captureResolution = .best }
        return c
    }

    private static func image(_ filter: SCContentFilter, _ cfg: SCStreamConfiguration) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
        }
        return try await SnapOneFrame(filter: filter, config: cfg).take()
    }
}

enum SnapCaptureError: Error { case gone, encode, noFrame }

/// macOS 13 has no SCScreenshotManager. A stream gives one frame, then stops.
private final class SnapOneFrame: NSObject, SCStreamOutput {
    private let stream: SCStream
    private var done: CheckedContinuation<CGImage, Error>?

    init(filter: SCContentFilter, config: SCStreamConfiguration) {
        stream = SCStream(filter: filter, configuration: config, delegate: nil)
    }

    func take() async throws -> CGImage {
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: .main)
        return try await withCheckedThrowingContinuation { c in
            done = c
            stream.startCapture { [weak self] err in if let err { self?.finish(.failure(err)) } }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let buf = sb.imageBuffer else { return }
        let ci = CIImage(cvPixelBuffer: buf)
        guard let img = CIContext().createCGImage(ci, from: ci.extent) else { return finish(.failure(SnapCaptureError.noFrame)) }
        finish(.success(img))
    }

    private func finish(_ r: Result<CGImage, Error>) {
        guard let c = done else { return }
        done = nil
        stream.stopCapture { _ in }
        c.resume(with: r)
    }
}

// MARK: Overlay

/// A dim panel over one screen. It shows the window under the pointer or the drag rectangle.
final class SnapOverlay: NSPanel {
    private weak var capturer: SnapCapturer?
    private let view: SnapOverlayView

    init(screen: NSScreen, capturer: SnapCapturer) {
        self.capturer = capturer
        view = SnapOverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isReleasedWhenClosed = false
        view.overlay = self
        contentView = view
        setAccessibilityLabel("Snap overlay. Click a window or drag an area. Escape cancels. Space switches mode.")
    }

    override var canBecomeKey: Bool { true }

    func show(highlight: CGRect?, selection: CGRect?, mode: SnapCapturer.Mode) {
        let o = frame.origin
        func local(_ r: CGRect?) -> CGRect? { r.map { $0.offsetBy(dx: -o.x, dy: -o.y) } }
        view.highlight = local(highlight)
        view.selection = local(selection)
        view.selectionPixels = selection.map { ($0.width * backingScaleFactor, $0.height * backingScaleFactor) }
        view.mode = mode
        view.needsDisplay = true
    }

    fileprivate func global(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x + frame.minX, y: p.y + frame.minY) }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 53: capturer?.cancel()
        case 49: capturer?.toggleMode(at: NSEvent.mouseLocation)
        default: super.keyDown(with: e)
        }
    }

    override func cancelOperation(_ sender: Any?) { capturer?.cancel() }

    fileprivate func mouseMoved(to p: CGPoint) { capturer?.hover(at: p) }
    fileprivate func dragged(_ r: CGRect) { capturer?.drag(r) }
    fileprivate func clicked(_ p: CGPoint) { capturer?.click(at: p) }
    fileprivate func selected(_ r: CGRect) { capturer?.select(r) }
}

private final class SnapOverlayView: NSView {
    weak var overlay: SnapOverlay?
    var highlight: CGRect?
    var selection: CGRect?
    var selectionPixels: (CGFloat, CGFloat)?
    var mode = SnapCapturer.Mode.window
    private var start: CGPoint?

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self))
        super.updateTrackingAreas()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func mouseMoved(with e: NSEvent) { overlay?.mouseMoved(to: NSEvent.mouseLocation) }

    override func mouseDown(with e: NSEvent) { start = NSEvent.mouseLocation }

    override func mouseDragged(with e: NSEvent) {
        guard let s = start else { return }
        overlay?.dragged(Self.rect(s, NSEvent.mouseLocation))
    }

    override func mouseUp(with e: NSEvent) {
        guard let s = start else { return }
        start = nil
        let p = NSEvent.mouseLocation
        if abs(p.x - s.x) < 4 && abs(p.y - s.y) < 4 { overlay?.clicked(p) } else { overlay?.selected(Self.rect(s, p)) }
    }

    private static func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    override func draw(_ dirty: NSRect) {
        let hole = selection ?? highlight
        let mask = NSBezierPath(rect: bounds)
        if let h = hole { mask.append(NSBezierPath(rect: h)) }
        mask.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill()
        mask.fill()
        if let h = hole {
            let edge = NSBezierPath(rect: h.insetBy(dx: -1, dy: -1))
            edge.lineWidth = 2
            NSColor(srgbRed: 0x56 / 255.0, green: 0xB4 / 255.0, blue: 0xE9 / 255.0, alpha: 1).setStroke()   // Okabe-Ito sky blue
            edge.stroke()
        }
        if let s = selection, let px = selectionPixels {
            label("\(Int(px.0.rounded())) × \(Int(px.1.rounded())) px", at: CGPoint(x: s.minX, y: s.minY - 24))
        }
        let hint = mode == .window ? "Click a window or drag an area · Space: area only · ⎋ cancel"
                                   : "Drag an area · Space: windows · ⎋ cancel"
        label(hint, at: CGPoint(x: bounds.midX, y: bounds.maxY - 64), centered: true)
    }

    private func label(_ s: String, at p: CGPoint, centered: Bool = false) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.white]
        let size = (s as NSString).size(withAttributes: attrs)
        var r = CGRect(x: centered ? p.x - size.width / 2 - 8 : p.x, y: max(4, p.y), width: size.width + 16, height: size.height + 6)
        r.origin.x = min(max(4, r.minX), bounds.maxX - r.width - 4)
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5).fill()
        (s as NSString).draw(at: CGPoint(x: r.minX + 8, y: r.minY + 3), withAttributes: attrs)
    }
}
