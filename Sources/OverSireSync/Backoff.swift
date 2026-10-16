import Foundation

/// 1, 2, 4 … 60 s, with up to 20% jitter.
public struct Backoff: Sendable {
    public private(set) var attempt = 0
    public let cap: Duration

    public init(cap: Duration = .seconds(60)) { self.cap = cap }

    public mutating func next(jitter: Double = Double.random(in: 0...0.2)) -> Duration {
        let base = min(cap, .seconds(1) * (1 << min(attempt, 16)))
        attempt += 1
        return base * (1 + jitter)
    }

    public mutating func reset() { attempt = 0 }
}

/// Keeps the last event ids, so a repeated event is handled once.
public struct RecentIDs: Sendable {
    public let capacity: Int
    private var order: [String] = []
    private var set = Set<String>()

    public init(capacity: Int = 2000) { self.capacity = capacity }

    public func contains(_ id: String) -> Bool { set.contains(id) }

    /// False if the id is a repeat.
    @discardableResult
    public mutating func insert(_ id: String) -> Bool {
        guard set.insert(id).inserted else { return false }
        order.append(id)
        if order.count > capacity { set.remove(order.removeFirst()) }
        return true
    }
}
