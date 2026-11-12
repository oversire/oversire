import Cocoa
import OverSireCore

// ─── Changes › diff table ────────────────────────────────────────────────────
// The diff of one file in a table view that reuses its rows (OVERSIRE-439). A long file stays fast, and there is no line cap.
// The cells lay out by frame: the gutters and the mark keep a fixed width, and the row view draws the fill across the row.
// The table keeps the text selection, the line pick, the hover "+" and a cursor row for the keyboard.

/// The diff panel of one desk: the header and the table. It lives as long as the desk.
final class DiffPanel: NSView {
    let desk: ReviewDesk
    let threads: ReviewThreads
    let table: DiffTable
    var reload: () -> Void = {}
    /// Shows another file of the review.
    var open: (ReviewFile) -> Void = { _ in }
    private let head = NSView()
    let ruler = DiffRuler()
    private weak var counter: Chiplet?
    private var monitor: Any?
    private var tokens: (id: String, diff: FileDiff, tokens: [[SyntaxLanguage.Token]])?

    init(desk: ReviewDesk, threads: ReviewThreads) {
        self.desk = desk
        self.threads = threads
        table = DiffTable()
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let rule = Box(fill: Palette.line, border: nil, radius: 0)
        head.translatesAutoresizingMaskIntoConstraints = false
        table.scroll.translatesAutoresizingMaskIntoConstraints = false
        ruler.table = table
        ruler.onChange = { [weak self] c in self?.go(to: c) }
        table.onScroll = { [weak self] in self?.ruler.needsDisplay = true }
        table.onShow = { [weak self] in self?.ruler.refresh() }
        [head, rule, table.scroll, ruler].forEach(addSubview)
        NSLayoutConstraint.activate([
            head.leadingAnchor.constraint(equalTo: leadingAnchor), head.trailingAnchor.constraint(equalTo: trailingAnchor), head.topAnchor.constraint(equalTo: topAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor), rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: head.bottomAnchor), rule.heightAnchor.constraint(equalToConstant: 1),
            table.scroll.leadingAnchor.constraint(equalTo: leadingAnchor), table.scroll.trailingAnchor.constraint(equalTo: ruler.leadingAnchor),
            table.scroll.topAnchor.constraint(equalTo: rule.bottomAnchor), table.scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            ruler.trailingAnchor.constraint(equalTo: trailingAnchor), ruler.widthAnchor.constraint(equalToConstant: DiffRuler.width),
            ruler.topAnchor.constraint(equalTo: table.scroll.topAnchor), ruler.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        table.onPick = { [weak self] p, shift in self?.pick(p, shift: shift, reload: true) }
        table.onDragPick = { [weak self] p in self?.pick(p, shift: true, reload: false) }
        table.picked = { [weak self] p in
            guard let self, let f = self.table.file, let pick = self.desk.pick, pick.repo == f.repo, pick.path == f.path else { return false }
            return pick.contains(p.line, side: p.side)
        }
        table.dragEnded = { [weak self] in self?.reload() }
        table.onWay = { [weak self] g, way in self?.expand(g, way) }
    }

    /// Opens lines of a gap. The line next to the gap keeps its place on the screen.
    func expand(_ g: DiffGap, _ way: DiffWay) {
        guard let f = table.file, let anchor = desk.expand(f, g, way) else { return }
        table.keep(anchor: anchor) { reload() }
    }
    required init?(coder: NSCoder) { fatalError() }

    // The panel moves between the page and the large view, so the monitor follows its window.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let w = self.window, e.window === w else { return e }
            let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard let key = DiffKey(key: e.keyCode, shift: mods.contains(.shift), option: mods.contains(.option),
                                    command: mods.contains(.command), control: mods.contains(.control), inText: w.firstResponder is NSTextView) else { return e }
            return self.handle(key) ? nil : e
        }
    }

    /// Does the action of a key. False when the key is not for the panel.
    func handle(_ key: DiffKey) -> Bool {
        switch key {
        case .size: toggleSize()
        case .files: showFiles()
        case .filePanel:
            guard desk.maximized else { return false }
            toggleFiles()
        case .nextFile, .previousFile: step(key == .nextFile ? 1 : -1)
        case .close:
            guard desk.maximized else { return false }
            toggleSize()
        case .nextChange, .previousChange: stepChange(key == .nextChange ? 1 : -1)
        case .viewedNext: viewedNext()
        }
        return true
    }

    /// Marks the file as viewed and opens the next file that is not viewed (OVERSIRE-447).
    func viewedNext() {
        guard let id = desk.file, let f = desk.files.first(where: { $0.id == id }) else { return NSSound.beep() }
        let next = desk.nextUnviewed(after: id)?.id
        Task { @MainActor [weak self] in
            guard let self else { return }
            if !f.viewed, !(await self.desk.setViewed(f, true)) { return }
            if let next, let n = self.desk.files.first(where: { $0.id == next }) { return self.open(n) }
            self.reload()
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: "All files are viewed.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
    }

    /// Goes to the next or the previous change (OVERSIRE-442). Past the last change of a file it opens the next file.
    func stepChange(_ k: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch await self.desk.step(k) {
            case .change: self.reload()
            case .file(let id, _): if let f = self.desk.files.first(where: { $0.id == id }) { self.open(f) }
            case .end(let at): self.atEnd(at)
            }
        }
    }

    /// A click on a mark of the ruler.
    func go(to change: Int) {
        desk.change = change
        reload()
    }

    private func atEnd(_ at: DiffLanding) {
        let text = "This is the \(at == .last ? "last" : "first") change of the review."
        NSSound.beep()
        counter?.flash(at == .last ? "Last change" : "First change")
        NSAccessibility.post(element: counter ?? self, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    func toggleSize() {
        desk.maximized.toggle()
        reload()
    }

    /// Shows or hides the file panel of the large view.
    func toggleFiles() {
        desk.maxFiles.toggle()
        reload()
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: desk.maxFiles ? "File panel shown." : "File panel hidden.", .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The files in the order of the file panel.
    var steps: DiffSteps { DiffSteps(files: desk.tree.steps(desk.view).map(\.id)) }

    /// Opens the file `k` steps away. Beeps at the two ends.
    func step(_ k: Int) {
        guard let id = desk.file, let next = steps.file(id, by: k), let f = desk.files.first(where: { $0.id == next }) else { return NSSound.beep() }
        open(f)
    }

    private weak var pathView: NSView?

    func showFiles() {
        guard let v = pathView ?? head.subviews.first, v.window != nil else { return }
        DiffFileSwitch.show(desk, from: v) { [weak self] f in self?.open(f) }
    }

    private func pick(_ p: DiffPlace, shift: Bool, reload again: Bool) {
        guard let f = table.file else { return }
        if let old = desk.pick, old.repo == f.repo, old.path == f.path {
            desk.pick = old.click(p.line, side: p.side, shift: shift)
        } else {
            desk.pick = LinePick(repo: f.repo, path: f.path, side: p.side, line: p.line)
        }
        desk.block = nil
        if again { reload() } else { table.refresh() }
    }

    /// Shows the file. The table keeps its scroll position while the file stays the same.
    func update(_ f: ReviewFile, diff: FileDiff?) {
        let changes = diff.map { desk.fold(f) ?? DiffFold($0) }?.changes.count ?? 0
        setHeader(f, full: diff?.full == true, changes: diff == nil ? nil : changes)
        table.change = desk.file == f.id ? desk.change : nil
        var notes: [String] = []
        if f.untracked == true { notes.append("This file is not committed. The agent did not commit it.") }
        guard let diff else {
            notes.append(desk.error.map { "The diff did not load: \($0)" } ?? "Loading the diff…")
            return table.show(DiffFold(FileDiff(repo: f.repo, path: f.path, status: f.status, hunks: [])), items: notes.map(DiffItem.note), tokens: [], desk: desk, file: f)
        }
        let fold = desk.fold(f) ?? DiffFold(diff)
        if diff.binary || f.binary {
            notes.append("Binary file. OverSire does not show a binary diff.")
            return table.show(fold, items: notes.map(DiffItem.note), tokens: [], desk: desk, file: f)
        }
        if diff.hunks.isEmpty { notes.append("No line changes.") }
        let notesOfFile = desk.comments(in: f)
        let marks = ReviewChangesTab.marks(notesOfFile)
        var places = Set(notesOfFile.compactMap { c -> DiffPlace? in
            guard case .code(_, _, let line, _, let side) = c.anchor else { return nil }
            return DiffPlace(side: side ?? .new, line: line)
        })
        if let pick = desk.pick, pick.repo == f.repo, pick.path == f.path { places.insert(DiffPlace(side: pick.side, line: pick.to)) }
        var items = notes.map(DiffItem.note) + fold.items(split: desk.split, threads: places)
        if diff.truncated { items.append(.note("The diff is long. OverSire shows the first lines only. Open the file in your editor for the rest.")) }
        table.marks = marks
        table.threadView = { [weak self] p in self?.thread(p, file: f, notes: notesOfFile) }
        table.show(fold, items: items, tokens: tokens(f, diff), desk: desk, file: f, threads: threads.hash)
        let at = table.change.map { "\(f.id)#\($0)" }
        if at != table.scrolledTo {
            table.scrolledTo = at
            if let c = table.change { DispatchQueue.main.async { [weak table] in table?.scroll(toChange: c) } }
        }
    }

    /// The syntax colors of each line of the fold, kept while the diff stays the same.
    private func tokens(_ f: ReviewFile, _ d: FileDiff) -> [[SyntaxLanguage.Token]] {
        if let t = tokens, t.id == f.id, t.diff == d { return t.tokens }
        let out: [[SyntaxLanguage.Token]] = SyntaxLanguage.of(f.path).map { l in d.hunks.flatMap { l.tokens(of: $0.lines) } } ?? []
        tokens = (f.id, d, out)
        return out
    }

    /// The threads and the composer after a line.
    private func thread(_ p: DiffPlace, file f: ReviewFile, notes: [ReviewComment]) -> NSView? {
        let here = notes.filter {
            guard case .code(_, _, let line, _, let side) = $0.anchor else { return false }
            return line == p.line && (side ?? .new) == p.side
        }
        var parts: [NSView] = []
        if !here.isEmpty { parts.append(threads.thread(here)) }
        if let pick = desk.pick, pick.repo == f.repo, pick.path == f.path, pick.side == p.side, pick.to == p.line {
            parts.append(threads.composer(pick.anchor, label: pick.label))
        }
        guard !parts.isEmpty else { return nil }
        let s = NSStackView(v: parts, spacing: 6)
        s.edgeInsets = NSEdgeInsets(top: 6, left: 40, bottom: 8, right: 12)
        return s
    }

    private func setHeader(_ f: ReviewFile, full: Bool, changes: Int?) {
        let path = f.oldPath.map { "\($0) → \(f.path)" } ?? f.path
        let pathField = PathHead(path, path: f.path, absolute: desk.absolutePath(f), open: { [weak self] in self?.showFiles() })
        pathView = pathField
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let mode = Segmented(["Unified", "Split"], selected: desk.split ? 1 : 0, label: "Diff view") { [weak self] i in
            self?.desk.split = i == 1
            self?.reload()
        }
        let wrap = ToggleChip("Wrap", on: desk.wrap, icon: desk.wrap ? nil : Glyph("arrow.turn.down.left", color: Palette.mut, size: 10)) { [weak self] in
            self?.desk.wrap.toggle()
            self?.reload()
        }
        wrap.setAccessibilityLabel("Wrap long lines")
        wrap.toolTip = desk.wrap ? "Long lines wrap. Click to keep each line on one row." : "Long lines scroll. Click to wrap them."
        let whole = ToggleChip("Full file", on: desk.wholeFile && full, enabled: full) { [weak self] in
            self?.desk.wholeFile.toggle()
            self?.reload()
        }
        whole.setAccessibilityLabel("Show the full file")
        whole.toolTip = full ? (desk.wholeFile ? "The diff shows all lines. Click to fold the unchanged lines." : "Show all lines of the file.")
            : "Update oversire on \(desk.summary.machine) to see the full file."
        let desk = desk
        let viewed = CheckBox("Viewed", on: f.viewed, label: "Mark \(f.path) as viewed") { on in Task { _ = await desk.setViewed(f, on) } }
        [wrap, whole, viewed].forEach { $0.setContentCompressionResistancePriority(.required, for: .horizontal) }
        var parts: [NSView] = [NSTextField.text(f.status.rawValue, size: 11, weight: .bold, color: ReviewChangesTab.color(f.status), mono: true), pathField, Spacer()]
        // The large view without the file panel has room for the file position, the pending count and long words.
        // With the panel, the tree shows them, so the path keeps its room.
        let wide = desk.maximized && !desk.maxFiles
        if f.isStale {
            let tag = Chiplet(wide ? "Changed since viewed" : "", symbol: "arrow.clockwise", color: Palette.warn)
            tag.setAccessibilityLabel("This file changed after you marked it as viewed")
            tag.toolTip = "The file changed after you marked it as viewed."
            parts.append(tag)
        }
        // The normal view is narrow. The file row shows the pending count there.
        if wide, let n = desk.pendingByFile[f.id] {
            let chip = Chiplet("\(n) pending", symbol: "text.bubble", color: Palette.warn)
            chip.setAccessibilityLabel("\(n) pending comment\(n == 1 ? "" : "s") in this file")
            parts.append(chip)
        }
        if wide {
            let order = steps.files
            let at = order.firstIndex(of: f.id)
            let back = IconButton("chevron.left", label: "Previous file", tip: "Previous file ⌥⇧↑") { [weak self] in self?.step(-1) }
            let next = IconButton("chevron.right", label: "Next file", tip: "Next file ⌥⇧↓") { [weak self] in self?.step(1) }
            back.isEnabled = (at ?? 0) > 0
            next.isEnabled = at.map { $0 < order.count - 1 } ?? false
            let count = NSTextField.text(at.map { "\($0 + 1) / \(order.count)" } ?? "– / \(order.count)", size: 11, color: Palette.mut, mono: true)
            count.setContentCompressionResistancePriority(.required, for: .horizontal)
            count.setAccessibilityLabel(at.map { "File \($0 + 1) of \(order.count)" } ?? "\(order.count) files")
            parts.insert(back, at: 0)
            parts.insert(contentsOf: [count, next], at: 3)
        }
        if desk.maximized {
            let shown = desk.maxFiles
            let side = IconButton("sidebar.left", label: shown ? "Hide the file panel" : "Show the file panel",
                                  tip: (shown ? "Hide files" : "Show files") + " ⌃⌘S") { [weak self] in self?.toggleFiles() }
            side.contentTintColor = shown ? Palette.acc : Palette.mut
            side.setAccessibilityExpanded(shown)
            parts.insert(side, at: 0)
        }
        if let n = changes {
            let up = IconButton("chevron.up", label: "Previous change", tip: "Previous change ⌥↑") { [weak self] in self?.stepChange(-1) }
            let down = IconButton("chevron.down", label: "Next change", tip: "Next change ⌥↓") { [weak self] in self?.stepChange(1) }
            let c = desk.change.flatMap { $0 < n ? $0 : nil }
            // A narrow header shows the count only.
            let word = wide ? (n == 0 ? "No changes" : "\(n) change\(n == 1 ? "" : "s")") : "\(n)"
            let chip = Chiplet(c.map { "\($0 + 1) / \(n)" } ?? word, mono: c != nil || !wide)
            chip.toolTip = "\(n) change\(n == 1 ? "" : "s") in this file"
            chip.setAccessibilityLabel(c.map { "Change \($0 + 1) of \(n)" } ?? (n == 0 ? "No changes in this file" : "\(n) change\(n == 1 ? "" : "s") in this file"))
            [up, chip, down].forEach { $0.setContentCompressionResistancePriority(.required, for: .horizontal) }
            counter = chip
            parts += [up, chip, down]
        }
        let size = desk.maximized
            ? IconButton("arrow.down.right.and.arrow.up.left", label: "Restore", tip: "Restore ⇧⌘M") { [weak self] in self?.toggleSize() }
            : IconButton("arrow.up.left.and.arrow.down.right", label: "Maximize", tip: "Maximize ⇧⌘M") { [weak self] in self?.toggleSize() }
        var tail: [NSView] = [wrap, whole, mode, viewed]
        if desk.maximized {
            if desk.allViewed {
                let done = Chiplet("All viewed", symbol: "checkmark.circle", color: Palette.ok)
                done.setAccessibilityLabel("All files are viewed")
                tail.append(done)
            } else {
                let to = desk.nextUnviewed(after: f.id).map { FileTree.base($0.path) }
                let next = ActionButton("Next", symbol: "checkmark", style: .primary) { [weak self] in self?.viewedNext() }
                next.toolTip = "Mark as viewed" + (to.map { " and open \($0)" } ?? "") + " ⌥V"
                next.setAccessibilityLabel("Mark \(f.path) as viewed" + (to.map { " and open \($0)" } ?? ""))
                tail.append(next)
            }
            tail.last?.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let row = NSStackView(h: parts + tail + [size], spacing: 8)
        row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        head.subviews.forEach { $0.removeFromSuperview() }
        head.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: head.leadingAnchor), row.trailingAnchor.constraint(equalTo: head.trailingAnchor),
            row.topAnchor.constraint(equalTo: head.topAnchor), row.bottomAnchor.constraint(equalTo: head.bottomAnchor),
        ])
    }
}

