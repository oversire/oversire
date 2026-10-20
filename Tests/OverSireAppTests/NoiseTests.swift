import XCTest
import OverSireCore
@testable import OverSireApp

final class NoiseTests: XCTestCase {
    private func plane(_ id: String, key: String?, at: TimeInterval, unread: Bool = false) -> InboxEntry {
        InboxEntry(id: "plane|" + id, source: .plane, title: key ?? "", body: "ada: change \(id)", at: Date(timeIntervalSince1970: at),
                   unread: unread, route: nil, activityId: id, itemKey: key)
    }

    func testPlaneRowsOfOneItemAndDayGroup() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let day: TimeInterval = 86400 * 20000
        let mention = InboxEntry(id: "m", source: .mention, title: "", body: "", at: Date(timeIntervalSince1970: day + 50),
                                 unread: true, route: nil, activityId: "m", itemKey: "A-1")
        let out = InboxFeed.grouped([plane("1", key: "A-1", at: day + 10, unread: true), plane("2", key: "A-1", at: day + 30),
                                     plane("3", key: "A-2", at: day + 20), plane("4", key: "A-1", at: day - 10), mention], calendar: utc)
        XCTAssertEqual(out.map(\.id), ["m", "plane|2", "plane|3", "plane|4"])
        XCTAssertEqual(out[1].groupedIds, ["1"])
        XCTAssertEqual(out[1].body, "2 changes · last: ada: change 2")
        XCTAssertTrue(out[1].unread, "one unread change makes the line unread")
        XCTAssertEqual(out[2].body, "ada: change 3", "a single change keeps its text")
    }

    func testActiveWorktrees() {
        func ws(_ phases: [AgentSession.Phase]) -> Workspace {
            Workspace(id: "w", repo: "r", path: "/p", name: "w", comment: nil, liveTerminals: 2, lastActivity: Date(),
                      agents: phases.map { AgentSession(phase: $0, since: Date()) })
        }
        XCTAssertTrue(AgentsPage.isActive(ws([.done]), linked: true), "a worktree with an item shows")
        XCTAssertFalse(AgentsPage.isActive(ws([.working, .waiting]), linked: false), "a working agent without an item key hides")
        XCTAssertFalse(AgentsPage.isActive(ws([]), linked: false), "a shell alone hides")
    }
}
