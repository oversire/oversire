import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

/// A socket that the test drives: push a message, or drop the line.
private final class FakeConnection: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [Result<String, Error>] = []
    private var waiter: CheckedContinuation<String, Error>?
    let sent = Locked<[String]>([])
    let closed = Locked(false)

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            let next: Result<String, Error>? = lock.withLock {
                if closed.get() { return .failure(ProviderError.transport("closed")) }
                if queue.isEmpty { waiter = c; return nil }
                return queue.removeFirst()
            }
            if let next { c.resume(with: next) }
        }
    }

    func send(_ text: String) async throws { sent.with { $0.append(text) } }

    func close() {
        closed.with { $0 = true }
        deliver(.failure(ProviderError.transport("closed")))
    }

    func push(_ text: String) { deliver(.success(text)) }
    func drop() { deliver(.failure(ProviderError.transport("reset"))) }

    private func deliver(_ r: Result<String, Error>) {
        let w: CheckedContinuation<String, Error>? = lock.withLock {
            if let w = waiter { waiter = nil; return w }
            queue.append(r)
            return nil
        }
        w?.resume(with: r)
    }
}

private final class FakeSocket: WebSocketConnecting, @unchecked Sendable {
    let script: Locked<[Result<FakeConnection, ProviderError>]>
    let requests = Locked<[URLRequest]>([])

    init(_ script: [Result<FakeConnection, ProviderError>]) { self.script = Locked(script) }

    func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        requests.with { $0.append(request) }
        guard let next = script.with({ $0.isEmpty ? nil : $0.removeFirst() }) else { throw ProviderError.transport("offline") }
        return try next.get()
    }
}

/// The cloud event log: GET /v1/events?after=, POST /v1/ack.
private final class FakeCloud: HTTPTransport, @unchecked Sendable {
    let log = Locked<[CloudEvent]>([])
    let head = Locked<Int?>(nil)       // set below the cursor to fake a new log
    let truncated = Locked(false)
    let requests = Locked<[String]>([])
    let acks = Locked<[Int]>([])

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        requests.with { $0.append("\(request.httpMethod ?? "GET") \(url.path)\(url.query.map { "?\($0)" } ?? "")") }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer t-1")
        var body: [String: Any] = ["ok": true]
        if url.path == "/v1/events" {
            let after = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "after" }!.value!)!
            let events = log.get().filter { $0.seq > after }
            let h = head.get() ?? log.get().last?.seq ?? 0
            body = ["events": events.map(json), "head": h, "next": events.last?.seq ?? max(after, 0),
                    "more": false, "truncated": truncated.with { t in defer { t = false }; return t }]
            if h < after { body["events"] = []; body["next"] = after }
        } else if url.path == "/v1/ack" {
            let obj = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Int]
            acks.with { $0.append(obj["seq"]!) }
        }
        let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (try JSONSerialization.data(withJSONObject: body), resp)
    }

    private func json(_ e: CloudEvent) -> [String: Any] {
        var d: [String: Any] = ["seq": e.seq, "deliveryId": e.deliveryId, "repo": e.repo, "kind": e.kind]
        d["action"] = e.action
        d["runId"] = e.runId
        return d
    }

    func add(_ seq: Int, run: Int) {
        log.with { $0.append(CloudEvent(seq: seq, deliveryId: "d\(seq)", repo: "acme/web", kind: "workflow_run",
                                        action: "completed", runId: run)) }
    }
}

final class CloudSourceTests: XCTestCase {
    let base = URL(string: "https://cloud.example.com")!

