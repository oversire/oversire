import OverSireCore
import XCTest
@testable import OverSireApp

final class ChangeBusTests: XCTestCase {
    private let clock = ManualSchedule()
    private lazy var bus = ChangeBus(schedule: clock.schedule)

    func testOneBurstGivesOneDelivery() {
        var got: [DataChange] = []
        let o = bus.observe { got.append($0) }
        for _ in 0..<20 { bus.post(DataChange(.runs, repos: ["o/a"], origin: .event)) }
        XCTAssertTrue(got.isEmpty)
        clock.advance(0.25)
        XCTAssertEqual(got.count, 1)
        XCTAssertEqual(got[0].repos, ["o/a"])
        XCTAssertEqual(bus.sent, 1)
        withExtendedLifetime(o) {}
    }

    func testMergeJoinsKeysDomainsAndOrigin() {
        var c = DataChange(.runs, repos: ["o/a"], origin: .poll)
        c.merge(DataChange([.runs, .projects], repos: ["o/b"], projects: ["ocral/p1"], origin: .user))
        XCTAssertEqual(c.domains, [.runs, .projects])
        XCTAssertEqual(c.repos, ["o/a", "o/b"])
        XCTAssertEqual(c.projects, ["ocral/p1"])
        XCTAssertEqual(c.origin, .user)
    }

    func testKeyedDomainWithNoKeysMeansAll() {
        var c = DataChange(.runs, repos: ["o/a"])
        c.merge(DataChange(.runs))
        XCTAssertEqual(c.repos, [])
        XCTAssertTrue(c.touches(.runs, repos: ["o/z"], projects: nil, items: nil))
    }

    func testTouchesFiltersByDomainAndKey() {
        let c = DataChange(.runs, repos: ["o/a"])
        XCTAssertFalse(c.touches(.prs, repos: nil, projects: nil, items: nil))
        XCTAssertTrue(c.touches(.runs, repos: nil, projects: nil, items: nil))
        XCTAssertTrue(c.touches(.runs, repos: ["o/a"], projects: nil, items: nil))
        XCTAssertFalse(c.touches(.runs, repos: ["o/b"], projects: nil, items: nil))
        XCTAssertTrue(DataChange(.queue).touches([.queue, .runs], repos: ["o/b"], projects: nil, items: nil))
    }

    func testCancelledObservationGetsNothing() {
        var n = 0
        var o: ChangeBus.Observation? = bus.observe { _ in n += 1 }
        o = nil
        bus.post(DataChange(.queue))
        clock.advance(1)
        XCTAssertEqual(n, 0)
        XCTAssertNil(o)
    }

    func testTwoBurstsGiveTwoDeliveries() {
        var n = 0
        let o = bus.observe { _ in n += 1 }
        bus.post(DataChange(.queue))
        clock.advance(1)
        bus.post(DataChange(.queue))
        clock.advance(1)
        XCTAssertEqual(n, 2)
        withExtendedLifetime(o) {}
    }

    func testReasonNamesDomainsAndKeys() {
        XCTAssertEqual(DataChange([.runs, .prs], repos: ["o/a"]).reason, "runs+prs o/a")
    }
}

final class RunDiffTests: XCTestCase {
    func testSameListsGiveNoRepo() {
        let a = [("o/a", [Run.sample(1)])]
        XCTAssertEqual(RunDiff.repos(a, a), [])
    }

    func testChangedRepoOnly() {
        let old = [("o/a", [Run.sample(1)]), ("o/b", [Run.sample(2)])]
        let new = [("o/a", [Run.sample(1)]), ("o/b", [Run.sample(2, status: "in_progress", conclusion: nil)])]
        XCTAssertEqual(RunDiff.repos(old, new), ["o/b"])
    }

    func testRepoThatComesOrGoes() {
        XCTAssertEqual(RunDiff.repos([("o/a", [Run.sample(1)])], [("o/b", [Run.sample(1)])]), ["o/a", "o/b"])
    }
}

final class UpdateGateTests: XCTestCase {
    private let clock = ManualSchedule()
    private lazy var gate = UpdateGate(idle: 1, schedule: clock.schedule)

    func testIdleGateRunsAtOnce() {
        var n = 0
        gate.submit { n += 1 }
        XCTAssertEqual(n, 1)
        XCTAssertFalse(gate.isHeld)
    }

    func testBusyGateHoldsUntilIdle() {
        var n = 0
        var held: [Bool] = []
        gate.onHeldChange = { held.append($0) }
        gate.begin(.scroll)
        gate.submit { n += 1 }
        XCTAssertTrue(gate.isHeld)
        clock.advance(5)
        XCTAssertEqual(n, 0, "no update while the signal is on")
        gate.end(.scroll)
        clock.advance(0.5)
        XCTAssertEqual(n, 0)
        clock.advance(0.6)
        XCTAssertEqual(n, 1)
        XCTAssertEqual(held, [true, false])
    }

    func testManyHeldUpdatesRunOnceWithTheLast() {
        var got: [Int] = []
        gate.begin(.mouse)
        for i in 0..<5 { gate.submit { got.append(i) } }
        gate.end(.mouse)
        clock.advance(2)
        XCTAssertEqual(got, [4])
    }

    func testNewSignalRestartsTheWait() {
        var n = 0
        gate.begin(.scroll)
        gate.submit { n += 1 }
        gate.end(.scroll)
        clock.advance(0.8)
        gate.begin(.menu)
        clock.advance(1)
        XCTAssertEqual(n, 0)
        gate.end(.menu)
        clock.advance(1)
        XCTAssertEqual(n, 1)
    }

    func testShowRunsTheHeldUpdateAtOnce() {
        var n = 0
        gate.begin(.scroll)
        gate.submit { n += 1 }
        gate.flushNow()
        XCTAssertEqual(n, 1)
        XCTAssertFalse(gate.isHeld)
        gate.end(.scroll)
        clock.advance(2)
        XCTAssertEqual(n, 1)
    }
}
