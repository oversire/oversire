import Cocoa
import OverSireCore

// ─── Projects tab ────────────────────────────────────────────────────────────

// Plane gives hex colors. The names are for the priority badge.
func projectColor(_ name: String) -> NSColor {
    if name.hasPrefix("#"), name.count == 7, let v = Int(name.dropFirst(), radix: 16) {
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }
    switch name.uppercased() {
    case "GREEN": return C_SUCCESS
    case "RED": return C_FAILURE
    case "ORANGE": return C_QUEUED
    case "YELLOW": return NSColor(srgbRed: 0.94, green: 0.89, blue: 0.26, alpha: 1)
    case "BLUE": return C_RUNNING
    case "PURPLE": return NSColor(srgbRed: 0.80, green: 0.47, blue: 0.65, alpha: 1)
    case "PINK": return NSColor(srgbRed: 0.84, green: 0.37, blue: 0.55, alpha: 1)
    default: return .secondaryLabelColor
    }
}

func runInTerminal(_ command: String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    proc.arguments = ["-e", "tell application \"Terminal\" to do script \"\(command)\""]
    proc.standardOutput = FileHandle.nullDevice
    proc.standardError = FileHandle.nullDevice
    try? proc.run()
}

final class StatusGlyph: NSView {
    let category: StatusCategory
    let color: NSColor
    /// A Done item with open sub-items: a warning triangle at the lower right.
    var warning = false { didSet { needsDisplay = true } }

    init(category: StatusCategory, color: NSColor, name: String) {
        self.category = category
        self.color = color
        super.init(frame: NSRect(x: 0, y: 0, width: 16, height: 16))
        toolTip = name
        setAccessibilityLabel(name)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The glyph of an item. A Done item with open sub-items gets the warning and says so.
    static func item(_ item: Item, snap: ProjectSnapshot) -> StatusGlyph {
        let opt = snap.option(item.statusOptionId)
        let open = snap.isDoneWithOpenSubItems(item) ? snap.openSubItems(of: item.id) : 0
        let name = (opt?.name ?? "No status") + (open > 0 ? " · \(open) sub-item\(open == 1 ? "" : "s") open" : "")
        let g = StatusGlyph(category: opt?.category ?? .todo, color: projectColor(opt?.color ?? "GRAY"), name: name)
        g.warning = open > 0
        return g
    }

    // The shapes use a 16 pt box. Other sizes scale it.
    override func draw(_ dirtyRect: NSRect) {
        let c = color
        let box = NSRect(x: 0, y: 0, width: 16, height: 16)
        if bounds.width != 16 {
            let t = NSAffineTransform()
            t.scale(by: min(bounds.width, bounds.height) / 16)
            t.concat()
        }
        let r = box.insetBy(dx: 1.5, dy: 1.5)
        switch category {
        case .todo:
            let p = NSBezierPath(ovalIn: r)
            p.lineWidth = 1.3
            let dash: [CGFloat] = [2, 1.5]
            p.setLineDash(dash, count: 2, phase: 0)
            c.setStroke(); p.stroke()
        case .progress:
            let outer = NSBezierPath(ovalIn: r)
            let inner = NSBezierPath(ovalIn: r.insetBy(dx: 3.5, dy: 3.5))
            outer.lineWidth = 1.5; inner.lineWidth = 1.5
            c.setStroke(); outer.stroke(); inner.stroke()
        case .review:
            let p = NSBezierPath(ovalIn: r)
            p.lineWidth = 1.4; c.setStroke(); p.stroke()
            c.setFill()
            NSBezierPath(ovalIn: NSRect(x: box.midX - 1.6, y: box.midY - 1.6, width: 3.2, height: 3.2)).fill()
        case .blocked:
            c.setFill()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 6, width: box.width - 4, height: 4), xRadius: 1, yRadius: 1).fill()
        case .done:
            let p = NSBezierPath()
            p.move(to: NSPoint(x: 3, y: 8))
            p.line(to: NSPoint(x: 6.5, y: 4.5))
            p.line(to: NSPoint(x: 13, y: 12))
            p.lineWidth = 1.7; p.lineCapStyle = .round; p.lineJoinStyle = .round
            c.setStroke(); p.stroke()
        }
        if warning {
            let t = NSBezierPath()
            t.move(to: NSPoint(x: 8.5, y: 0))
            t.line(to: NSPoint(x: 16, y: 0))
            t.line(to: NSPoint(x: 12.25, y: 7))
            t.close()
            Palette.bg.setStroke(); t.lineWidth = 1.5; t.stroke()
            Palette.bad.setFill(); t.fill()
        }
    }
}

