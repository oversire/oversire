import Cocoa

// ─── Basket panel ────────────────────────────────────────────────────────────
// Floats at the bottom left of the screen, above all apps. The macOS screenshot thumbnail uses the
// bottom right. Collapsed, it shows a stack of the last shots. Open, it lists the shots of one basket.

/// What the panel shows. Kept apart from the views so that the tests can check it.
struct SnapBasketState: Equatable {
    var baskets: [SnapBasket]       // the open baskets that have shots
    var project: String?            // the basket in view
    var open = false
    var confirmShot: UUID?
    var confirmAll = false
    var sending: String?            // the basket that is on its way
    var notice: Notice?

    /// A short result line. It stays when the sent basket leaves the panel.
    struct Notice: Equatable {
        var text: String
        var link: URL? = nil
        var bad = false
        var copy: String? = nil     // a basket to offer "Copy as Markdown" for
    }

    init(baskets: [SnapBasket], project: String?) {
        self.baskets = baskets.filter { $0.isOpen && !$0.shots.isEmpty }
        self.project = project
    }

    /// The basket of `project`, else the newest one. Nil when no basket has shots: the panel hides.
    var current: SnapBasket? {
        baskets.first { $0.project == project } ?? baskets.first
    }

    var others: [SnapBasket] {
        guard let c = current else { return [] }
        return baskets.filter { $0.id != c.id }
    }

    var isHidden: Bool { current == nil && notice == nil }
    var showsChips: Bool { open && baskets.count > 1 }
    var shotCount: Int { baskets.reduce(0) { $0 + $1.shots.count } }
}

final class BasketPanel: NSPanel {
    struct Actions {
        var edit: (SnapShot, SnapBasket) -> Void = { _, _ in }
        var send: (SnapBasket, SnapConfig.SendMode) -> Void = { _, _ in }
        var copy: (String) -> Void = { _ in }
        var snap: () -> Void = {}
    }

    private let store: SnapStore
    private let actions: Actions
    private let projects: () -> [SnapProjectChoice]
    private(set) var state: SnapBasketState
    private let root = NSVisualEffectView()
    private let column = NSStackView(v: [], spacing: 0)
    private var thumbs: [UUID: NSImage] = [:]
    private var observers: [NSObjectProtocol] = []
    static let width: CGFloat = 310

