import Cocoa

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
final class SidebarVC: NSViewController, NSTableViewDelegate, NSTableViewDataSource {
    var onPick: ((Route) -> Void)?
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
        scroll.documentView = table
        root.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        view = root
    }

    func set(_ new: [SidebarLine], selected: String) {
        selectedKey = selected
        if new != lines {
            lines = new
            table.reloadData()
        }
        select(selected)
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
}

final class SidebarCell: NSTableCellView {
    init(_ e: SidebarEntry) {
        super.init(frame: .zero)
        var views: [NSView] = []
        if let initial = e.initial {
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
