import XCTest
import OverSireCore
import OverSireTestKit

final class AutomationOwnerTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_800_000_000)
        var now: Date { lock.withLock { t } }
        func add(_ s: TimeInterval) { lock.withLock { t += s } }
    }

    /// Two daemons, mbp and mba. home is the name of the machine that serves the leases.
    final class World: @unchecked Sendable {
        let clock = Clock()
        let mbp: FakeDaemon
        let mba: FakeDaemon
        private let lock = NSLock()
        private var _home = "mbp"
        private var _offline: Set<String> = []
        var grouped = true

        init() {
            let g = Group(id: "g", name: "My machines", home: MachineName(rawValue: "mbp"), version: 1, members: [], devices: [], revoked: [], removed: [])
            mbp = FakeDaemon(machine: "mbp", group: g)
            mba = FakeDaemon(machine: "mba", group: g)
            for d in [mbp, mba] { d.now = { [clock] in clock.now } }
        }

        var home: String { lock.withLock { _home } }
        func offline(_ m: String) { lock.withLock { _ = _offline.insert(m) } }

        /// The group moves home: the daemons know it, the app still asks the old home.
        func move(to m: String) {
            for d in [mbp, mba] { d.group?.home = MachineName(rawValue: m) }
        }

        func appHome(_ hint: String?) -> LeaseHome {
            guard grouped else { return .none }
            let m = hint ?? home
            if lock.withLock({ _offline.contains(m) }) { return .unreachable(m) }
            let d = m == "mbp" ? mbp : mba
            return .member(m, DaemonClient(base: URL(string: "http://\(m):7690")!, token: nil, http: d))
        }

        func owner(_ device: String, _ name: String) -> AutomationOwner {
            AutomationOwner(home: { [self] in self.appHome($0) }, device: device, name: { name }, ttl: 90, clock: { [clock] in clock.now })
        }
    }

    func testNoActionBeforeTheFirstRefresh() {
        let o = World().owner("app-1", "mbp")
        XCTAssertEqual(o.role, .paused(""))
        XCTAssertFalse(o.mayAct)
    }

    func testSoloWithNoGroup() async {
        let w = World()
        w.grouped = false
        let o = w.owner("app-1", "mbp")
        await o.refresh()
        XCTAssertEqual(o.role, .solo)
        XCTAssertTrue(o.mayAct)
    }

    func testOwnerAndOther() async {
        let w = World()
        let a = w.owner("app-1", "mbp"), b = w.owner("app-2", "mba")
        await a.refresh()
        await b.refresh()
        guard case .owner(let la) = a.role, case .other(let lb) = b.role else { return XCTFail("\(a.role) \(b.role)") }
        XCTAssertEqual(la.holderName, "mbp")
        XCTAssertEqual(lb.holderName, "mbp")
        XCTAssertTrue(a.mayAct)
        XCTAssertFalse(b.mayAct)
    }

    func testRenewKeepsEpochAndMayActEndsBeforeUntil() async {
        let w = World()
        let a = w.owner("app-1", "mbp")
        await a.refresh()
        w.clock.add(30)
        await a.refresh()
        XCTAssertEqual(a.role.lease?.epoch, 1)
        XCTAssertEqual(a.role.lease?.until, w.clock.now.addingTimeInterval(90))
        w.clock.add(81)
        XCTAssertFalse(a.mayAct, "no action in the last 10 s of the lease")
    }

    func testFailedRenewPastUntilPauses() async {
        let w = World()
        let a = w.owner("app-1", "mbp")
        await a.refresh()
        w.mbp.online = false
        w.clock.add(30)
        await a.refresh()
        XCTAssertTrue(a.mayAct, "a failed renew keeps a lease that has not ended")
        w.clock.add(61)
        await a.refresh()
        XCTAssertEqual(a.role, .paused("mbp"))
        XCTAssertFalse(a.mayAct)

        w.mbp.online = true
        await a.refresh()
        XCTAssertTrue(a.mayAct, "the automations start again when the home is back")
    }

    func testUnreachableHomePauses() async {
        let w = World()
        w.offline("mbp")
        let a = w.owner("app-1", "mbp")
        await a.refresh()
        XCTAssertEqual(a.role, .paused("mbp"))
    }

    func testOtherGetsTheLeaseAfterExpiry() async {
        let w = World()
        let a = w.owner("app-1", "mbp"), b = w.owner("app-2", "mba")
        await a.refresh()
        w.clock.add(91)
        await b.refresh()
        XCTAssertTrue(b.mayAct)
        XCTAssertEqual(b.role.lease?.epoch, 2)
        await a.refresh()
        XCTAssertFalse(a.mayAct)
    }

    func testTake() async {
        let w = World()
        let a = w.owner("app-1", "mbp"), b = w.owner("app-2", "mba")
        await a.refresh()
        await b.take()
        XCTAssertTrue(b.mayAct)
        await a.refresh()
        guard case .other(let l) = a.role else { return XCTFail("\(a.role)") }
        XCTAssertEqual(l.holderName, "mba")
    }

    func testNotHomeFollowsTheNewHome() async {
        let w = World()
        w.move(to: "mba")
        let a = w.owner("app-1", "mbp")
        await a.refresh()
        XCTAssertTrue(a.mayAct)
        XCTAssertEqual(w.mba.leases[AutomationOwner.leaseName]?.holder, "app-1")
        XCTAssertNil(w.mbp.leases[AutomationOwner.leaseName])
    }

    func testReleaseOnSleep() async {
        let w = World()
        let a = w.owner("app-1", "mbp"), b = w.owner("app-2", "mba")
        await a.refresh()
        await a.release()
        XCTAssertFalse(a.mayAct)
        await b.refresh()
        XCTAssertTrue(b.mayAct, "the other app gets the lease at once")
        XCTAssertEqual(b.role.lease?.epoch, 2)
    }

    func testRenewDoesNotPost() async {
        let w = World()
        let a = w.owner("app-1", "mbp")
        let posts = Box()
        let obs = NotificationCenter.default.addObserver(forName: AutomationOwner.changed, object: a, queue: nil) { _ in posts.add() }
        defer { NotificationCenter.default.removeObserver(obs) }
        await a.refresh()
        w.clock.add(30)
        await a.refresh()
        XCTAssertEqual(posts.count, 1)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func add() { lock.withLock { n += 1 } }
    }
}
