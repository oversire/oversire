import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

/// Gives a new FakeDaemonSocket for each connect, or the next error.
private final class Sockets: WebSocketConnecting, @unchecked Sendable {
    let all = Locked<[FakeDaemonSocket]>([])
    let fail = Locked<[Error]>([])

    func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        if let e = fail.with({ $0.isEmpty ? nil : $0.removeFirst() }) { throw e }
        let s = FakeDaemonSocket()
        all.with { $0.append(s) }
        return s
    }

    func socket(_ i: Int) -> FakeDaemonSocket { all.get()[i] }
}

private func frames(_ s: FakeDaemonSocket) -> [StreamClientFrame] {
    s.sent.compactMap { m in
        guard case .text(let t) = m else { return nil }
        return try? JSONDecoder().decode(StreamClientFrame.self, from: Data(t.utf8))
    }
}

private func json(_ f: StreamDaemonFrame) -> WebSocketMessage {
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    return .text(String(decoding: try! enc.encode(f), as: UTF8.self))
}

private func binary(_ op: StreamBinaryFrame.Op, _ seq: UInt64, _ data: Data) -> WebSocketMessage {
    .data(StreamBinaryFrame(op: op, seq: seq, data: data).encoded)
}

private let request = URLRequest(url: URL(string: "ws://127.0.0.1:7690/v1/sessions/s-1/stream")!)
private let attached = StreamAttached(source: .stream, cols: 80, rows: 24, writable: true, resizable: true)

final class SessionStreamTests: XCTestCase {
    func testTerminalAttachSnapshotOutputAndAcks() async throws {
        let sockets = Sockets()
        let s = SessionStream(request: request, view: .terminal, socket: sockets, size: (100, 30), clock: ManualClock())
        let events = s.events()
        await eventually("connect") { sockets.all.get().count == 1 }
        let sock = sockets.socket(0)
        await eventually("attach") { !frames(sock).isEmpty }
        XCTAssertEqual(frames(sock).first, .attach(view: .terminal, cols: 100, rows: 30, after: nil))

        let big = Data(repeating: 0x41, count: Int(SessionStream.ackEvery))
        sock.push(json(.attached(attached)))
        sock.push(binary(.snapshot, 5, Data("hello".utf8)))
        sock.push(binary(.output, 5 + UInt64(big.count), big))
        let got = await take(4, from: events)
        XCTAssertEqual(got, [.connecting, .attached(attached), .snapshot(Data("hello".utf8)), .output(big)])
        await eventually("ack") { frames(sock).contains(.ack(seq: 5 + UInt64(big.count))) }
        XCTAssertFalse(frames(sock).contains(.ack(seq: 5)), "no ack before 64 KiB")

        await s.input(Data([0x03]))
        await s.control(cols: 120, rows: 40)
        await s.release()
        try await s.send(text: "hi")
        await eventually("client frames") { frames(sock).count == 5 }
        XCTAssertEqual(Array(frames(sock).suffix(3)), [.control(cols: 120, rows: 40), .release, .send(text: "hi")])
        XCTAssertTrue(sock.sent.contains(.data(StreamBinaryFrame(op: .input, seq: 0, data: Data([0x03])).encoded)))
        await s.stop()
    }

    func testKeepAliveAcks() async throws {
        let sockets = Sockets()
        let clock = ManualClock()
        let s = SessionStream(request: request, view: .terminal, socket: sockets, clock: clock)
        _ = s.events()
        await eventually("connect") { sockets.all.get().count == 1 }
        let sock = sockets.socket(0)
        sock.push(binary(.snapshot, 3, Data("abc".utf8)))
        try await clock.waitForSleepers()
        clock.advance(by: .seconds(30))
        await eventually("keep-alive ack") { frames(sock).contains(.ack(seq: 3)) }
        await s.stop()
    }

    func testReconnectsAndTheChatAttachesAfterTheLastSeq() async throws {
        let sockets = Sockets()
        let clock = ManualClock()
        let s = SessionStream(request: request, view: .chat, socket: sockets, clock: clock)
        let events = s.events()
        await eventually("connect") { sockets.all.get().count == 1 }
        let first = sockets.socket(0)
        let turn = SessionTurn(seq: 7, role: .assistant, at: Date(timeIntervalSince1970: 1_800_000_000), text: "done")
        first.push(json(.turns(from: 7, to: 7, turns: [turn])))
        _ = await take(2, from: events)
        first.close()
        let gone = await take(1, from: events)
        guard case .disconnected(_, let stopped)? = gone.first else { return XCTFail("\(gone)") }
        XCTAssertFalse(stopped)
        try await clock.waitForSleepers()
        clock.advance(by: .seconds(2))
        await eventually("second connect") { sockets.all.get().count == 2 }
        let second = sockets.socket(1)
        await eventually("attach") { !frames(second).isEmpty }
        XCTAssertEqual(frames(first).first, .attach(view: .chat, cols: nil, rows: nil, after: 0))
        XCTAssertEqual(frames(second).first, .attach(view: .chat, cols: nil, rows: nil, after: 7))
        await s.stop()
    }