// Borderless panel for text the row had to cut. Shown after a short hover.
enum HoverCard {
    private static var panel: NSPanel?
    private static var timer: Timer?
    private static var watch: Timer?
    static func schedule(_ text: String, from view: NSView) {
        cancel()
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in show(text, from: view) }
    }
    static func cancel() { timer?.invalidate(); timer = nil }
    static func close() { cancel(); watch?.invalidate(); watch = nil; panel?.orderOut(nil); panel = nil }

    static func show(_ text: String, from view: NSView) {
        guard view.window != nil, !text.isEmpty else { return }
        close()
        let font = NSFont.systemFont(ofSize: 12)
        let maxW: CGFloat = 360
        let h = min(160, textHeight(text, font: font, width: maxW - 16) + 16)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: maxW, height: h),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.hasShadow = true
        panel.backgroundColor = .windowBackgroundColor
        panel.isOpaque = false
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.frame = NSRect(x: 8, y: 6, width: maxW - 16, height: h - 12)
        let box = NSView(frame: panel.contentView!.bounds)
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        box.layer?.cornerRadius = 6
        box.layer?.borderWidth = 0.5
        box.layer?.borderColor = NSColor.separatorColor.cgColor
        box.addSubview(label)
        panel.contentView = box
        let origin = view.window!.convertToScreen(view.convert(view.bounds, to: nil))
        panel.setFrameOrigin(NSPoint(x: origin.minX, y: origin.maxY + 4))
        panel.orderFront(nil)
        self.panel = panel
        // Mouse-exited does not come when the window closes, the app goes to the back or the view is removed.
        watch = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak view] _ in
            guard let view, let win = view.window, win.isVisible, NSApp.isActive,
                  view.bounds.contains(view.convert(win.mouseLocationOutsideOfEventStream, from: nil)) else { close(); return }
        }
    }
}

// The sub-items as arcs from the top: green for done, then yellow for started.
final class ProgressRing: NSView {
    let done: Int
    let started: Int
    let total: Int
    init(done: Int, started: Int = 0, total: Int, size: CGFloat = 14) {
        self.done = done
        self.started = started
        self.total = total
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        toolTip = "\(done) of \(total) sub-items done" + (started > 0 ? ", \(started) in progress" : "") + ", \(total - done) open"
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1.5, dy: 1.5)
        let track = NSBezierPath(ovalIn: r)
        track.lineWidth = 2.2
        NSColor.tertiaryLabelColor.withAlphaComponent(0.35).setStroke(); track.stroke()
        guard total > 0 else { return }
        let deg = 360 / CGFloat(total)
        let mid = 90 - deg * CGFloat(done)
        // The started arc first, so that the round cap of the done arc covers the join.
        stroke(from: mid, to: mid - deg * CGFloat(min(started, total - done)), color: Palette.warn)
        stroke(from: 90, to: mid, color: C_SUCCESS)
    }

    private func stroke(from start: CGFloat, to end: CGFloat, color: NSColor) {
        guard start > end else { return }
        let arc = NSBezierPath()
        arc.appendArc(withCenter: NSPoint(x: bounds.midX, y: bounds.midY), radius: bounds.insetBy(dx: 1.5, dy: 1.5).width / 2,
                      startAngle: start, endAngle: end, clockwise: true)
        arc.lineWidth = 2.2; arc.lineCapStyle = .round
        color.setStroke(); arc.stroke()
    }
}

// "3 more sub-items in Plane", under the loaded sub-items.
final class SubItemNote: NSView {
    init(_ text: String, url: String, w: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 22))
        let x: CGFloat = 42
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11); label.textColor = .linkColor
        label.frame = NSRect(x: x, y: 3, width: w - x - 16, height: 16)
        addSubview(label)
        let click = Clicker(url)
        click.frame = NSRect(x: x, y: 0, width: min(w - x, label.intrinsicContentSize.width + 8), height: 22)
        addSubview(click)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class StackedBar: NSView {
    let parts: [(NSColor, Int)]
    init(parts: [(NSColor, Int)], frame: NSRect) {
        self.parts = parts
        super.init(frame: frame)
        let total = parts.map(\.1).reduce(0, +)
        toolTip = total > 0 ? parts.map { "\($0.1)" }.joined(separator: " · ") + " items" : "No items"
    }
    required init?(coder: NSCoder) { fatalError() }
    // An empty project shows only the track.
    override func draw(_ dirtyRect: NSRect) {
        let total = CGFloat(parts.map(\.1).reduce(0, +))
        var x: CGFloat = 0
        let path = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        NSColor.tertiaryLabelColor.withAlphaComponent(0.25).setFill()
        path.fill()
        guard total > 0 else { return }
        path.addClip()
        for (color, n) in parts where n > 0 {
            let w = bounds.width * CGFloat(n) / total
            color.setFill()
            NSRect(x: x, y: 0, width: w, height: bounds.height).fill()
            x += w
        }
    }
}

// A plain click target with a hand cursor.
final class TapArea: NSView {
    var onTap: (() -> Void)?
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onTap?() }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

enum DragPhase { case began, moved, ended }

// Drag handle of a project header. It runs its own event loop, so no pasteboard is needed.
final class GripView: NSView {
    var onDrag: ((DragPhase, NSEvent) -> Void)?
    override func draw(_ dirtyRect: NSRect) {
        guard let img = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to reorder")?
            .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold)) else { return }
        let tinted = NSImage(size: img.size, flipped: false) { r in
            img.draw(in: r)
            NSColor.tertiaryLabelColor.set()
            r.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(at: NSPoint(x: (bounds.width - img.size.width) / 2, y: (bounds.height - img.size.height) / 2),
                    from: .zero, operation: .sourceOver, fraction: 1)
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    override func mouseDown(with event: NSEvent) {
        NSCursor.closedHand.push()
        defer { NSCursor.pop() }
        onDrag?(.began, event)
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { onDrag?(.ended, e); return }
            onDrag?(.moved, e)
        }
    }
}

