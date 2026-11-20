import XCTest
import OverSireCore
import OverSireTestKit
@testable import TrackerBigTimer

final class BigTimerStreamTests: XCTestCase {
    static let server = URL(string: "https://bt.example.com")!
    static let account = AccountID(provider: .bigtimer, id: "bt.example.com")
    static let notFound = (404, [String: String](), #"{"type":"about:blank","title":"Not Found","status":404,"code":"not_found","detail":"No route."}"#)

    var fake: BigTimerFakeServer!

    override func setUp() { fake = BigTimerFakeServer() }

    func tracker(token: String = "good", http: (any HTTPTransport)? = nil, clock: any Clock<Duration> = ContinuousClock()) -> BigTimerTracker {
        BigTimerTracker(server: Self.server, account: Self.account, token: token, http: http ?? fake, clock: clock)
    }

    /// Reads the signals of a stream until it ends.
    func collect(_ s: AsyncThrowingStream<LiveSignal, Error>) -> Task<[LiveSignal], Error> {
        Task {
            var out: [LiveSignal] = []
            for try await x in s { out.append(x) }
            return out
        }
    }

    static let body = """
        retry: 5000

        : keep-alive

        id: b-1
        event: changes
        data: {"seq":5}

        id: b-2
        event: changes
        data: {"seq":null,"resync":true}

        id: b-3
        event: resync
        data: {"since":0}

        id: b-4
        event: presence
        data: {"member":"m1"}

        id: b-5
        event: ai_config
        data: {"changed":true}


        """

    static let signals = [LiveSignal(.changed, id: "b-1"), LiveSignal(.changed, id: "b-2"), LiveSignal(.resync, id: "b-3"),
                          LiveSignal(.alive, id: "b-4"), LiveSignal(.alive, id: "b-5")]

    func testStreamRequest() async throws {
        let t = tracker()
        _ = try await t.liveFeed(lastEventID: nil)
        let r = try XCTUnwrap(fake.requests.last)
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertEqual(r.url?.path, "/v1/stream")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer good")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Accept"), "text/event-stream")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
        XCTAssertNil(r.value(forHTTPHeaderField: "Last-Event-ID"))
        XCTAssertEqual(r.timeoutInterval, 90)
        _ = try await t.liveFeed(lastEventID: "ab12-7")
        XCTAssertEqual(fake.requests.last?.value(forHTTPHeaderField: "Last-Event-ID"), "ab12-7")
        XCTAssertGreaterThan(t.liveFeedTimeout, .seconds(50))
        XCTAssertLessThan(t.liveFeedTimeout, .seconds(90))
    }

    func testStreamSignals() async throws {
        let s = try await tracker().liveFeed(lastEventID: nil)
        let task = collect(s)
        for part in Self.body.components(separatedBy: "\n\n") where !part.isEmpty { fake.push(part + "\n\n") }
        fake.endStreams()
        let got = try await task.value
        XCTAssertEqual(got.filter { $0.id != nil }, Self.signals)
        XCTAssertEqual(got.first, LiveSignal(.alive), "the retry line shows that the stream is up")
        XCTAssertFalse(got.contains { $0.id == nil && $0.kind != .alive })
    }

    func testStreamChunksCutLines() async throws {
        let s = try await tracker().liveFeed(lastEventID: nil)
        let task = collect(s)
        for c in ReplayTransport.chunks(Data(Self.body.utf8), seed: 3) { fake.push(String(decoding: c, as: UTF8.self)) }
        fake.endStreams()
        let got = try await task.value
        XCTAssertEqual(got.filter { $0.id != nil }, Self.signals)
    }

    func testStream401SetsTheLatch() async throws {
        let t = tracker(token: "bad")
        await assertThrows(.unauthorized) { _ = try await t.liveFeed(lastEventID: nil) }
        await assertThrows(.unauthorized) { _ = try await t.projects() }
        XCTAssertEqual(fake.requests.count, 1)
    }

    func testStreamDuringTheLatchSendsNoRequest() async throws {
        let clock = ManualClock()
        let first = Locked(true)
        fake.override = { _ in
            first.with { f in defer { f = false }; return f }
                ? (401, [:], #"{"type":"about:blank","title":"Unauthorized","status":401,"code":"unauthorized","detail":"Bad token."}"#) : nil
        }
        let t = tracker(clock: clock)
        await assertThrows(.unauthorized) { _ = try await t.probe() }
        await assertThrows(.unauthorized) { _ = try await t.liveFeed(lastEventID: nil) }
        XCTAssertEqual(fake.requests.count, 1)
        clock.advance(by: .seconds(901))
        let stream = try await t.liveFeed(lastEventID: nil)
        XCTAssertEqual(fake.requests.count, 2)
        XCTAssertEqual(fake.openStreams, 1)
        withExtendedLifetime(stream) {}
    }

    func testStream404IsNotFound() async {
        fake.override = { _ in Self.notFound }
        let t = tracker()
        await assertThrows(.notFound) { _ = try await t.liveFeed(lastEventID: nil) }
    }

    func testStream403IsForbidden() async {
        fake.override = { _ in (403, [:], #"{"code":"insufficient_scope","detail":"No."}"#) }
        let t = tracker()
        await assertThrows(.forbidden) { _ = try await t.liveFeed(lastEventID: nil) }
    }

    func testStreamMaintenanceWaitsRetryAfter() async {
        fake.override = { _ in (503, ["Retry-After": "120"], #"{"code":"maintenance","detail":"Maintenance."}"#) }
        let t = tracker()
        await assertThrows(.rateLimited(retryAfter: .seconds(120))) { _ = try await t.liveFeed(lastEventID: nil) }
    }

    func testStreamNeedsEventStreamType() async {
        fake.override = { _ in (200, ["Content-Type": "text/html"], "<html>Login</html>") }
        let t = tracker()
        await assertThrows(.vendor(code: "not_a_stream", message: "The server did not answer with an event stream.")) {
            _ = try await t.liveFeed(lastEventID: nil)
        }
    }

    func testStreamWithoutStreamingIsUnsupported() async {
        let t = tracker(http: RecordedHTTP())
        await assertThrows(.unsupported(.liveFeed)) { _ = try await t.liveFeed(lastEventID: nil) }
    }

    func testCancelEndsTheRequest() async throws {
        let s = try await tracker().liveFeed(lastEventID: nil)
        let task = collect(s)
        XCTAssertEqual(fake.openStreams, 1)
        task.cancel()
        for _ in 0..<2000 where fake.closedStreams == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(fake.closedStreams, 1)
        XCTAssertEqual(fake.openStreams, 0)
    }

    func testSignalMapping() {
        XCTAssertEqual(BigTimerTracker.signal(for: SSEEvent(event: "changes", data: "{}", id: "a-1")), LiveSignal(.changed, id: "a-1"))
        XCTAssertEqual(BigTimerTracker.signal(for: SSEEvent(event: "notification", data: "{}")), LiveSignal(.alive))
        XCTAssertEqual(BigTimerTracker.signal(for: SSEEvent(data: "x", id: "a-2")), LiveSignal(.alive, id: "a-2"))
    }

    private func assertThrows(_ e: ProviderError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> Void) async {
        do {
            try await body()
            XCTFail("did not throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ProviderError, e, file: file, line: line)
        }
    }
}

private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    @discardableResult
    func with<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } }
}
