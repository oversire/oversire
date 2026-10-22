import Foundation
import Network

/// The socket of the MCP server: 127.0.0.1 on a random port. It starts with the first thread
/// and stops when no thread is left. One request for each connection.
public final class MCPListener: @unchecked Sendable {
    public let server: MCPServer
    private let queue = DispatchQueue(label: "oversire.mcp")
    private let lock = NSLock()
    private var listener: NWListener?
    private var port: UInt16?
    private var pruner: Task<Void, Never>?

    public init(server: MCPServer) { self.server = server }

    /// The URL and the bearer token of the thread. It starts the socket when it is off.
    public func endpoint(thread: String) async throws -> (url: URL, token: String) {
        let port = try await start()
        let token = await server.token(for: thread)
        return (URL(string: "http://127.0.0.1:\(port)/mcp")!, token)
    }

    public func closed(thread: String) async {
        await server.close(thread: thread)
        if await server.isEmpty { stop() }
    }

    public var isRunning: Bool { lock.withLock { listener != nil } }

    private func start() async throws -> UInt16 {
        if let p = lock.withLock({ port }) { return p }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.acceptLocalOnly = true
        let l = try NWListener(using: params)
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        let p: UInt16 = try await withCheckedThrowingContinuation { cont in
            let once = Once()
            l.stateUpdateHandler = { s in
                switch s {
                case .ready: if once.take() { cont.resume(returning: l.port?.rawValue ?? 0) }
                case .failed(let e): if once.take() { cont.resume(throwing: e) }
                case .cancelled: if once.take() { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            l.start(queue: queue)
        }
        // Two callers can start at the same time: keep the first socket.
        let kept: UInt16 = lock.withLock {
            if let port { return port }
            listener = l
            port = p
            return p
        }
        if kept != p { l.cancel() }
        lock.withLock {
            guard pruner == nil else { return }
            pruner = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    guard let self else { return }
                    if await self.server.prune() { self.stop() }
                }
            }
        }
        return kept
    }

    public func stop() {
        let (l, t) = lock.withLock {
            defer { listener = nil; port = nil; pruner = nil }
            return (listener, pruner)
        }
        l?.cancel()
        t?.cancel()
    }

    private func serve(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, HTTPRequestReader())
    }

    private func read(_ c: NWConnection, _ reader: HTTPRequestReader) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self, error == nil else { return c.cancel() }
            var r = reader
            switch r.feed(data ?? Data()) {
            case .more:
                if done { return c.cancel() }
                self.read(c, r)
            case .bad(let reply): self.send(c, reply)
            case .done(let m):
                Task {
                    let reply = await self.server.handle(m)
                    self.send(c, reply)
                }
            }
        }
    }

    private func send(_ c: NWConnection, _ reply: HTTPReply) {
        c.send(content: reply.wire, completion: .contentProcessed { _ in c.cancel() })
    }
}

private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func take() -> Bool { lock.withLock { defer { done = true }; return !done } }
}
