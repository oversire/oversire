import Cocoa
import OverSireCore

// ─── Item › Changes ──────────────────────────────────────────────────────────
// The code review of an item (OVERSIRE-372): the repos of the worktree group, a file list by repo, and the diff.
// Click a line number to comment on the line. Shift-click a second number on the same side for a range.
// Added lines show "+" on green, removed lines "−" on vermillion, so color is never the only signal.

/// A line number in a diff. A click picks the line. Return or Space picks it with the keyboard, Shift-Return makes a range.
final class DiffGutter: NSView {
    private let onPick: (_ shift: Bool) -> Void
    private let label: NSTextField

    init(_ text: String, width: CGFloat, picked: Bool, name: String, onPick: @escaping (_ shift: Bool) -> Void) {
        self.onPick = onPick
        label = .text(text, size: 11, color: picked ? Palette.acc : Palette.dim, mono: true)
        label.alignment = .right
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: width),
            label.leadingAnchor.constraint(equalTo: leadingAnchor), label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 1),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(name)
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
    /// The most diff lines that the tab shows for one file.
    static let lineLimit = 1500

    func threads(_ desk: ReviewDesk) -> ReviewThreads {
        if let t = threads[desk.id] { return t }
        let t = ReviewThreads(desk)
        t.reload = { [weak self] in self?.reload() }
        t.window = { [weak self] in self?.window() }
        t.approved = { [weak self, weak desk] in
            guard let self, let desk else { return }
            ReviewMergeSheet(desk: desk) { self.reload() }.present(over: self.window())
        }
        t.jump = { [weak self, weak desk] c in
            guard let desk, case .code(let repo, let path, _, _, _) = c.anchor else { return }
            desk.file = repo + "/" + path
            self?.open(desk)
        }
        threads[desk.id] = t
        return t
    }

    func rows(_ desk: ReviewDesk) -> [PageRow] {
        let t = threads(desk)
        let s = desk.summary
        var out: [PageRow] = []
        if let e = desk.error, desk.detail == nil {
            out.append(PageRow("error", e) { Banner(.bad, title: "The daemon on \(s.machine) did not give the review", body: e) })
        }
        out.append(PageRow("repos", s.repos, s.note, s.state, s.group, desk.pending.count) { [unowned self] in self.repos(desk) })
        if desk.detail == nil {
            out.append(PageRow("loading", desk.loading) {
                let c = ListCard()
                c.add(LoadingNote("Loading the review of \(s.key)"))
                return c
            })
            return out
        }
        out.append(PageRow("rounds", desk.rounds, s.round, desk.pending.count) { t.rounds() })
        let file = desk.files.first { $0.id == desk.file }
        let diff = file.flatMap { desk.diffs[$0.id] }
        let notes = file.map { desk.comments(in: $0) } ?? []
        out.append(PageRow("body", desk.files, desk.file, desk.split, desk.pick, diff, notes, t.hash, desk.pendingByFile, s.repos) { [unowned self] in
            let side = self.fileList(desk)
            let main = file.map { self.diffPanel(desk, file: $0, diff: diff, threads: t) } ?? EmptyNote("No changed files.") as NSView
            main.setContentHuggingPriority(.init(1), for: .horizontal)
            let h = NSStackView(h: [side, main], spacing: 14)
            h.alignment = .top
            h.distribution = .fill
            side.widthAnchor.constraint(equalToConstant: 250).isActive = true
            return h
        })
        out.append(PageRow("pending", desk.pending, t.hash) { t.pendingList() })
        out.append(PageRow("batch", desk.pending.count, desk.error, t.hash, desk.summary.round) { t.batchBar() })
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
            let line = NSStackView(h: parts, spacing: 8)
            line.setAccessibilityElement(true)
            line.setAccessibilityLabel("\(r.name), \(r.branch) into \(r.base), \(r.ahead) commits, \(mark.word)")
            card.add(line)
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

    // MARK: File list

    private func fileList(_ desk: ReviewDesk) -> NSView {
        let card = Card(padding: 8, spacing: 2)
        let pend = desk.pendingByFile
        let byRepo = Dictionary(grouping: desk.files, by: \.repo)
        for r in desk.summary.repos.map(\.name) + byRepo.keys.filter({ k in !desk.summary.repos.contains { $0.name == k } }).sorted() {
            guard let files = byRepo[r] else { continue }
            card.add(NSTextField.text(r, size: 11.5, weight: .semibold, color: Palette.mut, mono: true))
            for f in files {
                let (dir, name) = Self.split(f.path)
                let letter = NSTextField.text(f.status.rawValue, size: 11, weight: .bold, color: Self.color(f.status), mono: true)
                let title = NSStackView(v: [NSTextField.text(name, size: 12), NSTextField.text(dir, size: 10.5, color: Palette.dim)], spacing: 0)
                title.setContentCompressionResistancePriority(.init(1), for: .horizontal)
                var views: [NSView] = [letter, title, Spacer()]
                if let n = pend[f.id] { views.append(NSTextField.text("✎\(n)", size: 11, weight: .semibold, color: Palette.warn)) }
                if f.viewed { views.append(NSTextField.text("✓", size: 11, weight: .bold, color: Palette.ok)) }
                views.append(NSTextField.text(f.binary ? "bin" : "+\(f.added) −\(f.removed)", size: 10.5, color: Palette.dim, mono: true))
                let label = "\(Self.word(f.status)) \(f.path), \(f.added) added, \(f.removed) removed"
                    + (pend[f.id].map { ", \($0) pending comments" } ?? "") + (f.viewed ? ", viewed" : "")
                let row = Row(views, height: 30, inset: 6, label: label) { [weak self] in
                    desk.file = f.id
                    self?.open(desk)
                }
                row.stack.spacing = 6
                row.selected = f.id == desk.file
                card.add(row)
            }
            if let commits = desk.summary.repos.first(where: { $0.name == r })?.commits, !commits.isEmpty {
                card.add(NSTextField.text("Commits", size: 11, weight: .semibold, color: Palette.dim))
                for c in commits.prefix(8) {
                    let l = NSTextField.text("\(c.sha.prefix(7))  \(c.subject)", size: 11, color: Palette.mut, mono: true)
                    l.toolTip = c.subject
                    card.add(l)
                }
            }
        }
        return card
    }

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

    private func diffPanel(_ desk: ReviewDesk, file f: ReviewFile, diff: FileDiff?, threads t: ReviewThreads) -> NSView {
        let card = Card(padding: 0, spacing: 0)
        let path = f.oldPath.map { "\($0) → \(f.path)" } ?? f.path
        let pathField = NSTextField.text(path, size: 12, weight: .semibold, mono: true)
        pathField.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let mode = Segmented(["Unified", "Split"], selected: desk.split ? 1 : 0, label: "Diff view") { [weak self] i in
            desk.split = i == 1
            self?.reload()
        }
        let viewed = CheckBox("Viewed", on: f.viewed, label: "Mark \(f.path) as viewed") { on in Task { _ = await desk.setViewed(f, on) } }
        let head = NSStackView(h: [NSTextField.text(f.status.rawValue, size: 11, weight: .bold, color: Self.color(f.status), mono: true),
                                   pathField, Spacer(), mode, viewed], spacing: 8)
        head.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        card.add(head)
        let body = NSStackView(v: [], spacing: 0)
        body.alignment = .leading
        card.add(body)
        func note(_ s: String) {
            let n = NSTextField.text(s, size: 12, color: Palette.dim, lines: 3)
            let w = NSStackView(h: [n, Spacer()])
            w.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
            body.addFull(w)
        }
        if f.untracked == true { note("This file is not committed. The agent did not commit it.") }
        guard let diff else {
            note(desk.error.map { "The diff did not load: \($0)" } ?? "Loading the diff…")
            return card
        }
        if diff.binary || f.binary { note("Binary file. OverSire does not show a binary diff."); return card }
        if diff.hunks.isEmpty { note("No line changes.") }
        let notes = desk.comments(in: f)
        var shown = 0
        for h in diff.hunks {
            guard shown < Self.lineLimit else { break }
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
                    body.addFull(splitRow(desk, file: f, l, r))
                    shown += 1
                    for p in (l == r ? [l] : [l, r]).compactMap({ $0.flatMap(LinePick.place) }) {
                        after(p, desk: desk, file: f, notes: notes, threads: t, into: body)
                    }
                }
            } else {
                for l in h.lines {
                    body.addFull(unifiedRow(desk, file: f, l))
                    shown += 1
                    if let p = LinePick.place(l) { after(p, desk: desk, file: f, notes: notes, threads: t, into: body) }
                }
            }
        }
        if diff.truncated || shown >= Self.lineLimit { note("The diff is long. OverSire shows the first lines only. Open the file in your editor for the rest.") }
        return card
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
        body.addFull(s)
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

    private func gutter(_ desk: ReviewDesk, _ f: ReviewFile, _ l: DiffLine, text: String, width: CGFloat) -> NSView {
        guard let p = LinePick.place(l) else { return NSTextField.text(text, size: 11, color: Palette.dim, mono: true) }
        let on = picked(desk, f, p)
        return DiffGutter(text, width: width, picked: on, name: "Comment on \(p.side == .old ? "old " : "")line \(p.line)") { [weak self] shift in
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

    private func line(_ desk: ReviewDesk, _ f: ReviewFile, _ l: DiffLine?, gutters: [NSView]) -> NSView {
        guard let l else {
            let empty = Box(fill: Palette.raise.withAlphaComponent(0.5), border: nil, radius: 0)
            empty.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return empty
        }
        let (m, color) = Self.mark(l.kind)
        let on = LinePick.place(l).map { picked(desk, f, $0) } ?? false
        let fill = on ? Palette.acc.withAlphaComponent(0.2) : color?.withAlphaComponent(0.12)
        let box = Box(fill: fill, border: nil, radius: 0)
        let markField = NSTextField.text(m, size: 11.5, weight: .bold, color: color ?? Palette.dim, mono: true)
        markField.setAccessibilityLabel(l.kind == .add ? "added" : l.kind == .del ? "removed" : "")
        let text = NSTextField.text(l.text.isEmpty ? " " : l.text, size: 11.5, color: Palette.fg, lines: 0, mono: true)
        text.lineBreakMode = .byCharWrapping
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let s = NSStackView(h: gutters + [markField, text], spacing: 4)
        s.alignment = .top
        box.addSubview(s)
        NSLayoutConstraint.activate([
            s.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 2), s.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -8),
            s.topAnchor.constraint(equalTo: box.topAnchor, constant: 1), s.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -1),
        ])
        return box
    }

    /// The old and the new number. The number of the side that a comment takes is the button.
    private func unifiedRow(_ desk: ReviewDesk, file f: ReviewFile, _ l: DiffLine) -> NSView {
        func plain(_ n: Int?) -> NSView {
            let t = NSTextField.text(n.map(String.init) ?? "", size: 11, color: Palette.dim, mono: true)
            t.alignment = .right
            let box = NSStackView(h: [Spacer(), t])
            box.edgeInsets = NSEdgeInsets(top: 1, left: 0, bottom: 0, right: 6)
            box.widthAnchor.constraint(equalToConstant: 40).isActive = true
            return box
        }
        let numbers = l.kind == .del
            ? [gutter(desk, f, l, text: l.old.map(String.init) ?? "", width: 40), plain(nil)]
            : [plain(l.old), gutter(desk, f, l, text: l.new.map(String.init) ?? "", width: 40)]
        return line(desk, f, l, gutters: numbers)
    }

    private func splitRow(_ desk: ReviewDesk, file f: ReviewFile, _ l: DiffLine?, _ r: DiffLine?) -> NSView {
        let left = line(desk, f, l, gutters: l.map { [gutter(desk, f, $0, text: $0.old.map(String.init) ?? $0.new.map(String.init) ?? "", width: 40)] } ?? [])
        let right = line(desk, f, r, gutters: r.map { [gutter(desk, f, $0, text: $0.new.map(String.init) ?? "", width: 40)] } ?? [])
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