    init(store: SnapStore, projects: @escaping () -> [SnapProjectChoice], actions: Actions) {
        self.store = store
        self.projects = projects
        self.actions = actions
        state = SnapBasketState(baskets: store.openBaskets, project: PROJECTS_CFG.capture.snap.lastProject)
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .floating
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        setAccessibilityLabel("Snap basket")

        root.material = .popover
        root.state = .active
        root.blendingMode = .behindWindow
        root.wantsLayer = true
        root.layer?.cornerRadius = 12
        root.layer?.masksToBounds = true
        root.layer?.borderWidth = 1
        root.layer?.borderColor = Palette.line.cgColor
        contentView = root
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor), column.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            column.topAnchor.constraint(equalTo: root.topAnchor), column.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            column.widthAnchor.constraint(equalToConstant: Self.width),
        ])

        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: SnapStore.changed, object: store, queue: .main) { [weak self] _ in self?.storeChanged() },
            nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.place() },
        ]
        rebuild()
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    override var canBecomeKey: Bool { true }

    /// The user closed it with the shortcut. It stays hidden until the shortcut or the next add.
    private(set) var dismissed = false

    // MARK: Show and hide

    /// Shows the panel collapsed, for example after an add. It hides when no basket has shots.
    func showCollapsed(project: String?) {
        dismissed = false
        state = SnapBasketState(baskets: store.openBaskets, project: project ?? state.project)
        state.open = false
        rebuild()
        reveal()
    }

    /// ⌃⌥⌘B: opens the panel, or hides it when it is open.
    func toggle() {
        if isVisible && state.open {
            dismissed = true
            orderOut(nil)
            return
        }
        dismissed = false
        state = SnapBasketState(baskets: store.openBaskets, project: state.project)
        state.open = true
        rebuild()
        if state.isHidden { return NSSound.beep() }
        reveal()
        makeKey()
    }

    /// Shows a fixed state, for --uishots.
    func present(_ s: SnapBasketState) {
        dismissed = false
        state = s
        rebuild()
        reveal()
    }

    /// Opens the Send menu under its button. Returns the menu, so a caller can close it.
    func popSendMenu() -> NSMenu? {
        guard let b = state.current, let btn = UIShots.find(root, { ($0 as? NSButton)?.title == "Send ▾" }) else { return nil }
        let m = sendMenu(b)
        DispatchQueue.main.async { m.popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height + 4), in: btn) }
        return m
    }

    /// Marks a basket as on its way, or clears the mark.
    func setSending(_ id: String?) {
        state.sending = id
        if id != nil { state.notice = nil }
        rebuild()
    }

    /// Shows a result line. A line without an error hides after 8 s.
    func show(_ n: SnapBasketState.Notice) {
        dismissed = false
        state.notice = n
        rebuild()
        reveal()
        guard !n.bad else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.state.notice == n else { return }
            self.clearNotice()
        }
    }

    private func clearNotice() {
        state.notice = nil
        rebuild()
        if state.isHidden { orderOut(nil) } else if isVisible { place() }
    }

    /// Hides while the selection overlay is open.
    func suspend(_ on: Bool) {
        if on { orderOut(nil) } else if !dismissed { reveal() }
    }

    private func reveal() {
        guard !state.isHidden, !dismissed else { return orderOut(nil) }
        place()
        orderFrontRegardless()
    }

    private func storeChanged() {
        thumbs = thumbs.filter { id, _ in store.openBaskets.contains { $0.shots.contains { $0.id == id } } }
        var next = SnapBasketState(baskets: store.openBaskets, project: state.project)
        next.open = state.open
        next.confirmShot = state.confirmShot
        next.confirmAll = state.confirmAll
        next.sending = state.sending
        next.notice = state.notice
        guard next != state else { return }   // a note change: keep the text field and its focus
        state = next
        rebuild()
        if state.isHidden { orderOut(nil) } else if isVisible { place() }
    }

    // MARK: Position

    private var screen0: NSScreen? { NSScreen.screens.first }

    /// Each screen keeps its own place, by its display id.
    static func screenKey(_ s: NSScreen) -> String {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.stringValue ?? s.localizedName
    }

    /// The saved place on the screen, kept inside its visible frame. The default is the bottom left.
    static func origin(saved: CGPoint?, size: NSSize, in v: CGRect) -> CGPoint {
        let p = saved ?? CGPoint(x: v.minX + 12, y: v.minY + 12)
        return CGPoint(x: min(max(p.x, v.minX), v.maxX - size.width), y: min(max(p.y, v.minY), v.maxY - size.height))
    }

    private func place() {
        guard let s = screen ?? screen0 else { return }
        let size = column.fittingSize
        let maxH = s.visibleFrame.height * 0.7
        let h = min(size.height, maxH)
        let o = Self.origin(saved: PROJECTS_CFG.capture.snap.panelOrigins[Self.screenKey(s)], size: NSSize(width: Self.width, height: h), in: s.visibleFrame)
        setFrame(NSRect(origin: o, size: NSSize(width: Self.width, height: h)), display: true)
    }

    fileprivate func moved() {
        guard let s = screen else { return }
        PROJECTS_CFG.capture.snap.panelOrigins[Self.screenKey(s)] = frame.origin
        saveConfig()
    }

    fileprivate func nudge(_ d: CGVector) {
        setFrameOrigin(NSPoint(x: frame.minX + d.dx, y: frame.minY + d.dy))
        place(keeping: true)
    }

    private func place(keeping: Bool) {
        guard let s = screen ?? screen0 else { return }
        setFrameOrigin(Self.origin(saved: frame.origin, size: frame.size, in: s.visibleFrame))
        moved()
    }

    fileprivate func resetPlace() {
        if let s = screen { PROJECTS_CFG.capture.snap.panelOrigins[Self.screenKey(s)] = nil }
        saveConfig()
        place()
    }

    // MARK: Views

    private func rebuild() {
        column.clear()
        if let n = state.notice {
            column.addFull(noticeRow(n))
            if state.current != nil { column.addFull(SnapLine(vertical: false)) }
        }
        if let b = state.current { if state.open { buildOpen(b) } else { buildCollapsed(b) } }
        if isVisible { place() }
    }

    private func title(_ key: String) -> String { projects().first { $0.key == key }?.title ?? key }

    private func plural(_ n: Int, _ w: String) -> String { "\(n) \(w)\(n == 1 ? "" : "s")" }

    private func buildCollapsed(_ b: SnapBasket) {
        let stack = SnapThumbStack(b.shots.suffix(3).map { thumb($0, in: b) }) { [weak self] in self?.setOpen(true) }
        stack.setAccessibilityLabel("Open the basket")
        let count = NSTextField.text(plural(b.shots.count, "shot"), size: 13, weight: .semibold)
        let more = state.others.isEmpty ? "" : " · +\(state.others.count) basket"
        let proj = NSStackView(h: [NSImageView(image: PROJECT_ICONS.image(for: b.project, size: 16)),
                                   NSTextField.text(title(b.project) + more, size: 11.5, color: Palette.mut)], spacing: 5)
        let info = NSStackView(v: [count, proj], spacing: 1)
        let open = ActionButton("", symbol: "chevron.up", style: .link) { [weak self] in self?.setOpen(true) }
        open.setAccessibilityLabel("Open the basket")
        open.toolTip = "Open the basket (⌃⌥⌘B)"
        let row = NSStackView(h: [SnapGrip(panel: self), stack, info, Spacer(), open, sendButton(b)], spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 8, right: 10)
        column.addFull(row)
    }

    private func buildOpen(_ b: SnapBasket) {
        var head: [NSView] = [SnapGrip(panel: self), NSImageView(image: PROJECT_ICONS.image(for: b.project, size: 16)),
                              NSTextField.text(title(b.project), size: 12.5, weight: .semibold),
                              NSTextField.text(plural(b.shots.count, "shot") + " · 1 ticket", size: 11.5, color: Palette.dim)]
        head.append(Spacer())
        let close = ActionButton("", symbol: "chevron.down", style: .link) { [weak self] in self?.setOpen(false) }
        close.setAccessibilityLabel("Close the basket")
        close.toolTip = "Close (⌃⌥⌘B)"
        head.append(close)
        let h = NSStackView(h: head, spacing: 6)
        h.edgeInsets = NSEdgeInsets(top: 8, left: 4, bottom: 6, right: 10)
        column.addFull(h)
        if state.showsChips {
            let chips = NSStackView(h: state.baskets.map { o in
                let c = SnapChip(icon: PROJECT_ICONS.image(for: o.project, size: 14), text: "\(o.shots.count)", on: o.id == b.id) { [weak self] in
                    self?.state.project = o.project
                    self?.rebuild()
                }
                c.setAccessibilityLabel("\(title(o.project)) basket, \(plural(o.shots.count, "shot"))")
                c.toolTip = title(o.project)
                return c
            } + [Spacer()], spacing: 4)
            chips.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 8, right: 10)
            column.addFull(chips)
        }
        column.addFull(SnapLine(vertical: false))

        let rows = NSStackView(v: [], spacing: 0)
        for (i, s) in b.shots.enumerated() {
            if i > 0 { rows.addFull(SnapLine(vertical: false)) }
            rows.addFull(row(s, index: i, in: b))
        }
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let flip = SnapFlipped()
        flip.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(rows)
        rows.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: flip.leadingAnchor), rows.trailingAnchor.constraint(equalTo: flip.trailingAnchor),
            rows.topAnchor.constraint(equalTo: flip.topAnchor), rows.bottomAnchor.constraint(equalTo: flip.bottomAnchor),
        ])
        scroll.documentView = flip
        scroll.translatesAutoresizingMaskIntoConstraints = false
        flip.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        let maxH = (screen ?? screen0)?.visibleFrame.height ?? 800
        let fit = rows.fittingSize.height
        let hc = scroll.heightAnchor.constraint(equalToConstant: min(fit, maxH * 0.7 - 110))
        hc.isActive = true
        column.addFull(scroll)
        column.addFull(SnapLine(vertical: false))

        let foot: NSStackView
        if state.confirmAll {
            let n = b.shots.count
            foot = NSStackView(h: [NSTextField.text("Discard all \(plural(n, "shot")) and the notes?", size: 12, lines: 2), Spacer(),
                                   ActionButton("Discard", style: .danger) { [weak self] in self?.discard(b) },
                                   ActionButton("Keep") { [weak self] in self?.state.confirmAll = false; self?.rebuild() }], spacing: 6)
        } else {
            let snap = ActionButton("+ Snap") { [weak self] in self?.actions.snap() }
            snap.toolTip = "Snap (⌃⌥⌘S)"
            foot = NSStackView(h: [ActionButton("Discard") { [weak self] in self?.askDiscardAll() }, Spacer(), snap, sendButton(b)], spacing: 6)
        }
        foot.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        column.addFull(foot)
    }

    private func row(_ s: SnapShot, index i: Int, in b: SnapBasket) -> NSView {
        let n = i + 1
        let th = SnapThumb(thumb(s, in: b), number: n) { [weak self] in self?.actions.edit(s, b) }
        th.setAccessibilityLabel("Open shot \(n) in the editor")
        th.toolTip = "Open in the editor"
        th.onDelete = { [weak self] in self?.askRemove(s.id) }
        let r: NSStackView
        if state.confirmShot == s.id {
            let rm = ActionButton("Remove", style: .danger) { [weak self] in self?.remove(s.id) }
            let keep = ActionButton("Keep") { [weak self] in self?.state.confirmShot = nil; self?.rebuild() }
            r = NSStackView(h: [th, NSTextField.text("Remove shot \(n)?", size: 12), Spacer(), rm, keep], spacing: 8, align: .centerY)
            r.wantsLayer = true
            r.layer?.backgroundColor = Palette.bad.withAlphaComponent(0.08).cgColor
            DispatchQueue.main.async { [weak self] in self?.makeFirstResponder(rm) }
        } else {
            let note = SnapNoteView(placeholder: "Add a shot note")
            note.fill = nil
            note.border = nil
            note.string = s.note
            note.text.setAccessibilityLabel("Note for shot \(n)")
            note.onChange = { [weak self] t in self?.setNote(t, shot: s.id, in: b.id) }
            note.heightAnchor.constraint(equalToConstant: 40).isActive = true
            let marks = s.marks.isEmpty ? "No marks" : plural(s.marks.count, "mark")
            let sub = NSTextField.text("\(marks) · \(s.kind == .window ? "window" : "area")", size: 11, color: Palette.dim)
            let mid = NSStackView(v: [note, sub], spacing: 2)
            note.widthAnchor.constraint(equalTo: mid.widthAnchor).isActive = true
            let up = ActionButton("", symbol: "arrow.up", style: .link) { [weak self] in self?.move(i, by: -1, in: b.id) }
            up.isEnabled = i > 0
            up.setAccessibilityLabel("Move shot \(n) up")
            let down = ActionButton("", symbol: "arrow.down", style: .link) { [weak self] in self?.move(i, by: 1, in: b.id) }
            down.isEnabled = i < b.shots.count - 1
            down.setAccessibilityLabel("Move shot \(n) down")
            let x = ActionButton("", symbol: "xmark", style: .link) { [weak self] in self?.askRemove(s.id) }
            x.setAccessibilityLabel("Remove shot \(n)")
            x.toolTip = "Remove"
            for c in [up, down, x] {
                c.widthAnchor.constraint(equalToConstant: 22).isActive = true
                c.heightAnchor.constraint(equalToConstant: 18).isActive = true
            }
            let tools = NSStackView(v: [up, down, x], spacing: 2, align: .centerX)
            tools.setContentCompressionResistancePriority(.required, for: .vertical)
            r = NSStackView(h: [th, mid, tools], spacing: 8, align: .top)
        }
        r.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        return r
    }

    private func noticeRow(_ n: SnapBasketState.Notice) -> NSView {
        let icon = NSImageView(image: NSImage(systemSymbolName: n.bad ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                                              accessibilityDescription: n.bad ? "Error" : "Done") ?? NSImage())
        icon.contentTintColor = n.bad ? Palette.bad : Palette.ok
        var views: [NSView] = [icon, NSTextField.text(n.text, size: 12, lines: 3)]
        views.append(Spacer())
        if let id = n.copy { views.append(ActionButton("Copy as Markdown") { [weak self] in self?.actions.copy(id) }) }
        if let u = n.link { views.append(ActionButton("Open", style: .link) { NSWorkspace.shared.open(u) }) }
        let x = ActionButton("", symbol: "xmark", style: .link) { [weak self] in self?.clearNotice() }
        x.setAccessibilityLabel("Close the message")
        views.append(x)
        let r = NSStackView(h: views, spacing: 6, align: .centerY)
        r.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        r.setAccessibilityElement(true)
        r.setAccessibilityRole(.group)
        r.setAccessibilityLabel(n.text)
        return r
    }

    private func sendButton(_ b: SnapBasket) -> NSView {
        guard state.sending != b.id else {
            let btn = ActionButton("Sending…", style: .primary)
            btn.isEnabled = false
            return btn
        }
        let btn = ActionButton("Send ▾", style: .primary)
        btn.setAccessibilityLabel("Send the basket")
        btn.onClick = { [weak self, weak btn] in
            guard let self, let btn else { return }
            self.sendMenu(b).popUp(positioning: nil, at: NSPoint(x: 0, y: btn.bounds.height + 4), in: btn)
        }
        return btn
    }

    func sendMenu(_ b: SnapBasket) -> NSMenu {
        let m = NSMenu()
        for mode in SnapConfig.SendMode.allCases {
            let it = SnapMenuItem(title: mode.label) { [weak self] in self?.actions.send(b, mode) }
            if mode == .agent { it.keyEquivalent = "\r"; it.keyEquivalentModifierMask = .command }
            m.addItem(it)
        }
        return m
    }

    // MARK: Changes

    private func setOpen(_ on: Bool) {
        state.open = on
        state.confirmAll = false
        state.confirmShot = nil
        rebuild()
        place()
        if on { makeKey() }
    }

    private func askRemove(_ id: UUID) {
        state.confirmShot = id
        rebuild()
    }

    private func askDiscardAll() {
        state.confirmAll = true
        rebuild()
    }

    private func remove(_ id: UUID) {
        state.confirmShot = nil
        attempt { try store.remove(shot: id) }
    }

    private func discard(_ b: SnapBasket) {
        state.confirmAll = false
        attempt { try store.discard(basket: b.id) }
    }

    private func move(_ i: Int, by d: Int, in id: String) {
        guard var b = store.basket(id) else { return }
        b.reorder(i, to: i + d)
        attempt { try store.update(b) }
    }

    /// Notes save with each change. The panel does not rebuild, so the text field keeps the focus.
    private func setNote(_ t: String, shot: UUID, in id: String) {
        guard var b = store.basket(id), let i = b.shots.firstIndex(where: { $0.id == shot }) else { return }
        b.shots[i].note = t
        if let k = state.baskets.firstIndex(where: { $0.id == id }) { state.baskets[k] = b }
        attempt { try store.update(b) }
    }

    private func attempt(_ f: () throws -> Void) {
        do { try f() } catch {
            log.error("Snap: OverSire could not save the basket: \(error.localizedDescription, privacy: .public)")
            NSSound.beep()
        }
    }

    override func cancelOperation(_ sender: Any?) {
        if state.confirmShot != nil || state.confirmAll {
            state.confirmShot = nil
            state.confirmAll = false
            rebuild()
        } else if state.open {
            setOpen(false)
        }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.keyCode == 36, e.modifierFlags.intersection([.command, .shift, .option, .control]) == .command, let b = state.current {
            actions.send(b, .agent)
            return true
        }
        return super.performKeyEquivalent(with: e)
    }

    // MARK: Thumbnails

    private func thumb(_ s: SnapShot, in b: SnapBasket) -> NSImage {
        if let t = thumbs[s.id] { return t }
        let t = SnapThumb.render(s, png: store.png(of: s.id, in: b.id))
        thumbs[s.id] = t
        return t
    }

    /// Drops the cached thumbnail, for example after the editor saved new marks.
    func forget(_ id: UUID) { thumbs[id] = nil }
}