final class ProjectHeader: NSView {
    static let foldedH: CGFloat = 36
    let key: String
    let folded: Bool
    var onRefresh: (() -> Void)?
    var onFilter: ((String) -> Void)?
    var onFold: (() -> Void)?
    var onAdd: (() -> Void)?
    var onIntake: (() -> Void)?
    var onDrag: ((DragPhase, NSEvent) -> Void)? { didSet { grip?.onDrag = onDrag } }
    private var grip: GripView?

    init(snap: ProjectSnapshot, live: Bool, refreshing: Bool, filter: String?, updated: String, w: CGFloat,
         folded: Bool, canReorder: Bool) {
        self.key = snap.summary.ref.storeKey
        self.folded = folded
        let chips = snap.statusOptions
        let listed = snap.listed(subItems: PROJECTS_CFG.showSubItems)
        let h: CGFloat = folded ? ProjectHeader.foldedH : 72
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        let rowY = h - 26

        if canReorder {
            let g = GripView(frame: NSRect(x: 2, y: rowY, width: 14, height: 20))
            g.alphaValue = 0
            addSubview(g)
            grip = g
        }
        let chevron = NSButton(image: NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down",
                                              accessibilityDescription: folded ? "Expand" : "Collapse")!,
                               target: self, action: #selector(fold))
        chevron.isBordered = false
        chevron.contentTintColor = .secondaryLabelColor
        chevron.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        chevron.frame = NSRect(x: 16, y: rowY, width: 16, height: 20)
        addSubview(chevron)
        let owner = Badge(snap.summary.ref.workspace, maxChars: 16, tint: repoColor(snap.summary.ref.workspace))
        owner.frame.origin = NSPoint(x: 34, y: rowY)
        addSubview(owner)

        let chip = Badge(live ? "Live" : "Every \(PROJECTS_CFG.pollMinutes) min", tint: live ? C_SUCCESS : nil)
        chip.frame.origin = NSPoint(x: w - 182 - chip.frame.width, y: rowY)
        addSubview(chip)

        // Fixed frames, so the bars of folded headers line up in one column.
        let barX = w - 266 - 48 - 34 - 70
        let titleX = owner.frame.maxX + 8
        let intakeRight = min(chip.frame.minX - 6, w - 266)
        let titleMaxX = barX - 10
        let title = NSTextField(labelWithString: snap.summary.title)
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: titleX, y: rowY + 1, width: max(40, titleMaxX - titleX), height: 18)
        title.toolTip = "\(snap.summary.ref.workspace) › \(snap.summary.title)"
        addSubview(title)
        let tap = TapArea(frame: NSRect(x: owner.frame.minX, y: rowY, width: min(title.frame.maxX, titleX + title.intrinsicContentSize.width + 4) - owner.frame.minX, height: 20))
        tap.onTap = { [weak self] in self?.onFold?() }
        tap.toolTip = folded ? "Expand" : "Collapse"
        addSubview(tap)

        let parts = chips.map { chip in
            (projectColor(chip.color), listed.filter { $0.statusOptionId == chip.id }.count)
        }
        // Number chips in fixed slots, so the bars of folded headers line up: open items, then pending intake items.
        let pending = snap.intake?.count ?? 0
        let b = Badge("⇣ \(pending)", tint: snap.intake == nil ? nil : .systemPurple)
        b.frame.origin = NSPoint(x: intakeRight - b.frame.width, y: rowY)
        b.toolTip = snap.intake == nil ? "Intake is off for this project, or OverSire cannot read it"
            : "\(pending) intake item\(pending == 1 ? "" : "s") wait\(pending == 1 ? "s" : "") for triage. Click to open the intake."
        addSubview(b)
        if snap.intake != nil {
            let t = TapArea(frame: b.frame)
            t.toolTip = b.toolTip
            t.onTap = { [weak self] in self?.onIntake?() }
            addSubview(t)
        }
        let open = snap.notDoneCount(listed)
        let n = Badge("\(open)")
        n.frame.origin = NSPoint(x: intakeRight - 48 - n.frame.width, y: rowY)
        n.toolTip = "\(open) item\(open == 1 ? "" : "s") not done"
        addSubview(n)
        addSubview(StackedBar(parts: parts, frame: NSRect(x: barX, y: rowY + 7, width: 64, height: 6)))

