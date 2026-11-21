import Foundation
import OverSireCore

/// Polls the commits that agents wait on (`CIWatch`) at the active interval, with ETags.
/// One loop for each repo, so a repo has one request in flight. A repo with a live webhook polls at the guard interval.
/// The quota rule is `degraded`: below the threshold, no interest poll runs.
public actor InterestPoller: EventSource {
    private struct Entry {
        var watch: CIWatch
        var cursor: Cursor?
        var scheduler: PollScheduler?
        var holdUntil: Date?
    }

    private let providers: @Sendable (String) -> (any CommitPolling)?
    private let interval: Duration
    private let guardInterval: Duration
    private let clock: any Clock<Duration>
    private let now: @Sendable () -> Date
    private let degraded: @Sendable () async -> Bool
    private var entries: [String: Entry] = [:]
    private var hooked: Set<String> = []
    private var loops: [String: Task<Void, Never>] = [:]
    private var sleepers: [String: Task<Void, Never>] = [:]
    private var pokes: Set<String> = []
    private var paused = false
    private var errors: [String: String] = [:]
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var generation = 0

    /// `providers` gives the CI adapter of a repo, or nil when it cannot poll one commit (the repo keeps the normal poll).
    public init(providers: @escaping @Sendable (String) -> (any CommitPolling)?, interval: Duration = PollIntervals().active,
                guardInterval: Duration = .seconds(60), clock: any Clock<Duration> = ContinuousClock(),
                now: @escaping @Sendable () -> Date = Date.init, degraded: @escaping @Sendable () async -> Bool) {
        self.providers = providers
        self.interval = interval
        self.guardInterval = guardInterval
        self.clock = clock
        self.now = now
        self.degraded = degraded
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

    /// Replaces the watch set. An expired watch drops. A new watch gets a poll at once.
    public func setWatches(_ list: [CIWatch]) {
        let t = now()
        var next: [String: Entry] = [:]
        var added: Set<String> = []
        for w in list where (w.expiresAt ?? .distantFuture) > t {
            guard let key = Self.key(w) else { continue }
            if let old = entries[key] {
                next[key] = Entry(watch: w, cursor: old.cursor, scheduler: old.scheduler, holdUntil: old.holdUntil)
            } else {
                next[key] = Entry(watch: w)
                added.insert(w.repo.lowercased())
            }
        }
        entries = next
        errors = errors.filter { next[$0.key] != nil }
        guard continuation != nil else { return }
        reconcile(poke: added)
    }

    /// The repos that get live webhook events. They poll at the guard interval.
    public func setHooked(_ repos: Set<String>) { hooked = Set(repos.map { $0.lowercased() }) }

    public func stop() {
        loops.values.forEach { $0.cancel() }
        sleepers.values.forEach { $0.cancel() }
        loops = [:]
        sleepers = [:]
        continuation?.finish()
        continuation = nil
    }

    /// The identity of a watch: its id, else repo and sha or branch. nil: nothing to poll.
    static func key(_ w: CIWatch) -> String? {
        guard let target = interest(w) else { return nil }
        return w.id ?? "\(w.repo)@\(target.sha ?? target.branch ?? "")"
    }

    static func interest(_ w: CIWatch) -> CIInterest? {
        if let sha = w.sha, !sha.isEmpty { return CIInterest(repo: w.repo, sha: sha) }
        if let b = w.branch, !b.isEmpty { return CIInterest(repo: w.repo, branch: b) }
        // A ref like "#86" needs the daemon to name the commit.
        return w.ref.hasPrefix("#") || w.ref.isEmpty ? nil : CIInterest(repo: w.repo, branch: w.ref)
    }

    // MARK: Loops

    private func start(_ cont: AsyncStream<ProviderEvent>.Continuation) {
        stop()
        generation += 1
        let gen = generation
        continuation = cont
        cont.onTermination = { _ in Task { await self.stop(generation: gen) } }
        reconcile(poke: [])
    }

    private func stop(generation gen: Int) {
        if gen == generation { stop() }
    }

    private func reconcile(poke added: Set<String>) {
        let gen = generation
        let repos = Set(entries.values.map { $0.watch.repo.lowercased() })
        for repo in repos {
            if loops[repo] == nil {
                loops[repo] = Task { await self.loop(repo, generation: gen) }
            } else if added.contains(repo) {
                pokes.insert(repo)
                sleepers[repo]?.cancel()
            }
        }
    }

    private func loop(_ repo: String, generation gen: Int) async {
        while !Task.isCancelled, gen == generation {
            let keys = entries.filter { $0.value.watch.repo.lowercased() == repo }.keys.sorted()
            if keys.isEmpty {
                loops[repo] = nil
                return
            }
            await pass(keys)
            guard !Task.isCancelled, gen == generation else { return }
            if pokes.remove(repo) != nil { continue }
            let sleeper = Task { [clock, delay = delay(repo)] in _ = try? await clock.sleep(for: delay) }
            sleepers[repo] = sleeper
            await sleeper.value
            guard gen == generation else { return }
            sleepers[repo] = nil
            pokes.remove(repo)
        }
    }

    private func delay(_ repo: String) -> Duration { hooked.contains(repo) ? guardInterval : interval }

    private func pass(_ keys: [String]) async {
        if await degraded() { return }
        paused = false
        for key in keys {
            guard !Task.isCancelled, !paused, let e = entries[key], let target = Self.interest(e.watch) else { continue }
            if let exp = e.watch.expiresAt, exp <= now() {
                entries[key] = nil
                continue
            }
            if let hold = e.holdUntil, hold > now() { continue }
            guard let provider = providers(target.repo) else { continue }
            await poll(key, target, provider)
        }
    }

    private func poll(_ key: String, _ target: CIInterest, _ provider: any CommitPolling) async {
        do {
            let page = try await provider.pollCommit(target, since: entries[key]?.cursor)
            guard !Task.isCancelled, var e = entries[key] else { return }
            page.events.forEach { continuation?.yield($0) }
            e.cursor = page.cursor
            var plan = e.scheduler ?? PollScheduler(policy: provider.pollPolicy, intervals: scheduleIntervals)
            plan.succeeded(retryAfter: page.retryAfter)
            e.scheduler = plan
            e.holdUntil = page.retryAfter.map { now().addingTimeInterval($0.seconds) }
            entries[key] = e
            errors[key] = nil
        } catch is CancellationError {
            return
        } catch {
            guard var e = entries[key] else { return }
            if case ProviderError.rateLimited = error { paused = true }
            var plan = e.scheduler ?? PollScheduler(policy: provider.pollPolicy, intervals: scheduleIntervals)
            plan.failed(error)
            e.scheduler = plan
            e.holdUntil = now().addingTimeInterval(plan.delay(mode: .normal).seconds)
            entries[key] = e
            errors[key] = (error as? ProviderError)?.message ?? error.localizedDescription
        }
    }

    private var scheduleIntervals: PollIntervals {
        PollIntervals(normal: interval, active: interval, safety: interval)
    }
}

private extension Duration {
    var seconds: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
