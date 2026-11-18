import Cocoa
import OverSireCore
import OverSireAssistant

// "Move to epic": a popover at the epic chip of the item page. A pick runs item.setEpic.
final class EpicPicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSPopoverDelegate {
    static let width: CGFloat = 340
    private static var current: EpicPicker?
    static var windowNumber: Int? { current?.view.window?.windowNumber }
    static func dismiss() { current?.popover.close() }

    /// `started` runs when the write starts, `done` when it ends. The page uses them for its "Saving" note.
    static func show(for item: Item, snap: ProjectSnapshot, data: AppData, from anchor: NSView,
                     started: (() -> Void)? = nil, done: ((ActionResult) -> Void)? = nil) {
        guard let epics = snap.epics else { return }
        current?.popover.close()
        let model = EpicPickerModel(epics: epics.map { snap.rollup($0) }, current: snap.epicId(of: item.id))
        let vc = EpicPicker(model: model, item: item, snap: snap, data: data, anchor: anchor, started: started, done: done)
        vc.popover.behavior = .transient
        vc.popover.animates = false
        vc.popover.contentViewController = vc
        vc.popover.delegate = vc
        NSApp.withPinnedAppearance { vc.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY) }
        current = vc
        vc.view.window?.makeFirstResponder(vc.field)
    }

    private let popover = NSPopover()
    private let model: EpicPickerModel
    private let item: Item
    private let snap: ProjectSnapshot
    private unowned let data: AppData
    private weak var anchor: NSView?
    private let started: (() -> Void)?
    private let done: ((ActionResult) -> Void)?
    private let field = NSSearchField()
    private let table = NSTableView()
    private var shown: [EpicPickerModel.Row] = []

    private init(model: EpicPickerModel, item: Item, snap: ProjectSnapshot, data: AppData, anchor: NSView,
                 started: (() -> Void)?, done: ((ActionResult) -> Void)?) {
        self.model = model
        self.item = item
        self.snap = snap
        self.data = data
        self.anchor = anchor
        self.started = started
        self.done = done
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private func height(_ r: EpicPickerModel.Row) -> CGFloat {
        if case .epic = r { return 44 }
        return 32
    }

    override func loadView() {
        let all = model.rows(query: "")
        let list = min(300, all.reduce(0) { $0 + height($1) })
        let root = NSView(frame: NSRect(x: 0, y: 0, width: Self.width, height: list + 78))
        field.placeholderString = "Find an epic"
        field.setAccessibilityLabel("Find an epic")
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.addTableColumn(NSTableColumn(identifier: .init("e")))
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(pick)
        table.setAccessibilityLabel("Epics")
        scroll.documentView = table
        let hint = NSTextField.text("An item is in one epic. ↑↓ move · ↩ choose · esc close", size: 11, color: Palette.dim)
        root.addSubview(field); root.addSubview(scroll); root.addSubview(hint)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            field.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -4),
            scroll.bottomAnchor.constraint(equalTo: hint.topAnchor, constant: -6),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            hint.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
        ])
        view = root
        filter("")
    }

    private func filter(_ q: String) {
        shown = model.rows(query: q)
        table.reloadData()
        let first = shown.firstIndex { $0.isSelected } ?? 0
        if q.isEmpty { table.selectRowIndexes([first], byExtendingSelection: false) } else if let i = shown.firstIndex(where: { if case .epic = $0 { return true }; return false }) {
            table.selectRowIndexes([i], byExtendingSelection: false)
        } else {
            table.selectRowIndexes([0], byExtendingSelection: false)
        }
        table.scrollRowToVisible(table.selectedRow)
    }

    func controlTextDidChange(_ obj: Notification) { filter(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)): move(1); return true
        case #selector(NSResponder.moveUp(_:)): move(-1); return true
        case #selector(NSResponder.insertNewline(_:)): pick(); return true
        case #selector(NSResponder.cancelOperation(_:)): popover.close(); return true
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
        let row = shown[i]
        let window = anchor?.window
        popover.close()
        switch row {
        case .epic(let r, let selected): if !selected { set(r.epic.id.rawValue, in: window) }
        case .none(let selected): if !selected { set("none", in: window) }
        case .new:
            NewEpicSheet.present(over: window, snap: snap, data: data) { [weak self] id in self?.set(id.rawValue, in: window) }
        }
    }

    private func set(_ epic: String, in window: NSWindow?) {
        data.actions.click("item.setEpic", ["key": .string(item.key), "epic": .string(epic)], in: window, started: started, done: done)
    }

    func popoverDidClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { height(shown[row]) }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = shown[row]
        let v = NSTableCellView()
        let mark: NSView = r.isSelected ? Glyph("checkmark", color: Palette.fg, size: 12).fixedWidth(14) : Spacer(14)
        var views: [NSView] = [mark]
        switch r {
        case .epic(let roll, _):
            let name = NSStackView(v: [NSTextField.text(r.title, size: 13), NSTextField.text(r.detail ?? "", size: 11.5, color: Palette.dim)], spacing: 1)
            name.setContentCompressionResistancePriority(.init(200), for: .horizontal)
            let bar = EpicBar(done: roll.done, started: roll.started, total: roll.total, height: 5).fixedWidth(54)
            views += [EpicGlyph(roll.epic.state, late: roll.lateDays != nil, size: 14), name, Spacer(), bar,
                      NSTextField.text("\(roll.done)/\(roll.total)", size: 11.5, color: Palette.mut)]
        case .none:
            views += [NSTextField.text(r.title, size: 13)]
        case .new:
            views += [Glyph("plus", color: Palette.acc, size: 12), NSTextField.text(r.title, size: 13, color: Palette.acc)]
        }
        let s = NSStackView(h: views, spacing: 8)
        v.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            s.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            s.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        v.setAccessibilityRole(.button)
        v.setAccessibilityLabel(r.label)
        return v
    }
}