/// The rows of one diff: the data source, the delegate, the sizes and the hover.
final class DiffTable: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let scroll: NSScrollView = NSScrollView()
    let view = DiffTableView()
    private let column = NSTableColumn(identifier: .init("diff"))
    private(set) var fold = DiffFold(FileDiff(repo: "", path: "", status: .modified, hunks: []))
    private(set) var items: [DiffItem] = []
    private(set) var tokens: [[SyntaxLanguage.Token]] = []
    private(set) var file: ReviewFile?
    private(set) var wrap = false
    private(set) var split = false
    var marks: [DiffPlace: DiffGutter.Mark] = [:]
    var threadView: (DiffPlace) -> NSView? = { _ in nil }
    var onPick: (DiffPlace, Bool) -> Void = { _, _ in }
    var onDragPick: (DiffPlace) -> Void = { _ in }
    var dragEnded: () -> Void = {}
    var picked: (DiffPlace) -> Bool = { _ in false }
    private var threadCells: [DiffPlace: ThreadCell] = [:]
    private var threadHash: AnyHashable?
    private var heights: [Int: CGFloat] = [:]
    private var heightWidth: CGFloat = 0
    private var clipWidth: CGFloat = 0
    private var contentWidth: CGFloat = 0
    private var scrolled: NSObjectProtocol?
    private var framed: NSObjectProtocol?
    private(set) var hovered: (row: Int, column: Int)?
    /// A fold button: open lines of a gap.
    var onWay: (DiffGap, DiffWay) -> Void = { _, _ in }
    /// The machine of the review, for the hint of an older daemon.
    private var machine = ""
    /// The current change: its rows get a bar (OVERSIRE-442).
    var change: Int?
    /// The file and change that the table last scrolled to.
    var scrolledTo: String?
    private(set) var changeMarks: [DiffMark] = []
    var onScroll: () -> Void = {}
    var onShow: () -> Void = {}

    /// The longest text that a line shows with no wrap. A very long line (minified code) would make a huge view.
    static let nowrapLimit = 1000
    static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let gutterFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    /// The row of one line with no wrap.
    static let lineHeight: CGFloat = 18
    static let gapHeight: CGFloat = 24
    static let markWidth: CGFloat = 16
    static let lead: CGFloat = 2
    static let trail: CGFloat = 8

    static func gutterWidth(digits: Int) -> CGFloat {
        let digit = ("0" as NSString).size(withAttributes: [.font: gutterFont]).width
        return ceil(CGFloat(digits) * digit) + 10
    }

    override init() {
        super.init()
        view.owner = self
        view.addTableColumn(column)
        view.headerView = nil
        view.intercellSpacing = .zero
        view.selectionHighlightStyle = .none
        view.backgroundColor = Palette.panel
        view.usesAutomaticRowHeights = false
        view.columnAutoresizingStyle = .noColumnAutoresizing
        view.allowsColumnResizing = false
        view.gridStyleMask = []
        if #available(macOS 11.0, *) { view.style = .plain }
        view.dataSource = self
        view.delegate = self
        view.setAccessibilityLabel("Diff")
        scroll.documentView = view
        scroll.drawsBackground = true
        scroll.backgroundColor = Palette.panel
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.contentView.postsFrameChangedNotifications = true
        scrolled = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.followMouse()
            self?.placeThreads()
            self?.onScroll()
        }
        framed = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
            self?.fit()
            self?.onShow()
        }
    }

    deinit { [scrolled, framed].compactMap { $0 }.forEach(NotificationCenter.default.removeObserver) }

    /// Shows the rows. The same file keeps its scroll position.
    func show(_ fold: DiffFold, items: [DiffItem], tokens: [[SyntaxLanguage.Token]], desk: ReviewDesk, file: ReviewFile, threads hash: AnyHashable? = nil) {
        let same = file.id == self.file?.id
        // Before the data changes: each setter calls refresh(), and the table still has the old rows.
        if !same { view.selection = nil; view.cursor = nil }
        self.fold = fold
        self.items = items
        self.tokens = tokens
        self.file = file
        wrap = desk.wrap
        split = desk.split
        machine = desk.summary.machine
        if !same || hash != threadHash { threadCells = [:] }
        threadHash = hash
        heights = [:]
        contentWidth = longest()
        scroll.hasHorizontalScroller = !wrap && !split
        hovered = nil
        fit(force: true)
        view.reloadData()
        if !same { scroll.contentView.scroll(to: .zero); scroll.reflectScrolledClipView(scroll.contentView) }
        changeMarks = fold.marks(items)
        onShow()
        DispatchQueue.main.async { [weak self] in self?.followMouse(); self?.onShow() }
    }

    /// The rect of the rows of a change, in the table.
    func rect(ofChange c: Int) -> NSRect? {
        guard let m = changeMarks.first(where: { $0.change == c }) else { return nil }
        return view.rect(ofRow: m.rows.lowerBound).union(view.rect(ofRow: m.rows.upperBound - 1))
    }

    /// Scrolls the change to a third of the height.
    func scroll(toChange c: Int) {
        guard let r = rect(ofChange: c) else { return }
        let clip = scroll.contentView
        let top = max(0, min(r.minY - clip.bounds.height / 3, view.frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scroll.reflectScrolledClipView(clip)
    }

    /// The change of the lines in a row.
    func change(ofRow r: Int) -> Int? {
        switch items[r] {
        case .line(let i): return fold.change(at: i)
        case .pair(let o, let n): return [o, n].compactMap { $0 }.lazy.compactMap(fold.change(at:)).first
        default: return nil
        }
    }

    /// The row of the line with the new-side number `line`.
    func row(new line: Int) -> Int? {
        items.firstIndex {
            switch $0 {
            case .line(let i): return fold.lines[i].new == line
            case .pair(_, let n?): return fold.lines[n].new == line
            default: return false
            }
        }
    }

    /// Shows new rows and keeps the line `anchor` at its place on the screen.
    func keep(anchor: Int, _ change: () -> Void) {
        let y = row(new: anchor).map { view.rect(ofRow: $0).minY - scroll.contentView.bounds.minY }
        change()
        guard let y, let r = row(new: anchor) else { return }
        let clip = scroll.contentView
        let top = max(0, min(view.rect(ofRow: r).minY - y, view.frame.height - clip.bounds.height))
        clip.scroll(to: NSPoint(x: clip.bounds.minX, y: top))
        scroll.reflectScrolledClipView(clip)
    }

    /// Draws the rows again with no new data: a new pick or a new selection.
    func refresh() {
        let rows = view.rows(in: view.visibleRect)
        let end = min(NSMaxRange(rows), items.count)
        guard rows.location < end else { return }
        for r in rows.location..<end { configure(row: r) }
    }

    private func configure(row r: Int) {
        if let rv = view.rowView(atRow: r, makeIfNecessary: false) as? DiffRowView { style(rv, row: r) }
        if let c = view.view(atColumn: 0, row: r, makeIfNecessary: false) as? DiffLineCell { c.set(self, row: r) }
    }

    // MARK: Sizes

    var digits: Int { fold.digits }
    var gutter: CGFloat { Self.gutterWidth(digits: digits) }
    /// The x of the text of a unified row.
    var textX: CGFloat { Self.lead + 2 * gutter + Self.markWidth }

    /// The width of the longest line, for a unified diff that scrolls.
    private func longest() -> CGFloat {
        guard !wrap, !split, !fold.lines.isEmpty else { return 0 }
        let guess = fold.lines.indices.map { i -> (Int, Int) in
            let t = fold.lines[i].text
            return (i, min(t.utf16.count, Self.nowrapLimit) + t.filter { $0 == "\t" }.count * 3)
        }.sorted { $0.1 > $1.1 }.prefix(5)
        let w = guess.map { i, _ in shown(fold.lines[i]).size(withAttributes: [.font: Self.font]).width }.max() ?? 0
        return ceil(w) + 8
    }

    /// Sets the column width: the visible width, or the longest line when the diff scrolls.
    func fit(force: Bool = false) {
        let clip = scroll.contentView.bounds.width
        guard clip > 0 else { return }
        let w = max(clip, !wrap && !split ? textX + contentWidth + Self.trail : clip)
        guard force || abs(column.width - w) > 0.5 || abs(clipWidth - clip) > 0.5 else { return }
        column.width = w
        column.minWidth = w
        column.maxWidth = w
        // A thread row measures at the visible width, a wrapped line at the column width.
        if abs(heightWidth - w) > 0.5 || abs(clipWidth - clip) > 0.5, !heights.isEmpty {
            heights = [:]
            view.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
        }
        heightWidth = w
        clipWidth = clip
        placeThreads()
    }

    /// The text that a line shows: a space for an empty line, and a short form of a very long line with no wrap.
    func shown(_ l: DiffLine) -> String {
        var s = l.text.isEmpty ? " " : l.text
        if !wrap, s.utf16.count > Self.nowrapLimit { s = String(s.prefix(Self.nowrapLimit)) + " …" }
        return s
    }

    func styled(_ i: Int) -> NSAttributedString {
        SyntaxLanguage.styled(shown(fold.lines[i]), tokens: i < tokens.count ? tokens[i] : [], font: Self.font, wraps: wrap)
    }

    /// The text width of each half of a split row, or of a unified row.
    func textWidth(_ width: CGFloat) -> CGFloat {
        split ? (width - 1) / 2 - (Self.lead + gutter + Self.markWidth) - Self.trail : width - textX - Self.trail
    }

    private func textHeight(_ i: Int?, width: CGFloat) -> CGFloat {
        guard let i else { return Self.lineHeight }
        let r = styled(i).boundingRect(with: NSSize(width: max(20, width - 4), height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin])
        return max(Self.lineHeight, ceil(r.height) + 3)
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        if let h = heights[row] { return h }
        let width = max(column.width, 100)
        let h: CGFloat
        switch items[row] {
        case .line(let i): h = wrap ? textHeight(i, width: textWidth(width)) : Self.lineHeight
        case .pair(let o, let n): h = wrap ? max(textHeight(o, width: textWidth(width)), textHeight(n, width: textWidth(width))) : Self.lineHeight
        case .gap: h = Self.gapHeight
        case .note(let s): h = ceil((s as NSString).boundingRect(with: NSSize(width: max(100, visibleWidth - 24), height: 1000), options: [.usesLineFragmentOrigin],
                                                                attributes: [.font: NSFont.systemFont(ofSize: 12)]).height) + 20
        case .thread(let p): h = thread(p)?.measure(visibleWidth) ?? 1
        }
        heights[row] = h
        return h
    }

    var visibleWidth: CGFloat { max(200, scroll.contentView.bounds.width) }

    // MARK: Rows

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let rv = (tableView.makeView(withIdentifier: DiffRowView.id, owner: nil) as? DiffRowView) ?? DiffRowView()
        rv.identifier = DiffRowView.id
        style(rv, row: row)
        return rv
    }

    private func style(_ rv: DiffRowView, row: Int) {
        var kinds: (DiffLine.Kind?, DiffLine.Kind?) = (nil, nil), picks = (false, false), empty = (false, false)
        switch items[row] {
        case .line(let i):
            kinds.0 = fold.lines[i].kind
            picks.0 = DiffFold.place(fold.lines[i]).map(picked) ?? false
        case .pair(let o, let n):
            kinds = (o.map { fold.lines[$0].kind }, n.map { fold.lines[$0].kind })
            picks = (o.flatMap { DiffFold.place(fold.lines[$0]) }.map(picked) ?? false, n.flatMap { DiffFold.place(fold.lines[$0]) }.map(picked) ?? false)
            empty = (o == nil, n == nil)
            // A context line is one value on both sides.
            if o == n { picks.1 = picks.0 }
        case .gap: rv.gap = true
        default: break
        }
        if case .gap = items[row] {} else { rv.gap = false }
        rv.split = split
        rv.half = split ? (column.width - 1) / 2 : column.width
        rv.kinds = kinds
        rv.picks = picks
        rv.empty = empty
        rv.cursor = view.cursor == row && view.window?.firstResponder === view
        rv.current = change != nil && change(ofRow: row) == change
        rv.needsDisplay = true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        switch items[row] {
        case .line, .pair:
            let c = (tableView.makeView(withIdentifier: DiffLineCell.id, owner: nil) as? DiffLineCell) ?? DiffLineCell()
            c.set(self, row: row)
            return c
        case .gap(let g):
            let c = (tableView.makeView(withIdentifier: DiffFoldCell.id, owner: nil) as? DiffFoldCell) ?? DiffFoldCell()
            c.set(g, machine: fold.full ? nil : machine) { [weak self] way in self?.onWay(g, way) }
            return c
        case .note(let s):
            let c = (tableView.makeView(withIdentifier: DiffNoteCell.id, owner: nil) as? DiffNoteCell) ?? DiffNoteCell()
            c.set(s)
            return c
        case .thread(let p):
            let c = thread(p)
            c?.offset = scroll.contentView.bounds.minX
            c?.width = visibleWidth
            return c
        }
    }

    /// The cached thread row of a line. The composer keeps its view while the threads stay the same.
    private func thread(_ p: DiffPlace) -> ThreadCell? {
        if let c = threadCells[p] { return c }
        guard let v = threadView(p) else { return nil }
        let c = ThreadCell(v)
        threadCells[p] = c
        return c
    }

    /// A thread row and a fold row keep the visible width and stay in sight when a long line scrolls sideways.
    private func placeThreads() {
        let x = scroll.contentView.bounds.minX, w = visibleWidth
        for c in threadCells.values where c.superview != nil {
            c.offset = x
            c.width = w
            c.needsLayout = true
        }
        let rows = view.rows(in: view.visibleRect)
        for r in rows.location..<NSMaxRange(rows) {
            (view.view(atColumn: 0, row: r, makeIfNecessary: false) as? DiffFoldCell)?.needsLayout = true
        }
    }

    // MARK: Reveal

    /// Scrolls to the thread of a comment and flashes it. False when no row has it.
    @discardableResult
    func reveal(_ id: String) -> Bool {
        for (row, item) in items.enumerated() {
            guard case .thread(let p) = item, let c = thread(p), let v = c.content.descendant({ $0.identifier?.rawValue == id }) else { continue }
            view.scrollRowToVisible(row)
            let r = view.rect(ofRow: row)
            view.scrollToVisible(r.insetBy(dx: 0, dy: -40))
            DispatchQueue.main.async { v.flash() }
            return true
        }
        return false
    }

    // MARK: Hover

    /// The place of the line in a row and column. The split right half is column 1.
    func place(row: Int, column c: Int) -> DiffPlace? {
        guard row >= 0, row < items.count else { return nil }
        switch items[row] {
        case .line(let i): return DiffFold.place(fold.lines[i])
        case .pair(let o, let n): return (c == 0 ? o : n).flatMap { DiffFold.place(fold.lines[$0]) }
        default: return nil
        }
    }

    func column(at x: CGFloat) -> Int { split && x > (column.width - 1) / 2 ? 1 : 0 }

    /// Shows the "+" of the line under the mouse.
    func hover(at p: NSPoint?) {
        var next: (row: Int, column: Int)?
        if let p, view.visibleRect.contains(p) {
            let r = view.row(at: p)
            if r >= 0, place(row: r, column: column(at: p.x)) != nil { next = (r, column(at: p.x)) }
        }
        guard next?.row != hovered?.row || next?.column != hovered?.column else { return }
        let old = hovered
        hovered = next
        for r in [old?.row, next?.row].compactMap({ $0 }) {
            (view.view(atColumn: 0, row: r, makeIfNecessary: false) as? DiffLineCell)?.set(self, row: r)
        }
    }

    /// A scroll moves the rows under a still mouse, so find the row again (OVERSIRE-392).
    private func followMouse() {
        guard let w = view.window, w.isKeyWindow else { return hover(at: nil) }
        hover(at: view.convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }

    /// For `--uishots`: the hover look with no mouse, on the first line row in sight.
    func showPlus() {
        let rows = view.rows(in: view.visibleRect)
        for r in rows.location..<NSMaxRange(rows) where place(row: r, column: 0) != nil {
            hovered = (r, 0)
            configure(row: r)
            return
        }
    }
}

/// The table view of a diff. It owns the text selection and the cursor row.
final class DiffTableView: NSTableView {
    weak var owner: DiffTable?
    var selection: DiffSelection? { didSet { if oldValue != selection { owner?.refresh() } } }
    /// The row of the keyboard: ↑ and ↓ move it. Return or Space picks its line.
    var cursor: Int? { didSet { if oldValue != cursor { owner?.refresh() } } }
    private var tracking: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { DispatchQueue.main.async { self.owner?.refresh() }; return true }
    override func resignFirstResponder() -> Bool { DispatchQueue.main.async { self.owner?.refresh() }; return true }
    // The comment field in a thread row takes the focus.
    override func validateProposedFirstResponder(_ responder: NSResponder, for event: NSEvent?) -> Bool { true }

    // MARK: Selection

    /// The full-line offset of a point in a text. The end of a short form gives the end of the full line.
    private func offset(_ t: DiffText, _ p: NSPoint) -> Int {
        let at = t.index(at: t.convert(p, from: nil))
        let full = (t.code as NSString).length
        return t.stringValue != t.code && at >= t.length - 2 ? full : min(at, max(full, 0))
    }

    /// A click starts a selection, a drag extends it, Shift-click extends the last one.
    /// A double-click picks a word, a triple-click the line.
    func track(from t: DiffText, _ event: NSEvent) {
        window?.makeFirstResponder(self)
        let at = offset(t, event.locationInWindow)
        if event.clickCount >= 2 {
            let r = event.clickCount == 2 ? t.word(at: min(at, t.length)) : NSRange(location: 0, length: (t.code as NSString).length)
            selection = DiffSelection(column: t.column, from: .init(row: t.row, offset: r.location), to: .init(row: t.row, offset: NSMaxRange(r)))
            return
        }
        let end = DiffSelection.End(row: t.row, offset: at)
        if event.modifierFlags.contains(.shift), var s = selection, s.column == t.column {
            s.to = end
            selection = s
        } else {
            selection = DiffSelection(column: t.column, from: end, to: end)
        }
        drag { [weak self] p in
            guard let self, var s = self.selection, let e = self.end(at: p, column: s.column) else { return }
            s.to = e
            self.selection = s
        }
    }

    /// Runs `step` for each drag point until the mouse goes up, and scrolls at the edge.
    func drag(_ step: (NSPoint) -> Void) {
        NSEvent.startPeriodicEvents(afterDelay: 0.1, withPeriod: 0.05)
        defer { NSEvent.stopPeriodicEvents() }
        while let e = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp, .periodic]) {
            if e.type == .leftMouseUp { break }
            guard let w = window else { break }
            let p = w.mouseLocationOutsideOfEventStream
            if e.type == .periodic, let d = NSEvent.mouseEvent(with: .leftMouseDragged, location: p, modifierFlags: [], timestamp: e.timestamp,
                                                               windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
                autoscroll(with: d)
            }
            step(convert(p, from: nil))
        }
    }

    /// The selection end at a point of the table. A point between lines takes the start of the next line.
    private func end(at p: NSPoint, column: Int) -> DiffSelection.End? {
        guard let owner, !owner.items.isEmpty else { return nil }
        let row = self.row(at: p)
        guard row >= 0 else { return p.y < 0 ? .init(row: 0, offset: 0) : .init(row: owner.items.count - 1, offset: Int.max / 2) }
        if let c = view(atColumn: 0, row: row, makeIfNecessary: false) as? DiffLineCell, let t = c.text(column), !t.isHidden {
            return .init(row: row, offset: offset(t, convert(p, to: nil)))
        }
        return .init(row: row, offset: 0)
    }

    /// For `--uishots`: a selection with no mouse.
    func show(from: (row: Int, at: Int), to: (row: Int, at: Int)) {
        selection = DiffSelection(column: 0, from: .init(row: from.row, offset: from.at), to: .init(row: to.row, offset: to.at))
        window?.makeFirstResponder(self)
    }

    var selected: String? {
        guard let owner, let s = selection, !s.isEmpty else { return nil }
        let text = s.text(owner.fold, owner.items)
        return text.isEmpty ? nil : text
    }

    @objc func copy(_ sender: Any?) {
        guard let s = selected else { return NSSound.beep() }
        RowActions.copy(s)
    }

    @objc override func selectAll(_ sender: Any?) {
        guard let owner, !owner.items.isEmpty else { return }
        let c = selection?.column ?? (owner.split ? 1 : 0)
        selection = DiffSelection(column: c, from: .init(row: 0, offset: 0), to: .init(row: owner.items.count - 1, offset: Int.max / 2))
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        guard let owner else { return super.keyDown(with: event) }
        let mods = event.modifierFlags.intersection([.command, .option, .control])
        switch event.keyCode {
        case 125, 126 where mods.isEmpty:
            let down = event.keyCode == 125
            var r = (cursor ?? (down ? -1 : owner.items.count)) + (down ? 1 : -1)
            // The cursor stops on lines and on folds with buttons.
            func stops(_ r: Int) -> Bool {
                if case .gap(let g) = owner.items[r] { return !g.ways.isEmpty }
                return owner.place(row: r, column: owner.split ? 1 : 0) != nil || owner.place(row: r, column: 0) != nil
            }
            while r >= 0, r < owner.items.count, !stops(r) { r += down ? 1 : -1 }
            guard r >= 0, r < owner.items.count else { return NSSound.beep() }
            cursor = r
            scrollRowToVisible(r)
        case 36, 76, 49 where mods.isEmpty:
            if let r = cursor, owner.items.indices.contains(r), case .gap(let g) = owner.items[r], let way = g.ways.first {
                return owner.onWay(g, way)
            }
            guard let r = cursor, let p = owner.place(row: r, column: owner.split ? 1 : 0) ?? owner.place(row: r, column: 0) else { return super.keyDown(with: event) }
            owner.onPick(p, event.modifierFlags.contains(.shift))
        case 53 where selection != nil:
            selection = nil
        default: super.keyDown(with: event)
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(t)
        tracking = t
        super.updateTrackingAreas()
    }
    override func mouseMoved(with event: NSEvent) { owner?.hover(at: convert(event.locationInWindow, from: nil)) }
    override func mouseExited(with event: NSEvent) { owner?.hover(at: nil) }
}

