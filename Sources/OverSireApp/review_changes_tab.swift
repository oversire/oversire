import Cocoa
import OverSireCore

// ─── Item › Changes ──────────────────────────────────────────────────────────
// The code review of an item (OVERSIRE-372): the repos of the worktree group, the review bar, the file panel and the diff.
// The file panel and the diff scroll in their own height (OVERSIRE-387).
// Click a line number or the hover "+" to comment on the line. Shift-click a second number on the same side for a range.
// Added lines show "+" on green, removed lines "−" on vermillion, so color is never the only signal.

/// A line number in a diff. A click picks the line. Return or Space picks it with the keyboard, Shift-Return makes a range.
/// A drag from the number extends the pick row by row. A cell reuses the gutter, so `set` changes it in place.
final class DiffGutter: NSView {
    /// A line with a comment: pending or sent shows orange, answered green. The thread under the line says the same in text.
    enum Mark { case none, pending, answered }

    private let label = NSTextField.text("", size: 11, color: Palette.dim, mono: true)
    private let bar = Box(fill: Palette.acc, border: nil, radius: 1)
    private var onPick: ((_ shift: Bool) -> Void)?
    private var drag: (() -> Void)?
    var text: String { label.stringValue }

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = true
        label.translatesAutoresizingMaskIntoConstraints = true
        label.alignment = .right
        label.lineBreakMode = .byClipping
        bar.translatesAutoresizingMaskIntoConstraints = true
        addSubview(label)
        addSubview(bar)
        toolTip = "Click to comment. Shift-click for a range."
    }
    required init?(coder: NSCoder) { fatalError() }

    /// A gutter with no `onPick` shows a plain number: the other side of a unified row.
    func set(text: String, picked: Bool, mark: Mark, name: String, onPick: ((_ shift: Bool) -> Void)?, drag: (() -> Void)? = nil) {
        self.onPick = onPick
        self.drag = drag
        label.stringValue = text
        let strong = onPick != nil && (picked || mark != .none)
        label.font = .monospacedSystemFont(ofSize: 11, weight: strong ? .semibold : .regular)
        label.textColor = onPick != nil && picked ? Palette.acc : Palette.dim
        bar.isHidden = !strong
        bar.fill = picked ? Palette.acc : mark == .answered ? Palette.ok : Palette.warn
        setAccessibilityElement(onPick != nil)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name + (mark == .none ? "" : mark == .answered ? ", has an answered comment" : ", has a comment"))
        toolTip = onPick == nil ? nil : "Click to comment. Shift-click for a range."
        window?.invalidateCursorRects(for: self)
    }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 0, y: 1, width: max(0, bounds.width - 6), height: 16)
        bar.frame = NSRect(x: 0, y: 0, width: 3, height: min(18, bounds.height))
    }

    override func mouseDown(with event: NSEvent) {
        guard let onPick else { return super.mouseDown(with: event) }
        onPick(event.modifierFlags.contains(.shift))
        drag?()
    }
    override func resetCursorRects() { if onPick != nil { addCursorRect(bounds, cursor: .pointingHand) } }
    override func accessibilityPerformPress() -> Bool { onPick?(false); return onPick != nil }
    override var acceptsFirstResponder: Bool { onPick != nil }
    override var canBecomeKeyView: Bool { onPick != nil }
    override func keyDown(with event: NSEvent) {
        if let onPick, [36, 49, 76].contains(event.keyCode) { onPick(event.modifierFlags.contains(.shift)); return }
        super.keyDown(with: event)
    }
    override func drawFocusRingMask() { bounds.fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// The merge of one repo, from `ReviewRepo.merge`.
enum MergeChoice: Equatable {
    case merge, rebase, fix

    init(_ r: ReviewRepo) {
        switch r.merge {
        case .fastForward: self = .merge
        case .rebase: self = .rebase
        case .conflict: self = .fix
        }
    }

    var title: String {
        switch self {
        case .merge: return "Merge"
        case .rebase: return "Rebase and merge"
        case .fix: return "Fix with agent"
        }
    }

    /// The action of the sheet: a conflict wins, then a rebase.
    static func primary(_ repos: [ReviewRepo]) -> MergeChoice {
        let all = repos.map(MergeChoice.init)
        if all.contains(.fix) { return .fix }
        return all.contains(.rebase) ? .rebase : .merge
    }
}

/// The rows of the Changes tab. Main thread only.
final class ReviewChangesTab {
    var reload: () -> Void = {}
    var window: () -> NSWindow? = { nil }
    var go: (Route) -> Void = { _ in }
    private var threads: [String: ReviewThreads] = [:]
    private var panels: [String: FilePanel] = [:]
    private var diffs: [String: DiffPanel] = [:]
    private var modal: DiffModal?
    private weak var away: DiffAwayNote?

    func threads(_ desk: ReviewDesk) -> ReviewThreads {
        if let t = threads[desk.id], t.desk === desk { return t }
        let t = ReviewThreads(desk)
        t.reload = { [weak self] in self?.reload() }
        t.window = { [weak self] in self?.window() }
        t.approved = { [weak self, weak desk] in
            guard let self, let desk else { return }
            ReviewMergeSheet(desk: desk) { self.reload() }.present(over: self.window())
        }
        t.jump = { [weak self, weak desk] c in
            guard let desk, case .code(let repo, let path, _, _, _) = c.anchor else { return }
            let id = repo + "/" + path
            desk.file = id
            desk.reveal = ReviewThreads.anchorID(c)
            if let f = desk.files.first(where: { $0.id == id }), !desk.filter.matches(f) { desk.filter = FileFilter() }
            desk.collapsed = desk.collapsed.filter { !id.hasPrefix($0 + "/") }
            self?.open(desk)
        }
        threads[desk.id] = t
        return t
    }

    func panel(_ desk: ReviewDesk) -> FilePanel {
        if let p = panels[desk.id], p.desk === desk { return p }
        let p = FilePanel(desk)
        p.changed = { [weak self] in self?.reload() }
        p.open = { [weak self, weak desk] f in
            guard let desk else { return }
            desk.file = f.id
            self?.open(desk)
        }
        panels[desk.id] = p
        return p
    }

    /// The diff panel of a desk. It lives as long as the desk, so the table keeps its rows and its scroll position.
    func diffPanel(_ desk: ReviewDesk) -> DiffPanel {
        if let p = diffs[desk.id], p.desk === desk { return p }
        let p = DiffPanel(desk: desk, threads: threads(desk))
        p.reload = { [weak self] in self?.reload() }
        p.open = { [weak self, weak desk] f in
            guard let desk else { return }
            desk.file = f.id
            if !desk.filter.matches(f) { desk.filter = FileFilter() }
            self?.open(desk)
        }
        diffs[desk.id] = p
        return p
    }

    func rows(_ desk: ReviewDesk) -> [PageRow] {
        let t = threads(desk)
        let s = desk.summary
        var out: [PageRow] = []
        let read = desk.review.state
        if desk.detail == nil, case .failed = read {
            let part = desk.review.part(id: "review", title: "Review of \(s.key)")
            out.append(PageRow("error", read, desk.review.last.retry(now: Date())) {
                ReadNote("The daemon on \(s.machine) did not give the review.", part: part)
            })
        }
        out.append(PageRow("repos", s.repos, s.note, s.state, s.group, desk.pending.count, desk.filter.repo, read) { [unowned self] in self.repos(desk) })
        if desk.detail == nil {
            guard !read.didFail else { return out }
            out.append(PageRow("loading", desk.loading) {
                let c = ListCard()
                c.add(LoadingNote("Loading the review of \(s.key)"))
                return c
            })
            return out
        }
        out.append(PageRow("review-bar", desk.rounds, s.round, desk.pending, desk.error, t.hash) { t.reviewBar() })
        let file = desk.files.first { $0.id == desk.file }
        let diff = file.flatMap { desk.shownDiff($0) }
        let diffRead = file.map { desk.diffRead($0) }
        let notes = file.map { desk.comments(in: $0) } ?? []
        let fill: (NSView) -> Void = { [unowned self] v in
            guard let pane = v as? TwoPane else { return }
            let p = self.panel(desk)
            p.refresh()
            guard let file else {
                self.closeModal()
                pane.side.set(header: nil, fill: p.card, place: "files")
                return pane.main.set(header: nil, body: EmptyNote("No changed files."), place: "")
            }
            let panel = self.diffPanel(desk)
            panel.update(file, diff: diff)
            if desk.maximized {
                let note = self.away ?? DiffAwayNote()
                note.gone = { [weak self, weak desk] in
                    // A rebuild puts the note back at once. Only a page that leaves the screen closes the large view.
                    DispatchQueue.main.async {
                        guard let self, self.away?.window == nil, let desk else { return }
                        desk.maximized = false
                        self.closeModal()
                    }
                }
                self.away = note
                pane.main.set(header: nil, body: note, place: "max")
                if desk.maxFiles {
                    pane.side.set(header: nil, body: EmptyNote("The files are in the large view. Press ⇧⌘M to restore.", symbol: "sidebar.left"), place: "files-away")
                } else {
                    pane.side.set(header: nil, fill: p.card, place: "files")
                }
                // A new page is not in its window yet. Then the large view shows on the next turn.
                let show = { [weak self, weak desk, weak panel, weak p] in
                    guard let self, let desk, let panel, desk.maximized else { return }
                    let files: NSView? = desk.maxFiles ? p?.card : nil
                    guard let w = self.window() else {
                        desk.maximized = false
                        return self.reload()
                    }
                    if let m = self.modal, m.window === w { return m.hold(panel, files: files) }
                    self.closeModal()
                    self.modal = DiffModal.show(panel, files: files, in: w) { [weak self, weak desk] in
                        desk?.maximized = false
                        self?.reload()
                    }
                }
                if self.window() != nil { show() } else { DispatchQueue.main.async(execute: show) }
            } else {
                self.closeModal()
                pane.side.set(header: nil, fill: p.card, place: "files")
                pane.main.set(header: nil, fill: panel, place: file.id)
            }
            guard desk.reveal != nil else { return }
            DispatchQueue.main.async { [weak panel, weak desk] in
                guard let panel, let desk, let r = desk.reveal, panel.table.reveal(r) else { return }
                desk.reveal = nil
            }
        }
        out.append(PageRow("body", desk.files, desk.file, desk.split, desk.pick, diff, diffRead?.state, diffRead?.last.retry(now: Date()), notes, t.hash, desk.pendingByFile, s.repos,
                           desk.filter, desk.view, desk.collapsed, desk.reveal, desk.wrap, desk.maximized, desk.maxFiles, desk.opened, desk.wholeFile, desk.change, update: fill) {
            let pane = TwoPane(sideWidth: Self.sideWidth, keep: "changes")
            fill(pane)
            return pane
        })
        return out
    }

    /// The width of the file panel, in the page and in the large view.
    static let sideWidth: CGFloat = 300

    func closeModal() {
        modal?.dismiss()
        modal = nil
    }

    /// Shows the file and reads its diff.
    func open(_ desk: ReviewDesk) {
        desk.pick = nil
        reload()
        guard let f = desk.files.first(where: { $0.id == desk.file }) else { return }
        Task { await desk.diff(f) }
    }

    // MARK: Repos

    private func repos(_ desk: ReviewDesk) -> NSView {
        let s = desk.summary
        let card = Card(padding: 12, spacing: 8)
        for r in s.repos {
            let mark = ReviewMark(r)
            let texts = [
                NSTextField.text(r.name, size: 12.5, weight: .semibold, mono: true),
                NSTextField.text("\(r.branch) → \(r.base)", size: 12, color: Palette.mut, mono: true),
                NSTextField.text("·  \(r.ahead) commit\(r.ahead == 1 ? "" : "s")", size: 12, color: Palette.mut),
                NSTextField.text("·  " + (r.dirty ? "Uncommitted files" : "No uncommitted files"), size: 12, color: r.dirty ? Palette.warn : Palette.mut),
            ]
            // A row with a click keeps its text plain: the menu copies it.
            if s.repos.count < 2 { texts.forEach { $0.isSelectable = true } }
            var parts: [NSView] = texts + [Spacer()]
            switch r.merge {
            case .fastForward: parts.append(mark.line("Can fast-forward"))
            case .rebase: parts.append(mark.line("\(r.base) has \(r.behind) new commit\(r.behind == 1 ? "" : "s")"))
            case .conflict: parts.append(mark.line("Conflict: " + (r.conflictFiles ?? []).joined(separator: ", ")))
            }
            let label = "\(r.name), \(r.branch) into \(r.base), \(r.ahead) commits, \(mark.word)"
            guard s.repos.count > 1 else {
                let line = NSStackView(h: parts, spacing: 8)
                line.setAccessibilityElement(true)
                line.setAccessibilityLabel(label)
                card.add(line)
                continue
            }
            // A click shows only the files of this repo. A second click shows all.
            let on = desk.filter.repo == r.name
            let row = Row(parts, height: 28, inset: 8, label: label + (on ? ", files shown" : ", show its files")) { [weak self] in
                desk.filter.repo = on ? nil : r.name
                self?.reload()
            }
            row.stack.spacing = 8
            row.menuItems = {
                [MenuAction("Copy Repo Name") { RowActions.copy(r.name) }.item,
                 MenuAction("Copy Branch Name") { RowActions.copy(r.branch) }.item]
            }
            row.restBorder = on ? Palette.acc : nil
            row.selected = on
            card.add(row)
        }
        var foot: [NSView] = []
        if let note = s.note {
            let n = NSTextField.text("Agent: " + note, size: 12, color: Palette.mut, lines: 2)
            n.isSelectable = true
            foot.append(n)
        }
        foot.append(Spacer())
        if s.state == .conflict {
            foot.append(ActionButton("Fix with agent", style: .primary) { [weak self] in
                ReviewMergeSheet(desk: desk) { self?.reload() }.present(over: self?.window())
            })
        } else {
            let m = ActionButton("Merge…", symbol: "arrow.triangle.merge", style: s.state == .ready ? .primary : .plain) { [weak self] in
                ReviewMergeSheet(desk: desk) { self?.reload() }.present(over: self?.window())
            }
            m.isEnabled = s.state == .ready
            if s.state == .waiting { m.toolTip = "The agent works on the last round. Merge when it hands off." }
            foot.append(m)
        }
        foot.append(ReadAccessory(desk.review.part(id: "review", title: "Review of \(s.key)")))
        card.add(NSStackView(h: foot, spacing: 8))
        return card
    }

    // MARK: File names

    static func split(_ path: String) -> (dir: String, name: String) {
        guard let i = path.lastIndex(of: "/") else { return ("", path) }
        return (String(path[..<i]), String(path[path.index(after: i)...]))
    }

    static func color(_ s: FileStatus) -> NSColor {
        switch s {
        case .added: return Palette.ok
        case .deleted: return Palette.bad
        case .modified: return Palette.warn
        case .renamed: return Palette.acc
        }
    }

    static func word(_ s: FileStatus) -> String {
        switch s {
        case .added: return "Added"
        case .deleted: return "Deleted"
        case .modified: return "Changed"
        case .renamed: return "Renamed"
        }
    }


    // MARK: Diff

    /// The lines that have a comment. A line with an open comment shows as pending.
    static func marks(_ notes: [ReviewComment]) -> [DiffPlace: DiffGutter.Mark] {
        var out: [DiffPlace: DiffGutter.Mark] = [:]
        for c in notes {
            guard case .code(_, _, let line, let from, let side) = c.anchor else { continue }
            for n in min(from ?? line, line)...max(from ?? line, line) {
                let k = DiffPlace(side: side ?? .new, line: n)
                if c.state == .answered { out[k] = out[k] ?? .answered } else { out[k] = .pending }
            }
        }
        return out
    }
}