    func testTheChatAttachesBeforeARunningTool() async throws {
        let sockets = Sockets()
        let clock = ManualClock()
        let s = SessionStream(request: request, view: .chat, socket: sockets, clock: clock)
        let events = s.events()
        await eventually("connect") { sockets.all.get().count == 1 }
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let tool = SessionTurn(seq: 4, role: .tool, at: at, text: "", tool: TurnTool(name: "Bash", status: .running))
        let text = SessionTurn(seq: 5, role: .assistant, at: at, text: "more")
        sockets.socket(0).push(json(.turns(from: 4, to: 5, turns: [tool, text])))
        _ = await take(2, from: events)
        sockets.socket(0).close()
        _ = await take(1, from: events)
        try await clock.waitForSleepers()
        clock.advance(by: .seconds(2))
        await eventually("second connect") { sockets.all.get().count == 2 }
        await eventually("attach") { !frames(sockets.socket(1)).isEmpty }
        XCTAssertEqual(frames(sockets.socket(1)).first, .attach(view: .chat, cols: nil, rows: nil, after: 3))
        await s.stop()
    }

    func testTurnBookMerges() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let turn = { (seq: Int, text: String) in SessionTurn(seq: seq, role: .assistant, at: at, text: text) }
        let tool = { (seq: Int, st: TurnTool.Status) in SessionTurn(seq: seq, role: .tool, at: at, text: "", tool: TurnTool(name: "Bash", status: st)) }
        var b = TurnBook()
        XCTAssertTrue(b.merge([turn(1, "a"), turn(4, "d")]), "a gap")
        XCTAssertTrue(b.merge([turn(3, "c"), turn(2, "b")]), "out of order fills the gap")
        XCTAssertEqual(b.turns.map(\.seq), [1, 2, 3, 4])
        XCTAssertFalse(b.merge([turn(2, "b")]), "a repeat changes nothing")
        XCTAssertTrue(b.merge([tool(5, .running)]))
        XCTAssertTrue(b.merge([tool(5, .done)]), "the same seq replaces the turn")
        XCTAssertEqual(b.turns.map(\.seq), [1, 2, 3, 4, 5])
        XCTAssertEqual(b.turns.last?.tool?.status, .done)
        XCTAssertEqual(TurnBook([turn(2, "b"), turn(1, "a"), turn(2, "b2")]).turns.map(\.text), ["a", "b2"])
    }

    func testEndedStops() async throws {
        let sockets = Sockets()
        let clock = ManualClock()
        let s = SessionStream(request: request, view: .terminal, socket: sockets, clock: clock)
        let events = s.events()
        await eventually("connect") { sockets.all.get().count == 1 }
        sockets.socket(0).push(json(.ended(reason: "exited")))
        var all: [SessionStream.Event] = []
        for await e in events { all.append(e) }
        XCTAssertEqual(all, [.connecting, .ended(reason: "exited")])
        XCTAssertEqual(clock.sleeperCount, 0, "no retry")
    }

    func testUnsupportedAndUnauthorizedStop() async throws {
        let sockets = Sockets()
        let s = SessionStream(request: request, view: .chat, socket: sockets, clock: ManualClock())
        let events = s.events()
        await eventually("connect") { sockets.all.get().count == 1 }
        sockets.socket(0).push(json(.error(code: "unsupported", message: "no chat")))
        var all: [SessionStream.Event] = []
        for await e in events { all.append(e) }
        XCTAssertEqual(all.dropFirst().first, .failed(code: "unsupported", message: "no chat"))
        guard case .disconnected(_, true)? = all.last else { return XCTFail("\(all)") }

        let denied = Sockets()
        denied.fail.with { $0 = [ProviderError.unauthorized] }
        let s2 = SessionStream(request: request, view: .terminal, socket: denied, clock: ManualClock())
        var all2: [SessionStream.Event] = []
        for await e in s2.events() { all2.append(e) }
        XCTAssertEqual(all2, [.connecting, .disconnected("The daemon rejected this Mac's token.", stopped: true)])
    }

    func testStreamRequest() {
        let c = DaemonClient(base: URL(string: "http://mbp.tail.ts.net:7690")!, token: "t", http: FakeDaemon())
        let r = c.streamRequest(session: "s-1")
        XCTAssertEqual(r.url?.absoluteString, "ws://mbp.tail.ts.net:7690/v1/sessions/s-1/stream")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }
}
