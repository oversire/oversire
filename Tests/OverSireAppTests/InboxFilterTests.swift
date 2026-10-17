import OverSireCore
import XCTest
@testable import OverSireApp

final class InboxFilterTests: XCTestCase {
    private func entry(_ id: String, project: String?, priority: String?, source: InboxEntry.Source = .plane) -> InboxEntry {
        var e = InboxEntry(id: id, source: source, title: id, body: "", at: Date(), unread: true, route: nil)
        e.projectKey = project
        e.priority = priority
        return e
    }

    private lazy var list = [entry("a", project: "SLING", priority: "High"), entry("b", project: "TREBI", priority: nil),
                             entry("c", project: nil, priority: "Urgent", source: .run), entry("d", project: nil, priority: nil, source: .agent)]

    func testEmptyFilterPassesAll() {
        let f = InboxFilter()
        XCTAssertFalse(f.isOn)
        XCTAssertEqual(list.filter(f.pass).count, 4)
    }

    func testProjectFilter() {
        XCTAssertEqual(list.filter(InboxFilter(projects: ["SLING"]).pass).map(\.id), ["a"])
        XCTAssertEqual(list.filter(InboxFilter(projects: ["SLING", "TREBI"]).pass).map(\.id), ["a", "b"])
        XCTAssertEqual(list.filter(InboxFilter(projects: [InboxFilter.noProject]).pass).map(\.id), ["c", "d"])
    }

    func testPriorityFilter() {
        XCTAssertEqual(list.filter(InboxFilter(priorities: ["Urgent", "High"]).pass).map(\.id), ["a", "c"])
        XCTAssertEqual(list.filter(InboxFilter(priorities: [InboxFilter.noPriority]).pass).map(\.id), ["b", "d"])
    }

    func testBothFiltersMustPass() {
        XCTAssertEqual(list.filter(InboxFilter(projects: [InboxFilter.noProject], priorities: ["Urgent"]).pass).map(\.id), ["c"])
    }

    func testTabCountsFollowTheFilter() {
        let kept = list.filter(InboxFilter(priorities: [InboxFilter.noPriority]).pass)
        XCTAssertEqual(InboxPage.counts(kept) { $0.source.tab.rawValue }, ["all": 1, "agents": 1])
        XCTAssertEqual(InboxPage.counts(list) { $0.projectKey ?? InboxFilter.noProject }, ["SLING": 1, "TREBI": 1, InboxFilter.noProject: 2])
    }

    func testPriorityName() {
        XCTAssertEqual(InboxFilter.priorityName("high"), "High")
        XCTAssertEqual(InboxFilter.priorityName("Urgent"), "Urgent")
        XCTAssertNil(InboxFilter.priorityName("weird"))
        XCTAssertNil(InboxFilter.priorityName(nil))
    }

    func testSaveAndLoad() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "InboxFilterTests"))
        defer { d.removePersistentDomain(forName: "InboxFilterTests") }
        XCTAssertEqual(InboxFilter.load(d), InboxFilter())
        let f = InboxFilter(projects: ["SLING", InboxFilter.noProject], priorities: ["High"])
        f.save(d)
        XCTAssertEqual(InboxFilter.load(d), f)
    }
}
