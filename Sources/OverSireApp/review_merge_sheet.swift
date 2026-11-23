import Cocoa
import OverSireCore

// ─── Merge ───────────────────────────────────────────────────────────────────
// The local merge of a worktree group (OVERSIRE-372). The daemon merges each repo in order: a fast-forward,
// or a rebase and then a fast-forward. A conflict merges nothing; the agent rebases and fixes it.
// Nothing is pushed. With "Set Done", the app sets the item and its sub-items to Done, with a merge comment.

/// The parts that a folded merge takes (OVERSIRE-592). The ready parts are picked first.
struct MergePicks {
    let parts: [ReviewPart]
    let repos: [ReviewRepo]
    private(set) var picked: Set<String>

    init(parts: [ReviewPart], repos: [ReviewRepo]) {
        self.parts = parts
        self.repos = repos
        picked = []
        picked = Set(open.filter { reason($0) == nil }.map(\.key))
    }

    /// The parts that are not merged.
    var open: [ReviewPart] { parts.filter { $0.state != .merged && $0.mergedAt == nil } }

    func repos(of p: ReviewPart) -> [ReviewRepo] { repos.filter { $0.item == p.key } }

    /// Why the part cannot merge now. Nil: it is ready.
    func reason(_ p: ReviewPart) -> String? {
        let mine = repos(of: p)
        if p.state == .conflict || mine.contains(where: { $0.merge == .conflict }) { return "a repo has a conflict" }
        if p.state == .waiting { return "the agent works" + (p.round > 0 ? " on round \(p.round)" : "") }
        if !mine.contains(where: { $0.ahead > 0 }) { return "no commits to merge" }
        return nil
    }

    var allReady: Bool { open.allSatisfy { reason($0) == nil } }
    /// The key goes to Done only when the merge takes all open parts.
    var canSetDone: Bool { !open.isEmpty && open.allSatisfy { picked.contains($0.key) } }
    /// The picked keys in part order: the sub-items, then the parent.
    var items: [String] { open.map(\.key).filter(picked.contains) }

    mutating func set(_ key: String, _ on: Bool) {
        guard let p = open.first(where: { $0.key == key }), reason(p) == nil else { return }
        if on { picked.insert(key) } else { picked.remove(key) }
    }

    mutating func pickAll() { for p in open { set(p.key, true) } }

    /// The tooltip of "Merge all" when it is off.
    var notReady: String {
        open.compactMap { p in reason(p).map { "\(FilePanel.short(p.key)): \($0)" } }.joined(separator: "; ")
    }
}

final class ReviewMergeSheet {
    private let desk: ReviewDesk
    private let done: () -> Void
    private let sheet: DialogSheet
    private let removeGroup: CheckBox
    private let setDone: CheckBox
    private let result: NSTextField
    private var choice: MergeChoice
    private weak var parent: NSWindow?
    /// The parts of a folded review. Nil: one group.
    private(set) var picks: MergePicks?
    /// The part with the conflict after a failed folded merge.
    private var fixItem: String?

    init(desk: ReviewDesk, done: @escaping () -> Void) {
        self.desk = desk
        self.done = done
        let s = desk.summary
        if desk.folded { picks = MergePicks(parts: desk.parts, repos: s.repos) }
        choice = picks == nil ? MergeChoice.primary(s.repos) : .merge
        sheet = DialogSheet(title: choice == .fix ? "Fix the conflict of \(s.key)" : "Merge \(s.key)", width: 600)
        if picks != nil {
            _ = sheet.note("The daemon on \(s.machine) merges the picked groups locally, all or none: the sub-items first, then \(s.key). Nothing is pushed.")
        } else {
            _ = sheet.note("The daemon on \(s.machine) merges each repo locally, in this order. Nothing is pushed.")
        }
        let group = s.group.map { ($0 as NSString).lastPathComponent } ?? "the group"
        removeGroup = CheckBox(picks == nil ? "Remove the worktree group .wt/\(group) after all repos merge" : "Remove the worktree groups after all repos merge",
                               on: true)
        setDone = CheckBox(picks == nil ? "Set \(s.key) to Done and its sub-items, with a merge comment" : "Set \(s.key) to Done, with a merge comment",
                           on: true)
        result = .text("", size: 12, color: Palette.bad, lines: 6)
        build()
    }

