import Foundation

/// A clock that moves only when a test calls advance(by:).
public final class ManualClock: Clock, @unchecked Sendable {
    public struct Instant: InstantProtocol {
        public var offset: Duration
        public func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        public func duration(to other: Instant) -> Duration { other.offset - offset }
        public static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper {
        let id: UUID
        let deadline: Instant
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [Sleeper] = []
    private var slept: [Duration] = []

    public init() {}

    public var now: Instant { lock.withLock { current } }
    public var minimumResolution: Duration { .zero }

    /// The durations of all sleeps so far, in order.
    public var sleeps: [Duration] { lock.withLock { slept } }
    public var sleeperCount: Int { lock.withLock { sleepers.count } }

    public func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let ready: Bool = lock.withLock {
                    slept.append(current.duration(to: deadline))
                    if deadline <= current || Task.isCancelled { return true }
                    sleepers.append(Sleeper(id: id, deadline: deadline, continuation: c))
                    return false
                }
                if ready { Task.isCancelled ? c.resume(throwing: CancellationError()) : c.resume() }
            }
        } onCancel: {
            let s = lock.withLock { () -> Sleeper? in
                guard let i = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return sleepers.remove(at: i)
            }
            s?.continuation.resume(throwing: CancellationError())
        }
    }

    public func advance(by d: Duration) {
        let due: [Sleeper] = lock.withLock {
            current = current.advanced(by: d)
            let due = sleepers.filter { $0.deadline <= current }
            sleepers.removeAll { $0.deadline <= current }
            return due
        }
        due.forEach { $0.continuation.resume() }
    }

    /// Waits until n tasks sleep on this clock. Fails after about 2 s of real time.
    public func waitForSleepers(_ n: Int = 1) async throws {
        for _ in 0..<2000 {
            if sleeperCount >= n { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CancellationError()
    }
}
