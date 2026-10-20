import XCTest
import OverSireCore
import OverSireAI
@testable import OverSireApp

final class ItemStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)
    private var agent: AgentSession { AgentSession(phase: .done, since: now.addingTimeInterval(-600)) }
    private var blocked: SessionStatus {
        SessionStatus(id: "s", key: "A-1", reply: StatusReply(state: .blocked, headline: "Waits for a deploy", next: ["Close it"],
                                                               needsYou: [.init(text: "Approve the deploy")], blockedBy: ["A-2"]),
                      ticks: [false], at: now.addingTimeInterval(-60), trigger: .turnEnd, byAI: true, read: "")
    }

    private func resolve(_ s: SessionStatus?, old: String? = nil, state: SessionState? = .done, text: String? = nil,
                         agent: AgentSession?) -> ItemStatus? {
        ItemStatus.resolve(status: s, outOfDate: old, state: state, stateText: text, agent: agent, terminals: 1,
                           screen: "done at 14:00", idleNote: "Next status after 10 min idle", now: now)
    }

    func testCurrentAIStatusWins() throws {
        let s = try XCTUnwrap(resolve(blocked, agent: agent))
        XCTAssertEqual(s.source, .ai)
        XCTAssertEqual(s.label, "Blocked on you ✦")
        XCTAssertEqual(s.headline, "Waits for a deploy")
        XCTAssertEqual(s.needsYou, ["Approve the deploy"])
        XCTAssertEqual(s.next, ["Close it"])
        XCTAssertEqual(s.blockedBy, ["A-2"])
        XCTAssertEqual(s.facts.last, "Read at the turn end")
        XCTAssertTrue(s.facts.contains("1 terminal"))
    }

    func testStatusWithoutAIHasNoMark() throws {
        var b = blocked
        b.byAI = false
        let s = try XCTUnwrap(resolve(b, agent: agent))
        XCTAssertEqual(s.source, .ai)
        XCTAssertEqual(s.label, "Blocked on you")
    }

    func testOutdatedAIStatusGivesTheScreenState() throws {
        let s = try XCTUnwrap(resolve(blocked, old: "Out of date: a new agent message", state: .quiet, text: "Quiet 12m", agent: agent))
        XCTAssertEqual(s.source, .screen)
        XCTAssertEqual(s.label, "Quiet 12m")
        XCTAssertTrue(s.headline.contains("Out of date"))
        XCTAssertTrue(s.needsYou.isEmpty)
    }

    func testScreenStateWithoutStatus() throws {
        let s = try XCTUnwrap(resolve(nil, state: .working, text: "Working 50m", agent: agent))
        XCTAssertEqual(s.source, .screen)
        XCTAssertEqual(s.text, "Working 50m")
        XCTAssertEqual(s.origin, "no AI status yet")
        XCTAssertEqual(s.facts.last, "Next status after 10 min idle")
    }

    func testRuntimePhaseWithoutScreen() throws {
        let s = try XCTUnwrap(resolve(nil, state: nil, agent: AgentSession(phase: .waiting, since: now)))
        XCTAssertEqual(s.source, .phase)
        XCTAssertEqual(s.text, "Needs input")
    }

    func testNoSession() {
        XCTAssertNil(resolve(nil, state: nil, agent: nil))
    }
}