        let add = NSButton(image: NSImage(systemSymbolName: "plus", accessibilityDescription: "New item in \(snap.summary.title)")!,
                           target: self, action: #selector(addItem))
        add.isBordered = false
        add.contentTintColor = .secondaryLabelColor
        add.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        add.frame = NSRect(x: w - 174, y: rowY, width: 20, height: 20)
        add.toolTip = "New item in \(snap.summary.title)"
        addSubview(add)
        if refreshing {
            let sp = NSProgressIndicator(frame: NSRect(x: w - 148, y: rowY + 2, width: 16, height: 16))
            sp.style = .spinning; sp.controlSize = .small; sp.startAnimation(nil)
            addSubview(sp)
        } else {
            let reload = NSButton(image: NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: "Refresh \(snap.summary.title)")!,
                                  target: self, action: #selector(refresh))
            reload.isBordered = false
            reload.contentTintColor = .secondaryLabelColor
            reload.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
            reload.frame = NSRect(x: w - 150, y: rowY, width: 20, height: 20)
            reload.toolTip = "Get the latest items from Plane · updated \(updated)"
            addSubview(reload)
        }
        let link = NSTextField(labelWithString: "Open Project")
        link.font = .systemFont(ofSize: 11, weight: .medium); link.textColor = .linkColor
        link.frame = NSRect(x: w - 120, y: rowY + 2, width: 108, height: 16); link.alignment = .right
        addSubview(link)
        let click = Clicker(snap.summary.url)
        click.frame = NSRect(x: w - 124, y: rowY - 6, width: 124, height: 28)
        addSubview(click)

        let counts = snap.counts(listed).map { "\($0.value) \($0.key.label.lowercased())" }.sorted().joined(separator: ", ")
        toolTip = counts
        guard !folded else { return }
        var x: CGFloat = 12
        for opt in chips {
            let on = filter == opt.id
            let b = NSButton(title: "\(opt.name) \(listed.filter { $0.statusOptionId == opt.id }.count)", target: self, action: #selector(chip(_:)))
            b.bezelStyle = .inline
            b.font = .systemFont(ofSize: 10, weight: on ? .bold : .medium)
            b.contentTintColor = projectColor(opt.color)
            b.identifier = NSUserInterfaceItemIdentifier(opt.id)
            b.sizeToFit()
            b.frame = NSRect(x: x, y: 16, width: b.frame.width + 8, height: 18)
            b.toolTip = on ? "Show every status" : "Show only \(opt.name)"
            addSubview(b)
            x += b.frame.width + 4
            if x > w - 140 { break }
        }
        addSubview(StackedBar(parts: parts, frame: NSRect(x: 12, y: 6, width: w - 24, height: 6)))
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func refresh() { onRefresh?() }
    @objc func fold() { onFold?() }
    @objc func addItem() { onAdd?() }
    @objc func chip(_ sender: NSButton) { onFilter?(sender.identifier?.rawValue ?? "") }

    // A click on the top row, outside the buttons and chips with their own action, folds the project.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p), p.y >= bounds.height - ProjectHeader.foldedH { onFold?() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { grip?.alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { grip?.alphaValue = 0 }
}

// Orca agent state of an item. A click opens its terminal.
final class AgentPill: NSView {
    static let orca = NSColor(name: nil) { a in
        a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.64, green: 0.55, blue: 1, alpha: 1)
            : NSColor(red: 0.42, green: 0.31, blue: 0.85, alpha: 1)
    }
    var onClick: (() -> Void)?
    private let color: NSColor
    private let dashed: Bool

    // `status` gives the word and the color of the item status. The phase gives the dash and the pulse.
    init(_ agent: AgentSession, status: ItemStatus? = nil) {
        switch agent.phase {
        case .working: color = AgentPill.orca
        case .waiting: color = .systemOrange
        case .done: color = .systemGreen
        case .starting, .failed: color = .secondaryLabelColor
        }
        dashed = agent.phase == .starting || agent.phase == .failed
        let text = status?.label ?? agent.label()
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 10.5, weight: .semibold)
        l.textColor = agent.phase == .failed ? .systemRed : status?.tone.color ?? color
        let tw = ceil(l.intrinsicContentSize.width)
        super.init(frame: NSRect(x: 0, y: 0, width: tw + 26, height: 18))
        l.frame = NSRect(x: 19, y: 1, width: tw + 2, height: 15)
        addSubview(l)
        let dot = NSView(frame: NSRect(x: 8, y: 5.5, width: 7, height: 7))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = (agent.phase == .failed ? NSColor.systemRed : status?.tone.color ?? color).cgColor
        dot.layer?.cornerRadius = 3.5
        if agent.phase == .working || agent.phase == .starting {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1; pulse.toValue = 0.25; pulse.duration = 0.6
            pulse.autoreverses = true; pulse.repeatCount = .infinity
            dot.layer?.add(pulse, forKey: "pulse")
        }
        addSubview(dot)
        var tip = "\(agent.agent.rawValue) · \(agent.repo.isEmpty ? "Orca" : agent.repo)"
        if let h = status?.headline, !h.isEmpty { tip += "\n" + h } else if let m = agent.message, !m.isEmpty { tip += "\n" + String(m.prefix(300)) }
        toolTip = tip + (agent.phase == .failed ? "" : "\nClick to open the terminal in Orca")
        setAccessibilityRole(.button)
        setAccessibilityLabel("Session: " + text)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let p = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8.5, yRadius: 8.5)
        if dashed {
            NSColor.separatorColor.setStroke()
            p.setLineDash([3, 2], count: 2, phase: 0)
            p.lineWidth = 1; p.stroke()
        } else {
            color.withAlphaComponent(0.16).setFill(); p.fill()
        }
    }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() } }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

final class ProjectItemRow: NSView {
    var onToggle: (() -> Void)?
    var onStart: ((NSView) -> Void)?
    var onStartMenu: ((_ anchor: NSView, _ header: Bool) -> NSMenu)?   // "Start in Orca with"
    var onPill: ((NSView) -> Void)?
    let urlStr: String
    let expanded: Bool
    private var play: NSButton?
    private var startWith: NSButton?
    private var hasAgent = false

