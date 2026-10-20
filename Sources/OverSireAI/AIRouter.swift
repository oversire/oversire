import Foundation
import OverSireCore

/// Runs a task on the first available engine. The AI settings give the order.
/// Today: the local CLI, then the API key as its fallback. Later: cloud credits.
public struct AIRouter: Sendable {
    public static let keep = 200

    public let engines: [any AIEngine]
    let store: (any Store)?
    let now: @Sendable () -> Date
    /// Gets each engine that the router passes over, and why. The app writes it to the log.
    let skipped: (@Sendable (EngineID, AIError) -> Void)?

    public init(engines: [any AIEngine], store: (any Store)? = nil, now: @escaping @Sendable () -> Date = Date.init,
                skipped: (@Sendable (EngineID, AIError) -> Void)? = nil) {
        self.engines = engines
        self.store = store
        self.now = now
        self.skipped = skipped
    }

    /// A copy that reports the skipped engines to `skipped`, for one task.
    public func with(skipped: @escaping @Sendable (EngineID, AIError) -> Void) -> AIRouter {
        AIRouter(engines: engines, store: store, now: now, skipped: skipped)
    }

    public func run(_ task: AITask) async throws -> AIResult {
        var last = AIError.notConfigured
        for e in engines {
            guard await e.available() else {
                skipped?(e.id, .notConfigured)
                continue
            }
            do {
                let r = AIResult(task: task.id, engine: e.id, text: try await e.run(task), at: now())
                if task.kind != .ping { await save(r) }
                return r
            } catch let AIError.unavailable(why) {
                last = .unavailable(why)
                skipped?(e.id, last)
            }
        }
        throw last
    }

    // A lost result costs only a new AI call, so a store error does not fail the task.
    private func save(_ r: AIResult) async {
        guard let store else { return }
        try? await store.put(r)
        guard let all = try? await store.all(AIResult.self), all.count > Self.keep else { return }
        for old in all.sorted(by: { $0.at < $1.at }).prefix(all.count - Self.keep) {
            try? await store.delete(AIResult.self, id: old.id)
        }
    }
}
