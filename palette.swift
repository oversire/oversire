import Cocoa

// ⌘K: type to find a page, a project, an item, a run or an action. Return opens it.
final class CommandPalette: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSWindowDelegate {
    struct Entry {
        let title: String
        let detail: String
        let symbol: String
        let kind: String         // "Page", "Item", "Run", "Action"
        let run: () -> Void
    }

    private static var current: CommandPalette?

    static func show(over owner: AppWindow, query: String = "") {
        current?.close()
        let p = CommandPalette(owner: owner)
        current = p
        p.open()
        if !query.isEmpty { p.field.stringValue = query; p.filter(query) }
    }

    static func dismiss() { current?.close() }
    static var windowNumber: Int? { current?.panel.windowNumber }

    private weak var owner: AppWindow?
    private let panel: NSPanel
    private let field = NSSearchField()
    private let table = NSTableView()
    private var all: [Entry] = []
    private var shown: [Entry] = []

    private init(owner: AppWindow) {
        self.owner = owner
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 400),
                        styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setAccessibilityTitle("Command palette")
        let root = Box(fill: Palette.raise, border: Palette.line, radius: 0)
        field.placeholderString = "Search items, runs and pages, or type a command"
        field.font = .systemFont(ofSize: 15)
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        field.focusRingType = .none
        field.setAccessibilityLabel("Search")
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = 34
        table.addTableColumn(NSTableColumn(identifier: .init("e")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(pick)
        table.setAccessibilityLabel("Results")
        scroll.documentView = table
        let hint = NSTextField.text("↑↓ move · ↩ open · esc close", size: 11, color: Palette.dim)
        root.addSubview(field); root.addSubview(scroll); root.addSubview(hint)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        panel.contentView = root
        all = entries()
        filter("")
    }

    private func open() {
        guard let w = owner?.window else { return }
        let f = w.frame
        panel.setFrameOrigin(NSPoint(x: f.midX - 310, y: f.maxY - 140 - 400))
        w.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }

    private func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if CommandPalette.current === self { CommandPalette.current = nil }
    }

    func windowDidResignKey(_ notification: Notification) { close() }

    // MARK: Entries

    private func entries() -> [Entry] {
        guard let owner else { return [] }
        let data = owner.data
        func go(_ r: Route) -> () -> Void { { [weak owner] in owner?.show(r) } }
        var out: [Entry] = []
        let pages: [(Route, String, String)] = [
            (.home, "Home", "house"), (.inbox(.all), "Inbox", "tray"), (.inbox(.intake), "Inbox › Intake", "tray.and.arrow.down"),
            (.mine, "My items", "person.crop.circle"), (.agents, "Sessions", "cpu"), (.queue, "Queue", "list.number"),
            (.runs(.all), "Runs", "play.circle"), (.runs(.failed), "Runs › Failed", "xmark.octagon"),
            (.runs(.unlinked), "Runs › Unlinked", "link.badge.plus"), (.prs, "Pull requests", "arrow.triangle.pull"),
            (.insights, "Insights", "chart.bar"),
        ]
        for (r, t, s) in pages { out.append(Entry(title: t, detail: r.url.absoluteString, symbol: s, kind: "Page", run: go(r))) }
        for p in Route.SettingsPage.allCases {
            let r = Route.settings(p)
            out.append(Entry(title: "Settings › " + p.title, detail: r.url.absoluteString, symbol: "gearshape", kind: "Page", run: go(r)))
        }
        for p in data.projectStore.tracked {
            let r = Route.project(p.identifier.uppercased())
            out.append(Entry(title: p.title, detail: "\(p.ref.workspace) · \(p.identifier)", symbol: "folder", kind: "Project", run: go(r)))
        }
        for s in data.projectStore.snapshots.values {
            for i in s.sortedItems {
                let st = s.statusName(i.statusOptionId) ?? ""
                out.append(Entry(title: "\(i.key)  \(i.title)", detail: st, symbol: "circle.dashed", kind: "Item", run: go(.item(i.key, .overview))))
            }
        }
        for (repo, runs) in data.grouped {
            for r in runs.prefix(8) {
                out.append(Entry(title: "\(r.workflowName ?? r.name) · \(r.headBranch)", detail: "\(repo) · \(Tone(r).word)",
                                 symbol: Tone(r).symbol, kind: "Run", run: go(.run(repo: repo, id: r.id))))
            }
        }
        out.append(Entry(title: "Refresh now", detail: "⌘R", symbol: "arrow.clockwise", kind: "Action") { data.refresh(force: true, completion: nil) })
        for t in Theme.allCases {
            out.append(Entry(title: "Theme: \(t.label)", detail: "Settings › General", symbol: "circle.lefthalf.filled", kind: "Action") {
                GENERAL.theme = t
                saveConfig()
                (NSApp.delegate as? GHActionsBar)?.applySystemAppearance()
            })
        }
        out.append(Entry(title: "Copy link to this page", detail: owner.router.current.url.absoluteString, symbol: "link", kind: "Action") { [weak owner] in
            guard let owner else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(owner.router.current.url.absoluteString, forType: .string)
        })
        return out
    }

    // Every word must appear in the title or the detail. Items whose key starts with the query come first.
    private func filter(_ q: String) {
        let words = q.lowercased().split(separator: " ").map(String.init)
        if words.isEmpty {
            shown = all.filter { $0.kind == "Page" || $0.kind == "Action" || $0.kind == "Project" }
        } else {
            shown = all.filter { e in
                let hay = (e.title + " " + e.detail + " " + e.kind).lowercased()
                return words.allSatisfy { hay.contains($0) }
            }
            shown.sort { a, b in
                let pa = a.title.lowercased().hasPrefix(words[0]), pb = b.title.lowercased().hasPrefix(words[0])
                return pa && !pb
            }
        }
        shown = Array(shown.prefix(60))
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes([0], byExtendingSelection: false) }
    }

    func controlTextDidChange(_ obj: Notification) { filter(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): pick(); return true
        case #selector(NSResponder.cancelOperation(_:)): close(); return true
        default: return false
        }
    }

    private func move(_ d: Int) {
        guard !shown.isEmpty else { return }
        let i = max(0, min(shown.count - 1, table.selectedRow + d))
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
    }

    @objc private func pick() {
        let i = table.selectedRow
        guard i >= 0, i < shown.count else { return }
        let e = shown[i]
        close()
        e.run()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = shown[row]
        let v = NSTableCellView()
        let s = NSStackView(h: [Glyph(e.symbol, color: Palette.mut, size: 13),
                                NSTextField.text(e.title, size: 13),
                                NSTextField.text(e.detail, size: 11.5, color: Palette.dim),
                                Spacer(),
                                Chiplet(e.kind, color: Palette.dim)], spacing: 8)
        v.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            s.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            s.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        v.setAccessibilityLabel("\(e.kind): \(e.title), \(e.detail)")
        return v
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { true }
}