    // `agent` shows a pill. `canStart` shows ▶ on hover when no agent works on the item.
    init(item: Item, snap: ProjectSnapshot, unread: Bool, last: String?, w: CGFloat, expanded: Bool,
         progress: (done: Int, total: Int)? = nil, agent: AgentSession? = nil, status: ItemStatus? = nil, canStart: Bool = false) {
        self.urlStr = item.url
        self.expanded = expanded
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: ROW_H))
        let pill = agent.map { AgentPill($0, status: status) }
        hasAgent = agent != nil
        let reserve: CGFloat = pill.map { $0.frame.width + 6 } ?? (canStart ? 46 : 0)
        wantsLayer = true
        layer?.backgroundColor = expanded ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.1).cgColor : nil
        let opt = snap.option(item.statusOptionId)
        let glyph = StatusGlyph.item(item, snap: snap)
        glyph.frame.origin = NSPoint(x: 14, y: (ROW_H - 16) / 2)
        addSubview(glyph)
        if unread {
            let dot = Dot(color: C_RUNNING, frame: NSRect(x: 28, y: ROW_H - 16, width: 6, height: 6))
            dot.toolTip = "Unread"
            addSubview(dot)
        }
        let textX: CGFloat = 42
        let title = NSTextField(labelWithString: item.title)
        title.font = .systemFont(ofSize: 12.5, weight: .semibold)
        title.lineBreakMode = .byTruncatingTail
        title.frame = NSRect(x: textX, y: ROW_H - 24, width: w - textX - 200 - reserve, height: 18)
        title.toolTip = item.title
        addSubview(title)
        var x = textX
        let kb = Badge(item.key, maxChars: 22)
        kb.frame.origin = NSPoint(x: x, y: 6)
        addSubview(kb)
        x += kb.frame.width + 6
        if let opt {
            let sb = Badge(opt.name, maxChars: 18, tint: projectColor(opt.color))
            sb.frame.origin = NSPoint(x: x, y: 6)
            sb.toolTip = "Status: \(opt.name)"
            addSubview(sb)
            x += sb.frame.width + 6
        }
        if let pri = item.fields["Priority"] {
            let color = StatusOption.priorities.first { $0.name == pri }?.color ?? "ORANGE"
            let pb = Badge(pri, tint: projectColor(color))
            pb.frame.origin = NSPoint(x: x, y: 6)
            addSubview(pb)
            x += pb.frame.width + 6
        }
        if let progress {
            let ring = ProgressRing(done: progress.done, started: snap.started(of: item.id), total: progress.total)
            ring.frame.origin = NSPoint(x: x, y: 7)
            addSubview(ring)
            let n = NSTextField(labelWithString: "\(progress.done)/\(progress.total)")
            n.font = .monospacedDigitSystemFont(ofSize: 10, weight: .medium)
            n.textColor = .secondaryLabelColor
            n.sizeToFit()
            n.frame.origin = NSPoint(x: x + 17, y: 6)
            n.toolTip = ring.toolTip
            addSubview(n)
        }
        let who = item.assignees.isEmpty ? "" : item.assignees.prefix(2).joined(separator: ", ")
        let meta = NSTextField(labelWithString: who)
        meta.font = .systemFont(ofSize: 10); meta.textColor = .secondaryLabelColor
        meta.alignment = .right
        meta.frame = NSRect(x: w - 196 - reserve, y: ROW_H - 22, width: 120, height: 14)
        addSubview(meta)
        let time = NSTextField(labelWithString: relativeTime(item.updatedAt))
        time.font = .systemFont(ofSize: 10); time.textColor = .secondaryLabelColor; time.alignment = .right
        time.frame = NSRect(x: w - 196 - reserve, y: 8, width: 120, height: 14)
        addSubview(time)
        if let last = last, !last.isEmpty {
            title.toolTip = (title.toolTip ?? item.title) + "\n" + last
        }
        let lk = NSButton(frame: NSRect(x: w - 64, y: (ROW_H - 22) / 2, width: 28, height: 22))
        lk.image = NSImage(systemSymbolName: "arrow.up.right.square", accessibilityDescription: "Open in Plane")
        lk.isBordered = false; lk.target = self; lk.action = #selector(openLink)
        lk.toolTip = "Open in Plane"
        addSubview(lk)
        let cp = NSButton(frame: NSRect(x: w - 36, y: (ROW_H - 22) / 2, width: 28, height: 22))
        cp.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy link")
        cp.isBordered = false; cp.target = self; cp.action = #selector(copyLink)
        cp.toolTip = "Copy link"
        addSubview(cp)
        if let pill {
            pill.frame.origin = NSPoint(x: w - 66 - pill.frame.width, y: (ROW_H - 18) / 2)
            pill.onClick = { [weak self, weak pill] in if let pill { self?.onPill?(pill) } }
            addSubview(pill)
        } else if canStart {
            let b = NSButton(frame: NSRect(x: w - 108, y: (ROW_H - 22) / 2, width: 26, height: 22))
            b.image = NSImage(systemSymbolName: "play.fill", accessibilityDescription: "Start in Orca")
            b.contentTintColor = AgentPill.orca
            b.isBordered = false; b.target = self; b.action = #selector(startAgent(_:))
            b.toolTip = "Start \(item.key) in Orca with the default agent"
            b.alphaValue = 0
            addSubview(b)
            play = b
            let m = NSButton(frame: NSRect(x: w - 82, y: (ROW_H - 22) / 2, width: 16, height: 22))
            m.image = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Start in Orca with")
            m.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            m.contentTintColor = AgentPill.orca
            m.isBordered = false; m.target = self; m.action = #selector(startWithMenu(_:))
            m.toolTip = "Start in Orca with another agent"
            m.alphaValue = 0
            addSubview(m)
            startWith = m
        }
        let sub = progress.map { ", \($0.done) of \($0.total) sub-items done" } ?? ""
        setAccessibilityLabel("\(item.title), \(opt?.name ?? "no status")" + sub)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func startWithMenu(_ sender: NSButton) {
        onStartMenu?(play ?? sender, true).popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 2), in: sender)
    }
    // The right-click menu: Copy link, plus the Start in Orca entries.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Copy link", action: #selector(copyLink), keyEquivalent: "").target = self
        if onStart != nil {
            menu.addItem(.separator())
            menu.addItem(withTitle: hasAgent ? "Start another session in Orca" : "Start in Orca", action: #selector(startAgent(_:)), keyEquivalent: "").target = self
            if let sub = onStartMenu?(self, false) {
                let mi = NSMenuItem(title: "Start in Orca with", action: nil, keyEquivalent: "")
                mi.submenu = sub
                menu.addItem(mi)
            }
        }
        return menu
    }
    @objc func startAgent(_ sender: Any) { onStart?(play ?? (sender as? NSView) ?? self) }
    @objc func openLink() { if let u = URL(string: urlStr) { NSWorkspace.shared.open(u) } }
    @objc func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlStr, forType: .string)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hover(true) }
    override func mouseExited(with event: NSEvent) { hover(false); HoverCard.close() }
    // A scroll can skip the exit event. The scroll view calls this to fix the hover.
    func syncHover() {
        guard let w = window else { return }
        let inside = bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
        if inside != hovered { hover(inside) }
        if !inside { HoverCard.close() }
    }
    private var hovered = false
    func hover(_ on: Bool) {
        hovered = on
        let base = expanded ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.1).cgColor : nil
        layer?.backgroundColor = on ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.15).cgColor : base
        play?.alphaValue = on ? 1 : 0
        startWith?.alphaValue = on ? 1 : 0
        if on, let title = subviews.compactMap({ $0 as? NSTextField }).first, title.intrinsicContentSize.width > title.bounds.width {
            HoverCard.schedule(title.stringValue, from: title)
        }
    }
    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        guard bounds.contains(loc) else { return }
        if subviews.contains(where: { ($0 is NSButton || $0 is AgentPill) && $0.frame.contains(loc) }) { return }
        onToggle?()
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onToggle?() } else { super.keyDown(with: event) }
    }
}

