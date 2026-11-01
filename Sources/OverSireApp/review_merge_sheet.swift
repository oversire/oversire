import Cocoa
import OverSireCore

// ─── Merge ───────────────────────────────────────────────────────────────────
// The local merge of a worktree group (OVERSIRE-372). The daemon merges each repo in order: a fast-forward,
// or a rebase and then a fast-forward. A conflict merges nothing; the agent rebases and fixes it.
// Nothing is pushed. With "Set Done", the app sets the item and its sub-items to Done, with a merge comment.

final class ReviewMergeSheet {
    private let desk: ReviewDesk
    private let done: () -> Void
    private let sheet: DialogSheet
    private let removeGroup: CheckBox
    private let setDone: CheckBox
    private let result: NSTextField
    private var choice: MergeChoice

    init(desk: ReviewDesk, done: @escaping () -> Void) {
        self.desk = desk
        self.done = done
        let s = desk.summary
        choice = MergeChoice.primary(s.repos)
        sheet = DialogSheet(title: choice == .fix ? "Fix the conflict of \(s.key)" : "Merge \(s.key)", width: 600)
        _ = sheet.note("The daemon on \(s.machine) merges each repo locally, in this order. Nothing is pushed.")
        let group = s.group.map { ($0 as NSString).lastPathComponent } ?? "the group"
        removeGroup = CheckBox("Remove the worktree group .wt/\(group) after all repos merge", on: true)
        setDone = CheckBox("Set \(s.key) to Done and its sub-items, with a merge comment", on: true)
        result = .text("", size: 12, color: Palette.bad, lines: 6)
        build()
    }

    private func build() {
        let s = desk.summary
        let list = Card(padding: 10, spacing: 8, fill: Palette.raise)
        for (i, r) in s.repos.enumerated() { list.add(row(i + 1, r)) }
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
        if s.state == .waiting { _ = sheet.note("The agent works on the last round. The daemon refuses a merge until it hands off.", color: Palette.warn) }
        sheet.stack.addFull(result)
        sheet.buttons(cancel: "Cancel", primary: choice.title, onCancel: { [weak self] in self?.sheet.dismiss() }, onPrimary: { [weak self] in self?.run() })
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
        result.stringValue = ""
        let fix = choice == .fix, remove = removeGroup.isOn, setDone = setDone.isOn
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if fix {
                    _ = try await desk.fix()
                    finish()
                    return
                }
                let r = try await desk.merge(removeGroup: remove, setDone: setDone)
                if r.merged {
                    finish()
                } else {
                    show(r)
                }
            } catch {
                result.stringValue = "The daemon did not merge: " + ((error as? ProviderError)?.message ?? error.localizedDescription)
                sheet.primaryButton?.isEnabled = true
            }
        }
    }

    /// A conflict in the merge: the result of each repo, and the fix as the next action.
    private func show(_ r: MergeResult) {
        let lines = r.repos.map { m -> String in
            switch m.result {
            case .merged: return "✓ \(m.name): merged"
            case .rebased: return "✓ \(m.name): rebased and merged"
            case .conflict: return "✕ \(m.name): conflict in " + (m.conflictFiles ?? []).joined(separator: ", ")
            case .skipped: return "– \(m.name): not merged"
            }
        }
        result.stringValue = ([r.error ?? "A repo has a conflict. Nothing more merged."] + lines).joined(separator: "\n")
        choice = .fix
        sheet.primaryButton?.title = MergeChoice.fix.title
        sheet.primaryButton?.isEnabled = true
    }

    private func finish() {
        sheet.dismiss()
        done()
    }

    func present(over parent: NSWindow?) {
        sheet.present(over: parent)
        // The sheet keeps this object until it closes.
        sheet.onClose = { [self] in sheet.onClose = {} }
    }
}