    func testReconnectsAndCatchesUpAfterAGap() async throws {
        let clock = ManualClock()
        let first = FakeConnection(), second = FakeConnection()
        let socket = FakeSocket([.success(first), .success(second)])
        let cloud = FakeCloud()
        cloud.add(1, run: 100)
        cloud.add(2, run: 101)
        let cursors = CursorStore(url: nil)
        let source = CloudSource(base: base, token: "t-1", http: cloud, socket: socket, cursors: cursors, clock: clock)
        let stream = source.events()

        let start = await take(2, from: stream)
        XCTAssertEqual(start.map(\.id), ["d1", "d2"])
        XCTAssertEqual(socket.requests.get().first?.url?.absoluteString, "wss://cloud.example.com/v1/connect")
        await eventually("ack") { cloud.acks.get() == [2] }
        XCTAssertEqual(cursors["cloud"]?.rawValue, "2")
        var h = await source.health()
        XCTAssertEqual(h, .live)

        // A poke reads the new event.
        cloud.add(3, run: 102)
        first.push(#"{"type":"poke"}"#)
        let poked = await take(1, from: stream)
        XCTAssertEqual(poked.map(\.id), ["d3"])

        // The line drops. Events come in meanwhile. The source reconnects after the backoff and reads them.
        first.drop()
        await eventually("dropped") { await source.health() == .failed("Disconnected: reset") }
        await eventually("backoff sleep") { clock.sleeperCount == 1 }
        cloud.add(4, run: 103)
        cloud.add(5, run: 104)
        clock.advance(by: .seconds(2))
        let caught = await take(2, from: stream)
        XCTAssertEqual(caught.map(\.id), ["d4", "d5"])
        XCTAssertTrue(cloud.requests.get().contains("GET /v1/events?after=3&limit=500"))
        h = await source.health()
        XCTAssertEqual(h, .live)
        XCTAssertTrue(first.closed.get())
        await source.stop()
    }

    func testPingsAndPongTimeout() async throws {
        let clock = ManualClock()
        let conn = FakeConnection()
        let socket = FakeSocket([.success(conn)])
        let source = CloudSource(base: base, token: "t-1", http: FakeCloud(), socket: socket,
                                 cursors: CursorStore(url: nil), clock: clock)
        let stream = source.events()
        try await clock.waitForSleepers()
        clock.advance(by: .seconds(30))
        await eventually("ping") { conn.sent.get() == ["ping"] }
        conn.push("pong")
        await eventually("pong") { await source.pongSeen }
        try await clock.waitForSleepers()
        clock.advance(by: .seconds(30))
        await eventually("second ping") { conn.sent.get() == ["ping", "ping"] }
        // No pong: the next tick drops the line.
        try await clock.waitForSleepers()
        clock.advance(by: .seconds(30))
        await eventually("closed") { conn.closed.get() }
        await source.stop()
        _ = stream
    }

    func testUnauthorizedStops() async throws {
        let clock = ManualClock()
        let socket = FakeSocket([.failure(.unauthorized)])
        let source = CloudSource(base: base, token: "t-1", http: FakeCloud(), socket: socket,
                                 cursors: CursorStore(url: nil), clock: clock)
        let stream = source.events()
        await eventually("failed") { await source.health() == .failed("The cloud rejected this Mac's token") }
        XCTAssertEqual(clock.sleeperCount, 0, "no retry")
        XCTAssertEqual(socket.requests.get().count, 1)
        await source.stop()
        _ = stream
    }

    func testANewLogStartsOverAndAsksForAResync() async throws {
        let clock = ManualClock()
        let cloud = FakeCloud()
        cloud.add(1, run: 100)
        let cursors = CursorStore(url: nil)
        cursors["cloud"] = Cursor(rawValue: "50")
        let resyncs = Locked<[AccountID?]>([])
        let source = CloudSource(base: base, token: "t-1", http: cloud, socket: FakeSocket([.success(FakeConnection())]),
                                 cursors: cursors, clock: clock, onResync: { a in resyncs.with { $0.append(a) } })
        let got = await take(1, from: source.events())
        XCTAssertEqual(got.map(\.id), ["d1"])
        XCTAssertEqual(resyncs.get(), [nil])
        XCTAssertEqual(cursors["cloud"]?.rawValue, "1")
        await source.stop()
    }

    func testMergerSlowsPollingWhileTheCloudIsLive() async throws {
        let clock = ManualClock()
        let conn = FakeConnection()
        let source = CloudSource(base: base, token: "t-1", http: FakeCloud(), socket: FakeSocket([.success(conn)]),
                                 cursors: CursorStore(url: nil), clock: clock)
        let polling = PollingSource(providers: [], cursors: CursorStore(url: nil), clock: clock)
        let merger = EventMerger(polling: polling, cloud: source)
        let stream = merger.events()
        await eventually("cloud live") { await polling.isCloudLive }
        let h = await merger.health()
        XCTAssertEqual(h, .live)
        conn.drop()
        await eventually("cloud down") { await !polling.isCloudLive }
        await merger.stop()
        _ = stream
    }

    func testLegacyEventMapping() {
        let at = Date(timeIntervalSince1970: 0)
        let run = CloudEvent(seq: 1, deliveryId: "a", repo: "acme/web", kind: "workflow_run", action: "completed", runId: 7)
        guard case .event(let e)? = run.signal(at: at), case .run(let r) = e.subject else { return XCTFail("run") }
        XCTAssertEqual(e.provider, "github-actions")
        XCTAssertEqual(r.repo?.path, "acme/web")
        XCTAssertEqual(r.id, "7")
        XCTAssertEqual(e.action, "completed")

        let job = CloudEvent(seq: 2, deliveryId: "b", repo: "acme/web", kind: "workflow_job", runId: 7, jobId: 9)
        guard case .event(let je)? = job.signal(at: at), case .job(let j) = je.subject else { return XCTFail("job") }
        XCTAssertEqual(j.id, "9")
        XCTAssertEqual(je.action, "updated")

        let pr = CloudEvent(seq: 3, deliveryId: "c", repo: "acme/web", kind: "pull_request_review", action: "submitted", prNumber: 12)
        guard case .event(let pe)? = pr.signal(at: at), case .change(let c) = pe.subject else { return XCTFail("pr") }
        XCTAssertEqual(c.url.absoluteString, "https://github.com/acme/web/pull/12")
        XCTAssertEqual(pe.account, AccountID(provider: "github", id: "acme"))

        let item = CloudEvent(seq: 4, deliveryId: "d", repo: "", kind: "plane", org: "plane:ocral", projectId: "p1", itemId: "i1")
        guard case .event(let ie)? = item.signal(at: at), case .project(let p) = ie.subject else { return XCTFail("plane") }
        XCTAssertEqual(p.storeKey, "ocral/p1")

        let workspace = CloudEvent(seq: 5, deliveryId: "e", repo: "", kind: "plane", org: "plane:ocral")
        XCTAssertEqual(workspace.signal(at: at), .resync(AccountID(provider: "plane", id: "ocral")))
        XCTAssertNil(CloudEvent(seq: 6, deliveryId: "f", repo: "acme/web", kind: "push").signal(at: at))
    }
}
