import OverSireCore
import OverSireSync
import XCTest
@testable import OverSireApp

/// The link of a client to its home: offline after a grace, app closed, no source, home move (OVERSIRE-530).
@MainActor
final class ClientMirrorTests: XCTestCase {
    private final class Feed: MirrorFetch, @unchecked Sendable {
        private let lock = NSLock()
        private var _epoch = "e1"
        private var _fail: Error?
        private var _source: String? = "app-1"
        private var _online = true
        private var _ready = true

        var epoch: String { get { lock.withLock { _epoch } } set { lock.withLock { _epoch = newValue } } }
        var fail: Error? { get { lock.withLock { _fail } } set { lock.withLock { _fail = newValue } } }
        var source: String? { get { lock.withLock { _source } } set { lock.withLock { _source = newValue } } }
        var online: Bool { get { lock.withLock { _online } } set { lock.withLock { _online = newValue } } }
        var ready: Bool { get { lock.withLock { _ready } } set { lock.withLock { _ready = newValue } } }

        private var doc: MirrorDoc {
            MirrorDoc(kind: .settings, id: "s", v: MirrorCodec.version, hash: "h", seq: 1, at: Date(), body: try! MirrorCodec.body(JSONValue.object([:])))
        }

        func head() async throws -> MirrorHead {
            if let e = fail { throw e }
            return lock.withLock {
                MirrorHead(epoch: _epoch, head: 1, floor: 0, ready: _ready, source: _source, sourceName: "mbp", appVersion: "1.42", sourceOnline: _online)
            }
        }

        func page(after: Int64, limit: Int, epoch sent: String?) async throws -> MirrorPage {
            if let e = fail { throw e }
            let e = epoch
            if let sent, sent != e { return MirrorPage(epoch: e, docs: [], next: 0, more: false, reset: true) }
            return MirrorPage(epoch: e, docs: after < 1 ? [doc] : [], next: 1, more: false, reset: false)
        }
    }

    private struct Down: Error {}

    private final class Clock: @unchecked Sendable {
        var t = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private final class Timers {
        var jobs: [@MainActor () -> Void] = []
    }

    private func rig(_ feed: Feed) -> (ClientMirror, Clock, Timers) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("client-mirror-\(UUID().uuidString)").path
        let reader = MirrorReader(fetch: feed, cache: MirrorCache(dir: dir, debounce: 0))
        let m = ClientMirror(reader: reader) { _ in }
        let clock = Clock()
        let timers = Timers()
        m.now = { clock.t }
        m.after = { _, body in timers.jobs.append(body) }
        m.homeName = { "mbp" }
        m.counts = { (3, 1) }
        return (m, clock, timers)
    }

    func testOfflineAfterGrace() async {
        let feed = Feed()
        let (m, clock, timers) = rig(feed)
        var up = true
        m.socketUp = { up }
        await m.run()
        guard case .live = m.status else { return XCTFail("\(m.status)") }
        let data = m.status.dataTime
        let lost = clock.t
        up = false
        feed.fail = Down()
        m.socketChanged()
        await m.run()
        guard case .live = m.status else { return XCTFail("the grace holds the state: \(m.status)") }
        clock.t = lost.addingTimeInterval(ClientMirror.grace + 1)
        timers.jobs.forEach { $0() }
        XCTAssertEqual(m.status, .homeOffline(home: "mbp", since: lost, data: data))
        XCTAssertFalse(m.status.canChange)
    }

    func testShortDropStaysLive() async {
        let feed = Feed()
        let (m, clock, timers) = rig(feed)
        var up = true
        m.socketUp = { up }
        await m.run()
        up = false
        feed.fail = Down()
        m.socketChanged()
        await m.run()
        clock.t = clock.t.addingTimeInterval(10)
        up = true
        feed.fail = nil
        m.socketChanged()
        await m.run()
        clock.t = clock.t.addingTimeInterval(60)
        timers.jobs.forEach { $0() }
        guard case .live = m.status else { return XCTFail("\(m.status)") }
        XCTAssertTrue(m.status.canChange)
    }

    func testBoxNameOffMain() async {
        let feed = Feed()
        let (m, _, _) = rig(feed)
        m.homeName = { "box" }
        let box = m.box
        await m.run()
        let name = await Task.detached { box.name }.value
        XCTAssertEqual(name, "mbp")
    }

    func testAppClosed() async {
        let feed = Feed()
        let (m, _, _) = rig(feed)
        await m.run()
        feed.online = false
        await m.run()
        guard case .appClosed(let home, let data) = m.status else { return XCTFail("\(m.status)") }
        XCTAssertEqual(home, "mbp")
        XCTAssertNotNil(data)
        XCTAssertFalse(m.status.canChange)
        feed.online = true
        await m.run()
        guard case .live = m.status else { return XCTFail("\(m.status)") }
    }

    func testHomeMoveRepoints() async {
        let feed = Feed()
        let (m, _, _) = rig(feed)
        await m.run()
        feed.fail = StoreNotHome(home: "box", message: "mba is not home")
        var during: ClientLink?
        var calls = 0
        m.rehome = {
            calls += 1
            during = m.status
            feed.fail = nil
            feed.epoch = "e2"
        }
        await m.run()
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(during, .moving(to: "box"))
        guard case .live = m.status else { return XCTFail("the old data stays until the new feed is ready: \(m.status)") }
    }

    func testNoSource() async {
        let feed = Feed()
        feed.source = nil
        let (m, _, _) = rig(feed)
        await m.run()
        XCTAssertEqual(m.status, .noSource(home: "mbp"))
        XCTAssertFalse(m.status.canChange)
    }
}
