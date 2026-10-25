import OverSireCore
import OverSireSync
import OverSireTestKit
import RuntimeDaemon
import XCTest
@testable import OverSireApp

private final class Keys: CredentialKeeping, @unchecked Sendable {
    func get(_ key: String) -> String? { "t" }
    func set(_ key: String, _ value: String) {}
}

/// The app callers of the daemon runtimes: MachineHub, AgentIndex, AgentTerminal, QuestionHub and RefreshPlan.
final class MachineRuntimeCallerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private let repo = "/Users/ada/Projects/towertail"
    private let mba = MachineLink(machine: "mba", base: DaemonClient.loopback, token: nil, local: true)
    private let mbp = MachineLink(machine: "mbp", base: URL(string: "http://mbp:7690")!, token: "t", local: false)

    private func hub(_ d: FakeDaemon, sessions: String? = nil) -> MachineHub {
        let h = MachineHub(local: DaemonClient(base: DaemonClient.loopback, token: nil, http: d), keychain: Keys(), http: d, cache: nil)
        h.config = { MachinesConfig(sessions: sessions) }
        return h
    }

    private func wait(_ f: () -> Bool) async {
        for _ in 0..<200 where !f() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    // MARK: MachineHub

    func testOneRuntimeForEachMachine() {
        let h = hub(FakeDaemon())
        h.use([mba, mbp])
        XCTAssertTrue(h.runtime("mba") is LocalMachineRuntime, "only this Mac reveals")
        XCTAssertFalse(h.runtime("mbp") is any Revealing)
        XCTAssertEqual(h.runtime("mbp")?.account, AccountID(provider: .daemon, id: "mbp"))
        XCTAssertNil(h.runtime("mini"))
        let kept = h.runtime("mbp")
        h.use([mba, mbp, MachineLink(machine: "mini", base: URL(string: "http://mini:7690")!, token: "t", local: false)])
        XCTAssertTrue(h.runtime("mbp") === kept, "a link that did not change keeps its runtime")
        h.use([mba])
        XCTAssertNil(h.runtime("mbp"))
    }

    func testTheSessionsMachine() {
        var h = hub(FakeDaemon())
        h.use([mba, mbp])
        XCTAssertEqual(h.sessions?.account.id, "mba", "default: this Mac")
        h = hub(FakeDaemon(), sessions: "mbp")
        h.use([mba, mbp])
        XCTAssertEqual(h.sessions?.account.id, "mbp")
        h.use([mba])
        XCTAssertNil(h.sessions, "the machine has no link")
    }

    func testNoLocalDaemonOnlyAfterTheFirstRead() async {
        let d = FakeDaemon()
        d.online = false
        let h = hub(d)
        XCTAssertFalse(h.noLocalDaemon, "the app does not know yet")
        h.use([mbp])
        XCTAssertFalse(h.noLocalDaemon)
        h.refresh()
        await wait { h.read }
        h.use([mbp])
        await wait { h.noLocalDaemon }
        XCTAssertTrue(h.noLocalDaemon)
        h.use([mba, mbp])
        XCTAssertFalse(h.noLocalDaemon)
    }

    func testAViewerMacNeedsNoDaemon() async {
        let d = FakeDaemon()
        d.online = false
        let h = hub(d)
        h.refresh()
        await wait { h.read }
        h.use([mbp])
        await wait { h.noLocalDaemon }
        XCTAssertTrue(h.needsDaemon, "this Mac runs the sessions")
        h.config = { MachinesConfig(sessions: "mbp") }
        XCTAssertFalse(h.needsDaemon, "the sessions run on mbp")
    }

    // MARK: AgentTerminal and AgentIndex

    func testOpenTerminalStartsInPlaceAndOnlyThisMacShows() async throws {
        let d = FakeDaemon()
        let h = hub(d)
        h.use([mba, mbp])
        let local = try XCTUnwrap(h.runtime("mba"))
        try await local.refresh()
        let s = try await local.openTerminal(path: repo, title: "OVERSIRE-9", launch: AgentLaunch(profile: "claude", cli: "claude", command: "claude"), prompt: "Go")
        XCTAssertEqual(s.workspace.account, AccountID(provider: .daemon, id: "mba"))
        guard case .start(let r)? = d.runtime.orders.last?.order else { return XCTFail("no start order") }
        XCTAssertEqual(r.inPlace, true)
        XCTAssertEqual(r.repo, repo)
        try await local.show(s)
        XCTAssertEqual(d.runtime.reveals.count, 1)

        let remote = try XCTUnwrap(h.runtime("mbp"))
        try await remote.show(s)
        XCTAssertEqual(d.runtime.reveals.count, 1, "a remote machine does not reveal")
    }

    @MainActor
    func testAgentIndexReadsTheWorkspacesOfTheMachine() async throws {
        let d = FakeDaemon()
        let h = hub(d)
        h.use([mba, mbp])
        let local = try XCTUnwrap(h.runtime("mba"))
        try await local.refresh()
        _ = try await local.openTerminal(path: repo, title: "OVERSIRE-9", launch: AgentLaunch(profile: "claude", cli: "claude", command: "claude"), prompt: "Go")

        let index = AgentIndex(writes: nil)
        index.runtime = { local }
        XCTAssertTrue(index.canReveal)
        XCTAssertEqual(index.place, "this Mac")
        XCTAssertFalse(index.remote)
        let done = expectation(description: "poll")
        index.poll { done.fulfill() }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertNil(index.lastError)
        XCTAssertEqual(index.cards.map(\.path), [repo])

        index.runtime = { h.runtime("mbp") }
        XCTAssertFalse(index.canReveal)
        XCTAssertEqual(index.place, "mbp")
        XCTAssertTrue(index.remote)
    }

    // MARK: QuestionHub

    func testQuestionPlaceNamesTheMachine() {
        let h = hub(FakeDaemon())
        h.use([mba, mbp])
        let old = ENV.machines
        ENV.machines = h
        defer { ENV.machines = old }
        let questions = QuestionHub(agents: AgentIndex(writes: nil),
                                    writes: StoreWrites(store: LocalStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))))
        func question(_ machine: String) -> SessionQuestion {
            let s = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: .daemon, id: machine), id: "w1"), id: "term_1")
            return SessionQuestion(id: QuestionID(rawValue: "\(machine):q1"), session: s, origin: .session,
                                   items: [QuestionItem(id: "q1", text: "Go?", kind: .single, options: [.init(label: "Yes")])], via: .form, askedAt: t0)
        }
        XCTAssertEqual(questions.place(question("mba")), QuestionPlace(runtime: "OverSire daemon", host: "this Mac", app: "Orca"))
        XCTAssertEqual(questions.place(question("mbp")), QuestionPlace(runtime: "OverSire daemon", host: "remote: mbp", local: false))
    }

    // MARK: RefreshPlan

    private func event(_ machine: String, _ action: String) -> ProviderEvent {
        let account = AccountID(provider: .daemon, id: machine)
        let ref = SessionRef(workspace: WorkspaceRef(account: account, id: "w1"), id: "term_a")
        return ProviderEvent(id: "\(machine)-\(action)", provider: .daemon, account: account, kind: .session, action: action,
                             subject: .session(ref), at: t0)
    }

    func testASessionEventNamesItsMachine() {
        let plan = RefreshPlan([event("mbp", "working"), event("mbp", "waiting"), event("mba", "done"), event("mini", "question")],
                               knownRepos: [], machines: ["mbp", "mba"])
        XCTAssertEqual(plan.sessionMachines, ["mbp", "mba"], "once each; an unknown machine gives nothing")
        XCTAssertEqual(plan.questionMachines, ["mbp"])
        XCTAssertTrue(RefreshPlan([event("mbp", "question")], knownRepos: []).sessionMachines.isEmpty, "no machines: no route")
    }
}