extension DiffTableView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(copy(_:)) ? selected != nil : true
    }
}

/// The row of a diff. It draws the fill of the kind across the row, or of each half of a split row, and the pick bar.
final class DiffRowView: NSTableRowView {
    static let id = NSUserInterfaceItemIdentifier("diff.row")
    var kinds: (DiffLine.Kind?, DiffLine.Kind?) = (nil, nil)
    var picks = (false, false)
    var empty = (false, false)
    var split = false
    var gap = false
    var half: CGFloat = 0
    var cursor = false
    var current = false

    override func drawBackground(in dirtyRect: NSRect) {
        Palette.panel.setFill()
        bounds.fill()
        if gap {
            Palette.acc.withAlphaComponent(0.08).setFill()
            bounds.fill()
        }
        let halves: [(NSRect, DiffLine.Kind?, Bool, Bool)] = split
            ? [(NSRect(x: 0, y: 0, width: half, height: bounds.height), kinds.0, picks.0, empty.0),
               (NSRect(x: half + 1, y: 0, width: bounds.width - half - 1, height: bounds.height), kinds.1, picks.1, empty.1)]
            : [(bounds, kinds.0, picks.0, false)]
        for (r, kind, picked, none) in halves {
            if none {
                Palette.raise.withAlphaComponent(0.5).setFill()
                r.fill()
                continue
            }
            if let c = picked ? Palette.acc.withAlphaComponent(0.2) : Self.color(kind)?.withAlphaComponent(current ? 0.24 : 0.12) {
                c.setFill()
                r.fill()
            }
        }
        if split, !gap, kinds.0 != nil || kinds.1 != nil || empty.0 || empty.1 {
            Palette.line.setFill()
            NSRect(x: half, y: 0, width: 1, height: bounds.height).fill()
        }
        if current {
            Palette.acc.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        }
        if cursor {
            Palette.acc.setStroke()
            let p = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 0.5))
            p.lineWidth = 1
            p.stroke()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {}

