import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// The sessions of a daemon in AgentIndex, and the session events of a daemon in RefreshPlan.
final class DaemonSessionsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private struct Reader: AgentSessionsReading {
        var result: Result<[DaemonSession], ProviderError>
        func sessions() async throws -> [DaemonSession] { try result.get() }
    }

    private func session(_ id: String, card: String?, _ state: DaemonSession.State, reason: DaemonSession.Reason? = nil) -> DaemonSession {
        DaemonSession(id: id, machine: "mbp", runtime: "orca", harness: "claude", workspace: card, terminal: "term_\(id)", cwd: "/w",
                      repo: "o/app", state: state, reason: reason, prompt: "Go", lastMessage: "Done?", stateSince: t0, updatedAt: t0, sources: ["hook"])
    }

    private func card(_ id: String) -> Workspace {
        Workspace(id: id, repo: "app", path: "/fake/\(id)", name: id, comment: nil, liveTerminals: 1, lastActivity: t0,
                  agents: [AgentSession(phase: .working, since: t0, card: id, paneKey: "\(id):ps")])
    }

    func testTheSessionsOfTheDaemonGiveTheAgents() async throws {
        let rt = FakeRuntime(account: "mbp")
        rt.set([card("w1"), card("w2")])
        let reader = Reader(result: .success([
            session("a", card: "w1", .working, reason: .question),
            session("b", card: "w1", .done),
            session("c", card: nil, .working),
        ]))
        let (r, ps) = await AgentIndex.read(rt, reader: reader, cached: [card("w1"), card("w2")], psDue: false)
        XCTAssertFalse(ps, "no worktree ps when the cards are known and ps is not due")
        XCTAssertEqual(rt.workspacesCalls, 0)
        let cards = try r.get()
        XCTAssertEqual(cards.map(\.id), ["w1", "w2"])
        XCTAssertEqual(cards[0].agents.map(\.paneKey), ["a", "b"])
        XCTAssertEqual(cards[0].agents.map(\.phase), [.waiting, .done], "a question is needs input")
        XCTAssertEqual(cards[0].agents[0].label(), "Needs input")
        XCTAssertEqual(cards[0].agents[0].repo, "app", "the card keeps its repo")
        XCTAssertEqual(cards[1].agents, [], "the daemon gives all agents of a card")
    }

    func testAnUnknownCardOrADueReadRunsWorktreePS() async throws {
        let rt = FakeRuntime(account: "mbp")
        rt.set([card("w1"), card("w9")])
        let reader = Reader(result: .success([session("a", card: "w9", .waiting)]))
        let (r, ps) = await AgentIndex.read(rt, reader: reader, cached: [card("w1")], psDue: false)
        XCTAssertTrue(ps)
        XCTAssertEqual(try r.get().map(\.id), ["w1", "w9"])
        XCTAssertEqual(try r.get()[1].agents.map(\.phase), [.waiting])
        let (_, due) = await AgentIndex.read(rt, reader: reader, cached: [card("w1"), card("w9")], psDue: true)
        XCTAssertTrue(due)
        XCTAssertEqual(rt.workspacesCalls, 2)
    }

    func testAFailedDaemonFallsBackToWorktreePS() async throws {
        let rt = FakeRuntime(account: "mbp")
        rt.set([card("w1")])
        let (r, ps) = await AgentIndex.read(rt, reader: Reader(result: .failure(.transport("refused"))), cached: [card("w1")], psDue: false)
        XCTAssertTrue(ps)
        XCTAssertEqual(try r.get()[0].agents.map(\.paneKey), ["w1:ps"])
        let (none, _) = await AgentIndex.read(rt, reader: nil, cached: [], psDue: false)
        XCTAssertEqual(try none.get().map(\.id), ["w1"])
    }

    // MARK: RefreshPlan

    private func event(_ machine: String, _ action: String) -> ProviderEvent {
        let account = AccountID(provider: "orca", id: machine)
        let ref = SessionRef(workspace: WorkspaceRef(account: account, id: "w1"), id: "term_a")
        return ProviderEvent(id: "\(machine)-\(action)", provider: "orca", account: account, kind: .session, action: action,
                             subject: .session(ref), at: t0)
    }

    func testASessionEventOfAMachineNamesItsAccount() {
        let machines = ["mbp": "mbp", "mba": "local"]
        let plan = RefreshPlan([event("mbp", "working"), event("mbp", "waiting"), event("mba", "done"), event("mini", "question")],
                               knownRepos: [], machines: machines)
        XCTAssertEqual(plan.sessionAccounts, ["mbp", "local"], "once each; an unknown machine gives nothing")
        XCTAssertEqual(plan.questionMachines, ["mbp"])
        XCTAssertTrue(RefreshPlan([event("mbp", "question")], knownRepos: []).sessionAccounts.isEmpty, "no machines: no route")
    }
}
