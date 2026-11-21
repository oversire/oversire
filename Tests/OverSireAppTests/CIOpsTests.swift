import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// The CI writes of the app: rights, de-dup and event rows.
final class CIOpsTests: XCTestCase {
    final class Accounts: RepoAccounts {
        let ci: FakeCI
        init(_ ci: FakeCI) { self.ci = ci }
        func codeHost(owner: String) -> (any CodeHost)? { nil }
        func ci(owner: String) -> (any CIProvider)? { ci }
    }

    actor Outlet: EventOutlet {
        var rows: [EventDraft] = []
        func append(_ drafts: [EventDraft]) async { rows += drafts }
        func link(_ l: [ItemLink]) async {}
    }

    final class Box<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ v: T) { value = v }
        func get() -> T { lock.withLock { value } }
        func set(_ v: T) { lock.withLock { value = v } }
        func update(_ f: (inout T) -> Void) { lock.withLock { f(&value) } }
    }

    struct Rig {
        let fake: FakeCI
        let outlet = Outlet()
        let desk: EventDesk
        let rights = Box(AgentCIRights())
        let clock = Box(Date(timeIntervalSince1970: 1_793_000_000))
        let refreshed = Box<[String]>([])
        let ops: CIOps

        init(_ fake: FakeCI = FakeCI()) {
            self.fake = fake
            let desk = EventDesk(outlet: outlet)
            desk.machine = { "mba" }
            desk.email = { "fritz@example.com" }
            self.desk = desk
            let rights = rights, clock = clock, refreshed = refreshed
            ops = CIOps(accounts: Accounts(fake), rights: { rights.get() }, tracked: { ["fake/app"] }, desk: { desk },
                        refresh: { repo in refreshed.update { $0.append(repo) } }, now: { clock.get() }, ciName: { _ in "Fake CI" })
            desk.now = { clock.get() }
        }

        func advance(_ s: TimeInterval) { clock.update { $0 = $0.addingTimeInterval(s) } }

        func rows(count: Int) async -> [EventDraft] {
            for _ in 0..<200 {
                let r = await outlet.rows
                if r.count >= count { return r }
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            return await outlet.rows
        }
    }

    let human = EventActor.user
    let agent = EventActor(type: .agent, name: "codex", via: "cli@mba")

    func expectError(_ expected: CIOpError, _ body: () async throws -> CIActionResult, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? CIOpError, expected, file: file, line: line)
        }
    }

    func running(_ id: String = "1", attempt: Int = 1) -> Run {
        FakeCI.run(id: id, status: "in_progress", conclusion: nil, attempt: attempt)
    }

    // MARK: Rerun

    func testRerunOnRunningAttemptIsNoop() async throws {
        let rig = Rig()
        rig.fake.put(running(attempt: 2))
        let r = try await rig.ops.rerun(repo: "fake/app", run: "1", failedOnly: false, by: human)
        XCTAssertTrue(r.ok && r.noop)
        XCTAssertEqual(r.run?.attempt, 2)
        XCTAssertEqual(r.summary, "Run 1 attempt 2 is already running. No new rerun.")
        XCTAssertEqual(rig.fake.vendorCalls, 0)
    }

    func testRerunGivesTheRunAsRead() async throws {
        let rig = Rig()
        let r = try await rig.ops.rerun(repo: "fake/app", run: "1", failedOnly: false, by: human)
        XCTAssertFalse(r.noop)
        XCTAssertEqual(r.run?.attempt, 1, "the new attempt is run.attempt + 1")
        XCTAssertEqual(rig.fake.vendorCalls, 1)
        XCTAssertEqual(rig.refreshed.get(), ["fake/app"])
    }

    func testConcurrentRerunsCallVendorOnce() async throws {
        let rig = Rig()
        async let a = rig.ops.rerun(repo: "fake/app", run: "1", failedOnly: false, by: human)
        async let b = rig.ops.rerun(repo: "fake/app", run: "1", failedOnly: false, by: human)
        let results = try await [a, b]
        XCTAssertEqual(rig.fake.vendorCalls, 1)
        XCTAssertEqual(results.filter(\.noop).count, 1)
    }

    func testRerunWithin60sIsNoop() async throws {
        let rig = Rig()
        _ = try await rig.ops.rerun(repo: "fake/app", run: "1", failedOnly: false, by: human)
        rig.fake.put(FakeCI.run(id: "1", status: "completed", conclusion: "failure", attempt: 2))
        rig.advance(10)
        let again = try await rig.ops.rerun(repo: "fake/app", run: "1", failedOnly: false, by: human)
        XCTAssertTrue(again.noop)
        XCTAssertEqual(rig.fake.vendorCalls, 1)
        rig.advance(51)
        let later = try await rig.ops.rerun(repo: "fake/app", run: "1", failedOnly: false, by: human)
        XCTAssertFalse(later.noop)
        XCTAssertEqual(later.run?.attempt, 2)
        XCTAssertEqual(rig.fake.vendorCalls, 2)
    }

    func testRerunJobSharesKey() async throws {
        let rig = Rig()
        _ = try await rig.ops.rerun(repo: "fake/app", run: "1", failedOnly: true, by: human)
        rig.fake.put(FakeCI.run(id: "1", status: "completed", conclusion: "failure", attempt: 2))
        rig.advance(5)
        let job = try await rig.ops.rerunJob(repo: "fake/app", run: "1", job: "1-build", by: human)
        XCTAssertTrue(job.noop)
        XCTAssertEqual(rig.fake.vendorCalls, 1)
    }

    func testRerunJobRuns() async throws {
        let rig = Rig()
        let r = try await rig.ops.rerunJob(repo: "fake/app", run: "1", job: "1-build", by: human)
        XCTAssertFalse(r.noop)
        XCTAssertEqual(r.summary, "Job 1-build runs again.")
        XCTAssertEqual(rig.fake.vendorCalls, 1)
    }

    func testRerunFailedOnSuccessIsInvalid() async {
        let rig = Rig()
        rig.fake.put(FakeCI.run(id: "1", status: "completed", conclusion: "success", attempt: 1))
        await expectError(.invalid("Run 1 has no failed jobs.")) { try await rig.ops.rerun(repo: "fake/app", run: "1", failedOnly: true, by: human) }
        XCTAssertEqual(rig.fake.vendorCalls, 0)
    }

    func testRerunVendorErrorIsVendor() async {
        let rig = Rig()
        do {
            _ = try await rig.ops.rerun(repo: "fake/app", run: "99", failedOnly: false, by: human)
            XCTFail("expected vendor")
        } catch CIOpError.vendor {
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: Cancel

    func testCancelCompletedIsNoop() async throws {
        let rig = Rig()
        let r = try await rig.ops.cancel(repo: "fake/app", run: "1", by: human)
        XCTAssertTrue(r.noop)
        XCTAssertEqual(rig.fake.vendorCalls, 0)
    }

    func testAgentCancelAllowedByDefault() async throws {
        let rig = Rig()
        rig.fake.put(running())
        let r = try await rig.ops.cancel(repo: "fake/app", run: "1", by: agent)
        XCTAssertFalse(r.noop)
        XCTAssertEqual(rig.fake.vendorCalls, 1)
    }

    func testAgentCancelRefusedWhenOff() async {
        let rig = Rig()
        rig.fake.put(running())
        rig.rights.set(AgentCIRights(cancel: false, approve: false))
        await expectError(.agentRefused("Agents may not cancel runs. Turn it on in Settings › Agents › CI.")) {
            try await rig.ops.cancel(repo: "fake/app", run: "1", by: agent)
        }
        XCTAssertEqual(rig.fake.vendorCalls, 0)
        let assistant = EventActor(type: .agent, name: "assistant")
        await expectError(.agentRefused("Agents may not cancel runs. Turn it on in Settings › Agents › CI.")) {
            try await rig.ops.cancel(repo: "fake/app", run: "1", by: assistant)
        }
    }

    func testHumanCancelIgnoresTheAgentSetting() async throws {
        let rig = Rig()
        rig.fake.put(running())
        rig.rights.set(AgentCIRights(cancel: false, approve: false))
        let r = try await rig.ops.cancel(repo: "fake/app", run: "1", by: human)
        XCTAssertFalse(r.noop)
    }

    // MARK: Approve

    func gates() -> [Gate] {
        [Gate(id: "10", name: "prod", canApprove: true), Gate(id: "11", name: "stage", canApprove: true), Gate(id: "12", name: "dev", canApprove: false)]
    }

    func testAgentApproveRefusedByDefault() async {
        let rig = Rig()
        rig.fake.pending = ["1": gates()]
        await expectError(.agentRefused("Agents may not approve deployments. Turn it on in Settings › Agents › CI.")) {
            try await rig.ops.approve(repo: "fake/app", run: "1", environments: [], comment: nil, by: agent)
        }
        XCTAssertEqual(rig.fake.vendorCalls, 0)
    }

    func testHumanApproveAllowed() async throws {
        let rig = Rig()
        rig.fake.pending = ["1": gates()]
        let r = try await rig.ops.approve(repo: "fake/app", run: "1", environments: [], comment: nil, by: human)
        XCTAssertFalse(r.noop)
        XCTAssertEqual(rig.fake.pending["1"]?.map(\.id), ["12"], "the gate that the user cannot approve stays")
    }

    func testAgentApproveAllowedWhenOn() async throws {
        let rig = Rig()
        rig.rights.set(AgentCIRights(cancel: true, approve: true))
        rig.fake.pending = ["1": gates()]
        let r = try await rig.ops.approve(repo: "fake/app", run: "1", environments: [], comment: nil, by: agent)
        XCTAssertFalse(r.noop)
    }

    func testApproveNoWaitingGateIsNoop() async throws {
        let rig = Rig()
        let r = try await rig.ops.approve(repo: "fake/app", run: "1", environments: [], comment: nil, by: human)
        XCTAssertTrue(r.noop)
        XCTAssertEqual(r.summary, "Run 1 waits for no deployment that you can approve.")
        XCTAssertEqual(rig.fake.vendorCalls, 0)
        let rows = await rig.rows(count: 1)
        XCTAssertEqual(rows.count, 0)
    }

    func testApproveFiltersEnvironments() async throws {
        let rig = Rig()
        rig.fake.pending = ["1": gates()]
        let r = try await rig.ops.approve(repo: "fake/app", run: "1", environments: ["prod"], comment: nil, by: human)
        XCTAssertFalse(r.noop)
        XCTAssertEqual(rig.fake.pending["1"]?.map(\.id), ["11", "12"])
        let rows = await rig.rows(count: 1)
        XCTAssertEqual(rows.first?.id, "gha:1:1:approved:10")
        XCTAssertEqual(rows.first?.payload?["environments"], .array([.string("prod")]))
    }

    // MARK: Dispatch

    func testDispatchFindsWorkflowByName() async throws {
        let rig = Rig()
        for name in ["CI", "ci.yml", "ci"] {
            let r = try await rig.ops.dispatch(repo: "fake/app", workflow: name, ref: "main", inputs: ["n": name], by: human)
            XCTAssertFalse(r.noop, name)
        }
        XCTAssertEqual(rig.fake.dispatched.count, 3)
        XCTAssertEqual(rig.fake.dispatched.first?.pipeline, "ci")
    }

    func testDispatchGivesTheNewRun() async throws {
        let rig = Rig()
        let r = try await rig.ops.dispatch(repo: "fake/app", workflow: "CI", ref: "main", inputs: [:], by: agent)
        XCTAssertEqual(r.run?.id, "101")
        XCTAssertEqual(r.run?.status, "queued")
        XCTAssertNotNil(r.url)
    }

    func testDispatchUnknownWorkflowListsNames() async {
        let rig = Rig()
        await expectError(.invalid("fake/app has no workflow nope. Workflows: CI.")) {
            try await rig.ops.dispatch(repo: "fake/app", workflow: "nope", ref: "main", inputs: [:], by: human)
        }
        XCTAssertEqual(rig.fake.vendorCalls, 0)
    }

    func testDispatchTooManyInputs() async {
        let rig = Rig()
        let many = Dictionary(uniqueKeysWithValues: (1...26).map { ("k\($0)", "v") })
        do {
            _ = try await rig.ops.dispatch(repo: "fake/app", workflow: "CI", ref: "main", inputs: many, by: human)
            XCTFail("expected invalid")
        } catch CIOpError.invalid {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testDispatchNeedsRef() async {
        let rig = Rig()
        do {
            _ = try await rig.ops.dispatch(repo: "fake/app", workflow: "CI", ref: "", inputs: [:], by: human)
            XCTFail("expected invalid")
        } catch CIOpError.invalid {
        } catch {
            XCTFail("\(error)")
        }
    }

    func testDispatchTwiceWithin30sIsNoop() async throws {
        let rig = Rig()
        _ = try await rig.ops.dispatch(repo: "fake/app", workflow: "CI", ref: "main", inputs: ["a": "1"], by: agent)
        rig.advance(10)
        let again = try await rig.ops.dispatch(repo: "fake/app", workflow: "CI", ref: "main", inputs: ["a": "1"], by: agent)
        XCTAssertTrue(again.noop)
        let other = try await rig.ops.dispatch(repo: "fake/app", workflow: "CI", ref: "main", inputs: ["a": "2"], by: agent)
        XCTAssertFalse(other.noop)
        rig.advance(31)
        let later = try await rig.ops.dispatch(repo: "fake/app", workflow: "CI", ref: "main", inputs: ["a": "1"], by: agent)
        XCTAssertFalse(later.noop)
        XCTAssertEqual(rig.fake.dispatched.count, 3)
    }

    func testDispatchRowHoldsInputKeysOnly() async throws {
        let rig = Rig()
        _ = try await rig.ops.dispatch(repo: "fake/app", workflow: "CI", ref: "main", inputs: ["token": "s3cret", "env": "prod"], by: agent)
        let rows = await rig.rows(count: 1)
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row.kind, .ciDispatched)
        XCTAssertEqual(row.id, "gha:dispatch:101")
        XCTAssertEqual(row.payload?["inputKeys"], .array([.string("env"), .string("token")]))
        XCTAssertFalse(String(describing: row).contains("s3cret"))
        XCTAssertEqual(EventCatalog.repo.problems(row), [])
    }

    // MARK: Support, scope, events

    func testUnsupportedDispatch() async {
        let rig = Rig(FakeCI(capabilities: [.rerun]))
        await expectError(.unsupported(ci: "Fake CI", what: "dispatch")) {
            try await rig.ops.dispatch(repo: "fake/app", workflow: "CI", ref: "main", inputs: [:], by: human)
        }
        rig.rights.set(AgentCIRights(cancel: true, approve: true))
        await expectError(.unsupported(ci: "Fake CI", what: "deployment approval")) {
            try await rig.ops.approve(repo: "fake/app", run: "1", environments: [], comment: nil, by: human)
        }
        await expectError(.unsupported(ci: "Fake CI", what: "cancel")) { try await rig.ops.cancel(repo: "fake/app", run: "1", by: human) }
    }

    func testUntrackedRepo() async {
        let rig = Rig()
        await expectError(.untracked("x/y")) { try await rig.ops.rerun(repo: "x/y", run: "1", failedOnly: false, by: human) }
        await expectError(.untracked("x/y")) { try await rig.ops.dispatch(repo: "x/y", workflow: "CI", ref: "main", inputs: [:], by: human) }
    }

    func testWriteSendsEventRow() async throws {
        let rig = Rig()
        rig.fake.put(running())
        _ = try await rig.ops.cancel(repo: "fake/app", run: "1", by: agent)
        let rows = await rig.rows(count: 1)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .ciCancelled)
        XCTAssertEqual(rows[0].id, "gha:1:1:cancelled")
        XCTAssertEqual(rows[0].actorType, .agent)
        XCTAssertEqual(rows[0].actor, "codex")
        XCTAssertEqual(rows[0].via, "cli@mba")
        XCTAssertEqual(EventCatalog.repo.problems(rows[0]), [])
        // A noop sends no row.
        rig.fake.put(FakeCI.run(id: "1", status: "completed", conclusion: "cancelled", attempt: 1))
        let noop = try await rig.ops.cancel(repo: "fake/app", run: "1", by: agent)
        XCTAssertTrue(noop.noop)
        try await Task.sleep(nanoseconds: 50_000_000)
        let after = await rig.outlet.rows
        XCTAssertEqual(after.count, 1)
    }
}