// MARK: Small views

/// ⠿: drag to move the panel, arrows to move it with the keyboard, double-click to reset.
final class SnapGrip: NSView {
    private weak var panel: BasketPanel?
    private var start: (mouse: NSPoint, origin: NSPoint)?

    init(panel: BasketPanel) {
        self.panel = panel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 14).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Move the basket panel. Use the arrow keys.")
        toolTip = "Drag to move · double-click to reset"
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func draw(_ dirty: NSRect) {
        let focused = window?.firstResponder === self
        if focused {
            Palette.sel.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: focused ? Palette.fg : Palette.dim]
        let s = "⠿" as NSString
        let z = s.size(withAttributes: attrs)
        s.draw(at: NSPoint(x: bounds.midX - z.width / 2, y: bounds.midY - z.height / 2), withAttributes: attrs)
        if focused {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { start = nil; panel?.resetPlace(); return }
        guard let w = window else { return }
        start = (NSEvent.mouseLocation, w.frame.origin)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with e: NSEvent) {
        guard let s = start, let w = window else { return }
        let p = NSEvent.mouseLocation
        w.setFrameOrigin(NSPoint(x: s.origin.x + p.x - s.mouse.x, y: s.origin.y + p.y - s.mouse.y))
    }

    override func mouseUp(with e: NSEvent) {
        guard start != nil else { return }
        start = nil
        NSCursor.pop()
        panel?.nudge(.zero)
    }

    override func keyDown(with e: NSEvent) {
        let d: [UInt16: CGVector] = [123: CGVector(dx: -20, dy: 0), 124: CGVector(dx: 20, dy: 0), 125: CGVector(dx: 0, dy: -20), 126: CGVector(dx: 0, dy: 20)]
        if let v = d[e.keyCode] { panel?.nudge(v) } else { super.keyDown(with: e) }
    }

    override func accessibilityPerformPress() -> Bool { window?.makeFirstResponder(self) ?? false }
}

/// A thumbnail with its shot number. A click opens the shot. ⌫ asks to remove it.
final class SnapThumb: NSView {
    static let size = NSSize(width: 64, height: 42)
    private let image: NSImage
    private let number: Int?
    private let onClick: () -> Void
    var onDelete: (() -> Void)?

