import Foundation
import OverSireCore

public protocol WebSocketConnecting: Sendable {
    /// Throws ProviderError.unauthorized when the server rejects the token.
    func connect(_ request: URLRequest) async throws -> any WebSocketConnection
}

public protocol WebSocketConnection: Sendable {
    /// Text messages. Throws when the socket closes (ProviderError.unauthorized for close code 4001).
    func receive() async throws -> String
    func send(_ text: String) async throws
    func close()
}

/// A WebSocket that pokes, and a REST read of the event log: the paid push path to oversire/cloud, and an oversire daemon.
public actor CloudSource: EventSource {
    public static let cursorKey = "cloud"

    private let base: URL
    private let token: String?
    /// The subject of the health text, for example "The cloud" or "mbp".
    public nonisolated let name: String
    private let key: String
    private let http: any HTTPTransport
    private let socket: any WebSocketConnecting
    private let cursors: CursorStore
    private let clock: any Clock<Duration>
    private let pingEvery: Duration
    private let onResync: @Sendable (AccountID?) -> Void
    private let onStore: @Sendable () -> Void
    private let onGroup: @Sendable () -> Void

    private var state: SourceHealth = .off
    private var continuation: AsyncStream<ProviderEvent>.Continuation?
    private var healthContinuation: AsyncStream<SourceHealth>.Continuation?
    private var runner: Task<Void, Never>?
    private var generation = 0
    private(set) var pongSeen = true
    private var syncing = false
    private var syncAgain = false
    public private(set) var lastSync: Date?

    /// onResync: the log has a gap (nil: all accounts) or an event names no subject.
    /// onStore: the store op log has new ops. It also runs after each connect.
    /// onGroup: a daemon sends {"type":"group"} after a change of the machine group.
    /// A nil token sends no Authorization header (a daemon on loopback).
    public init(base: URL, token: String?, name: String = "The cloud", cursorKey: String = CloudSource.cursorKey,
                http: any HTTPTransport, socket: any WebSocketConnecting, cursors: CursorStore,
                clock: any Clock<Duration> = ContinuousClock(), pingEvery: Duration = .seconds(30),
                onResync: @escaping @Sendable (AccountID?) -> Void = { _ in },
                onStore: @escaping @Sendable () -> Void = {}, onGroup: @escaping @Sendable () -> Void = {}) {
        self.base = base
        self.token = token
        self.name = name
        self.key = cursorKey
        self.http = http
        self.socket = socket
        self.cursors = cursors
        self.clock = clock
        self.pingEvery = pingEvery
        self.onResync = onResync
        self.onStore = onStore
        self.onGroup = onGroup
    }

    public nonisolated func events() -> AsyncStream<ProviderEvent> {
        let (stream, cont) = AsyncStream.makeStream(of: ProviderEvent.self)
        Task { await self.start(cont) }
        return stream
    }

    /// One consumer: the merger.
    public func healthUpdates() -> AsyncStream<SourceHealth> {
        let (stream, cont) = AsyncStream.makeStream(of: SourceHealth.self, bufferingPolicy: .bufferingNewest(1))
        healthContinuation?.finish()
        healthContinuation = cont
        cont.yield(state)
        return stream
    }

    public func health() -> SourceHealth { state }

    public func stop() {
        runner?.cancel()
        runner = nil
        continuation?.finish()
        continuation = nil
        setHealth(.off)
    }

    private func start(_ cont: AsyncStream<ProviderEvent>.Continuation) {
        stop()
        generation += 1
        let gen = generation
        continuation = cont
        cont.onTermination = { _ in Task { await self.stop(generation: gen) } }
        runner = Task { await self.run() }
    }

    private func stop(generation gen: Int) {
        if gen == generation { stop() }
    }

    private func setHealth(_ h: SourceHealth) {
        guard h != state else { return }
        state = h
        healthContinuation?.yield(h)
    }

    private func run() async {
        var backoff = Backoff()
        while !Task.isCancelled {
            if state != .live { setHealth(.connecting) }
            do {
                let conn = try await socket.connect(request("/v1/connect", socket: true))
                setHealth(.live)
                backoff.reset()
                pongSeen = true
                onStore()
                await sync()
                try await withThrowingTaskGroup(of: Void.self) { g in
                    g.addTask { while true { await self.handle(try await conn.receive()) } }
                    g.addTask { [clock, pingEvery] in
                        while true {
                            try await clock.sleep(for: pingEvery)
                            try await self.ping(conn)
                        }
                    }
                    defer {
                        conn.close()
                        g.cancelAll()
                    }
                    try await g.next()
                }
            } catch ProviderError.unauthorized {
                setHealth(.failed(rejected))
                return
            } catch {
                if Task.isCancelled { return }
                setHealth(.failed("Disconnected: \((error as? ProviderError)?.message ?? error.localizedDescription)"))
            }
            try? await clock.sleep(for: backoff.next())
        }
    }

    private func handle(_ message: String) {
        if message == "pong" { pongSeen = true; return }
        if message.contains("\"store\"") { pongSeen = true; onStore(); return }
        if message.contains("\"group\"") { pongSeen = true; onGroup(); return }
        guard message.contains("\"poke\"") else { return }
        pongSeen = true
        Task { await self.sync() }
    }

    // "ping" text gets an auto-response from the Durable Object, so it does not wake it.
    private func ping(_ conn: any WebSocketConnection) async throws {
        guard pongSeen else { throw ProviderError.transport("No pong from \(name)") }
        pongSeen = false
        try await conn.send("ping")
    }

    /// Reads the log from the cursor. Calls during a read run once more after it.
    public func sync() async {
        guard !syncing else { syncAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            do {
                try await catchUp()
                lastSync = Date()
            } catch ProviderError.unauthorized {
                setHealth(.failed(rejected))
                return
            } catch {
                return
            }
        } while syncAgain
    }

    private func catchUp() async throws {
        let start = cursors[key].flatMap { Int($0.rawValue) } ?? 0
        var after = start, truncated = false, events: [CloudEntry] = []
        while true {
            let page: CloudEventsPage = try await get("/v1/events?after=\(after)&limit=500&schema=1")
            // A new log starts again at seq 1: read it from the start.
            if page.head < after { after = 0; truncated = true; events = []; continue }
            events += page.events
            truncated = truncated || page.truncated
            after = page.next
            if !page.more { break }
        }
        if truncated { onResync(nil) }
        let now = Date()
        for e in events {
            switch e.signal(at: now) {
            case .event(let pe): continuation?.yield(pe)
            case .resync(let account): onResync(account)
            case nil: break
            }
        }
        guard after != start else { return }
        cursors[key] = Cursor(rawValue: String(after))
        _ = try? await send("POST", "/v1/ack", body: try JSONSerialization.data(withJSONObject: ["seq": after]))
    }

    private func request(_ path: String, socket: Bool = false) -> URLRequest {
        var url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!
        if socket, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.scheme = c.scheme == "http" ? "ws" : "wss"
            url = c.url!
        }
        var r = URLRequest(url: url)
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private var rejected: String { "\(name) rejected this Mac's token" }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let data = try await send("GET", path)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        do { return try dec.decode(T.self, from: data) }
        catch { throw ProviderError.decoding(String(describing: error)) }
    }

    private func send(_ method: String, _ path: String, body: Data? = nil) async throws -> Data {
        var r = request(path)
        r.httpMethod = method
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await http.send(r)
        switch resp.statusCode {
        case 200..<300: return data
        case 401: throw ProviderError.unauthorized
        case 403: throw ProviderError.forbidden
        case 404: throw ProviderError.notFound
        case 429: throw ProviderError.rateLimited(retryAfter: resp.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).map { .seconds($0) })
        default: throw ProviderError.vendor(code: String(resp.statusCode), message: String(decoding: data.prefix(200), as: UTF8.self))
        }
    }
}