    private func build() {
        let s = desk.summary
        let list = Card(padding: 10, spacing: 8, fill: Palette.raise)
        if let picks {
            for p in picks.parts { list.add(partRow(p, picks)) }
        } else {
            for (i, r) in s.repos.enumerated() { list.add(row(i + 1, r)) }
        }
        if s.repos.isEmpty { list.add(NSTextField.text("No repo has commits to merge.", size: 12, color: Palette.dim)) }
        sheet.stack.addFull(list)
        if choice == .fix {
            _ = sheet.note("Nothing merges while a repo has a conflict. The agent rebases the group on its base, fixes the conflict and hands off again.",
                           color: Palette.mut)
        } else {
            sheet.stack.addFull(removeGroup)
            sheet.stack.addFull(setDone)
        }
        let n = desk.pending.count
        if n > 0 {
            let warn = NSStackView(h: [NSTextField.text("▲", size: 12, weight: .bold, color: Palette.warn),
                                       NSTextField.text("\(n) pending comment\(n == 1 ? " is" : "s are") not sent. The agent never sees \(n == 1 ? "it" : "them") after the merge.",
                                                        size: 12, color: Palette.warn, lines: 2)], spacing: 6)
            warn.setAccessibilityElement(true)
            warn.setAccessibilityLabel("Warning: \(n) pending comments are not sent.")
            sheet.stack.addFull(warn)
        }
        if s.state == .waiting, picks == nil { _ = sheet.note("The agent works on the last round. The daemon refuses a merge until it hands off.", color: Palette.warn) }
        sheet.stack.addFull(result)
        if let picks {
            sheet.buttons(cancel: "Cancel", primary: choice.title, extra: picks.open.count > 1 ? "Merge all" : nil,
                          onCancel: { [weak self] in self?.sheet.dismiss() },
                          onExtra: { [weak self] in
                              self?.picks?.pickAll()
                              self?.run()
                          },
                          onPrimary: { [weak self] in self?.run() })
            updatePicks()
        } else {
            sheet.buttons(cancel: "Cancel", primary: choice.title, onCancel: { [weak self] in self?.sheet.dismiss() }, onPrimary: { [weak self] in self?.run() })
        }
    }

