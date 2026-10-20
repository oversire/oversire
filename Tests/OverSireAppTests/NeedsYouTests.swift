import XCTest
import OverSireAI
@testable import OverSireApp

final class NeedsYouTests: XCTestCase {
    private func j(_ key: String, _ v: StatusReply.State, at: TimeInterval) -> SessionStatus {
        SessionStatus(id: key, key: key, reply: StatusReply(state: v, headline: ""), ticks: [], at: Date(timeIntervalSince1970: at),
                      trigger: .idle, byAI: true, read: "")
    }

    func testChecksOfOneKindGroup() {
        let lines = NeedsYou.checks([j("A-1", .done, at: 10), j("A-2", .stuck, at: 20), j("A-3", .done, at: 30)])
        XCTAssertEqual(lines.map(\.title), ["AI: 2 sessions look done", "AI: the A-2 session: looks stuck"])
        XCTAssertEqual(lines[0].keys, ["A-1", "A-3"])
        XCTAssertEqual(lines[0].body, "A-1 · A-3")
        XCTAssertEqual(lines[0].at, Date(timeIntervalSince1970: 30), "the newest check gives the time")
        XCTAssertTrue(lines[1].keys.isEmpty, "one check keeps its own line")
        XCTAssertTrue(NeedsYou.checks([]).isEmpty)
    }
}
