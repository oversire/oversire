import Foundation
import OverSireCore

public enum LiveFeedState: Hashable, Sendable {
    /// Not started, or stopped by `stop()`.
    case off
    case connecting
    case live
    /// The stream dropped. It connects again after the backoff.
    case retrying(ProviderError)
    /// `.unauthorized`, `.forbidden`, `.notFound`, `.unsupported`: no new connect until `wake()`.
    case stopped(ProviderError)

    var isRetrying: Bool {
        if case .retrying = self { return true }
        return false
    }

    public var health: SourceHealth {
        switch self {
        case .off: return .off
        case .connecting: return .connecting
        case .live: return .live
        case .retrying(let e), .stopped(let e): return .failed(e.message)
        }
    }
}

/// Keeps the hint stream of a `LiveFeeding` provider open. A hint pulls the feed with `poll(since:)`.
/// The stream is a hint: polling and the stream give the same events.
public actor LiveFeedSource: EventSource {
    public nonisolated let account: AccountID
    private let feed: any LiveFeeding
    private let cursors: CursorStore
    private let clock: any Clock<Duration>
    private let elapsed: @Sendable () -> Duration
    private let isOnline: @Sendable () -> Bool
    private let onResync: @Sendable (AccountID) -> Void

    private var current: LiveFeedState = .off
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var stateContinuation: AsyncStream<LiveFeedState>.Continuation?
    private var runner: Task<Void, Never>?
    private var generation = 0
    private var backoff = Backoff()
    private var sleeper: Task<Void, Never>?
    private var wakeSeen = false
    private var signalSeen = false
    private var lastSignal: Duration = .zero
    private var timedOut = false
    private var fatal: ProviderError?
    private var reader: Task<Void, Error>?
    private var pullTask: Task<Void, Never>?
    private var pulling = false
    private var pullAgain = false
    private var pullFailed = false
    private var forceResync = false
    private(set) var lastEventID: String?

    /// `onResync` runs when the feed has a gap: a `resync` signal, or an expired cursor.
    /// While `isOnline` is false, no connect runs: call `wake()` when the path comes back.
    public init(feed: any LiveFeeding, cursors: CursorStore, clock: any Clock<Duration> = ContinuousClock(),
                isOnline: @escaping @Sendable () -> Bool = { true },
                onResync: @escaping @Sendable (AccountID) -> Void = { _ in }) {
        self.feed = feed
        self.account = feed.account
        self.cursors = cursors
        self.clock = clock
        elapsed = Self.stopwatch(clock)
        self.isOnline = isOnline
        self.onResync = onResync
    }

    /// Apart from a later `PollingSource` cursor of the same account.
    public static func cursorKey(_ a: AccountID) -> String { CursorStore.key(a) + "#live" }

    private static func stopwatch<C: Clock>(_ c: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let start = c.now
        return { start.duration(to: c.now) }
    }

    private var key: String { Self.cursorKey(account) }

    public nonisolated func events() -> AsyncStream<ProviderEvent> {
        let (stream, cont) = AsyncStream.makeStream(of: ProviderEvent.self)
        Task { await self.start(cont) }
        return stream
    }

    public func health() -> SourceHealth { current.health }

    public func state() -> LiveFeedState { current }

    /// One consumer. It yields the current state first.
    public func stateUpdates() -> AsyncStream<LiveFeedState> {
        let (stream, cont) = AsyncStream.makeStream(of: LiveFeedState.self, bufferingPolicy: .bufferingNewest(1))
        stateContinuation?.finish()
        stateContinuation = cont
        cont.yield(current)
        return stream
    }

    /// The network came back, or the user asked to connect again. It ends the backoff and starts a stopped feed.
    public func wake() {
        if let sleeper {
            sleeper.cancel()
        } else if case .stopped = current, continuation != nil {
            startRunner()
        } else if current != .live {
            wakeSeen = true
        }
    }

    public func stop() {
        runner?.cancel()
        pullTask?.cancel()
        sleeper?.cancel()
        runner = nil
        pullTask = nil
        pulling = false
        continuation?.finish()
        continuation = nil
        setState(.off)
    }

    private func start(_ cont: AsyncStream<ProviderEvent>.Continuation) {
        stop()
        generation += 1
        let gen = generation
        continuation = cont
        cont.onTermination = { _ in Task { await self.stop(generation: gen) } }
        startRunner()
    }

    private func stop(generation gen: Int) {
        if gen == generation { stop() }
    }

    private func startRunner() {
        backoff = Backoff()
        runner = Task { await self.run() }
    }

    private func setState(_ s: LiveFeedState) {
        guard s != current else { return }
        current = s
        stateContinuation?.yield(s)
    }

    // MARK: Connection

    private func run() async {
        while !Task.isCancelled {
            guard isOnline() else {
                setState(.retrying(.transport("This Mac is offline")))
                await pause(.seconds(3600))
                continue
            }
            if !current.isRetrying && current != .live { setState(.connecting) }
            var retryAfter: Duration?
            do {
                let stream = try await feed.liveFeed(lastEventID: lastEventID)
                try await consume(stream)
                if Task.isCancelled { return }
                setState(.retrying(.transport("The stream ended")))
            } catch {
                if Task.isCancelled { return }
                let e = error as? ProviderError ?? .transport(error.localizedDescription)
                switch e {
                case .unauthorized, .forbidden, .notFound, .unsupported:
                    setState(.stopped(e))
                    return
                case .rateLimited(let r): retryAfter = r
                default: break
                }
                setState(.retrying(e))
            }
            await pause(max(backoff.next(), retryAfter ?? .zero))
        }
    }

    /// Sleeps. `wake()` ends the sleep.
    private func pause(_ d: Duration) async {
        if wakeSeen { wakeSeen = false; return }
        let t = Task { [clock] in _ = try? await clock.sleep(for: d) }
        sleeper = t
        await withTaskCancellationHandler { await t.value } onCancel: { t.cancel() }
        sleeper = nil
    }

    /// Reads signals until the stream ends or throws. It throws when the stream is silent too long.
    private func consume(_ stream: AsyncThrowingStream<LiveSignal, Error>) async throws {
        signalSeen = false
        timedOut = false
        fatal = nil
        lastSignal = elapsed()
        let reader = Task { for try await s in stream { await self.handle(s) } }
        self.reader = reader
        let timeout = feed.liveFeedTimeout
        let watchdog = Task { await self.watch(reader, timeout: timeout) }
        defer {
            reader.cancel()
            watchdog.cancel()
            self.reader = nil
        }
        requestPull()
        try await withTaskCancellationHandler { try await reader.value } onCancel: { reader.cancel() }
        if let fatal { throw fatal }
        if timedOut { throw ProviderError.transport("No data for \(Int(timeout.timeInterval)) s") }
    }

    private func watch(_ reader: Task<Void, Error>, timeout: Duration) async {
        while !Task.isCancelled {
            let left = timeout - (elapsed() - lastSignal)
            if left <= .zero {
                timedOut = true
                reader.cancel()
                return
            }
            try? await clock.sleep(for: left)
        }
    }

    private func handle(_ s: LiveSignal) {
        guard !Task.isCancelled else { return }
        lastSignal = elapsed()
        lastEventID = s.id ?? lastEventID
        if !signalSeen {
            signalSeen = true
            wakeSeen = false
            backoff.reset()
            setState(.live)
        }
        switch s.kind {
        case .alive: if pullFailed { requestPull() }
        case .changed: requestPull()
        case .resync:
            forceResync = true
            requestPull()
        }
    }

    // MARK: Pull

    /// One pull at a time. A request during a pull gives one more pull after it.
    private func requestPull() {
        guard !pulling else { pullAgain = true; return }
        pulling = true
        pullTask = Task { await self.pullLoop() }
    }

    private func pullLoop() async {
        repeat {
            pullAgain = false
            do {
                try await pullOnce()
                pullFailed = false
            } catch ProviderError.unauthorized {
                fatal = .unauthorized
                pulling = false
                reader?.cancel()
                return
            } catch is CancellationError {
                pulling = false
                return
            } catch {
                pullFailed = true
            }
        } while pullAgain && !Task.isCancelled
        pulling = false
    }

    private func pullOnce() async throws {
        let forced = forceResync
        let before = forced ? nil : cursors[key]
        let page = try await feed.poll(since: before)
        guard !Task.isCancelled else { throw CancellationError() }
        page.events.forEach { continuation?.yield($0) }
        cursors[key] = page.cursor
        forceResync = false
        if forced || (page.baseline && before != nil) { onResync(account) }
    }
}
