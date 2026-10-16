import Foundation
import OverSireCore
import OverSireAI

/// An AI engine with set replies by task kind. Each task is kept.
public final class FakeAIEngine: AIEngine, @unchecked Sendable {
    public let id: EngineID
    private let lock = NSLock()
    private var isAvailable: Bool
    private var replies: [AITaskKind: Result<String, AIError>] = [:]
    private var ran: [AITask] = []

    public init(id: EngineID = "fake", available: Bool = true) {
        self.id = id
        isAvailable = available
    }

    public var tasks: [AITask] { lock.withLock { ran } }

    public func setAvailable(_ on: Bool) { lock.withLock { isAvailable = on } }

    public func on(_ kind: AITaskKind, _ reply: Result<String, AIError>) { lock.withLock { replies[kind] = reply } }

    public func available() async -> Bool { lock.withLock { isAvailable } }

    public func run(_ task: AITask) async throws -> String {
        let reply = lock.withLock {
            ran.append(task)
            return replies[task.kind] ?? .success("ok")
        }
        return try reply.get()
    }
}