final class ActivityLine: NSView {
    let urlStr: String
    var expanded = false
    let full: String
    let hoverCard: Bool
    init(_ entry: ActivityEntry, w: CGFloat, hoverCard: Bool = true) {
        urlStr = entry.url
        full = entry.text
        self.hoverCard = hoverCard
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 22))
        wantsLayer = true
        let who = entry.actor.map { $0 + " · " } ?? ""
        let line = NSTextField(labelWithString: who + entry.text + " · " + relativeTime(entry.at))
        line.font = .systemFont(ofSize: 11)
        line.textColor = entry.unread ? .controlAccentColor : .secondaryLabelColor
        line.lineBreakMode = .byTruncatingTail
        line.frame = NSRect(x: 8, y: 3, width: w - 40, height: 16)
        line.identifier = NSUserInterfaceItemIdentifier("line")
        addSubview(line)
        let cp = NSButton(frame: NSRect(x: w - 28, y: 1, width: 22, height: 18))
        cp.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: "Copy link")
        cp.isBordered = false; cp.target = self; cp.action = #selector(copyLink)
        cp.alphaValue = 0
        cp.identifier = NSUserInterfaceItemIdentifier("copy")
        addSubview(cp)
        if hoverCard { toolTip = entry.text }
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func copyLink() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(urlStr, forType: .string)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }
    override func mouseEntered(with event: NSEvent) {
        (subviews.first { $0.identifier?.rawValue == "copy" })?.alphaValue = 1
        if hoverCard, let line = subviews.compactMap({ $0 as? NSTextField }).first, line.intrinsicContentSize.width > line.bounds.width {
            HoverCard.schedule(full, from: self)
        }
    }
    override func mouseExited(with event: NSEvent) {
        (subviews.first { $0.identifier?.rawValue == "copy" })?.alphaValue = 0
        HoverCard.close()
    }
    override func mouseUp(with event: NSEvent) {
        let loc = convert(event.locationInWindow, from: nil)
        if subviews.contains(where: { $0 is NSButton && $0.frame.contains(loc) }) { return }
        expanded.toggle()
        guard let line = subviews.compactMap({ $0 as? NSTextField }).first else { return }
        if expanded {
            let h = textHeight(line.stringValue, font: line.font!, width: line.frame.width) + 8
            line.frame.size.height = max(16, h)
            line.lineBreakMode = .byWordWrapping
            line.maximumNumberOfLines = 0
            frame.size.height = line.frame.height + 8
        } else {
            line.frame.size.height = 16
            line.maximumNumberOfLines = 1
            line.lineBreakMode = .byTruncatingTail
            frame.size.height = 22
        }
        superview?.needsLayout = true
    }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { mouseUp(with: event) } else { super.keyDown(with: event) }
    }
}

