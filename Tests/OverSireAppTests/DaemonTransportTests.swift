import XCTest
import Network
import OverSireCore
@testable import OverSireApp

/// A real HTTP server on loopback: "/slow" answers after 2 s, each other path at once.
private final class SlowServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "slow-server")

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [queue] c in
            c.start(queue: queue)
            c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let head = String(decoding: data ?? Data(), as: UTF8.self)
                let slow = head.hasPrefix("GET /slow")
                queue.asyncAfter(deadline: .now() + (slow ? 2 : 0)) {
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: keep-alive\r\n\r\n{}"
                    c.send(content: Data(reply.utf8), completion: .contentProcessed { _ in })
                }
            }
        }
    }

    func start() async throws -> Int {
        let ready = AsyncStream<Void> { cont in
            listener.stateUpdateHandler = { if case .ready = $0 { cont.yield(); cont.finish() } }
        }
        listener.start(queue: queue)
        for await _ in ready { break }
        return Int(listener.port!.rawValue)
    }

    deinit { listener.cancel() }
}

final class DaemonTransportTests: XCTestCase {
    func testSessionsKeepSixteenConnections() {
        XCTAssertEqual(DaemonTransport.session().configuration.httpMaximumConnectionsPerHost, 16)
    }

    /// The bug of OVERSIRE-426: slow calls took all connections, and a fast call timed out in the queue.
    func testSlowCallsDoNotDelayAFastCall() async throws {
        let server = try SlowServer()
        let port = try await server.start()
        let t = DaemonTransport()
        func request(_ path: String, timeout: TimeInterval) -> URLRequest {
            URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, timeoutInterval: timeout)
        }
        // 8 slow calls on each session: more than the 6 connections of URLSession.shared.
        let slow = Task {
            try await withThrowingTaskGroup(of: Void.self) { g in
                for i in 0..<16 { g.addTask { _ = try await t.send(request("/slow", timeout: i < 8 ? 5 : 30)) } }
                try await g.waitForAll()
            }
        }
        try await Task.sleep(for: .milliseconds(300))
        let t0 = Date()
        let (_, resp) = try await t.send(request("/fast", timeout: 5))
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1, "the fast call waited for a connection")
        try await slow.value
    }

    func testLongTimeoutGoesOnTheLongSession() async throws {
        final class Count: HTTPTransport, HTTPStreaming, @unchecked Sendable {
            var n = 0
            func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
                n += 1
                return (Data(), HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            func stream(_ r: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
                n += 1
                return (HTTPURLResponse(url: r.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, AsyncThrowingStream { $0.finish() })
            }
        }
        let short = Count(), long = Count()
        let t = DaemonTransport(short: short, long: long)
        let c = DaemonClient(base: DaemonClient.loopback, token: nil, http: t)
        _ = try? await c.sessions()
        _ = try? await c.workspaces()
        _ = try? await c.ask(session: "s", text: "hi")
        XCTAssertEqual(short.n, 1)
        XCTAssertEqual(long.n, 2)
    }
}
