import Foundation
import os
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
            var r = await Self.attempt(router, task, cfg: self.cfg)
            if retry, case .failure(.unavailable) = r {
                try? await Task.sleep(nanoseconds: UInt64(Self.retryDelay * 1e9))
                r = await Self.attempt(router, task, cfg: self.cfg)
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    // Writes one log line for the task, and one warning for each engine that the router passed over.
    private static func attempt(_ router: AIRouter, _ task: AITask, cfg: AIConfig) async -> Result<String, AIError> {
        let skips = OSAllocatedUnfairLock(initialState: [(EngineID, AIError)]())
        let start = Date()
        let r: Result<AIResult, AIError>
        do {
            r = .success(try await router.with { id, e in skips.withLock { $0.append((id, e)) }; Self.skipped(id, e) }.run(task))
        } catch {
            r = .failure(error as? AIError ?? .network(error.localizedDescription))
        }
        guard task.kind != .ping else { return r.map(\.text) }
        let job = jobName(task.kind)
        let subject = task.id.split(separator: ":", maxSplits: 1).dropFirst().first.map(String.init)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        let passed = skips.withLock { $0 }
        for (id, e) in passed where e != .notConfigured {
            APP_LOG.write(LogEntry(level: .warn, area: .ai, job: job, subject: subject, host: id.rawValue, message: "Skipped: \(e.message)"))
        }
        let used = (try? r.get())?.engine ?? router.engines.map(\.id).first { id in !passed.contains { $0.0 == id } } ?? passed.first?.0
        var e: LogEntry
        switch r {
        case .success(let res):
            e = LogEntry(level: .ok, area: .ai, job: job, subject: subject, host: res.engine.rawValue, message: "Done", ms: ms)
            e.output = String(res.text.prefix(4000))
        case .failure(let err):
            e = LogEntry(level: .error, area: .ai, job: job, subject: subject, host: used?.rawValue, message: err.message, ms: ms)
        }
        e.engine = (used ?? .apiKey).rawValue
        e.model = used == .localCLI ? [cfg.cliHarness, cfg.cliModel].filter { !$0.isEmpty }.joined(separator: " · ") : cfg.apiKey.model
        e.input = (try? task.kind.prompt(task.input)).map { String($0.user.prefix(4000)) }
        APP_LOG.write(e)
        return r.map(\.text)
    }

    static func jobName(_ k: AITaskKind) -> String {
        switch k {
        case .status: return "Status"
        case .itemSummary, .sessionSummary: return "Summary"
        case .sessionEnd: return "Session end"
        case .failureReason: return "CI cause"
        case .digest: return "CI digest"
        case .order: return "Queue order"
        case .draft: return "Titles"
        case .tidy: return "Tidy"
        case .triage: return "Triage"
        case .question: return "Question"
        case .changeSummary: return "PR summary"
        case .check: return "Check"
        default: return k.rawValue
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
