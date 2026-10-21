import Cocoa
import OverSireCore

// One line in the sidebar: a page, a project or a saved view.
struct SidebarEntry: Equatable {
    var key: String              // Route.sidebarKey
    var route: Route
    var title: String
    var symbol: String
    var badge: String?
    var badgeTone: NSColor?      // a dot before the badge; the badge text says what it counts
    var badgeLabel: String?      // VoiceOver text for the badge
    var initial: (text: String, color: NSColor)?

    static func == (a: SidebarEntry, b: SidebarEntry) -> Bool {
        a.key == b.key && a.title == b.title && a.badge == b.badge && a.badgeLabel == b.badgeLabel
    }
}

enum SidebarLine: Equatable {
    case header(String)
    case entry(SidebarEntry)
}

// The window sidebar. A source list table, so arrow keys and VoiceOver work.
final class SidebarVC: NSViewController, NSTableViewDelegate, NSTableViewDataSource, NSMenuDelegate {
    var onPick: ((Route) -> Void)?
    var commander: RowCommander?
    /// The connection line at the bottom.
    let live = LiveLine()
    var onLive: (() -> Void)? { get { live.onClick } set { live.onClick = newValue } }
    private let table = NSTableView()
    private var lines: [SidebarLine] = []
    private var selectedKey = "home"
    private var picking = false

    override func loadView() {
        let root = Box(fill: Palette.side, border: nil, radius: 0)
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.headerView = nil
        table.style = .sourceList
        table.backgroundColor = .clear
        table.rowSizeStyle = .custom
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.addTableColumn(NSTableColumn(identifier: .init("main")))
        table.delegate = self
        table.dataSource = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("Main")
        table.menu = NSMenu()
        table.menu?.delegate = self
        scroll.documentView = table
        root.addSubview(scroll)
        root.addSubview(live)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: live.topAnchor),
            live.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            live.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            live.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
        NotificationCenter.default.addObserver(forName: ProjectIconStore.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.table.reloadData()
            self.select(self.selectedKey)
        }
    }

    /// Reloads only the rows that changed. A new or removed line reloads the table.
    func set(_ new: [SidebarLine], selected: String) {
        selectedKey = selected
        if new != lines {
            let changed = SidebarVC.changedRows(lines, new)
            lines = new
            if let changed {
                table.reloadData(forRowIndexes: changed, columnIndexes: [0])
            } else {
                table.reloadData()
            }
        }
        select(selected)
    }

    /// The rows whose line changed, or nil when the lines are not the same list of keys.
    static func changedRows(_ old: [SidebarLine], _ new: [SidebarLine]) -> IndexSet? {
        func key(_ l: SidebarLine) -> String { if case .entry(let e) = l { return e.key }; if case .header(let t) = l { return "# " + t }; return "" }
        guard old.count == new.count, zip(old, new).allSatisfy({ key($0) == key($1) }) else { return nil }
        return IndexSet(zip(old, new).enumerated().filter { $0.element.0 != $0.element.1 }.map(\.offset))
    }

    func select(_ key: String) {
        selectedKey = key
        let i = lines.firstIndex { if case .entry(let e) = $0 { return e.key == key }; return false }
        picking = true
        if let i { table.selectRowIndexes([i], byExtendingSelection: false); table.scrollRowToVisible(i) }
        else { table.deselectAll(nil) }
        picking = false
    }

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        if case .header = lines[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .entry = lines[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if case .header = lines[row] { return 28 }
        return 30
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch lines[row] {
        case .header(let t):
            let l = NSTextField.text(t, size: 11, weight: .semibold, color: Palette.dim)
            let v = NSTableCellView()
            v.addSubview(l)
            NSLayoutConstraint.activate([
                l.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
                l.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),
            ])
            return v
        case .entry(let e):
            return SidebarCell(e)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !picking, table.selectedRow >= 0, case .entry(let e) = lines[table.selectedRow] else { return }
        selectedKey = e.key
        onPick?(e.route)
    }

    // A click on the selected entry changes no selection. It still opens the entry, so a project goes back to its list.
    @objc private func clicked() { reopen(row: table.clickedRow) }

    private func reopen(row: Int) {
        guard row >= 0, row == table.selectedRow, case .entry(let e) = lines[row] else { return }
        onPick?(e.route)
    }

    // For uishots: the same as a click on the selected entry with this title.
    func reopen(title: String) -> Bool {
        guard let row = lines.firstIndex(where: { if case .entry(let e) = $0 { return e.title == title } else { return false } }) else { return false }
        reopen(row: row)
        return true
    }

    func focus() { view.window?.makeFirstResponder(table) }

    // The right-click menu of a project row.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, case .entry(let e) = lines[row], case .project(let key) = e.route, let commander,
              let p = commander.data.projectStore.tracked.first(where: { $0.identifier.uppercased() == key }) else { return }
        let entries = RowMenu.sidebarProject(p, hasTrackerIcon: p.logo != nil)
        commander.items(entries, anchor: table.view(atColumn: 0, row: row, makeIfNecessary: false)).forEach { menu.addItem($0) }
    }
}

