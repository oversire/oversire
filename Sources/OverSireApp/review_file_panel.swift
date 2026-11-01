import Cocoa
import OverSireCore

// ─── Changes › file panel ────────────────────────────────────────────────────
// The side of the Changes tab (OVERSIRE-388, OVERSIRE-389): a fixed header with search, view, repo filter and
// status switches, and the rows of `FileTree`. The header stays across builds, so the search field keeps the focus.

/// An on and off switch with a letter badge and a count. An off switch shows a hollow badge and struck text,
/// so the state does not rely on color.
final class SwitchChip: Box {
    private let badge = NSTextField.text("", size: 10, weight: .bold, mono: true)
    private let badgeBox = Box(fill: nil, border: nil, radius: 4)
    private let word = NSTextField.text("", size: 11.5)
    private let count = NSTextField.text("", size: 11.5, color: Palette.dim)
    private let color: NSColor
    private let flip: () -> Void
    private let name: String
    private(set) var on = true

    init(_ letter: String, _ name: String, color: NSColor, _ flip: @escaping () -> Void) {
        self.color = color
        self.flip = flip
        self.name = name
        super.init(fill: Palette.raise, border: Palette.line, radius: 6)
        badge.stringValue = letter
        badge.alignment = .center
        badgeBox.addSubview(badge)
        let s = NSStackView(h: [badgeBox, word, count], spacing: 4)
        addSubview(s)
        NSLayoutConstraint.activate([
            badgeBox.widthAnchor.constraint(equalToConstant: 15), badgeBox.heightAnchor.constraint(equalToConstant: 15),
            badge.centerXAnchor.constraint(equalTo: badgeBox.centerXAnchor), badge.centerYAnchor.constraint(equalTo: badgeBox.centerYAnchor),
            s.centerXAnchor.constraint(equalTo: centerXAnchor), s.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            s.topAnchor.constraint(equalTo: topAnchor, constant: 3), s.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        toolTip = "Show \(name.lowercased()) files"
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(on: Bool, count n: Int) {
        self.on = on
        fill = on ? Palette.raise : nil
        badgeBox.fill = on ? color : nil
        badgeBox.border = on ? nil : Palette.dim
        badge.textColor = on ? Palette.bg : Palette.dim
        word.attributedStringValue = NSAttributedString(string: name, attributes: [
            .font: NSFont.systemFont(ofSize: 11.5), .foregroundColor: on ? Palette.fg : Palette.dim,
            .strikethroughStyle: on ? 0 : NSUnderlineStyle.single.rawValue,
        ])
        count.stringValue = "\(n)"
        setAccessibilityLabel("\(name) files, \(n)")
        setAccessibilityValue(on ? 1 : 0)
        setAccessibilityValueDescription(on ? "shown" : "hidden")
    }

    override func mouseUp(with event: NSEvent) { flip() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { flip(); return true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { flip(); return }
        super.keyDown(with: event)
    }
    override func drawFocusRingMask() { NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// A row of the tree. Left closes a folder, right opens it.
final class TreeRow: Row {
    var fold: (open: Bool, toggle: () -> Void)?

    override func keyDown(with event: NSEvent) {
        if let fold, event.keyCode == 123 || event.keyCode == 124 {
            if fold.open == (event.keyCode == 123) { fold.toggle() }
            return
        }
        super.keyDown(with: event)
    }
}

/// The file panel of one review. Main thread only.
final class FilePanel: NSObject, NSSearchFieldDelegate {
    private(set) weak var desk: ReviewDesk?
    /// Builds the page again.
    var changed: () -> Void = {}
    /// Shows a file.
    var open: (ReviewFile) -> Void = { _ in }

    let head = NSStackView(v: [], spacing: 8)
    private let count = NSTextField.text("", size: 12, color: Palette.dim)
    private let search = NSSearchField()
    private var searchOpen = false
    private lazy var searchButton = IconButton("magnifyingglass", label: "Search files", tip: "Search files (⌘F)") { [weak self] in self?.toggleSearch() }
    private lazy var view = Segmented(["", ""], selected: 0, label: "File view") { [weak self] i in
        self?.desk?.view = i == 0 ? .tree : .list
        self?.changed()
    }
    private var repos = Segmented([], selected: 0, label: "Repository") { _ in }
    private var repoNames: [String] = []
    private let repoSlot = NSStackView(h: [], spacing: 0)
    private var chips: [FileGroup: SwitchChip] = [:]

    init(_ desk: ReviewDesk) {
        self.desk = desk
        super.init()
        for (i, (symbol, name)) in [("list.bullet.indent", "Tree view"), ("list.bullet", "List view")].enumerated() {
            view.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: name), forSegment: i)
            view.setToolTip(name, forSegment: i)
            view.setWidth(28, forSegment: i)
        }
        searchButton.keyEquivalent = "f"
        searchButton.keyEquivalentModifierMask = .command
        let top = NSStackView(h: [NSTextField.text("Files", size: 12.5, weight: .semibold), count, Spacer(), searchButton, view], spacing: 6)
        search.placeholderString = "Filter by name or path"
        search.delegate = self
        search.controlSize = .small
        search.font = .systemFont(ofSize: 12)
        search.setAccessibilityLabel("Filter files")
        search.isHidden = true
        let row = NSStackView(h: [], spacing: 4)
        row.distribution = .fillEqually
        for (g, color) in [(FileGroup.new, Palette.ok), (.changed, Palette.warn), (.deleted, Palette.bad)] {
            let c = SwitchChip(g.letter, g.word, color: color) { [weak self] in self?.flip(g) }
            chips[g] = c
            row.addArrangedSubview(c)
        }
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("Show files")
        head.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        [top, search, repoSlot, row].forEach { head.addFull($0) }
        update()
    }

    private func flip(_ g: FileGroup) {
        guard let desk else { return }
        if desk.filter.hidden.contains(g) { desk.filter.hidden.remove(g) } else { desk.filter.hidden.insert(g) }
        changed()
    }

    private func toggleSearch() {
        searchOpen.toggle()
        if !searchOpen, desk?.filter.query.isEmpty == false {
            desk?.filter.query = ""
            search.stringValue = ""
            changed()
        }
        update()
        if searchOpen { search.window?.makeFirstResponder(search) }
    }

    func controlTextDidChange(_ obj: Notification) {
        desk?.filter.query = search.stringValue
        changed()
    }

    /// Esc clears the text, then closes the field.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        guard sel == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if search.stringValue.isEmpty { toggleSearch() } else {
            search.stringValue = ""
            controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        }
        return true
    }

    /// The header values from the desk. The views stay.
    func update() {
        guard let desk else { return }
        if !desk.filter.query.isEmpty { searchOpen = true }
        let tree = desk.tree, shown = tree.shown.count, all = desk.files.count
        count.stringValue = shown == all ? "\(all) files" : "\(shown) of \(all)"
        search.isHidden = !searchOpen
        if search.stringValue != desk.filter.query { search.stringValue = desk.filter.query }
        searchButton.contentTintColor = searchOpen ? Palette.acc : Palette.mut
        searchButton.setAccessibilityExpanded(searchOpen)
        view.selectedSegment = desk.view == .tree ? 0 : 1

        let names = desk.summary.repos.map(\.name)
        if names != repoNames {
            repoNames = names
            repos = Segmented(["All"] + names, selected: 0, label: "Repository") { [weak self] i in
                guard let self else { return }
                self.desk?.filter.repo = i == 0 ? nil : self.repoNames[i - 1]
                self.changed()
            }
            repoSlot.arrangedSubviews.forEach { $0.removeFromSuperview() }
            repoSlot.addArrangedSubview(repos)
        }
        repoSlot.isHidden = names.count < 2
        for (i, n) in names.enumerated() { repos.setLabel("\(n) \(desk.files.filter { $0.repo == n }.count)", forSegment: i + 1) }
        repos.setLabel("All \(all)", forSegment: 0)
        repos.selectedSegment = desk.filter.repo.flatMap { names.firstIndex(of: $0) }.map { $0 + 1 } ?? 0

        var scoped = FileFilter()
        scoped.repo = desk.filter.repo
        let inScope = desk.files.filter(scoped.matches)
        for (g, c) in chips { c.set(on: !desk.filter.hidden.contains(g), count: inScope.filter { FileGroup($0.status) == g }.count) }
    }

    // MARK: Rows

    func body() -> NSView {
        let list = NSStackView(v: [], spacing: 1)
        list.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 8, right: 6)
        guard let desk else { return list }
        update()
        let rows = desk.tree.rows(desk.view)
        let answered = desk.answeredByFile
        for r in rows {
            switch r.kind {
            case .head:
                let t = NSTextField.text(r.name, size: 11.5, weight: .semibold, color: Palette.mut, mono: true)
                let s = NSStackView(h: [t, Spacer()])
                s.edgeInsets = NSEdgeInsets(top: 8, left: 6, bottom: 2, right: 6)
                list.addFull(s)
            case .repo, .folder: list.addFull(folderRow(r, desk: desk))
            case .file: list.addFull(fileRow(r, desk: desk, answered: answered[r.id] ?? 0))
            }
        }
        if rows.isEmpty, !desk.files.isEmpty {
            let clear = ActionButton("Clear the filters", style: .link) { [weak self] in
                self?.desk?.filter = FileFilter()
                self?.changed()
            }
            let note = NSStackView(v: [NSTextField.text("No files match.", size: 12.5, color: Palette.dim), clear], spacing: 4)
            note.alignment = .centerX
            note.edgeInsets = NSEdgeInsets(top: 24, left: 8, bottom: 8, right: 8)
            list.addFull(note)
        }
        if !desk.filter.searching { commits(desk, into: list) }
        return list
    }

    private func folderRow(_ r: FileTree.Row, desk: ReviewDesk) -> NSView {
        let toggle = { [weak self, weak desk] in
            guard let desk else { return }
            if desk.collapsed.contains(r.id) { desk.collapsed.remove(r.id) } else { desk.collapsed.insert(r.id) }
            self?.changed()
        }
        let repo = r.kind == .repo
        let name = NSTextField.text(r.name, size: repo ? 12 : 12.5, weight: repo ? .bold : .regular, color: repo ? Palette.fg : Palette.mut, mono: repo)
        name.lineBreakMode = .byTruncatingMiddle
        name.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        var views: [NSView] = [Glyph(r.open ? "chevron.down" : "chevron.right", color: Palette.dim, size: 9),
                               Glyph(repo ? "shippingbox" : "folder", color: repo ? Palette.acc : Palette.dim, size: 11.5), name, Spacer()]
        if r.pending > 0 { views += badge("text.bubble", r.pending, Palette.warn) }
        views.append(NSTextField.text("\(r.files)", size: 11, color: Palette.dim, mono: true))
        let label = "\(repo ? "Repo" : "Folder") \(r.name), \(r.files) files" + (r.pending > 0 ? ", \(r.pending) pending comments" : "")
            + (r.open ? ", open" : ", closed")
        let row = TreeRow(views, height: 26, inset: 6 + CGFloat(r.depth) * 14, label: label) { toggle() }
        row.stack.spacing = 5
        row.fold = (r.open, toggle)
        row.setAccessibilityExpanded(r.open)
        return row
    }

    private func fileRow(_ r: FileTree.Row, desk: ReviewDesk, answered: Int) -> NSView {
        guard let f = r.file else { return NSView() }
        let deleted = f.status == .deleted
        let letter = NSTextField.text(f.status.rawValue, size: 11, weight: .bold, color: ReviewChangesTab.color(f.status), mono: true)
        let name = NSTextField.text("", size: 12.5)
        name.attributedStringValue = NSAttributedString(string: desk.view == .list ? FileTree.base(f.path) : r.name, attributes: [
            .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: deleted ? Palette.mut : Palette.fg,
            .strikethroughStyle: deleted ? NSUnderlineStyle.single.rawValue : 0,
        ])
        name.lineBreakMode = .byTruncatingMiddle
        var title: NSView = name
        if desk.view == .list {
            let dir = ReviewChangesTab.split(f.path).dir
            title = NSStackView(v: [name] + (dir.isEmpty ? [] : [NSTextField.text(dir, size: 10.5, color: Palette.dim)]), spacing: 0)
        }
        title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        var views: [NSView] = [letter, title, Spacer()]
        if r.pending > 0 { views += badge("text.bubble", r.pending, Palette.warn) }
        if answered > 0 { views += badge("checkmark", answered, Palette.ok) }
        if f.viewed { views.append(Glyph("eye", color: Palette.dim, size: 10, label: "Viewed")) }
        views.append(NSTextField.text(f.binary ? "bin" : deleted ? "−\(f.removed)" : "+\(f.added) −\(f.removed)", size: 10.5, color: Palette.dim, mono: true))
        let label = "\(ReviewChangesTab.word(f.status)) \(f.path), \(f.added) added, \(f.removed) removed"
            + (r.pending > 0 ? ", \(r.pending) pending comments" : "") + (answered > 0 ? ", \(answered) answered" : "") + (f.viewed ? ", viewed" : "")
        let row = TreeRow(views, height: desk.view == .list ? 34 : 26, inset: desk.view == .list ? 6 : 8 + CGFloat(r.depth) * 14, label: label) { [weak self] in
            self?.open(f)
        }
        row.stack.spacing = 5
        row.selected = f.id == desk.file
        return row
    }

    private func badge(_ symbol: String, _ n: Int, _ color: NSColor) -> [NSView] {
        let s = NSStackView(h: [Glyph(symbol, color: color, size: 9.5), NSTextField.text("\(n)", size: 11, weight: .semibold, color: color)], spacing: 2)
        s.setContentCompressionResistancePriority(.required, for: .horizontal)
        return [s]
    }

    private func commits(_ desk: ReviewDesk, into list: NSStackView) {
        for r in desk.summary.repos where desk.filter.repo == nil || desk.filter.repo == r.name {
            guard let commits = r.commits, !commits.isEmpty else { continue }
            let t = NSTextField.text(desk.summary.repos.count > 1 ? "Commits · \(r.name)" : "Commits", size: 11, weight: .semibold, color: Palette.dim)
            let h = NSStackView(h: [t, Spacer()])
            h.edgeInsets = NSEdgeInsets(top: 12, left: 6, bottom: 2, right: 6)
            list.addFull(h)
            for c in commits.prefix(8) {
                let l = NSTextField.text("\(c.sha.prefix(7))  \(c.subject)", size: 11, color: Palette.mut, mono: true)
                l.lineBreakMode = .byTruncatingTail
                l.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                l.toolTip = c.subject
                let s = NSStackView(h: [l, Spacer()])
                s.edgeInsets = NSEdgeInsets(top: 1, left: 6, bottom: 1, right: 6)
                list.addFull(s)
            }
        }
    }
}
