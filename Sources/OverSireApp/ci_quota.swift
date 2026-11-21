import Foundation
import OverSireCore

/// The GitHub quota for the CI keepers. Below 10 % left, the keepers fetch less.
@MainActor
final class CIQuota {
    private let meter: RateMeter
    private let monitor: RateLimitMonitor
    private let live: () -> Bool
    private let clock: () -> Date
    private var handlers: [() -> Void] = []
    private var lastDegraded = false
    private var lastSource = CISource.poll

    init(meter: RateMeter, monitor: RateLimitMonitor, live: @escaping () -> Bool, clock: @escaping () -> Date = Date.init) {
        self.meter = meter
        self.monitor = monitor
        self.live = live
        self.clock = clock
        lastDegraded = degraded
        lastSource = source
    }

    /// The lower of the REST budget from the answers and the budget of the footer monitor.
    var budget: RateBudget? {
        let now = clock()
        let kept = monitor.latest?.budget.flatMap { $0.resetAt > now ? $0 : nil }
        return [meter.lowest(now: now), kept].compactMap { $0 }.min { $0.share < $1.share }
    }

    var degraded: Bool {
        guard let b = budget else { return false }
        return b.remaining < b.limit / 10
    }

    var source: CISource { live() ? .webhook : .poll }

    /// `f` runs when `degraded` or `source` changes. Call `evaluate` after a poll or a change of the link.
    func onChange(_ f: @escaping () -> Void) { handlers.append(f) }

    func evaluate() {
        let (d, s) = (degraded, source)
        guard d != lastDegraded || s != lastSource else { return }
        lastDegraded = d
        lastSource = s
        handlers.forEach { $0() }
    }
}

private extension RateBudget {
    var share: Double { limit > 0 ? Double(remaining) / Double(limit) : 1 }
}
