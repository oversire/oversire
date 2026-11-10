import Foundation

// ─── Call priority ───────────────────────────────────────────────────────────
// A person waits for a user call. A background call (poll, refresh, automation) can wait longer.

public enum CallPriority: Int, Comparable, Sendable {
    case background = 0
    case user = 1

    public static func < (a: CallPriority, b: CallPriority) -> Bool { a.rawValue < b.rawValue }

    /// A `Task {}` and a child task inherit it. `Task.detached` does not.
    @TaskLocal public static var current: CallPriority = .background

    public static func run<T>(_ p: CallPriority, _ op: () async throws -> T) async rethrows -> T {
        try await $current.withValue(p, operation: op)
    }

    /// Starts a task that runs with the priority. The task keeps the isolation of no actor.
    @discardableResult
    public static func task(_ p: CallPriority, _ op: @escaping @Sendable () async -> Void) -> Task<Void, Never> {
        $current.withValue(p) { Task(operation: op) }
    }

    public static func user<T>(_ op: () async throws -> T) async rethrows -> T {
        try await run(.user, op)
    }
}

/// The wait of one request at the rate gate. `GatedTransport` sets it, and the HTTP log reads it.
public struct GateWait: Sendable, Equatable {
    public var ms: Int
    public var priority: CallPriority

    public init(ms: Int, priority: CallPriority) {
        self.ms = ms
        self.priority = priority
    }

    @TaskLocal public static var current: GateWait? = nil
}