    /// One part of a folded review: a checkbox, the state, and the repos with their merge mode.
    private func partRow(_ p: ReviewPart, _ picks: MergePicks) -> NSView {
        let role = p.key == desk.key ? "parent" : "sub-item"
        let why = picks.reason(p)
        let merged = !picks.open.contains { $0.key == p.key }
        let state = merged ? "merged" : why.map { "not ready: \($0)" } ?? "ready"
        let box = CheckBox("\(p.key) · \(role)", on: picks.picked.contains(p.key), label: "Merge \(p.key), \(state)") { [weak self] on in
            self?.picks?.set(p.key, on)
            self?.updatePicks()
        }
        box.isEnabled = !merged && why == nil
        box.font = .systemFont(ofSize: 12.5, weight: .semibold)
        let mark = merged ? ReviewMark("✓", Palette.mut, state) : why == nil ? ReviewMark("◆", Palette.ok, state) : ReviewMark("▲", Palette.warn, state)
        let tag = Chiplet(state, icon: mark.view(size: 11), color: mark.color)
        let head = NSStackView(h: [box, Spacer(), tag], spacing: 8)
        var repoLines: [NSView] = []
        for r in picks.repos(of: p) {
            let what: String
            switch r.merge {
            case .fastForward: what = "fast-forward, \(r.ahead) commit\(r.ahead == 1 ? "" : "s")"
            case .rebase: what = "rebase on \(r.behind) new commit\(r.behind == 1 ? "" : "s"), then fast-forward"
            case .conflict: what = "conflict"
            }
            let t = NSTextField.text("\(r.name)  \(r.branch) → \(r.base) · \(what)", size: 11.5, color: Palette.mut, mono: true)
            t.setContentCompressionResistancePriority(.init(1), for: .horizontal)
            repoLines.append(t)
        }
        let sub = NSStackView(v: repoLines, spacing: 2)
        sub.alignment = .leading
        sub.edgeInsets = NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 0)
        let v = NSStackView(v: [head, sub], spacing: 3)
        v.alignment = .leading
        head.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        v.setAccessibilityElement(false)
        return v
    }

    /// The button titles and the Done checkbox after a pick.
    private func updatePicks() {
        guard let picks, choice != .fix else { return }
        let n = picks.items.count
        sheet.primaryButton?.title = "Merge \(n) ready group\(n == 1 ? "" : "s")"
        sheet.primaryButton?.isEnabled = n > 0
        if let x = sheet.extraButton {
            x.isEnabled = picks.allReady
            x.toolTip = picks.allReady ? "Merge all \(picks.open.count) groups" : "Not ready: " + picks.notReady
        }
        setDone.isEnabled = picks.canSetDone
        if !picks.canSetDone { setDone.state = .off }
        setDone.toolTip = picks.canSetDone ? nil : "Pick all groups to set \(desk.key) to Done. Each merged sub-item goes to Done."
    }

    private func row(_ n: Int, _ r: ReviewRepo) -> NSView {
        let mark = ReviewMark(r)
        let what: String
        switch r.merge {
        case .fastForward: what = "Fast-forward \(r.base) to \(r.branch) (\(r.ahead) commit\(r.ahead == 1 ? "" : "s"))."
        case .rebase: what = "\(r.base) has \(r.behind) new commit\(r.behind == 1 ? "" : "s"). The daemon rebases \(r.branch), then fast-forwards."
        case .conflict: what = "Conflict in " + ((r.conflictFiles ?? []).isEmpty ? "the rebase" : (r.conflictFiles ?? []).joined(separator: ", ")) + ". Nothing merged."
        }
        let text = NSStackView(v: [NSTextField.text("\(n). \(r.name)  \(r.branch) → \(r.base)", size: 12.5, weight: .semibold, mono: true),
                                   NSTextField.text(what, size: 12, color: Palette.mut, lines: 2)], spacing: 2)
        text.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let tag = Chiplet(MergeChoice(r).title, icon: mark.view(size: 11), color: mark.color)
        let h = NSStackView(h: [mark.view(size: 14), text, Spacer(), tag], spacing: 8)
        h.alignment = .top
        h.setAccessibilityElement(true)
        h.setAccessibilityLabel("\(r.name): \(MergeChoice(r).title). \(what)")
        return h
    }

    private func run() {
        sheet.primaryButton?.isEnabled = false
        sheet.extraButton?.isEnabled = false
        result.stringValue = ""
        let fix = choice == .fix, remove = removeGroup.isOn, setDone = setDone.isOn && setDone.isEnabled, items = picks?.items, fixItem = fixItem
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if fix {
                    _ = try await desk.fix(item: fixItem)
                    finish()
                    return
                }
                let r = try await desk.merge(items: items, removeGroup: remove, setDone: setDone)
                if r.merged {
                    let window = self.parent
                    finish()
                    // The merge is done, but the daemon could not remove the group.
                    if let e = r.error { AlertConfirm.tell("\(self.desk.key) is merged", info: e, in: window) }
                } else {
                    show(r)
                }
            } catch {
                result.stringValue = "The daemon did not merge: " + ((error as? ProviderError)?.message ?? error.localizedDescription)
                sheet.primaryButton?.isEnabled = true
                updatePicks()
            }
        }
    }

    /// A conflict in the merge: the result of each repo, by part in a folded merge, and the fix as the next action.
    private func show(_ r: MergeResult) {
        var last: String?
        var lines: [String] = []
        for m in r.repos {
            if let item = m.item, item != last { lines.append(item) }
            last = m.item
            lines.append((m.item == nil ? "" : "   ") + Self.line(m))
        }
        result.stringValue = ([r.error ?? "A repo has a conflict. Nothing more merged."] + lines).joined(separator: "\n")
        fixItem = r.repos.first { $0.result == .conflict }?.item
        choice = .fix
        sheet.primaryButton?.title = MergeChoice.fix.title
        sheet.primaryButton?.isEnabled = true
        sheet.extraButton?.isHidden = true
    }

    static func line(_ m: RepoMerge) -> String {
        switch m.result {
        case .merged: return "✓ \(m.name): merged"
        case .rebased: return "✓ \(m.name): rebased and merged"
        case .conflict: return "✕ \(m.name): conflict in " + (m.conflictFiles ?? []).joined(separator: ", ")
        case .skipped: return "– \(m.name): not merged"
        }
    }

    private func finish() {
        sheet.dismiss()
        done()
    }

    func present(over parent: NSWindow?) {
        self.parent = parent
        sheet.present(over: parent)
        // The sheet keeps this object until it closes.
        sheet.onClose = { [self] in sheet.onClose = {} }
    }
}
