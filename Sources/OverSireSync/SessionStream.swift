import Foundation
import OverSireCore

/// The live view of one session through the daemon of its machine (session-stream.json).
/// It connects again with backoff. A terminal view acks each 64 KiB. A chat view attaches again after the last seq it saw.
public actor SessionStream {
    public enum Event: Hashable, Sendable {
        case connecting
        case attached(StreamAttached)
        /// Replaces the screen.
        case snapshot(Data)
        case output(Data)
        case resized(cols: Int, rows: Int)
        case lease(LeaseHolder)
        case turns([SessionTurn])
        /// The session ended. The stream stops.
        case ended(reason: String)
        /// An error frame of the daemon. The socket stays open.
        case failed(code: String, message: String)
        /// The socket closed. `stopped` tells that the stream does not connect again.
        case disconnected(String, stopped: Bool)
    }

    /// The client acks after this many bytes.
    public static let ackEvery: UInt64 = 64 << 10

    private let request: URLRequest
    private let view: StreamView
    private let socket: any WebSocketConnecting
    private let clock: any Clock<Duration>
    private let keepAlive: Duration
    private var size: (cols: Int, rows: Int)?

    private var continuation: AsyncStream<Event>.Continuation?
    private var runner: Task<Void, Never>?
    private var conn: (any WebSocketConnection)?
    private var received: UInt64 = 0
    private var acked: UInt64 = 0
    private var lastSeq = 0
    private var attachedOnce = false
    /// The stream does not connect again.
    private var done = false
    private var ended = false

    /// `size` is the size of the view, for a stream that the client can resize.
    public init(request: URLRequest, view: StreamView, socket: any WebSocketConnecting, size: (cols: Int, rows: Int)? = nil,
                clock: any Clock<Duration> = ContinuousClock(), keepAlive: Duration = .seconds(30)) {
        self.request = request
        self.view = view
        self.socket = socket
        self.size = size
        self.clock = clock
        self.keepAlive = keepAlive
    }

    /// One consumer. A second call stops the first stream.
    public nonisolated func events() -> AsyncStream<Event> {
        let (stream, cont) = AsyncStream.makeStream(of: Event.self)
        Task { await self.start(cont) }
        return stream
    }

    public func stop() {
        runner?.cancel()
        runner = nil
        conn?.close()
        conn = nil
        continuation?.finish()
        continuation = nil
    }

    /// Keys for the terminal. Nothing goes when the socket is not open.
    public func input(_ data: Data) async {
        guard let conn, !data.isEmpty else { return }
        try? await conn.send(data: StreamBinaryFrame(op: .input, seq: 0, data: data).encoded)
    }

    /// Text for the session: a chat message, or text for a terminal.
    public func send(text: String) async throws {
        guard let conn else { throw ProviderError.transport("The stream is not connected.") }
        try await conn.send(Self.encode(.send(text: text)))
    }

    /// Takes the size of the terminal. The size also goes with each new attach.
    public func control(cols: Int, rows: Int) async {
        size = (cols, rows)
        try? await conn?.send(Self.encode(.control(cols: cols, rows: rows)))
    }

    /// Gives the size back to the runtime.
    public func release() async {
        try? await conn?.send(Self.encode(.release))
    }

    private func start(_ cont: AsyncStream<Event>.Continuation) {
        stop()
        continuation = cont
        cont.onTermination = { _ in Task { await self.stop() } }
        runner = Task { await self.run() }
    }

    private func emit(_ e: Event) { continuation?.yield(e) }

    private func run() async {
        var backoff = Backoff(cap: .seconds(30))
        while !Task.isCancelled && !done {
            emit(.connecting)
            var reason = "The stream closed."
            do {
                let c = try await socket.connect(request)
                conn = c
                received = 0
                acked = 0
                try await c.send(Self.encode(.attach(view: view, cols: size?.cols, rows: size?.rows, after: view == .chat ? lastSeq : nil)))
                try await withThrowingTaskGroup(of: Void.self) { g in
                    g.addTask {
                        while true {
                            if try await self.handle(try await c.receiveMessage()) { return }
                        }
                    }
                    g.addTask { [clock, keepAlive] in
                        while true {
                            try await clock.sleep(for: keepAlive)
                            try await self.ack(c, force: true)
                        }
                    }
                    defer {
                        c.close()
                        g.cancelAll()
                    }
                    try await g.next()
                }
                if attachedOnce { backoff.reset() }
            } catch ProviderError.unauthorized {
                done = true
                reason = "The daemon rejected this Mac's token."
            } catch ProviderError.notFound {
                done = true
                reason = "The daemon does not know the session."
            } catch {
                if Task.isCancelled { return }
                if attachedOnce { backoff.reset() }
                reason = (error as? ProviderError)?.message ?? error.localizedDescription
            }
            conn = nil
            attachedOnce = false
            if Task.isCancelled || ended { break }
            emit(.disconnected(reason, stopped: done))
            if done { break }
            try? await clock.sleep(for: backoff.next())
        }
        continuation?.finish()
    }

    /// Gives true when the stream must stop.
    private func handle(_ m: WebSocketMessage) async throws -> Bool {
        switch m {
        case .data(let d):
            guard let f = StreamBinaryFrame(d) else { return false }
            received = f.seq
            switch f.op {
            case .snapshot: emit(.snapshot(f.data))
            case .output: emit(.output(f.data))
            case .input: break
            }
            if let conn { try await ack(conn, force: false) }
        case .text(let s):
            guard let f = try? Self.decoder().decode(StreamDaemonFrame.self, from: Data(s.utf8)) else { return false }
            switch f {
            case .attached(let a):
                attachedOnce = true
                emit(.attached(a))
            case .resized(let cols, let rows): emit(.resized(cols: cols, rows: rows))
            case .lease(let h): emit(.lease(h))
            case .turns(_, let to, let turns):
                lastSeq = max(lastSeq, to)
                emit(.turns(turns))
            case .ended(let reason):
                done = true
                ended = true
                emit(.ended(reason: reason))
                return true
            case .error(let code, let message):
                emit(.failed(code: code, message: message))
                // The daemon cannot give this view: connecting again gives the same answer.
                if code == "unsupported" {
                    done = true
                    return true
                }
            }
        }
        return false
    }

    private func ack(_ c: any WebSocketConnection, force: Bool) async throws {
        guard force || received - acked >= Self.ackEvery else { return }
        acked = received
        try await c.send(Self.encode(.ack(seq: received)))
    }

    /// ISO 8601 times with or without fractions, as the daemon writes them.
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = parseISO(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "not an ISO 8601 time: \(s)"))
            }
            return date
        }
        return d
    }

    static func encode(_ f: StreamClientFrame) -> String {
        String(decoding: (try? JSONEncoder().encode(f)) ?? Data(), as: UTF8.self)
    }
}
