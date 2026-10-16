import Foundation
import OverSireCore

public struct PollIntervals: Hashable, Sendable {
    public var normal: Duration
    public var active: Duration       // a run is in progress and the user looks
    public var safety: Duration       // the cloud pushes changes; polling only reconciles
    public var maxBackoff: Duration

    public init(normal: Duration = .seconds(30), active: Duration = .seconds(10), safety: Duration = .seconds(600),
                maxBackoff: Duration = .seconds(600)) {
        self.normal = normal
        self.active = active
        self.safety = safety
        self.maxBackoff = maxBackoff
    }
}

public enum PollMode: Hashable, Sendable {
    case normal, active, safety
}

/// The poll cadence of one account. It obeys the vendor PollPolicy, backs off on errors
/// and keeps a reserve of the rate budget for the user's own actions.
public struct PollScheduler: Sendable {
    public let policy: PollPolicy
    public var intervals: PollIntervals
    public private(set) var failures = 0
    private var retryAfter: Duration?

    public init(policy: PollPolicy, intervals: PollIntervals = PollIntervals()) {
        self.policy = policy
        self.intervals = intervals
    }

    public mutating func succeeded(retryAfter: Duration? = nil) {
        failures = 0
        self.retryAfter = retryAfter
    }

    public mutating func failed(_ error: Error) {
        failures += 1
        if case ProviderError.rateLimited(let after) = error { retryAfter = after } else { retryAfter = nil }
    }

    public func delay(mode: PollMode, budget: RateBudget? = nil, now: Date = Date()) -> Duration {
        let base: Duration
        switch mode {
        case .normal: base = intervals.normal
        case .active: base = intervals.active
        case .safety: base = intervals.safety
        }
        var d = max(base, policy.minInterval)
        if failures > 0 { d = max(d, min(intervals.maxBackoff, d * (1 << min(failures, 16)))) }
        if let r = retryAfter { d = max(d, r) }
        if let b = budget, b.limit > 0 {
            let untilReset = Duration.seconds(max(0, b.resetAt.timeIntervalSince(now)))
            let reserve = b.limit / 10
            d = b.remaining <= reserve ? max(d, untilReset) : max(d, untilReset / (b.remaining - reserve))
        }
        return d
    }
}