final class SidebarCell: NSTableCellView {
    init(_ e: SidebarEntry) {
        super.init(frame: .zero)
        var views: [NSView] = []
        if case .project(let key) = e.route {
            let icon = NSImageView(image: PROJECT_ICONS.image(for: key, size: 18))
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.widthAnchor.constraint(equalToConstant: 18).isActive = true
            icon.heightAnchor.constraint(equalToConstant: 18).isActive = true
            views.append(icon)
        } else if let initial = e.initial {
            let b = Box(fill: initial.color, border: nil, radius: 4)
            let t = NSTextField.text(initial.text, size: 10, weight: .bold, color: .white)
            b.addSubview(t)
            NSLayoutConstraint.activate([
                b.widthAnchor.constraint(equalToConstant: 18), b.heightAnchor.constraint(equalToConstant: 18),
                t.centerXAnchor.constraint(equalTo: b.centerXAnchor), t.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            ])
            views.append(b)
        } else {
            let g = Glyph(e.symbol, color: e.badgeTone ?? Palette.mut, size: 13)
            g.widthAnchor.constraint(equalToConstant: 18).isActive = true
            views.append(g)
        }
        let title = NSTextField.text(e.title, size: 13, color: Palette.fg)
        views.append(title)
        views.append(Spacer())
        if let badge = e.badge {
            var parts: [NSView] = []
            if let tone = e.badgeTone {
                let dot = Box(fill: tone, border: nil, radius: 3)
                dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
                parts.append(dot)
            }
            let t = NSTextField.text(badge, size: 11, weight: .medium, color: Palette.mut)
            t.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
            parts.append(t)
            let pill = Box(fill: Palette.raise, border: Palette.line, radius: 8)
            pill.toolTip = e.badgeLabel
            let s = NSStackView(h: parts, spacing: 4)
            pill.addSubview(s)
            NSLayoutConstraint.activate([
                s.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 6),
                s.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
                s.topAnchor.constraint(equalTo: pill.topAnchor, constant: 1),
                s.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -1),
            ])
            views.append(pill)
        }
        let row = NSStackView(h: views, spacing: 8)
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityLabel(e.title + (e.badgeLabel.map { ", " + $0 } ?? ""))
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// What the live line shows: the cloud state and the last burst of events. Pure, for the tests.
struct LiveLineModel: Equatable {
    enum Mark: Equatable { case connected, connecting, disconnected, polling }

    var state: LiveSync.State
    var lastBurst: Date?
    var pollEvery: TimeInterval = POLL_NORMAL

    /// How long "just now" shows after a burst.
    static let pingTime: TimeInterval = 4

    var mark: Mark {
        switch state {
        case .live: return .connected
        case .connecting: return .connecting
        case .error: return .disconnected
        case .off: return .polling
        }
    }

    var title: String {
        switch state {
        case .live: return "Connected"
        case .connecting: return "Connecting…"
        case .error: return "Disconnected"
        case .off: return "Polling"
        }
    }

    /// The dim text after the title.
    var detail: String? {
        switch state {
        case .connecting: return "polling meanwhile"
        case .error: return "polling every \(Int(pollEvery)) s"
        default: return nil
        }
    }

    func justNow(at now: Date) -> Bool { lastBurst.map { now.timeIntervalSince($0) < Self.pingTime && now >= $0 } ?? false }

    var tooltip: String {
        if case .error(let m) = state { return "Cloud error: \(m)" }
        return lastBurst.map { "Last event \(relativeTime($0))" } ?? (state == .off ? "No cloud. OverSire polls GitHub and the trackers." : "No events yet")
    }
}

