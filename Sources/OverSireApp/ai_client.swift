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

    convenience init(cfg: AIConfig, key: String?, store: (any Store)? = STORE_WRITES.store) {
        self.init(cfg: cfg, router: AIRouter(engines: Self.engines(cfg, key: key), store: store, skipped: Self.skipped))
    }

    // The saved config, when AI is on.
    static var current: AIClient? {
        let key = keyStore.get(keyName)
        guard AI_CFG.isOn(key: key) else { return nil }
        return AIClient(cfg: AI_CFG, key: key)
    }

    // The local CLI first, then the API key when it is the fallback and its Test passed.
    static func engines(_ cfg: AIConfig, key: String?) -> [any AIEngine] {
        let api: [any AIEngine] = key.map { [APIKeyEngine(config: cfg.apiKey, key: $0, http: URLSessionTransport())] } ?? []
        guard cfg.engine == .localCLI else { return api }
        return [LocalCLI.shared.engine(cfg)] + (cfg.fallback == .apiKey && cfg.keyVerified(key) ? api : [])
    }

    static let skipped: @Sendable (EngineID, AIError) -> Void = { id, e in
        log.warning("AI engine \(id.rawValue, privacy: .public) skipped: \(e.message, privacy: .public)")
    }

    static let retryDelay: TimeInterval = 120

    /// `done` runs on the main queue. `id`: a task with the same id replaces the stored result.
    /// With the fallback "wait", a task that the CLI cannot run now tries once more after `retryDelay`.
    func run(_ kind: AITaskKind, _ input: AIInput, id: String = UUID().uuidString, subject: SubjectRef? = nil,
             done: @escaping (Result<String, AIError>) -> Void) {
        let (router, task) = (router, AITask(id: id, kind: kind, subject: subject, input: input))
        let retry = cfg.engine == .localCLI && cfg.fallback == .wait && kind != .ping
        Task {
            var r = await Self.attempt(router, task)
            if retry, case .failure(.unavailable) = r {
                try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1e9))
                r = await Self.attempt(router, task)
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    private static func attempt(_ router: AIRouter, _ task: AITask) async -> Result<String, AIError> {
        do { return .success(try await router.run(task).text) } catch {
            return .failure(error as? AIError ?? .network(error.localizedDescription))
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
