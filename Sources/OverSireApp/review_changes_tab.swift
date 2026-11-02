import Cocoa
import OverSireCore

// ─── Item › Changes ──────────────────────────────────────────────────────────
// The code review of an item (OVERSIRE-372): the repos of the worktree group, the review bar, the file panel and the diff.
// The file panel and the diff scroll in their own height (OVERSIRE-387).
// Click a line number or the hover "+" to comment on the line. Shift-click a second number on the same side for a range.
// Added lines show "+" on green, removed lines "−" on vermillion, so color is never the only signal.

/// A line number in a diff. A click picks the line. Return or Space picks it with the keyboard, Shift-Return makes a range.
final class DiffGutter: NSView {
    private let onPick: (_ shift: Bool) -> Void
    private let label: NSTextField

    /// A line with a comment: pending or sent shows orange, answered green. The thread under the line says the same in text.
    enum Mark { case none, pending, answered }

    init(_ text: String, width: CGFloat, picked: Bool, mark: Mark = .none, name: String, onPick: @escaping (_ shift: Bool) -> Void) {
        self.onPick = onPick
        label = .text(text, size: 11, weight: picked || mark != .none ? .semibold : .regular, color: picked ? Palette.acc : Palette.dim, mono: true)
        label.alignment = .right
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        if picked || mark != .none {
            let bar = Box(fill: picked ? Palette.acc : mark == .answered ? Palette.ok : Palette.warn, border: nil, radius: 1)
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.widthAnchor.constraint(equalToConstant: 3),
                bar.topAnchor.constraint(equalTo: topAnchor), bar.heightAnchor.constraint(equalToConstant: 18),
            ])
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            label.leadingAnchor.constraint(equalTo: leadingAnchor), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name + (mark == .none ? "" : mark == .answered ? ", has an answered comment" : ", has a comment"))
        toolTip = "Click to comment. Shift-click for a range."
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onPick(event.modifierFlags.contains(.shift)) }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func accessibilityPerformPress() -> Bool { onPick(false); return true }
    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }
    override func keyDown(with event: NSEvent) {
        if [36, 49, 76].contains(event.keyCode) { onPick(event.modifierFlags.contains(.shift)); return }
        super.keyDown(with: event)
    }
    override func drawFocusRingMask() { bounds.fill() }
    override var focusRingMaskBounds: NSRect { bounds }
}

/// A diff line that shows a "+" on hover. A click on the "+" starts a comment on the line.
/// The keyboard path is the line number (`DiffGutter`), so the "+" is not an accessibility element.
/// One line at a time shows its "+". A scroll moves the lines under a still mouse, and AppKit does not always
/// send `mouseExited` then, so the line under the mouse is found again after each scroll (OVERSIRE-392).
final class DiffLineBox: Box {
    private var plus: NSView?
    private var tracking: NSTrackingArea?
    private static weak var hovered: DiffLineBox?
    private static var scrolled: NSObjectProtocol?

    func addPlus(at anchor: NSView, onPick: @escaping (_ shift: Bool) -> Void) {
        let p = PlusMark(onPick)
        p.isHidden = true
        addSubview(p)
        NSLayoutConstraint.activate([
            p.centerXAnchor.constraint(equalTo: anchor.centerXAnchor), p.topAnchor.constraint(equalTo: topAnchor, constant: 1),
        ])
        plus = p
    }