    static func color(_ k: DiffLine.Kind?) -> NSColor? {
        switch k {
        case .add: return Palette.ok
        case .del: return Palette.bad
        default: return nil
        }
    }
}

/// One diff row: the gutters, the marks and the text. A split row has two halves of equal width.
final class DiffLineCell: NSView {
    static let id = NSUserInterfaceItemIdentifier("diff.line")
    private let gutters = [DiffGutter(), DiffGutter(), DiffGutter()]
    private let marks = [NSTextField.text("", size: 11.5, weight: .bold, mono: true), NSTextField.text("", size: 11.5, weight: .bold, mono: true)]
    private let texts = [DiffText(labelWithString: ""), DiffText(labelWithString: "")]
    private let plus = PlusMark()
    private var split = false
    private var gutter: CGFloat = 0
    private weak var owner: DiffTable?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        for v in gutters as [NSView] + marks + texts + [plus] {
            v.translatesAutoresizingMaskIntoConstraints = true
            addSubview(v)
        }
        for m in marks { m.alignment = .center }
        for t in texts {
            t.font = DiffTable.font
            t.textColor = Palette.fg
            t.cell?.isScrollable = false
        }
        plus.isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.row)
    }
    required init?(coder: NSCoder) { fatalError() }

    func text(_ column: Int) -> DiffText? { split ? texts[column] : column == 0 ? texts[0] : nil }

    /// The frame of the mark of a column, for tests.
    func markFrame(_ column: Int) -> NSRect { marks[column].frame }
    func gutterFrames() -> [NSRect] { gutters.filter { !$0.isHidden }.map(\.frame) }
    func gutterTexts() -> [String] { gutters.filter { !$0.isHidden }.map(\.text) }

    func set(_ t: DiffTable, row: Int) {
        owner = t
        split = t.split
        gutter = t.gutter
        var lines: [(index: Int?, column: Int)]
        switch t.items[row] {
        case .line(let i): lines = [(i, 0)]
        case .pair(let o, let n): lines = [(o, 0), (n, 1)]
        default: return
        }
        texts[1].isHidden = !split
        marks[1].isHidden = !split
        gutters[2].isHidden = !split
        gutters[1].isHidden = split
        var names: [String] = []
        for (index, c) in lines {
            let text = texts[c], mark = marks[c]
            text.row = row
            text.column = c
            text.table = t.view
            guard let i = index else {
                text.code = ""
                text.stringValue = ""
                text.selection = nil
                mark.stringValue = ""
                (split ? gutters[2 * c] : gutters[0]).set(text: "", picked: false, mark: .none, name: "", onPick: nil)
                continue
            }
            let l = t.fold.lines[i]
            let p = DiffFold.place(l)
            let on = p.map(t.picked) ?? false
            let gm = p.flatMap { t.marks[$0] } ?? .none
            let name = "Comment on \(p?.side == .old ? "old " : "")line \(p?.line ?? 0)"
            let pick: ((Bool) -> Void)? = p.map { p in { [weak t] shift in t?.onPick(p, shift) } }
            if split {
                let n = c == 0 ? (l.old ?? l.new) : l.new
                gutters[2 * c].set(text: n.map(String.init) ?? "", picked: on, mark: gm, name: name, onPick: pick, drag: p.map { dragPick(t, $0) })
            } else if l.kind == .del {
                gutters[0].set(text: l.old.map(String.init) ?? "", picked: on, mark: gm, name: name, onPick: pick, drag: p.map { dragPick(t, $0) })
                gutters[1].set(text: "", picked: false, mark: .none, name: "", onPick: nil)
            } else {
                gutters[0].set(text: l.old.map(String.init) ?? "", picked: false, mark: .none, name: "", onPick: nil)
                gutters[1].set(text: l.new.map(String.init) ?? "", picked: on, mark: gm, name: name, onPick: pick, drag: p.map { dragPick(t, $0) })
            }
            let (m, color) = Self.mark(l.kind)
            mark.stringValue = m
            mark.textColor = color ?? Palette.dim
            text.code = l.text
            text.maximumNumberOfLines = t.wrap ? 0 : 1
            text.cell?.wraps = t.wrap
            text.lineBreakMode = t.wrap ? .byCharWrapping : .byClipping
            text.attributedStringValue = t.styled(i)
            text.toolTip = !t.wrap && split ? l.text : nil
            if let s = t.view.selection, s.column == c, let r = s.range(row: row, length: (l.text as NSString).length) {
                text.selection = NSIntersectionRange(r, NSRange(location: 0, length: text.length))
            } else {
                text.selection = nil
            }
            let word = l.kind == .add ? "added" : l.kind == .del ? "removed" : "unchanged"
            names.append("Line \(p?.line ?? 0), \(word): \(l.text)")
        }
        setAccessibilityLabel(names.joined(separator: "; "))
        if let h = t.hovered, h.row == row, let p = t.place(row: row, column: h.column) {
            plus.onPick = { [weak t] shift in t?.onPick(p, shift) }
            plus.column = h.column
            plus.isHidden = false
        } else {
            plus.isHidden = true
        }
        needsLayout = true
    }

    private func dragPick(_ t: DiffTable, _ start: DiffPlace) -> () -> Void {
        { [weak t] in
            guard let t else { return }
            t.view.drag { p in
                let r = t.view.row(at: p)
                guard let place = t.place(row: r, column: t.column(at: p.x)), place.side == start.side else { return }
                t.onDragPick(place)
            }
            t.dragEnded()
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height, g = gutter, m = DiffTable.markWidth, lead = DiffTable.lead, trail = DiffTable.trail
        func place(_ c: Int, x0: CGFloat, width: CGFloat, guts: [DiffGutter]) {
            var x = x0 + lead
            for gv in guts {
                gv.frame = NSRect(x: x, y: 0, width: g, height: h)
                x += g
            }
            marks[c].frame = NSRect(x: x, y: 1, width: m, height: 16)
            x += m
            texts[c].frame = NSRect(x: x, y: 1, width: max(0, x0 + width - x - trail + 6), height: max(0, h - 2))
        }
        if split {
            let half = (bounds.width - 1) / 2
            place(0, x0: 0, width: half, guts: [gutters[0]])
            place(1, x0: half + 1, width: bounds.width - half - 1, guts: [gutters[2]])
        } else {
            place(0, x0: 0, width: bounds.width, guts: [gutters[0], gutters[1]])
        }
        let mf = marks[plus.column].frame
        plus.frame = NSRect(x: mf.midX - 8, y: 1, width: 16, height: 16)
    }

    static func mark(_ k: DiffLine.Kind) -> (String, NSColor?) {
        switch k {
        case .add: return ("+", Palette.ok)
        case .del: return ("−", Palette.bad)
        case .ctx: return (" ", nil)
        }
    }

    /// The hover "+". A click starts a comment on the line. The keyboard path is the line number, so it is not an accessibility element.
    final class PlusMark: Box {
        var onPick: (Bool) -> Void = { _ in }
        var column = 0

        init() {
            super.init(fill: Palette.acc, border: nil, radius: 4)
            translatesAutoresizingMaskIntoConstraints = true
            let t = NSTextField.text("+", size: 12, weight: .bold, color: Palette.bg, mono: true)
            t.alignment = .center
            t.translatesAutoresizingMaskIntoConstraints = true
            t.frame = NSRect(x: 0, y: 0, width: 16, height: 16)
            addSubview(t)
            toolTip = "Comment on this line. Shift-click for a range."
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) { onPick(event.modifierFlags.contains(.shift)) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

/// A fold row: the hunk header and the count of hidden lines.
final class DiffFoldCell: NSView {
    static let id = NSUserInterfaceItemIdentifier("diff.fold")
    private let header = NSTextField.text("", size: 11, color: Palette.acc, mono: true)
    private let count = NSTextField.text("", size: 11.5, color: Palette.dim)
    private let buttons = NSStackView(h: [], spacing: 10)
    /// The visible part of the row. A wide diff scrolls sideways, and the text stays in sight.
    private let inner = NSView()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        header.isSelectable = true
        header.lineBreakMode = .byTruncatingTail
        // The header gives its width first.
        header.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        count.setContentCompressionResistancePriority(.required, for: .horizontal)
        let s = NSStackView(h: [header, count, Spacer(), buttons], spacing: 8)
        inner.translatesAutoresizingMaskIntoConstraints = true
        addSubview(inner)
        inner.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: inner.leadingAnchor, constant: 12), s.trailingAnchor.constraint(equalTo: inner.trailingAnchor, constant: -12),
            s.centerYAnchor.constraint(equalTo: inner.centerYAnchor),
        ])
        setAccessibilityElement(false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `machine` is set for a partial diff: the app does not have the hidden lines, and the hint names the machine to update.
    func set(_ g: DiffGap, machine: String?, open: @escaping (DiffWay) -> Void) {
        header.stringValue = g.header
        header.isHidden = g.header.isEmpty
        count.stringValue = "\(g.hidden) line\(g.hidden == 1 ? "" : "s") hidden"
        count.setAccessibilityLabel([g.header, count.stringValue].filter { !$0.isEmpty }.joined(separator: ", "))
        buttons.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if let machine {
            let hint = NSTextField.text("Update oversire on \(machine) to show these lines.", size: 11, color: Palette.dim)
            hint.setContentCompressionResistancePriority(.required, for: .horizontal)
            buttons.addArrangedSubview(hint)
            return
        }
        for way in g.ways {
            let (title, symbol) = Self.title(way, hidden: g.hidden, one: g.ways.count == 1)
            let b = ActionButton(title, symbol: symbol, style: .link) { open(way) }
            b.font = .systemFont(ofSize: 11)
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            buttons.addArrangedSubview(b)
        }
    }

    static func title(_ way: DiffWay, hidden: Int, one: Bool) -> (String, String) {
        switch way {
        case .down: return ("Show \(DiffFold.step) lines below", "arrow.down")
        case .up: return ("Show \(DiffFold.step) lines above", "arrow.up")
        case .all: return one ? ("Unfold", "arrow.up.and.down") : ("Show all \(hidden) lines", "arrow.up.and.down")
        }
    }

    /// For tests: the titles of the buttons, or the hint.
    var titles: [String] { buttons.arrangedSubviews.map { ($0 as? NSButton)?.title ?? ($0 as? NSTextField)?.stringValue ?? "" } }

    override func layout() {
        let clip = enclosingScrollView?.contentView.bounds ?? bounds
        inner.frame = NSRect(x: max(0, min(clip.minX, bounds.width - clip.width)), y: 0, width: min(clip.width, bounds.width), height: bounds.height)
        super.layout()
    }
}

/// A note row: loading, a binary file, a long diff.
final class DiffNoteCell: NSView {
    static let id = NSUserInterfaceItemIdentifier("diff.note")
    private let label = NSTextField.text("", size: 12, color: Palette.dim, lines: 3)

    init() {
        super.init(frame: .zero)
        identifier = Self.id
        label.isSelectable = true
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 10),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ s: String) { label.stringValue = s }
}