final class FeedRow: NSView {
    var onToggle: (() -> Void)?
    let expanded: Bool
    init(_ entry: ActivityEntry, itemTitle: String, project: String, status: String?, w: CGFloat, expanded: Bool) {
        self.expanded = expanded
        let bodyH: CGFloat = expanded ? textHeight(entry.text, font: .systemFont(ofSize: 12), width: w - 56) + 8 : 0
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 48 + bodyH))
        wantsLayer = true
        if entry.unread {
            addSubview(Dot(color: C_RUNNING, frame: NSRect(x: 10, y: 30, width: 6, height: 6)))
        }
        let actor = entry.actor ?? "Someone"
        let head = NSTextField(labelWithString: "\(actor) · \(entry.text)")
        head.font = .systemFont(ofSize: 12, weight: .medium)
        head.lineBreakMode = .byTruncatingTail
        head.frame = NSRect(x: 24, y: 26, width: w - 120, height: 16)
        addSubview(head)
        let sub = NSTextField(labelWithString: "\(itemTitle) · \(project)" + (status.map { " · \($0)" } ?? ""))
        sub.font = .systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor
        sub.lineBreakMode = .byTruncatingTail
        sub.frame = NSRect(x: 24, y: 8, width: w - 120, height: 14)
        addSubview(sub)
        let time = NSTextField(labelWithString: relativeTime(entry.at))
        time.font = .systemFont(ofSize: 10); time.textColor = .tertiaryLabelColor; time.alignment = .right
        time.frame = NSRect(x: w - 90, y: 26, width: 76, height: 14)
        addSubview(time)
        if expanded {
            let body = NSTextField(wrappingLabelWithString: entry.text)
            body.font = .systemFont(ofSize: 12)
            body.frame = NSRect(x: 24, y: 48, width: w - 40, height: bodyH)
            addSubview(body)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func mouseUp(with event: NSEvent) { onToggle?() }
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 49 { onToggle?() } else { super.keyDown(with: event) }
    }
}

