import OverSireCore
import XCTest
@testable import OverSireApp

final class ProjectNotifierTests: XCTestCase {
    private var posted: [Notice] = []
    private var withdrawn: [String] = []
    private var clock = Date(timeIntervalSince1970: 1_790_000_000)

    private func notifier() -> ProjectNotifier {
        let n = ProjectNotifier(post: { [unowned self] in posted.append($0) }, withdraw: { [unowned self] in withdrawn.append($0) })
        n.now = { [unowned self] in clock }
        return n
    }

    private var snap: ProjectSnapshot {
        let item = Item(id: "a", key: "ENG-1", title: "Item", url: "u", statusOptionId: "t", fields: [:], assignees: ["me"], labels: [],
                        author: "bea", updatedBy: "bea", updatedAt: clock, activityAt: clock, commentCount: 0, lastComment: nil, mentionsMe: false)
        return ProjectSnapshot(summary: ProjectSummary(ref: ProjectRef(workspace: "ws", id: "p"), identifier: "ENG", title: "Eng", url: "", closed: false),
                               statusOptions: [StatusOption(id: "t", name: "Todo", color: "", group: "unstarted")], items: [item],
                               fetchedAt: clock, me: "me")
    }

    private var all: ProjectNotificationSettings {
        var s = ProjectNotificationSettings()
        s.status = NotifyScope(any: true, mine: true)
        s.closed = NotifyScope(any: true, mine: true)
        s.otherFields = NotifyScope(any: true, mine: true)
        return s
    }

    func testAwayLineGivesNoNotification() {
        let notifier = ProjectNotifier()
        var all = ProjectNotificationSettings()
        all.comment = NotifyScope(any: true, mine: true)
        XCTAssertFalse(notifier.allows(.away(items: 5), item: nil, me: "me", settings: all))
        XCTAssertFalse(notifier.allows(.away(items: 1), item: nil, me: nil, settings: ProjectNotificationSettings()))
    }

    func testWindowShowsNetChange() {
        let n = notifier()
        n.handle([("a", .status(from: "Done", to: "In Progress")), ("a", .reopened)], in: snap, settings: all)
        XCTAssertEqual(posted.last?.title, "↺ Reopened · ENG-1")
        clock += 60
        n.handle([("a", .status(from: "In Progress", to: "Done")), ("a", .closed)], in: snap, settings: all)
        XCTAssertEqual(posted.count, 2)
        XCTAssertEqual(posted.last?.id, "project:a")
        XCTAssertEqual(posted.last?.title, "✓ Done again · ENG-1")
        XCTAssertEqual(posted.last?.level, .passive)
        XCTAssertFalse(posted.last?.body.contains("Reopened\n") ?? true, "no list of steps")
    }

    func testNewWindowAfterTwoMinutes() {
        let n = notifier()
        n.handle([("a", .status(from: "Todo", to: "Done")), ("a", .closed)], in: snap, settings: all)
        clock += 180
        n.handle([("a", .status(from: "Done", to: "Todo")), ("a", .reopened)], in: snap, settings: all)
        XCTAssertEqual(posted.map(\.title), ["✓ Done · ENG-1", "↺ Reopened · ENG-1"])
        XCTAssertEqual(posted.last?.body, "Todo. Was Done.")
    }

    func testEmptyNetWithdraws() {
        let n = notifier()
        n.handle([("a", .field(name: "Priority", from: "Low", to: "High"))], in: snap, settings: all)
        XCTAssertEqual(posted.last?.title, "✎ Priority · ENG-1")
        clock += 30
        n.handle([("a", .field(name: "Priority", from: "High", to: "Low"))], in: snap, settings: all)
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(withdrawn, ["project:a"])
    }
}