    init(_ image: NSImage, number: Int?, size: NSSize = SnapThumb.size, onClick: @escaping () -> Void) {
        self.image = image
        self.number = number
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size.width + 5).isActive = true
        heightAnchor.constraint(equalToConstant: size.height + 5).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    override func draw(_ dirty: NSRect) {
        let r = NSRect(x: 5, y: 5, width: bounds.width - 5, height: bounds.height - 5)
        let clip = NSBezierPath(roundedRect: r, xRadius: 5, yRadius: 5)
        NSGraphicsContext.saveGraphicsState()
        clip.addClip()
        Palette.raise.setFill()
        r.fill()
        image.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
        Palette.line.setStroke()
        clip.stroke()
        if let n = number {
            let d = NSRect(x: 0, y: 0, width: 16, height: 16)
            Palette.acc.setFill()
            NSBezierPath(ovalIn: d).fill()
            let s = "\(n)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9.5, weight: .bold), .foregroundColor: NSColor.white]
            let z = s.size(withAttributes: attrs)
            s.draw(at: NSPoint(x: d.midX - z.width / 2, y: d.midY - z.height / 2), withAttributes: attrs)
        }
        if window?.firstResponder === self {
            NSGraphicsContext.saveGraphicsState()
            NSFocusRingPlacement.only.set()
            clip.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    override func mouseDown(with e: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func keyDown(with e: NSEvent) {
        switch e.keyCode {
        case 36, 49: onClick()
        case 51, 117: onDelete?()
        default: super.keyDown(with: e)
        }
    }

    /// The crop of the shot with its marks, at twice the thumbnail size.
    static func render(_ s: SnapShot, png: Data?) -> NSImage {
        let size = NSSize(width: size.width * 2, height: size.height * 2)
        guard let png, let rep = NSBitmapImageRep(data: png), let cg = rep.cgImage,
              let crop = cg.cropping(to: CGRect(x: s.crop.x, y: s.crop.y, width: s.crop.w, height: s.crop.h)) else { return NSImage(size: size) }
        return NSImage(size: size, flipped: true) { r in
            let k = max(r.width / CGFloat(s.crop.w), r.height / CGFloat(s.crop.h))
            let w = CGFloat(s.crop.w) * k, h = CGFloat(s.crop.h) * k
            let o = NSPoint(x: (r.width - w) / 2, y: (r.height - h) / 2)
            NSImage(cgImage: crop, size: NSSize(width: crop.width, height: crop.height))
                .draw(in: NSRect(x: o.x, y: o.y, width: w, height: h), from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            NSColor(cgColor: SnapRenderer.vermillion)!.setStroke()
            for m in s.marks {
                let mr = NSRect(x: o.x + CGFloat(m.rect.x - s.crop.x) * k, y: o.y + CGFloat(m.rect.y - s.crop.y) * k,
                                width: CGFloat(m.rect.w) * k, height: CGFloat(m.rect.h) * k)
                let p = NSBezierPath(rect: mr)
                p.lineWidth = 2.5
                p.stroke()
            }
            return true
        }
    }
}

/// The last shots as a small stack. A click opens the basket.
final class SnapThumbStack: NSView {
    private let onClick: () -> Void

    init(_ images: [NSImage], onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 56).isActive = true
        heightAnchor.constraint(equalToConstant: 38).isActive = true
        let n = images.count
        for (i, img) in images.enumerated() {
            let back = CGFloat(n - 1 - i)
            let t = SnapThumb(img, number: nil, size: NSSize(width: 44, height: 30)) {}
            addSubview(t)
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: leadingAnchor, constant: back * 6 - 5),
                t.topAnchor.constraint(equalTo: topAnchor, constant: back * 4 - 5),
            ])
        }
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ p: NSPoint) -> NSView? { frame.contains(p) ? self : nil }
    override func mouseDown(with e: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

/// A project chip: icon and shot count. The chip in view has the accent border.
final class SnapChip: Box {
    private let onClick: () -> Void

    init(icon: NSImage, text: String, on: Bool, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(fill: nil, border: on ? Palette.acc : Palette.line, radius: 9)
        let label = NSTextField.text(text, size: 11, weight: .medium, color: on ? Palette.acc : Palette.mut)
        let s = NSStackView(h: [NSImageView(image: icon), label], spacing: 4)
        s.edgeInsets = NSEdgeInsets(top: 1, left: 3, bottom: 1, right: 7)
        addSubview(s)
        s.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: leadingAnchor), s.trailingAnchor.constraint(equalTo: trailingAnchor),
            s.topAnchor.constraint(equalTo: topAnchor), s.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilitySelected(on)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with e: NSEvent) { onClick() }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }
}

final class SnapMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }

    @objc private func fire() { run() }
}
