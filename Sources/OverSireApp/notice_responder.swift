import Foundation
import OverSireCore
import OverSireAssistant

/// Does the button of a notice. Each change goes through the action catalog, so it writes the same rows as the button in the app,
/// and a client sends it to the source app.
@MainActor final class NoticeResponder {
    /// The notice that a button is on.
    struct Pressed {
        var id: String
        var category: String
        var target: NoticeTarget
        var thread: String
    }

    private let actions: any ActionCatalog
    private let open: (Route) -> Void
    private let canStart: (String) -> Bool
    private let groom: (String) -> Void
    private let install: () -> Void
    private let post: (Notice) -> Void

    /// `canStart`: the item is planned and its project has a root, so Start work starts a session. Else it opens the item.
    /// `groom` gets the project store key.
    init(actions: any ActionCatalog, open: @escaping (Route) -> Void, canStart: @escaping (String) -> Bool, groom: @escaping (String) -> Void,
         install: @escaping () -> Void, post: @escaping (Notice) -> Void) {
        self.actions = actions
        self.open = open
        self.canStart = canStart
        self.groom = groom
        self.install = install
        self.post = post
    }

    /// `text`: the text of Reply.
    func handle(_ a: NoticeAction, on n: Pressed, text: String?) async {
        let t = n.target
        switch a {
        case .open: return
        case .markRead:
            guard let key = t.key else { return }
            await run(a, n, "item.markRead", ["key": .string(key)])
        case .reply:
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            if let q = t.question {
                await run(a, n, "question.answer", ["id": .string(q), "answer": .string(text)])
            } else if let key = t.key {
                // The user clicked Send already, so the outward send asks no more.
                let session = n.category == NoticeCategory.agentWaiting.id
                await run(a, n, session ? "session.send" : "item.comment", session ? ["key": .string(key), "text": .string(text)] : ["key": .string(key), "body": .string(text)])
            }
        case .answer(let label):
            guard let q = t.question else { return }
            await run(a, n, "question.answer", ["id": .string(q), "answer": .string(label)])
        case .approve, .deny:
            guard let q = t.question else { return }
            await run(a, n, "question.answer", ["id": .string(q), "answer": .string(a == .approve ? QuestionItem.allow : QuestionItem.deny)])
        case .rerunFailed:
            guard let repo = t.repo, let id = t.run else { return }
            await run(a, n, "ci.rerun", ["repo": .string(repo), "run": .string(id), "failedOnly": .bool(true)])
        case .startWork:
            guard let key = t.key else { return }
            if canStart(key) { await run(a, n, "session.start", ["key": .string(key)]) } else { open(.item(key, .overview)) }
        case .groom:
            if let p = t.project { groom(p) }
        case .openSession: if let key = t.key { open(.item(key, .session)) }
        case .reviewChanges: if let key = t.key { open(.item(key, .changes)) }
        case .openRun: if let key = t.key { open(.item(key, .runbook)) }
        case .openLogs:
            if let repo = t.repo, let id = t.run { open(.run(repo: repo, id: id)) } else { open(.settings(.logs)) }
        case .install: install()
        case .later: return
        }
    }

    private func run(_ a: NoticeAction, _ n: Pressed, _ id: String, _ values: [String: JSONValue]) async {
        switch await actions.run(id, ActionArgs(.object(values))) {
        case .ok: return
        case .failed(let why), .notAllowed(let why):
            post(.failed(a, id: n.id, subject: n.target.key ?? n.target.repo ?? "OverSire", reason: why, thread: n.thread, target: n.target))
        }
    }
}
