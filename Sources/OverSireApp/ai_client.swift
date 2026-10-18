import Foundation
import OverSireCore
import OverSireAI

// ─── AI client ───────────────────────────────────────────────────────────────
// The app side of OverSireAI: it builds AI tasks and gives the replies to the main queue.

final class AIClient {
    static let keyStore = SecretStore(service: "com.oversire.app.ai")
    static let keyName = "API_KEY"

    let cfg: AIConfig
    let router: AIRouter

    init(cfg: AIConfig, router: AIRouter) {
        self.cfg = cfg
        self.router = router
    }

    convenience init(cfg: AIConfig, key: String, store: (any Store)? = STORE_WRITES.store) {
        self.init(cfg: cfg, router: AIRouter(engines: [APIKeyEngine(config: cfg.apiKey, key: key, http: URLSessionTransport())], store: store))
    }

    // The saved config, when AI is on.
    static var current: AIClient? {
        let key = keyStore.get(keyName)
        guard AI_CFG.isOn(key: key), let key else { return nil }
        return AIClient(cfg: AI_CFG, key: key)
    }

    /// `done` runs on the main queue. `id`: a task with the same id replaces the stored result.
    func run(_ kind: AITaskKind, _ input: AIInput, id: String = UUID().uuidString, subject: SubjectRef? = nil,
             done: @escaping (Result<String, AIError>) -> Void) {
        let (router, task) = (router, AITask(id: id, kind: kind, subject: subject, input: input))
        Task {
            let r: Result<String, AIError>
            do { r = .success(try await router.run(task).text) } catch {
                r = .failure(error as? AIError ?? .network(error.localizedDescription))
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    func test(done: @escaping (Result<TimeInterval, AIError>) -> Void) {
        let start = Date()
        run(.ping, AIInput(text: "ping")) { r in done(r.map { _ in Date().timeIntervalSince(start) }) }
    }

    func draft(body: String, ctx: DraftContext, done: @escaping (Result<DraftSuggestion, AIError>) -> Void) {
        run(.draft, ctx.input(body: body, extra: cfg.extraContext)) { r in
            done(r.flatMap { text in
                DraftSuggestion.parse(text, ctx: ctx).map { .success($0) } ?? .failure(.badReply(String(text.prefix(80))))
            })
        }
    }

    func tidy(body: String, done: @escaping (Result<String, AIError>) -> Void) {
        run(.tidy, AIInput(text: body, context: ["extra": cfg.extraContext])) { r in
            done(r.flatMap { text in
                let t = unfenced(text)
                return t.isEmpty ? .failure(.badReply("empty")) : .success(t)
            })
        }
    }
}
