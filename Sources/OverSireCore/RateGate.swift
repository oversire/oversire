import Foundation

// ─── Rate gate ───────────────────────────────────────────────────────────────
// One gate for each API token (OVERSIRE-428). All callers share its budget, and a 429 pauses all of them.

public actor RateGate {
    public struct Clock: Sendable {
        public var now: @Sendable () -> Date
        public var sleep: @Sendable (TimeInterval) async throws -> Void

        public init(now: @escaping @Sendable () -> Date, sleep: @escaping @Sendable (TimeInterval) async throws -> Void) {
            self.now = now
            self.sleep = sleep
        }

        public static let system = Clock(now: Date.init, sleep: { try await Task.sleep(nanoseconds: UInt64(max(0, $0) * 1e9)) })
    }

    public static let defaultPause: TimeInterval = 15
    public static let maxPause: TimeInterval = 60

    private let perMinute: @Sendable () -> Int
    private let concurrent: Int
    private let clock: Clock
    private var tokens: Double
    private var filledAt: Date
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    public private(set) var pausedUntil: Date?

    /// perMinute: the budget, read at each call, so it can follow the automation lease.
    public init(perMinute: @escaping @Sendable () -> Int, concurrent: Int = 2, clock: Clock = .system) {
        self.perMinute = perMinute
        self.concurrent = max(1, concurrent)
        self.clock = clock
        tokens = Double(max(1, perMinute()))
        filledAt = clock.now()
    }

    /// Waits for a free slot, the end of a pause and a token. Call `leave()` after the request.
    public func enter() async throws {
        while true {
            try Task.checkCancellation()
            if running >= concurrent {
                await withCheckedContinuation { waiters.append($0) }
                continue
            }
            let now = clock.now()
            if let p = pausedUntil, p > now {
                try await clock.sleep(p.timeIntervalSince(now))
                continue
            }
            let rate = Double(max(1, perMinute()))
            tokens = min(rate, tokens + max(0, now.timeIntervalSince(filledAt)) * rate / 60)
            filledAt = now
            if tokens >= 1 {
                tokens -= 1
                running += 1
                return
            }
            try await clock.sleep((1 - tokens) * 60 / rate)
        }
    }

    public func leave() {
        running = max(0, running - 1)
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }

    /// Pauses all callers after a 429. Gives the pause in seconds when it starts a new pause, else nil.
    public func pause(retryAfter: TimeInterval?) -> TimeInterval? {
        let now = clock.now()
        let secs = min(Self.maxPause, max(1, retryAfter ?? Self.defaultPause))
        let until = now.addingTimeInterval(secs)
        let fresh = pausedUntil.map { $0 <= now } ?? true
        if fresh || until > pausedUntil! { pausedUntil = until }
        tokens = 0
        filledAt = pausedUntil!
        return fresh ? secs : nil
    }
}

/// Sends each request through a RateGate. A 429 pauses the gate, and the request tries again two times.
public struct GatedTransport: HTTPTransport {
    let base: any HTTPTransport
    let gate: RateGate
    let log: any LogSink
    let host: String

    /// host: the account in the log line, for example the Plane workspace.
    public init(_ base: any HTTPTransport, gate: RateGate, log: any LogSink = NoLog(), host: String) {
        self.base = base
        self.gate = gate
        self.log = log
        self.host = host
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        var attempt = 0
        while true {
            try await gate.enter()
            let out: (Data, HTTPURLResponse)
            do { out = try await base.send(request) } catch {
                await gate.leave()
                throw error
            }
            await gate.leave()
            guard out.1.statusCode == 429, attempt < 2 else { return out }
            attempt += 1
            let after = out.1.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            if let secs = await gate.pause(retryAfter: after) {
                log.write(LogEntry(level: .warn, area: .net, job: "Rate limit", host: host,
                                   message: "HTTP 429: all requests wait \(Int(secs)) s"))
            }
        }
    }
}
