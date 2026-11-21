import Foundation

/// The newest rate budget that each login has seen, for each API resource. A client records, the app reads.
public final class RateMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var budgets: [String: RateBudget] = [:]

    public init() {}

    /// `key` names the login. `resource` is the quota bucket, for example `core` or `graphql`.
    /// An older window is ignored. In the same window, the lower value wins, because answers can arrive out of order.
    public func record(_ b: RateBudget, key: String, resource: String = "core") {
        let k = key + "/" + resource
        lock.withLock {
            if let old = budgets[k] {
                if b.resetAt < old.resetAt { return }
                if b.resetAt == old.resetAt, b.remaining > old.remaining { return }
            }
            budgets[k] = b
        }
    }

    /// The budget of `resource` with the smallest share left. A budget with a window in the past is ignored.
    public func lowest(now: Date, resource: String = "core") -> RateBudget? {
        lock.withLock {
            budgets.filter { $0.key.hasSuffix("/" + resource) }.values
                .filter { $0.resetAt > now && $0.limit > 0 }
                .min { Double($0.remaining) / Double($0.limit) < Double($1.remaining) / Double($1.limit) }
        }
    }
}
