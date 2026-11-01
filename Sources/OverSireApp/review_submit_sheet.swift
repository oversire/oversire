import Cocoa
import OverSireCore

// ─── Submit review ───────────────────────────────────────────────────────────
// One submit sends all pending comments as one round (OVERSIRE-372). The daemon of the review sends the prompt
// to the session. The app writes the tracker parts: the round comment, and Todo for an approved plan.

final class ReviewSubmitSheet {
    private let desk: ReviewDesk
    private let done: (ReviewVerdict) -> Void
    private let sheet: DialogSheet
    private let summary: CommentField
    private var verdict: ReviewVerdict
    private let post: CheckBox
    private let target: NSTextField
    private let preview: NSTextField
    private let error: NSTextField

    init(desk: ReviewDesk, verdict: ReviewVerdict? = nil, done: @escaping (ReviewVerdict) -> Void) {
        self.desk = desk
        self.done = done
        self.verdict = verdict ?? (desk.pending.isEmpty ? .approve : .requestChanges)
        let n = desk.pending.count
        let what = desk.kind == .plan ? "plan" : "code"
        sheet = DialogSheet(title: "Submit \(what) review · round \(desk.nextRound)", width: 560)
        _ = sheet.note("\(desk.key) · \(n) pending comment\(n == 1 ? "" : "s") · machine \(desk.machine)")
        summary = CommentField("", placeholder: "Summary for the agent (optional)", label: "Summary for the agent")
        post = CheckBox("Also post the round on the Plane item", on: false, label: "Also post the round on the Plane item")
        target = .text("", size: 12.5, color: Palette.mut, lines: 3)
        preview = .text("", size: 11, color: Palette.mut, lines: 14, mono: true)
        error = .text("", size: 12, color: Palette.bad, lines: 3)
        build()
    }

    private func build() {
        sheet.stack.addFull(summary)
        let choice = Segmented(["Request changes", "Approve"], selected: verdict == .approve ? 1 : 0, label: "Verdict") { [weak self] i in
            self?.verdict = i == 1 ? .approve : .requestChanges
            self?.update()
        }
        sheet.stack.addFull(NSStackView(h: [NSTextField.text("Verdict", size: 12.5, weight: .semibold), choice, Spacer()], spacing: 10))
        sheet.stack.addFull(target)
        let box = Box(fill: Palette.raise, border: Palette.line, radius: 8)
        box.addSubview(preview)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), preview.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
            preview.topAnchor.constraint(equalTo: box.topAnchor, constant: 8), preview.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
        ])
        preview.setAccessibilityLabel("Prompt preview")
        sheet.stack.addFull(box)
        sheet.stack.addFull(post)
        _ = sheet.note("The daemon on \(desk.machine) sends it, so this works from any Mac. Plane writes go through the app.")
        sheet.stack.addFull(error)
        sheet.buttons(cancel: "Cancel", primary: "Submit review", onCancel: { [weak self] in self?.sheet.dismiss() }, onPrimary: { [weak self] in self?.send() })
        update()
    }

    /// The session text, the prompt preview and the button title for the verdict.
    private func update() {
        let session = desk.summary.session
        let who = session?.harness.map { "The \($0) session" } ?? "The session"
        var button = "Submit review"
        if verdict == .approve {
            preview.stringValue = "Approve sends no prompt to the agent."
            if desk.kind == .plan {
                target.stringValue = "Approve sets \(desk.key) and its sub-items to Todo. Then the queue can take them. Approve writes to Plane through the app."
                button = "Approve plan"
            } else {
                target.stringValue = "Approve opens the merge next. Nothing merges before you confirm."
                button = "Approve, then merge…"
            }
        } else {
            preview.stringValue = desk.prompt(summary: summary.stringValue)
            switch session?.state {
            case .idle?:
                target.stringValue = "\(who) is idle. It gets the prompt now."
            case .working?:
                target.stringValue = "\(who) works now. The prompt waits for the end of its turn, then the daemon sends it."
                button = "Submit, send at end of turn"
            default:
                target.stringValue = "The session has ended. The daemon starts a new session in the same place with the prompt."
            }
        }
        sheet.primaryButton?.title = button
        sheet.primaryButton?.isEnabled = verdict == .approve || !desk.pending.isEmpty || !summary.stringValue.isEmpty
    }

    private func send() {
        let v = verdict
        sheet.primaryButton?.isEnabled = false
        error.stringValue = ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await desk.submit(v, summary: summary.stringValue, post: post.isOn)
                sheet.dismiss()
                done(v)
            } catch {
                self.error.stringValue = "The submit failed: " + ((error as? ProviderError)?.message ?? error.localizedDescription)
                sheet.primaryButton?.isEnabled = true
            }
        }
    }

    func present(over parent: NSWindow?) {
        sheet.present(over: parent)
        // The sheet keeps this object until it closes.
        let typing = NotificationCenter.default.addObserver(forName: NSControl.textDidChangeNotification, object: summary, queue: .main) { [weak self] _ in
            self?.update()
        }
        sheet.onClose = { [self] in
            NotificationCenter.default.removeObserver(typing)
            sheet.onClose = {}
        }
    }
}