/// The connection line at the bottom of the window sidebar. One ring for each burst of events, never a count.
final class LiveLine: Box {
    var onClick: (() -> Void)?
    private(set) var model = LiveLineModel(state: .off)
    private let markView = LiveMark()
    private let title = NSTextField.text("", size: 11.5, color: Palette.mut)
    private let detail = NSTextField.text("", size: 11.5, color: Palette.dim)
    private let ping = NSTextField.text("just now", size: 11, color: Palette.dim)
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(now: @escaping () -> Date = Date.init, schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = ChangeBus.mainAfter) {
        self.now = now
        self.schedule = schedule
        super.init(fill: Palette.side, border: nil, radius: 0)
        let line = Box(fill: Palette.line, border: nil, radius: 0)
        ping.alphaValue = 0.7
        ping.isHidden = true
        detail.lineBreakMode = .byTruncatingTail
        let row = NSStackView(h: [markView, title, detail, Spacer(), ping], spacing: 6)
        addSubview(line)
        addSubview(row)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 30),
            line.leadingAnchor.constraint(equalTo: leadingAnchor), line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.topAnchor.constraint(equalTo: topAnchor), line.heightAnchor.constraint(equalToConstant: 1),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            row.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        render()
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ relay: LiveSync) { set(LiveLineModel(state: relay.state, lastBurst: relay.lastBurstAt)) }

    func set(_ m: LiveLineModel) {
        let burst = m.lastBurst != nil && m.lastBurst != model.lastBurst && m.justNow(at: now())
        model = m
        render()
        guard burst else { return }
        if !RowReconciler.reduceMotion { markView.ring() }
        let at = m.lastBurst
        schedule(LiveLineModel.pingTime) { [weak self] in
            guard let self, self.model.lastBurst == at else { return }
            self.render()
        }
    }

    /// True while "just now" shows.
    var showsPing: Bool { !ping.isHidden }

    private func render() {
        markView.mark = model.mark
        title.stringValue = model.title
        detail.stringValue = model.detail.map { "· " + $0 } ?? ""
        detail.isHidden = model.detail == nil
        ping.isHidden = !model.justNow(at: now())
        toolTip = model.tooltip
        setAccessibilityLabel(model.title)
        setAccessibilityHelp("Opens the Activity page")
    }

    var text: String { [title.stringValue, detail.isHidden ? nil : detail.stringValue].compactMap { $0 }.joined(separator: " ") }

    override func mouseUp(with event: NSEvent) { onClick?() }
    override func accessibilityPerformPress() -> Bool { onClick?(); return onClick != nil }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// The mark of the live line: a filled circle, a hollow circle or a triangle with "!".
final class LiveMark: NSView {
    var mark: LiveLineModel.Mark = .polling { didSet { needsDisplay = true } }
    private let size: CGFloat = 9

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: 12), heightAnchor.constraint(equalToConstant: 12)])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        switch mark {
        case .connected:
            Palette.ok.setFill()
            NSBezierPath(ovalIn: r).fill()
        case .connecting:
            Palette.dim.setStroke()
            let p = NSBezierPath(ovalIn: r.insetBy(dx: 0.75, dy: 0.75))
            p.lineWidth = 1.5
            p.stroke()
        case .polling:
            Palette.dim.setFill()
            NSBezierPath(ovalIn: r).fill()
        case .disconnected:
            let t = NSRect(x: (bounds.width - 11) / 2, y: (bounds.height - 10) / 2, width: 11, height: 10)
            let p = NSBezierPath()
            p.move(to: NSPoint(x: t.midX, y: t.maxY))
            p.line(to: NSPoint(x: t.maxX, y: t.minY))
            p.line(to: NSPoint(x: t.minX, y: t.minY))
            p.close()
            Palette.bad.setFill()
            p.fill()
            let bang = NSAttributedString(string: "!", attributes: [.font: NSFont.systemFont(ofSize: 7.5, weight: .heavy), .foregroundColor: NSColor.white])
            let s = bang.size()
            bang.draw(at: NSPoint(x: t.midX - s.width / 2, y: t.minY - 0.5))
        }
    }

    /// One ring that grows out of the mark and fades.
    func ring() {
        guard let layer else { return }
        let ring = CAShapeLayer()
        let r = NSRect(x: (bounds.width - size) / 2, y: (bounds.height - size) / 2, width: size, height: size)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: r, transform: nil)
        ring.fillColor = nil
        effectiveAppearance.performAsCurrentDrawingAppearance {
            ring.strokeColor = (mark == .disconnected ? Palette.bad : mark == .connected ? Palette.ok : Palette.dim).cgColor
        }
        ring.lineWidth = 1.5
        ring.opacity = 0
        layer.masksToBounds = false
        layer.addSublayer(ring)
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 2.4
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.9
        fade.toValue = 0
        let g = CAAnimationGroup()
        g.animations = [grow, fade]
        g.duration = 1.2
        g.timingFunction = CAMediaTimingFunction(name: .easeOut)
        ring.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        ring.position = CGPoint(x: bounds.midX, y: bounds.midY)
        CATransaction.begin()
        CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
        ring.add(g, forKey: "ring")
        CATransaction.commit()
    }
}
