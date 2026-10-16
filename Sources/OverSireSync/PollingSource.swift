import Foundation
import OverSireCore

/// Polls each provider in its own loop and keeps each cursor on disk.
public actor PollingSource: EventSource {
    private let providers: [any Provider]
    private let cursors: CursorStore
    private let clock: any Clock<Duration>
    private var intervals: PollIntervals
    private var active: Set<AccountID> = []
    private var busy: Set<AccountID> = []
    private var cloudLive = false
    private var errors: [AccountID: String] = [:]
    private var loops: [Task<Void, Never>] = []
    private var sleepers: [AccountID: Task<Void, Never>] = [:]
    private var pokes: Set<AccountID> = []
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var generation = 0

    public init(providers: [any Provider], cursors: CursorStore, clock: any Clock<Duration> = ContinuousClock(),
                intervals: PollIntervals = PollIntervals()) {
        self.providers = providers
        self.cursors = cursors
        self.clock = clock
        self.intervals = intervals
    }

    public nonisolated func events() -> AsyncStream<ProviderEvent> {
        let (stream, cont) = AsyncStream.makeStream(of: ProviderEvent.self)
        Task { await self.start(cont) }
        return stream
    }

    public func health() -> SourceHealth {
        guard continuation != nil else { return .off }
        return errors.values.sorted().first.map(SourceHealth.failed) ?? .live
    }

    public var isCloudLive: Bool { cloudLive }

    public func setIntervals(_ i: PollIntervals) { intervals = i }

    /// Accounts with a run in progress poll at the active interval. A new one polls now.
    public func setActive(_ accounts: Set<AccountID>) {
        let new = accounts.subtracting(active)
        active = accounts
        if !cloudLive { new.forEach(pollNow) }
    }

    /// A live cloud pushes changes, so polling slows to the safety interval.
    /// When the cloud drops, each account polls now to catch up.
    public func setCloudLive(_ live: Bool) {
        guard live != cloudLive else { return }
        cloudLive = live
        if !live { providers.map(\.account).forEach(pollNow) }
    }

    public func pollNow(_ account: AccountID) {
        pokes.insert(account)
        sleepers[account]?.cancel()
    }

    public func stop() {
        loops.forEach { $0.cancel() }
        sleepers.values.forEach { $0.cancel() }
        loops = []
        sleepers = [:]
        continuation?.finish()
        continuation = nil
    }

    func mode(_ account: AccountID) -> PollMode {
        cloudLive ? .safety : active.contains(account) || busy.contains(account) ? .active : .normal
    }

    private func start(_ cont: AsyncStream<ProviderEvent>.Continuation) {
        stop()
        generation += 1
        let gen = generation
        continuation = cont
        cont.onTermination = { _ in Task { await self.stop(generation: gen) } }
        loops = providers.map { p in Task { await self.loop(p, generation: gen) } }
    }

    private func stop(generation gen: Int) {
        if gen == generation { stop() }
    }

    private func loop(_ p: any Provider, generation gen: Int) async {
        var plan = PollScheduler(policy: p.pollPolicy, intervals: intervals)
        while !Task.isCancelled {
            var budget: RateBudget?
            do {
                let page = try await p.poll(since: cursors[p.account])
                guard !Task.isCancelled, gen == generation else { return }
                page.events.forEach { continuation?.yield($0) }
                cursors[p.account] = page.cursor
                budget = page.budget
                if budget == nil, let r = p as? any RateReporting { budget = try? await r.budget() }
                if page.busy { busy.insert(p.account) } else { busy.remove(p.account) }
                plan.succeeded(retryAfter: page.retryAfter)
                errors[p.account] = nil
            } catch is CancellationError {
                return
            } catch {
                plan.failed(error)
                errors[p.account] = (error as? ProviderError)?.message ?? error.localizedDescription
            }
            plan.intervals = intervals
            let delay = plan.delay(mode: mode(p.account), budget: budget)
            if pokes.remove(p.account) != nil { continue }
            let sleeper = Task { [clock] in _ = try? await clock.sleep(for: delay) }
            sleepers[p.account] = sleeper
            await sleeper.value
            guard gen == generation else { return }
            sleepers[p.account] = nil
            pokes.remove(p.account)
        }
    }
}
