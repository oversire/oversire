import XCTest
import OverSireCore
import OverSireTestKit
@testable import RuntimeOrca

/// While a daemon is live for the account, it finds the forms. Orca then gives only the asks.
final class OrcaDaemonModeTests: XCTestCase {
    typealias S = OrcaFormsTests
    typealias F = OrcaAskFixtures

    func testScreenQuestionsOffGivesOnlyTheAsks() async throws {
        let orca = ReplayOrca()
        orca.on("terminal list", S.terminals)
        orca.on("orchestration run-current", F.bound)
        orca.on("orchestration inbox", F.inbox())
        orca.on("worktree ps", S.ps)
        orca.on("terminal read", S.read("form-local"))
        let rt = OrcaRuntime(exe: "/bin/sh", environment: "mbp", commands: orca)
        rt.now = { ISO8601DateFormatter().date(from: "2026-10-21T03:00:00Z")! }
        let form = rt.sessionRef(workspace: "b07c::/w", handle: "term_form")
        let asker = rt.sessionRef(workspace: "b07c::/w::workspace:e760", handle: F.asker)

        XCTAssertTrue(rt.screenQuestions)
        let all = try await rt.openQuestions(in: [form, asker])
        XCTAssertTrue(all.contains { $0.via == .form })
        XCTAssertTrue(all.contains { $0.via == .askReply })

        rt.screenQuestions = false
        let asks = try await rt.openQuestions(in: [form, asker])
        XCTAssertFalse(asks.isEmpty)
        XCTAssertTrue(asks.allSatisfy { $0.via == .askReply }, "\(asks.map(\.via))")
        XCTAssertTrue(asks.allSatisfy { rt.owns($0.id) })

        rt.screenQuestions = true
        let again = try await rt.openQuestions(in: [form, asker])
        XCTAssertTrue(again.contains { $0.via == .form })
    }

    func testSupervisedNamesTheWorkersOfTheCoordinator() async throws {
        let orca = ReplayOrca()
        orca.on("terminal list", F.terminals)
        orca.on("orchestration run-current", F.bound)
        orca.on("orchestration inbox", F.inbox())
        orca.on("worktree ps", #"{"ok":true,"result":{"worktrees":[]}}"#)
        let rt = OrcaRuntime(exe: "/bin/sh", environment: "mbp", commands: orca)
        let workers = try await rt.supervised()
        XCTAssertEqual(workers, [F.asker, F.other, "term_old"], "each terminal that wrote to the run")
        XCTAssertFalse(rt.owns("daemon:mbp:form:x"))
    }
}
