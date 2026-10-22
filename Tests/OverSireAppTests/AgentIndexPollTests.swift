import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// Runs the scheduled work of AgentIndex when the test moves the clock.
private final class ManualScheduler {
    let clock = ManualClock()
    private var jobs: [(id: Int, at: Duration, work: () -> Void)] = []
    private var nextID = 0

    var pending: Int { jobs.count }
    var elapsed: TimeInterval { Double(clock.now.offset.components.seconds) }

    func schedule(_ after: TimeInterval, _ work: @escaping () -> Void) -> () -> Void {
        nextID += 1
        let id = nextID
        jobs.append((id, clock.now.offset + .milliseconds(Int(after * 1000)), work))
        return { [weak self] in self?.jobs.removeAll { $0.id == id } }
    }

    func advance(by s: TimeInterval) {
        let end = clock.now.offset + .milliseconds(Int(s * 1000))
        while let job = jobs.filter({ $0.at <= end }).min(by: { $0.at < $1.at }) {
            jobs.removeAll { $0.id == job.id }
            clock.advance(by: job.at - clock.now.offset)
            job.work()
        }
        clock.advance(by: end - clock.now.offset)
    }
}

private actor Latch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

final class AgentIndexPollTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    private var rt: FakeRuntime!
    private var sched: ManualScheduler!
    private var index: AgentIndex!
    private var alerts: [String] = []

    override func setUp() {
        rt = FakeRuntime()
        sched = ManualScheduler()
        index = AgentIndex(writes: nil)
        let rt = rt!, sched = sched!, t0 = t0
        index.runtime = { rt }
        index.now = { t0.addingTimeInterval(sched.elapsed) }
        index.schedule = { sched.schedule($0, $1) }
        index.onAlert = { [weak self] key, _ in self?.alerts.append(key) }
        alerts = []
    }

    private var now: Date { t0.addingTimeInterval(sched.elapsed) }

    private func card(_ phase: AgentSession.Phase, since: Date) -> Workspace {
        Workspace(id: "w1", repo: "app", path: "/fake/app", name: "ABC-1", comment: nil, liveTerminals: 1, lastActivity: since,
                  agents: [AgentSession(phase: phase, since: since, card: "w1", paneKey: "w1:1")])
    }

    private func waitUntil(_ cond: () -> Bool, file: StaticString = #filePath, line: UInt = #line) {
        let end = Date().addingTimeInterval(2)
        while !cond() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        XCTAssertTrue(cond(), file: file, line: line)
    }

    private func settle(calls: Int, file: StaticString = #filePath, line: UInt = #line) {
        waitUntil({ rt.workspacesCalls == calls && !index.polling }, file: file, line: line)
    }

    private func pollNow() {
        let n = rt.workspacesCalls
        index.poll()
        settle(calls: n + 1)
    }

    func testPollDuringAPollRunsOnceMore() {
        let latch = Latch()
        rt.gateWorkspaces { await latch.wait() }
        index.poll()
        waitUntil { rt.workspacesCalls == 1 }
        index.poll()
        index.hint()
        XCTAssertEqual(rt.workspacesCalls, 1)
        Task { await latch.release() }
        settle(calls: 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(rt.workspacesCalls, 2)
    }

    func testHintFromAnotherThreadPolls() {
        let other = AccountID(provider: "fake-runtime", id: "other")
        DispatchQueue.global().async { [index] in index!.hint(account: other) }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(rt.workspacesCalls, 0, "a hint of another account does nothing")
        DispatchQueue.global().async { [index, rt] in index!.hint(account: rt!.account) }
        settle(calls: 1)
    }

    func testYoungWaitingStateAlertsAtTenSeconds() {
        pollNow()
        rt.set([card(.waiting, since: now.addingTimeInterval(-3))])
        pollNow()
        XCTAssertEqual(alerts, [])
        XCTAssertEqual(index.holdCheckCount, 1)
        XCTAssertEqual(sched.pending, 1)

        sched.advance(by: 7)
        settle(calls: 3)
        XCTAssertEqual(alerts, ["ABC-1"])
        XCTAssertEqual(index.holdCheckCount, 0)
        XCTAssertEqual(sched.pending, 0)
    }

    func testNewStateReplacesTheHoldCheck() {
        pollNow()
        rt.set([card(.waiting, since: now.addingTimeInterval(-3))])
        pollNow()
        XCTAssertEqual(sched.pending, 1)

        sched.advance(by: 2)
        rt.set([card(.working, since: now)])
        pollNow()
        XCTAssertEqual(index.holdCheckCount, 0, "a working agent needs no check")
        XCTAssertEqual(sched.pending, 0)

        rt.set([card(.waiting, since: now)])
        pollNow()
        XCTAssertEqual(sched.pending, 1)
        sched.advance(by: 9)
        XCTAssertEqual(rt.workspacesCalls, 4, "the old check is gone")
        sched.advance(by: 1)
        settle(calls: 5)
        XCTAssertEqual(alerts, ["ABC-1"])
    }

    func testBackgroundCadenceFollowsTheAgents() {
        rt.set([card(.working, since: t0)])
        index.startTimer()
        settle(calls: 1)
        for n in 2...3 {
            sched.advance(by: 15)
            settle(calls: n)
        }
        rt.set([card(.done, since: t0)])
        sched.advance(by: 15)
        settle(calls: 4)
        XCTAssertEqual(index.agent("ABC-1")?.phase, .done)
        for _ in 0..<3 {
            sched.advance(by: 15)
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            XCTAssertEqual(rt.workspacesCalls, 4, "all done: no poll before 60 s")
        }
        sched.advance(by: 15)
        settle(calls: 5)
    }
}
