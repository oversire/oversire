import Cocoa
import OverSireCore

// ─── Changes › large view ────────────────────────────────────────────────────
// ⇧⌘M shows the diff panel in a card at 90% of the window, over a dim scrim (OVERSIRE-440).
// The panel moves into the card and back, so the table keeps its rows and its scroll position.
// The file panel can sit at the left of the card (OVERSIRE-461). It moves in the same way.
// ⌘P opens the file switch from the path: type to filter, ↑ ↓ to move, Return to open.

/// The large view of the diff. Esc or a click on the scrim closes it.
final class DiffModal: NSView {
    private let scrim = Scrim()
    private let card = Box(fill: Palette.panel, border: Palette.line, radius: 12)
    private let close: () -> Void
    private let filesSlot = NSView()
    private let rule = Box(fill: Palette.line, border: nil, radius: 0)
    private let diffSlot = NSView()
    private var withFiles: NSLayoutConstraint!
    private var noFiles: NSLayoutConstraint!
    private(set) weak var panel: DiffPanel?
    private(set) weak var files: NSView?

    /// Adds the large view on top of the window and moves the panel into it.
    /// `files` is the file panel. It shows at the left of the diff.
    static func show(_ panel: DiffPanel, files: NSView? = nil, in window: NSWindow, close: @escaping () -> Void) -> DiffModal {
        let m = DiffModal(close: close)
        guard let root = window.contentView else { return m }
        root.addSubview(m)
        NSLayoutConstraint.activate([
            m.leadingAnchor.constraint(equalTo: root.leadingAnchor), m.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            // Below the toolbar of a full-size content view.
            m.topAnchor.constraint(equalTo: root.safeAreaLayoutGuide.topAnchor), m.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        m.hold(panel, files: files)
        return m
    }

    private init(close: @escaping () -> Void) {
        self.close = close
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        scrim.onClick = { [weak self] in self?.close() }
        card.layer?.masksToBounds = true
        [scrim, card].forEach(addSubview)
        [filesSlot, rule, diffSlot].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview($0)
        }
        withFiles = diffSlot.leadingAnchor.constraint(equalTo: rule.trailingAnchor)
        noFiles = diffSlot.leadingAnchor.constraint(equalTo: card.leadingAnchor)
        NSLayoutConstraint.activate([
            filesSlot.leadingAnchor.constraint(equalTo: card.leadingAnchor), filesSlot.topAnchor.constraint(equalTo: card.topAnchor),
            filesSlot.bottomAnchor.constraint(equalTo: card.bottomAnchor), filesSlot.widthAnchor.constraint(equalToConstant: ReviewChangesTab.sideWidth),
            rule.leadingAnchor.constraint(equalTo: filesSlot.trailingAnchor), rule.widthAnchor.constraint(equalToConstant: 1),
            rule.topAnchor.constraint(equalTo: card.topAnchor), rule.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            diffSlot.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            diffSlot.topAnchor.constraint(equalTo: card.topAnchor), diffSlot.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            noFiles,
        ])
        filesSlot.isHidden = true
        rule.isHidden = true
        filesSlot.setAccessibilityElement(true)
        filesSlot.setAccessibilityRole(.group)
        filesSlot.setAccessibilityLabel("Files")
        NSLayoutConstraint.activate([
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor), scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.topAnchor.constraint(equalTo: topAnchor), scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            card.centerXAnchor.constraint(equalTo: centerXAnchor), card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.9), card.heightAnchor.constraint(equalTo: heightAnchor, multiplier: 0.9),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Diff, large view")
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Moves the panel and the file panel into the card. A panel that is in place stays, with its focus and scroll position.
    func hold(_ p: DiffPanel, files: NSView?) {
        if p.superview !== diffSlot {
            panel = p
            diffSlot.subviews.forEach { $0.removeFromSuperview() }
            p.removeFromSuperview()
            Self.pin(p, in: diffSlot)
            DispatchQueue.main.async { [weak p] in p?.window?.makeFirstResponder(p?.table.view) }
        }
        if files !== self.files || files?.superview !== filesSlot {
            filesSlot.subviews.forEach { $0.removeFromSuperview() }
            self.files = files
            files.map { Self.pin($0, in: filesSlot) }
        }
        filesSlot.isHidden = files == nil
        rule.isHidden = files == nil
        if files == nil {
            noFiles.isActive = true
            withFiles.isActive = false
        } else {
            noFiles.isActive = false
            withFiles.isActive = true
        }
        // The focus was in the file panel that left.
        if files == nil, window != nil, (window?.firstResponder as? NSView).map({ !$0.isDescendant(of: diffSlot) }) ?? true {
            window?.makeFirstResponder(p.table.view)
        }
        window?.recalculateKeyViewLoop()
    }

    private static func pin(_ v: NSView, in box: NSView) {
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor), v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            v.topAnchor.constraint(equalTo: box.topAnchor), v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
    }

    /// Removes the large view. The panels go back on the next build of the tab.
    /// A view that is not in the card any more stays where it is.
    func dismiss() {
        if panel?.superview === diffSlot { panel?.removeFromSuperview() }
        if files?.superview === filesSlot { files?.removeFromSuperview() }
        removeFromSuperview()
    }

    override func cancelOperation(_ sender: Any?) { close() }

    /// The dim layer behind the card. It takes the clicks, so the page under it does not get them.
    private final class Scrim: Box {
        var onClick: () -> Void = {}
        init() { super.init(fill: NSColor.black.withAlphaComponent(0.45), border: nil, radius: 0) }
        required init?(coder: NSCoder) { fatalError() }
        override func mouseDown(with event: NSEvent) { onClick() }
        override func scrollWheel(with event: NSEvent) {}
    }
}

/// The file switch: a filter field and the files of the review, by repo. It opens in a popover from the path.
final class DiffFileSwitch: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private static weak var shown: NSPopover?
    private let desk: ReviewDesk
    private let open: (ReviewFile) -> Void
    private let field = NSSearchField()
    private let table = NSTableView()
    private(set) var rows: [FileTree.Row] = []
    private var popover: NSPopover?

