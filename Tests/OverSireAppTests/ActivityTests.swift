import OverSireCore
import XCTest
import OverSireTestKit
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

    // MARK: Removed items

    private let ref = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "OVERSIRE")

    private func plane(_ id: String, key: String) -> Item {
        Item(id: id, key: key, title: "Title of \(key)", url: "https://app.plane.so/ocral/browse/\(key)/", statusOptionId: nil, fields: [:],
             assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil,
             mentionsMe: false)
    }

    private func snap(_ items: [Item]) -> ProjectSnapshot {
        ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                        statusOptions: [], items: items, fetchedAt: Date())
    }

    @MainActor
    func testOldEntryGetsTheKeyFromItsLink() throws {
        let d = TestAppData()
        let old = ActivityEntry.make(projectKey: "gone/p9", itemId: "u-36", change: .removed, actor: nil,
                                     url: "https://app.plane.so/ocral/browse/OVERSIRE-36/", at: Date())
        XCTAssertNil(old.itemKey)
        try (String(decoding: JSONEncoder().encode(old), as: UTF8.self) + "\n").write(toFile: d.tmp + "/activity.jsonl", atomically: true, encoding: .utf8)
        let e = try XCTUnwrap(ActivityFeed.entries(d).first)
        XCTAssertEqual(e.itemKey, "OVERSIRE-36")
        XCTAssertEqual(e.projectKey, "OVERSIRE")
        XCTAssertFalse(e.title.contains("A removed item"))
    }

    @MainActor
    func testARemovedItemKeepsItsTitle() throws {
        let d = TestAppData()
        d.projectStore.absorb(snap([plane("u-1", key: "OVERSIRE-1"), plane("u-2", key: "OVERSIRE-2")]))
        d.projectStore.absorb(snap([plane("u-1", key: "OVERSIRE-1")]))
        let saved = try XCTUnwrap(d.projectStore.activity(limit: 10, project: nil).first)
        XCTAssertEqual(saved.itemKey, "OVERSIRE-2")
        XCTAssertEqual(saved.title, "Title of OVERSIRE-2")
        let e = try XCTUnwrap(ActivityFeed.entries(d).first)
        XCTAssertEqual(e.title, "Title of OVERSIRE-2")
        XCTAssertEqual(e.itemKey, "OVERSIRE-2")
        XCTAssertEqual(e.projectKey, "OVERSIRE")
        XCTAssertTrue(FeedLine(e) {}.accessibilityLabel()?.hasPrefix("OVERSIRE-2 Plane: ") == true)
    }

    @MainActor
    func testNoRemovedEntryWhenTheItemStillExists() async throws {
        let fake = FakeTracker()
        let there = try await fake.create(ItemDraft(title: "Still there"), in: fake.project)
        let kept = Item(id: there.id, key: "FAKE-1", title: "Still there", url: "https://tracker.fake/FAKE-1", statusOptionId: nil, fields: [:], assignees: [], labels: [],
                        author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)
        let gone = Item(id: "no-such-id", key: "FAKE-99", title: "Gone", url: "https://tracker.fake/FAKE-99", statusOptionId: nil, fields: [:], assignees: [], labels: [],
                        author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)
        let summary = ProjectSummary(ref: fake.project, identifier: "FAKE", title: "Fake", url: "", closed: false)
        let before = ProjectSnapshot(summary: summary, statusOptions: [], items: [kept, gone], fetchedAt: Date())
        let after = ProjectSnapshot(summary: summary, statusOptions: [], items: [], fetchedAt: Date())
        let still = await ProjectStore.stillThere(fake, before, after)
        XCTAssertEqual(still, [there.id], "only the item that Plane does not find counts as removed")

        let d = TestAppData()
        d.projectStore.absorb(before)
        d.projectStore.absorb(after, kept: still)
        XCTAssertEqual(d.projectStore.activity(limit: 10, project: nil).map(\.itemKey), ["FAKE-99"])
    }
}
