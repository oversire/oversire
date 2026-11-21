import XCTest
import OverSireCore
import OverSireTestKit
@testable import TrackerBigTimer

/// The index of all issues of a project (OVERSIRE-577).
final class BigTimerIndexTests: XCTestCase {
    static let server = URL(string: "https://bt.example.com")!
    static let account = AccountID(provider: .bigtimer, id: "bt.example.com")

    var fake: BigTimerFakeServer!
    var acme: String!

    override func setUp() {
        fake = BigTimerFakeServer()
        acme = fake.addProject(prefix: "ACME")
    }

    func tracker(clock: any Clock<Duration> = ContinuousClock()) -> BigTimerTracker {
        BigTimerTracker(server: Self.server, account: Self.account, token: "good", http: fake, clock: clock)
    }

    var project: ProjectRef { ProjectRef(account: Self.account, id: acme, key: "ACME") }

    func indexCalls() -> Int { fake.paths("GET").filter { $0 == "/v1/issues" }.count }

    func testIndexPagesAllIssues() async throws {
        for n in 1...150 { fake.addIssue(project: acme, title: "Item \(n)") }
        let stubs = try await tracker().index(project)
        XCTAssertEqual(stubs.count, 150)
        XCTAssertEqual(Set(stubs.compactMap(\.key)).count, 150)
        XCTAssertEqual(indexCalls(), 2, "two pages")
        let first = try XCTUnwrap(fake.requests.first { $0.url?.path == "/v1/issues" })
        XCTAssertTrue(first.url!.query!.contains("kind=issue"))
        XCTAssertTrue(first.url!.query!.contains("limit=500"))
    }

    func testIndexSkipsEpics() async throws {
        let epic = fake.addEpic(project: acme, title: "E")
        let one = fake.addIssue(project: acme, title: "One", status: "in_progress", epic: epic)
        let stubs = try await tracker().index(project)
        XCTAssertEqual(stubs.map(\.id), [one])
        XCTAssertEqual(stubs.first?.key, "ACME-2")
        XCTAssertEqual(stubs.first?.stateId, "in_progress")
        XCTAssertEqual(stubs.first?.epicId?.rawValue, epic)
        XCTAssertNotNil(stubs.first?.activityAt)
    }

    func testIndexSubItemEpicFromParent() async throws {
        let epic = fake.addEpic(project: acme, title: "E")
        let parent = fake.addIssue(project: acme, title: "Parent", epic: epic)
        let kid = fake.addIssue(project: acme, title: "Kid", parent: parent)
        let stubs = try await tracker().index(project)
        let stub = try XCTUnwrap(stubs.first { $0.id == kid })
        XCTAssertEqual(stub.parentId, parent)
        XCTAssertEqual(stub.epicId?.rawValue, epic, "no epic key is cached, the parent row gives the epic")
    }

    func testIndexIsKeptFiveMinutes() async throws {
        let clock = ManualClock()
        let t = tracker(clock: clock)
        fake.addIssue(project: acme, title: "One")
        _ = try await t.index(project)
        _ = try await t.index(project)
        XCTAssertEqual(indexCalls(), 1)
        clock.advance(by: .seconds(301))
        _ = try await t.index(project)
        XCTAssertEqual(indexCalls(), 2)
    }

    func testIndexCacheDroppedOnWrite() async throws {
        let t = tracker()
        fake.addIssue(project: acme, title: "One")
        _ = try await t.index(project)
        let ref = try await t.create(ItemDraft(title: "Two"), in: project)
        let after = try await t.index(project)
        XCTAssertEqual(after.count, 2)
        try await t.update(ref, ItemPatch(status: "done"))
        let last = try await t.index(project)
        XCTAssertEqual(last.first { $0.id == ref.id }?.stateId, "done")
        XCTAssertEqual(indexCalls(), 3)
    }

    func testIndexCacheDroppedOnFeedChange() async throws {
        let t = tracker()
        fake.addIssue(project: acme, title: "One")
        let base = try await t.poll(since: nil)
        _ = try await t.index(project)
        _ = try await t.index(project)
        XCTAssertEqual(indexCalls(), 1)
        fake.addIssue(project: acme, title: "Two")
        _ = try await t.poll(since: base.cursor)
        let after = try await t.index(project)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(indexCalls(), 2)
    }

    func testFeedChangeOfAnotherProjectKeepsTheIndex() async throws {
        let other = fake.addProject(prefix: "OTH")
        let t = tracker()
        fake.addIssue(project: acme, title: "One")
        let base = try await t.poll(since: nil)
        _ = try await t.index(project)
        fake.addIssue(project: other, title: "Elsewhere")
        _ = try await t.poll(since: base.cursor)
        _ = try await t.index(project)
        XCTAssertEqual(indexCalls(), 1)
    }

    func testIndexStopsAtTheLimitAndGivesAnError() async throws {
        for n in 1...250 { fake.addIssue(project: acme, title: "Item \(n)") }
        let t = tracker()
        t.indexCache.limit = 150
        do { _ = try await t.index(project); XCTFail("no throw") } catch {
            guard case .vendor(let code, _)? = error as? ProviderError else { return XCTFail("\(error)") }
            XCTAssertEqual(code, "index_truncated")
        }
        XCTAssertEqual(indexCalls(), 2, "the read stops at the limit")
        do { _ = try await t.index(project) } catch {}
        XCTAssertEqual(indexCalls(), 2, "the cut is kept, too")
    }
}