/// The threads and the composer after a line. It keeps the visible width of the table.
final class ThreadCell: NSView {
    let content: NSView
    var offset: CGFloat = 0
    var width: CGFloat = 0
    private var measured: (width: CGFloat, height: CGFloat)?

    override var isFlipped: Bool { true }

    init(_ content: NSView) {
        self.content = content
        super.init(frame: .zero)
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = []
        addSubview(content)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The height at a width.
    func measure(_ w: CGFloat) -> CGFloat {
        if let m = measured, m.width == w { return m.height }
        content.frame = NSRect(x: 0, y: 0, width: w, height: 1000)
        let c = NSLayoutConstraint(item: content, attribute: .width, relatedBy: .equal, toItem: nil, attribute: .notAnAttribute, multiplier: 1, constant: w)
        content.translatesAutoresizingMaskIntoConstraints = false
        c.isActive = true
        Self.widen(content, w)
        content.layoutSubtreeIfNeeded()
        SidePane.fitLabels(content)
        content.layoutSubtreeIfNeeded()
        let h = ceil(content.fittingSize.height)
        c.isActive = false
        content.translatesAutoresizingMaskIntoConstraints = true
        measured = (w, h)
        return h
    }

    /// A wrapped label keeps the width of its first layout. Start each label at the full width, so a card does not stay narrow.
    private static func widen(_ v: NSView, _ w: CGFloat) {
        if let f = v as? NSTextField, f.maximumNumberOfLines != 1, !f.isEditable { f.preferredMaxLayoutWidth = w }
        v.subviews.forEach { widen($0, w) }
    }

    override func layout() {
        super.layout()
        content.frame = NSRect(x: offset, y: 0, width: width > 0 ? width : bounds.width, height: bounds.height)
        SidePane.fitLabels(content)
    }
}