    /// Opens the switch under a view. A second call closes the first switch.
    @discardableResult
    static func show(_ desk: ReviewDesk, from view: NSView, open: @escaping (ReviewFile) -> Void) -> DiffFileSwitch {
        shown?.close()
        let s = DiffFileSwitch(desk, open: open)
        let p = NSPopover()
        p.behavior = .transient
        p.contentViewController = s
        s.popover = p
        p.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
        shown = p
        return s
    }

    static func dismiss() { shown?.close() }

    init(_ desk: ReviewDesk, open: @escaping (ReviewFile) -> Void) {
        self.desk = desk
        self.open = open
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 380))
        field.placeholderString = "Filter files"
        field.setAccessibilityLabel("Filter files")
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.headerView = nil
        table.addTableColumn(NSTableColumn(identifier: .init("file")))
        table.rowHeight = 26
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.setAccessibilityLabel("Files")
        if #available(macOS 11.0, *) { table.style = .plain }
        scroll.documentView = table
        [field, scroll].forEach(root.addSubview)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10), field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 8), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -6),
        ])
        view = root
        filter()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(field)
    }

    /// The rows of the list view with the text of the field. The repo filter of the panel stays.
    func filter() {
        var tree = desk.tree
        tree.filter.query = field.stringValue
        tree.filter.hidden = []
        rows = tree.rows(.list)
        table.reloadData()
        let at = rows.firstIndex { $0.file?.id == desk.file } ?? rows.firstIndex { $0.file != nil }
        if let at { select(at) }
    }

    private func select(_ r: Int) {
        table.selectRowIndexes([r], byExtendingSelection: false)
        table.scrollRowToVisible(r)
    }

    /// Moves the selection to the next file row up or down.
    func move(_ by: Int) {
        var r = table.selectedRow + by
        while rows.indices.contains(r), rows[r].file == nil { r += by }
        if rows.indices.contains(r) { select(r) }
    }

    func choose() {
        guard rows.indices.contains(table.selectedRow), let f = rows[table.selectedRow].file else { return NSSound.beep() }
        popover?.close()
        open(f)
    }

    @objc private func clicked() { choose() }

    func controlTextDidChange(_ obj: Notification) { filter() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.insertNewline(_:)): choose()
        case #selector(NSResponder.cancelOperation(_:)): popover?.close()
        default: return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { rows[row].file != nil }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        guard let f = r.file else {
            let t = NSTextField.text(r.name, size: 11.5, weight: .semibold, color: Palette.mut, mono: true)
            let s = NSStackView(h: [t, Spacer()])
            s.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
            return s
        }
        let letter = NSTextField.text(FileGroup(f.status).letter, size: 11, weight: .bold, color: ReviewChangesTab.color(f.status), mono: true)
        let path = NSTextField.text(f.path, size: 12, mono: true)
        path.lineBreakMode = .byTruncatingMiddle
        let counts = NSTextField.text("+\(f.added) −\(f.removed)", size: 11, color: Palette.mut, mono: true)
        counts.setContentCompressionResistancePriority(.required, for: .horizontal)
        var parts: [NSView] = [letter, path, Spacer(), counts]
        if f.viewed { parts.append(Glyph("checkmark", color: Palette.ok, size: 10)) }
        if f.isStale { parts.append(Glyph("arrow.clockwise", color: Palette.warn, size: 10)) }
        let s = NSStackView(h: parts, spacing: 8)
        s.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        s.setAccessibilityElement(true)
        s.setAccessibilityRole(.row)
        s.setAccessibilityLabel("\(ReviewChangesTab.word(f.status)) \(f.path), \(f.added) added, \(f.removed) removed" + (f.viewed ? ", viewed" : f.isStale ? ", changed since viewed" : ""))
        return s
    }
}

/// The note in the page while the diff is in the large view. It tells when it leaves its window.
final class DiffAwayNote: NSView {
    var gone: () -> Void = {}

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let note = EmptyNote("The diff is in the large view. Press ⇧⌘M to restore.", symbol: "arrow.up.left.and.arrow.down.right")
        addSubview(note)
        NSLayoutConstraint.activate([
            note.leadingAnchor.constraint(equalTo: leadingAnchor), note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            note.topAnchor.constraint(equalTo: topAnchor), note.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { gone() }
    }
}