    override func updateTrackingAreas() {
        if let tracking { removeTrackingArea(tracking) }
        if plus != nil {
            let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
            addTrackingArea(t)
            tracking = t
        }
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { Self.hover(self) }
    override func mouseExited(with event: NSEvent) { if Self.hovered === self { Self.hover(nil) } }
    /// For `--uishots`: the hover look with no mouse.
    func showPlus() { plus?.isHidden = false }

    private static func hover(_ box: DiffLineBox?) {
        guard hovered !== box else { return }
        hovered?.plus?.isHidden = true
        hovered = box
        box?.plus?.isHidden = false
        if let scrolled { NotificationCenter.default.removeObserver(scrolled) }
        scrolled = nil
        guard let clip = box?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrolled = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak clip] _ in
            guard let window = clip?.window else { hover(nil); return }
            var v = window.contentView?.hitTest(window.mouseLocationOutsideOfEventStream)
            while let x = v, !(x is DiffLineBox) { v = x.superview }
            hover(v as? DiffLineBox)
        }
    }

    private final class PlusMark: Box {
        private let onPick: (_ shift: Bool) -> Void

        init(_ onPick: @escaping (_ shift: Bool) -> Void) {
            self.onPick = onPick
            super.init(fill: Palette.acc, border: nil, radius: 4)
            let t = NSTextField.text("+", size: 12, weight: .bold, color: Palette.bg, mono: true)
            addSubview(t)
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: 16), heightAnchor.constraint(equalToConstant: 16),
                t.centerXAnchor.constraint(equalTo: centerXAnchor), t.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            toolTip = "Comment on this line. Shift-click for a range."
            setAccessibilityElement(false)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func mouseDown(with event: NSEvent) { onPick(event.modifierFlags.contains(.shift)) }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    }
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
    /// The most diff lines that the tab shows for one file.
    static let lineLimit = 1500

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

    func rows(_ desk: ReviewDesk) -> [PageRow] {
        let t = threads(desk)
        let s = desk.summary
        var out: [PageRow] = []
        if let e = desk.error, desk.detail == nil {
            out.append(PageRow("error", e) { Banner(.bad, title: "The daemon on \(s.machine) did not give the review", body: e) })
        }
        out.append(PageRow("repos", s.repos, s.note, s.state, s.group, desk.pending.count, desk.filter.repo) { [unowned self] in self.repos(desk) })
        if desk.detail == nil {
            out.append(PageRow("loading", desk.loading) {
                let c = ListCard()
                c.add(LoadingNote("Loading the review of \(s.key)"))
                return c
            })
            return out
        }
        out.append(PageRow("review-bar", desk.rounds, s.round, desk.pending, desk.error, t.hash) { t.reviewBar() })
        let file = desk.files.first { $0.id == desk.file }
        let diff = file.flatMap { desk.diffs[$0.id] }
        let notes = file.map { desk.comments(in: $0) } ?? []
        let fill: (NSView) -> Void = { [unowned self] v in
            guard let pane = v as? TwoPane else { return }
            let p = self.panel(desk)
            pane.side.set(header: p.head, body: p.body(), place: "files")
            if let file {
                let (head, body) = self.diffPanel(desk, file: file, diff: diff, threads: t)
                pane.main.set(header: head, body: body, place: file.id, wide: desk.scrolls)
            } else {
                pane.main.set(header: nil, body: EmptyNote("No changed files."), place: "")
            }
            guard desk.reveal != nil else { return }
            DispatchQueue.main.async { [weak pane, weak desk] in
                guard let pane, let desk, let r = desk.reveal, pane.main.reveal(r) else { return }
                desk.reveal = nil
            }
        }
        out.append(PageRow("body", desk.files, desk.file, desk.split, desk.pick, diff, notes, t.hash, desk.pendingByFile, s.repos,
                           desk.filter, desk.view, desk.collapsed, desk.reveal, desk.wrap, update: fill) {
            let pane = TwoPane(sideWidth: 300, keep: "changes")
            fill(pane)
            return pane
        })
        return out
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
            var parts: [NSView] = [
                NSTextField.text(r.name, size: 12.5, weight: .semibold, mono: true),
                NSTextField.text("\(r.branch) → \(r.base)", size: 12, color: Palette.mut, mono: true),
                NSTextField.text("·  \(r.ahead) commit\(r.ahead == 1 ? "" : "s")", size: 12, color: Palette.mut),
                NSTextField.text("·  " + (r.dirty ? "Uncommitted files" : "No uncommitted files"), size: 12, color: r.dirty ? Palette.warn : Palette.mut),
                Spacer(),
            ]
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
            row.restBorder = on ? Palette.acc : nil
            row.selected = on
            card.add(row)
        }
        var foot: [NSView] = []
        if let note = s.note { foot.append(NSTextField.text("Agent: " + note, size: 12, color: Palette.mut, lines: 2)) }
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

    /// The fixed header and the body of the diff of one file.
    private func diffPanel(_ desk: ReviewDesk, file f: ReviewFile, diff: FileDiff?, threads t: ReviewThreads) -> (NSView, NSView) {
        let path = f.oldPath.map { "\($0) → \(f.path)" } ?? f.path
        let pathField = NSTextField.text(path, size: 12, weight: .semibold, mono: true)
        pathField.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let mode = Segmented(["Unified", "Split"], selected: desk.split ? 1 : 0, label: "Diff view") { [weak self] i in
            desk.split = i == 1
            self?.reload()
        }
        let wrap = ToggleChip("Wrap", on: desk.wrap, icon: desk.wrap ? nil : Glyph("arrow.turn.down.left", color: Palette.mut, size: 10)) { [weak self] in
            desk.wrap.toggle()
            self?.reload()
        }
        wrap.setAccessibilityLabel("Wrap long lines")
        let viewed = CheckBox("Viewed", on: f.viewed, label: "Mark \(f.path) as viewed") { on in Task { _ = await desk.setViewed(f, on) } }
        wrap.toolTip = desk.wrap ? "Long lines wrap. Click to keep each line on one row." : "Long lines scroll. Click to wrap them."
        [wrap, viewed].forEach { $0.setContentCompressionResistancePriority(.required, for: .horizontal) }
        var parts: [NSView] = [NSTextField.text(f.status.rawValue, size: 11, weight: .bold, color: Self.color(f.status), mono: true), pathField, Spacer()]
        if let n = desk.pendingByFile[f.id] {
            let chip = Chiplet("\(n) pending", symbol: "text.bubble", color: Palette.warn)
            chip.setAccessibilityLabel("\(n) pending comment\(n == 1 ? "" : "s") in this file")
            parts.append(chip)
        }
        let head = NSStackView(h: parts + [wrap, mode, viewed], spacing: 8)
        head.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        let body = NSStackView(v: [], spacing: 0)
        body.alignment = .leading
        body.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
        func note(_ s: String) {
            let n = NSTextField.text(s, size: 12, color: Palette.dim, lines: 3)
            let w = NSStackView(h: [n, Spacer()])
            w.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            body.addFull(w)
        }
        if f.untracked == true { note("This file is not committed. The agent did not commit it.") }
        guard let diff else {
            note(desk.error.map { "The diff did not load: \($0)" } ?? "Loading the diff…")
            return (head, body)
        }
        if diff.binary || f.binary { note("Binary file. OverSire does not show a binary diff."); return (head, body) }
        if diff.hunks.isEmpty { note("No line changes.") }
        let notes = desk.comments(in: f)
        let marks = Self.marks(notes)
        let language = SyntaxLanguage.of(f.path)
        var shown = 0
        for h in diff.hunks {
            guard shown < Self.lineLimit else { break }
            var colors: [Place: [SyntaxLanguage.Token]] = [:]
            if let language {
                for (l, t) in zip(h.lines, language.tokens(of: h.lines)) {
                    if let p = LinePick.place(l) { colors[Place(side: p.side, line: p.line)] = t }
                }
            }
            let range = "@@ −\(h.oldStart),\(h.oldLines) +\(h.newStart),\(h.newLines) @@" + (h.header.isEmpty ? "" : " " + h.header)
            let hl = NSTextField.text(range, size: 11, color: Palette.acc, mono: true)
            let hv = Box(fill: Palette.acc.withAlphaComponent(0.08), border: nil, radius: 0)
            hv.addSubview(hl)
            NSLayoutConstraint.activate([
                hl.leadingAnchor.constraint(equalTo: hv.leadingAnchor, constant: 12), hl.trailingAnchor.constraint(lessThanOrEqualTo: hv.trailingAnchor, constant: -12),
                hl.topAnchor.constraint(equalTo: hv.topAnchor, constant: 3), hl.bottomAnchor.constraint(equalTo: hv.bottomAnchor, constant: -3),
            ])
            body.addFull(hv)
            if desk.split {
                for (l, r) in Self.pairs(h.lines) {
                    body.addFull(splitRow(desk, file: f, marks, colors, l, r))
                    shown += 1
                    for p in (l == r ? [l] : [l, r]).compactMap({ $0.flatMap(LinePick.place) }) {
                        after(p, desk: desk, file: f, notes: notes, threads: t, into: body)
                    }
                }
            } else {
                for l in h.lines {
                    body.addFull(unifiedRow(desk, file: f, marks, colors, l))
                    shown += 1
                    if let p = LinePick.place(l) { after(p, desk: desk, file: f, notes: notes, threads: t, into: body) }
                }
            }
        }
        if diff.truncated || shown >= Self.lineLimit { note("The diff is long. OverSire shows the first lines only. Open the file in your editor for the rest.") }
        return (head, body)
    }

    struct Place: Hashable {
        let side: ReviewAnchor.Side
        let line: Int
    }

    /// The lines that have a comment. A line with an open comment shows as pending.
    static func marks(_ notes: [ReviewComment]) -> [Place: DiffGutter.Mark] {
        var out: [Place: DiffGutter.Mark] = [:]
        for c in notes {
            guard case .code(_, _, let line, let from, let side) = c.anchor else { continue }
            for n in min(from ?? line, line)...max(from ?? line, line) {
                let k = Place(side: side ?? .new, line: n)
                if c.state == .answered { out[k] = out[k] ?? .answered } else { out[k] = .pending }
            }
        }
        return out
    }

    /// The threads and the composer after a line.
    private func after(_ p: (side: ReviewAnchor.Side, line: Int), desk: ReviewDesk, file f: ReviewFile, notes: [ReviewComment], threads t: ReviewThreads, into body: NSStackView) {
        let here = notes.filter {
            guard case .code(_, _, let line, _, let side) = $0.anchor else { return false }
            return line == p.line && (side ?? .new) == p.side
        }
        var parts: [NSView] = []
        if !here.isEmpty { parts.append(t.thread(here)) }
        if let pick = desk.pick, pick.repo == f.repo, pick.path == f.path, pick.side == p.side, pick.to == p.line {
            parts.append(t.composer(pick.anchor, label: pick.label))
        }
        guard !parts.isEmpty else { return }
        let s = NSStackView(v: parts, spacing: 6)
        s.edgeInsets = NSEdgeInsets(top: 6, left: 40, bottom: 8, right: 12)
        if desk.scrolls { body.addArrangedSubview(ViewportWidth(s)) } else { body.addFull(s) }
    }

    private func picked(_ desk: ReviewDesk, _ f: ReviewFile, _ p: (side: ReviewAnchor.Side, line: Int)) -> Bool {
        guard let pick = desk.pick, pick.repo == f.repo, pick.path == f.path else { return false }
        return pick.contains(p.line, side: p.side)
    }

    private func pickLine(_ desk: ReviewDesk, _ f: ReviewFile, _ p: (side: ReviewAnchor.Side, line: Int), shift: Bool) {
        if let old = desk.pick, old.repo == f.repo, old.path == f.path {
            desk.pick = old.click(p.line, side: p.side, shift: shift)
        } else {
            desk.pick = LinePick(repo: f.repo, path: f.path, side: p.side, line: p.line)
        }
        desk.block = nil
        reload()
    }

    private func gutter(_ desk: ReviewDesk, _ f: ReviewFile, _ marks: [Place: DiffGutter.Mark], _ l: DiffLine, text: String, width: CGFloat) -> NSView {
        guard let p = LinePick.place(l) else { return NSTextField.text(text, size: 11, color: Palette.dim, mono: true) }
        let on = picked(desk, f, p)
        return DiffGutter(text, width: width, picked: on, mark: marks[Place(side: p.side, line: p.line)] ?? .none, name: "Comment on \(p.side == .old ? "old " : "")line \(p.line)") { [weak self] shift in
            self?.pickLine(desk, f, p, shift: shift)
        }
    }

    private static func mark(_ k: DiffLine.Kind) -> (String, NSColor?) {
        switch k {
        case .add: return ("+", Palette.ok)
        case .del: return ("−", Palette.bad)
        case .ctx: return (" ", nil)
        }
    }

    /// The longest text that a line shows with no wrap. A very long line (minified code) would make a huge view.
    static let nowrapLimit = 1000

    private func line(_ desk: ReviewDesk, _ f: ReviewFile, _ l: DiffLine?, tokens: [SyntaxLanguage.Token], gutters: [NSView]) -> NSView {
        guard let l else {
            let empty = Box(fill: Palette.raise.withAlphaComponent(0.5), border: nil, radius: 0)
            empty.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return empty
        }
        let (m, color) = Self.mark(l.kind)
        let on = LinePick.place(l).map { picked(desk, f, $0) } ?? false
        let fill = on ? Palette.acc.withAlphaComponent(0.2) : color?.withAlphaComponent(0.12)
        let box = DiffLineBox(fill: fill, border: nil, radius: 0)
        let markField = NSTextField.text(m, size: 11.5, weight: .bold, color: color ?? Palette.dim, mono: true)
        markField.setAccessibilityLabel(l.kind == .add ? "added" : l.kind == .del ? "removed" : "")
        var shown = l.text.isEmpty ? " " : l.text
        if !desk.wrap, shown.utf16.count > Self.nowrapLimit { shown = String(shown.prefix(Self.nowrapLimit)) + " …" }
        let text = NSTextField.text("", size: 11.5, lines: desk.wrap ? 0 : 1, mono: true)
        text.lineBreakMode = desk.wrap ? .byCharWrapping : .byClipping
        text.attributedStringValue = SyntaxLanguage.styled(shown, tokens: tokens, font: text.font ?? .monospacedSystemFont(ofSize: 11.5, weight: .regular), wraps: desk.wrap)
        // With wrap, the text takes the free width and wraps at the edge of the card. A unified diff with no wrap keeps the full width
        // and scrolls. A split diff with no wrap clips each side at its column, so both sides stay in sight.
        text.setContentCompressionResistancePriority(desk.scrolls ? .required : .init(1), for: .horizontal)
        if !desk.wrap, desk.split { text.toolTip = l.text }
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        let s = NSStackView(h: gutters + [markField, text], spacing: 4)
        s.alignment = .top
        s.distribution = .fill
        box.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 2), s.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            s.topAnchor.constraint(equalTo: box.topAnchor, constant: 1), s.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])
        if let p = LinePick.place(l) {
            box.addPlus(at: markField) { [weak self] shift in self?.pickLine(desk, f, p, shift: shift) }
        }
        return box
    }

    /// The old and the new number. The number of the side that a comment takes is the button.
    private func unifiedRow(_ desk: ReviewDesk, file f: ReviewFile, _ marks: [Place: DiffGutter.Mark], _ colors: [Place: [SyntaxLanguage.Token]], _ l: DiffLine) -> NSView {
        func plain(_ n: Int?) -> NSView {
            let t = NSTextField.text(n.map(String.init) ?? "", size: 11, color: Palette.dim, mono: true)
            t.alignment = .right
            let box = NSStackView(h: [Spacer(), t])
            box.edgeInsets = NSEdgeInsets(top: 1, left: 0, bottom: 0, right: 6)
            box.widthAnchor.constraint(equalToConstant: 40).isActive = true
            return box
        }
        let numbers = l.kind == .del
            ? [gutter(desk, f, marks, l, text: l.old.map(String.init) ?? "", width: 40), plain(nil)]
            : [plain(l.old), gutter(desk, f, marks, l, text: l.new.map(String.init) ?? "", width: 40)]
        return line(desk, f, l, tokens: Self.tokens(colors, l), gutters: numbers)
    }

    private static func tokens(_ colors: [Place: [SyntaxLanguage.Token]], _ l: DiffLine?) -> [SyntaxLanguage.Token] {
        guard let l, let p = LinePick.place(l) else { return [] }
        return colors[Place(side: p.side, line: p.line)] ?? []
    }

    private func splitRow(_ desk: ReviewDesk, file f: ReviewFile, _ marks: [Place: DiffGutter.Mark], _ colors: [Place: [SyntaxLanguage.Token]],
                          _ l: DiffLine?, _ r: DiffLine?) -> NSView {
        let left = line(desk, f, l, tokens: Self.tokens(colors, l), gutters: l.map { [gutter(desk, f, marks, $0, text: $0.old.map(String.init) ?? $0.new.map(String.init) ?? "", width: 40)] } ?? [])
        let right = line(desk, f, r, tokens: Self.tokens(colors, r), gutters: r.map { [gutter(desk, f, marks, $0, text: $0.new.map(String.init) ?? "", width: 40)] } ?? [])
        let rule = Box(fill: Palette.line, border: nil, radius: 0)
        rule.widthAnchor.constraint(equalToConstant: 1).isActive = true
        let h = NSStackView(h: [left, rule, right], spacing: 0)
        h.alignment = .top
        h.distribution = .fill
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        rule.heightAnchor.constraint(equalTo: h.heightAnchor).isActive = true
        return h
    }

    /// The lines of a hunk side by side. A run of removed lines pairs with the next run of added lines.
    /// A context line shows on both sides, as one value.
    static func pairs(_ lines: [DiffLine]) -> [(DiffLine?, DiffLine?)] {
        var out: [(DiffLine?, DiffLine?)] = []
        var dels: [DiffLine] = [], adds: [DiffLine] = []
        func flush() {
            for i in 0..<max(dels.count, adds.count) { out.append((i < dels.count ? dels[i] : nil, i < adds.count ? adds[i] : nil)) }
            dels = []
            adds = []
        }
        for l in lines {
            switch l.kind {
            case .del:
                if !adds.isEmpty { flush() }
                dels.append(l)
            case .add: adds.append(l)
            case .ctx:
                flush()
                out.append((l, l))
            }
        }
        flush()
        return out
    }
}
