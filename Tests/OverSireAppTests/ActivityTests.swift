import OverSireCore
import XCTest
@testable import OverSireApp

final class ActivityTests: XCTestCase {
    private func entry(_ id: String, project: String?, source: FeedEntry.Source = .plane, at: Date = Date()) -> FeedEntry {
        var e = FeedEntry(id: id, source: source, title: id, body: "", at: at, route: nil)
        e.projectKey = project
        return e
    }

    private lazy var list = [entry("a", project: "SLING"), entry("b", project: "TREBI", source: .mention),
                             entry("c", project: nil, source: .run), entry("d", project: nil, source: .agent)]

    func testIntakeLineShowsTheIDOrTheFallback() {
        var e = entry("i", project: "TREBI", source: .intake)
        XCTAssertEqual(e.shownID, "TREBI-–", "no UUID while the number loads")
        e.intakeKey = "TREBI-471"
        XCTAssertEqual(e.shownID, "TREBI-471")
        XCTAssertEqual(FeedLine(e, layout: FeedLine.intakeLayout) {}.accessibilityLabel()?.hasPrefix("TREBI-471 "), true)
    }

    func testEmptyFilterPassesAll() {
        let f = FeedFilter()
        XCTAssertFalse(f.isOn)
        XCTAssertEqual(list.filter(f.pass).count, 4)
    }

    func testProjectFilter() {
        XCTAssertEqual(list.filter(FeedFilter(projects: ["SLING"]).pass).map(\.id), ["a"])
        XCTAssertEqual(list.filter(FeedFilter(projects: ["SLING", "TREBI"]).pass).map(\.id), ["a", "b"])
        XCTAssertEqual(list.filter(FeedFilter(projects: [FeedFilter.noProject]).pass).map(\.id), ["c", "d"])
    }

    func testSourceFilter() {
        XCTAssertEqual(list.filter(FeedFilter(sources: ["GitHub", "Orca"]).pass).map(\.id), ["c", "d"])
        XCTAssertEqual(list.filter(FeedFilter(projects: [FeedFilter.noProject], sources: ["Orca"]).pass).map(\.id), ["d"])
    }

    func testCounts() {
        XCTAssertEqual(ActivityPage.counts(list) { $0.source.rawValue }, ["Plane": 1, "Mention": 1, "GitHub": 1, "Orca": 1])
        XCTAssertEqual(ActivityPage.counts(list) { $0.projectKey ?? FeedFilter.noProject }, ["SLING": 1, "TREBI": 1, FeedFilter.noProject: 2])
    }

    func testFilterSaves() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "ActivityTests"))
        defer { d.removePersistentDomain(forName: "ActivityTests") }
        XCTAssertEqual(FeedFilter.load(d), FeedFilter())
        let f = FeedFilter(projects: ["SLING", FeedFilter.noProject], sources: ["AI"])
        f.save(d)
        XCTAssertEqual(FeedFilter.load(d), f)
    }

    @MainActor
    func testActivityRowHasNoUnreadState() {
        let row = FeedLine(entry("a", project: "SLING")) {}
        XCTAssertEqual(row.accessibilityLabel(), "Plane: a. ")
        XCTAssertNil(FeedLine.layout.columns.first { $0.id == "unread" }, "no unread dot")
    }

    func testIntakeCountForEachProject() {
        let items = [entry("1", project: "SLING", source: .intake), entry("2", project: "TREBI", source: .intake),
                     entry("3", project: "SLING", source: .intake), entry("4", project: nil, source: .intake)]
        let c = IntakeListPage.counts(items)
        XCTAssertEqual(c.map(\.project), ["SLING", FeedFilter.noProject, "TREBI"])
        XCTAssertEqual(c.map(\.count), [2, 1, 1])
    }

    func testIntakeAddedToday() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 86400 * 20000 + 3600)
        let items = [entry("1", project: "A", at: now.addingTimeInterval(-60)), entry("2", project: "A", at: now.addingTimeInterval(-3599)),
                     entry("3", project: "A", at: now.addingTimeInterval(-3601))]
        XCTAssertEqual(IntakeListPage.addedToday(items, now: now, calendar: utc), 2, "midnight is the boundary")
    }
}