extension TabVC {
    func buildProjectsContent(_ w: CGFloat) -> [NSView] {
        let store = (NSApp.delegate as? GHActionsBar)?.projectStore
        guard let store = store else {
            return [EmptyRow("Projects are not ready yet.", w: w)]
        }
        let tracked = (NSApp.delegate as? GHActionsBar)?.projectCatalog.resolve(PROJECTS_CFG) ?? []
        let agents = (NSApp.delegate as? GHActionsBar)?.agentIndex.ready
        let job = (NSApp.delegate as? GHActionsBar)?.statusJob
        if PROJECTS_CFG.workspaces.isEmpty {
            return [EmptyRow("Add a Plane workspace in Settings → Providers.", w: w, icon: "square.grid.2x2")]
        }
        if tracked.isEmpty {
            return [EmptyRow("No projects tracked. Pick projects in Settings → Projects.", w: w, icon: "square.grid.2x2")]
        }
        if let err = store.lastError, store.snapshots.isEmpty {
            return [EmptyRow(err, w: w, icon: "exclamationmark.triangle")]
        }
        if projectView == .activity { return buildActivityFeed(w, store: store) }
        var rows: [NSView] = []
        if let notice = projectNotice { rows.append(EmptyRow(notice, w: w, icon: "checkmark.circle")) }
        let shown = selectedProject.map { key in tracked.filter { $0.ref.storeKey == key } } ?? tracked
        let query = projectQuery.trimmingCharacters(in: .whitespaces)
        let canReorder = selectedProject == nil && shown.count > 1
        for summary in shown {
            let key = summary.ref.storeKey
            guard let snap = store.snapshots[key] else {
                rows.append(LoadingRow(w: w))
                continue
            }
            var items = snap.sorted(snap.listed(subItems: PROJECTS_CFG.showSubItems))
            items = items.filter { !snap.isHiddenDone($0, afterDays: PROJECTS_CFG.hideDoneAfterDays) && $0.matches(query) }
            if assignedOnly { items = items.filter { $0.isMine(snap.me) } }
            if unreadOnly { items = items.filter { store.isUnread(itemId: $0.id) } }
            if let fid = statusFilter[key] { items = items.filter { $0.statusOptionId == fid } }
            // A query opens the projects with matches and folds the rest. The saved fold state stays.
            let folded = query.isEmpty ? PROJECTS_CFG.isFolded(key) : items.isEmpty
            let live = store.liveKeys.contains(key)
            let header = ProjectHeader(snap: snap, live: live, refreshing: store.refreshing.contains(key),
                                       filter: statusFilter[key], updated: relativeTime(snap.fetchedAt), w: w,
                                       folded: folded, canReorder: canReorder)
            header.onRefresh = { [weak store] in store?.refresh([key], force: true) { _ in } }
            header.onFilter = { [weak self] id in
                guard let self = self else { return }
                if self.statusFilter[key] == id { self.statusFilter[key] = nil }
                else { self.statusFilter[key] = id }
                self.rebuildContent()
            }
            header.onFold = { [weak self] in
                PROJECTS_CFG.setFolded(key, !PROJECTS_CFG.isFolded(key))
                saveConfig()
                self?.rebuildContent(anchor: "project:" + key)
            }
            header.identifier = NSUserInterfaceItemIdentifier("project:" + key)
            header.onAdd = { [weak self] in self?.presentNewItem(target: key, prefill: nil) }
            header.onIntake = { (NSApp.delegate as? GHActionsBar)?.open(.intake(summary.identifier.uppercased())) }
            header.onDrag = { [weak self] phase, event in self?.dragProject(key, phase: phase, event: event) }
            rows.append(header)
            if folded { continue }
            let cap = PROJECTS_CFG.itemsPerProject
            let limited = (cap > 0 && !showAllProjects.contains(key)) ? Array(items.prefix(cap)) : items
            if limited.isEmpty {
                rows.append(EmptyRow("No items match these filters", w: w))
            }
            for item in limited {
                let progress = snap.progress(of: item.id)
                let last = store.activity(limit: 20, project: key).first { $0.itemId == item.id }?.text
                let row = ProjectItemRow(item: item, snap: snap, unread: store.isUnread(itemId: item.id),
                                         last: last, w: w, expanded: false,
                                         progress: progress.total > 0 ? progress : nil,
                                         agent: agents?.agent(item.key), status: job?.item(item.key),
                                         canStart: agents != nil && agents?.agent(item.key) == nil
                                            && snap.option(item.statusOptionId)?.category ?? .todo == .todo)
                row.onToggle = { ItemWindow.show(item.id) }
                if agents != nil {
                    let starter = (NSApp.delegate as? AppData).map(SessionStartMenu.init)
                    row.onStart = { anchor in starter?.start(item, snap: snap, at: anchor) }
                    row.onStartMenu = { anchor, header in starter?.agents(item, snap: snap, at: anchor, header: header) ?? NSMenu() }
                    row.onPill = { anchor in starter?.pill(item, snap: snap, at: anchor) }
                }
                row.identifier = NSUserInterfaceItemIdentifier("item:" + item.id)
                rows.append(row)
            }
            if cap > 0 && items.count > cap && !showAllProjects.contains(key) {
                let more = NSButton(title: "\(limited.count) of \(items.count) items · Show all", target: self, action: #selector(showAll(_:)))
                more.identifier = NSUserInterfaceItemIdentifier(key)
                more.bezelStyle = .inline; more.font = .systemFont(ofSize: 11)
                more.frame = NSRect(x: 0, y: 0, width: w, height: 28)
                rows.append(more)
            }
        }
        if rows.isEmpty { rows.append(EmptyRow("No projects to show", w: w)) }
        return rows
    }

    func buildActivityFeed(_ w: CGFloat, store: ProjectStore) -> [NSView] {
        var entries = store.activity(limit: 100, project: selectedProject)
        if assignedOnly {
            entries = entries.filter { id in
                store.item(id.itemId).map { $0.item.isMine($0.snap.me) } ?? false
            }
        }
        if unreadOnly { entries = entries.filter(\.unread) }
        if entries.isEmpty { return [EmptyRow("No project activity yet.", w: w, icon: "clock")] }
        var rows: [NSView] = []
        var lastDay = ""
        let cal = Calendar.current
        let df = DateFormatter(); df.dateFormat = "MMM d"
        for e in entries {
            let day: String
            if cal.isDateInToday(e.at) { day = "Today" }
            else if cal.isDateInYesterday(e.at) { day = "Yesterday" }
            else { day = df.string(from: e.at) }
            if day != lastDay {
                rows.append(SectionLabel(day.uppercased(), w: w))
                lastDay = day
            }
            let item = store.item(e.itemId)
            let title = item?.item.title ?? "Item"
            let project = item?.snap.summary.title ?? e.projectKey
            let status = item?.snap.statusName(item?.item.statusOptionId)
            let row = FeedRow(e, itemTitle: title, project: project, status: status, w: w, expanded: expandedItem == e.id)
            row.onToggle = { [weak self, weak store] in
                guard let self = self else { return }
                self.expandedItem = self.expandedItem == e.id ? nil : e.id
                store?.markActivityRead(e.id)
                self.rebuildContent()
            }
            rows.append(row)
        }
        return rows
    }

    // Drop position = the number of headers above the pointer.
    func dragProject(_ key: String, phase: DragPhase, event: NSEvent) {
        let headers = doc.subviews.compactMap { $0 as? ProjectHeader }.sorted { $0.frame.minY < $1.frame.minY }
        switch phase {
        case .began:
            let line = NSView(frame: NSRect(x: 8, y: 0, width: doc.frame.width - 16, height: 2))
            line.wantsLayer = true
            line.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            line.isHidden = true
            doc.addSubview(line)
            dragLine = line
            dragTarget = nil
        case .moved:
            doc.autoscroll(with: event)
            let p = doc.convert(event.locationInWindow, from: nil)
            let target = headers.filter { $0.frame.midY < p.y }.count
            dragTarget = target
            let y = target < headers.count ? headers[target].frame.minY : doc.frame.height
            dragLine?.frame.origin.y = max(0, min(doc.frame.height - 2, y - 1))
            dragLine?.isHidden = false
        case .ended:
            dragLine?.removeFromSuperview()
            dragLine = nil
            guard let target = dragTarget else { return }
            var keys = headers.map(\.key)
            guard let from = keys.firstIndex(of: key) else { return }
            keys.remove(at: from)
            keys.insert(key, at: from < target ? target - 1 : target)
            let rest = PROJECTS_CFG.order.filter { k in !keys.contains { $0.caseInsensitiveCompare(k) == .orderedSame } }
            PROJECTS_CFG.order = keys + rest
            saveConfig()
            rebuildContent()
        }
    }

    @objc func showAll(_ sender: NSButton) {
        if let key = sender.identifier?.rawValue { showAllProjects.insert(key) }
        rebuildContent()
    }
}
