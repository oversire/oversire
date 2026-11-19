import OverSireCore
import XCTest
@testable import OverSireApp

final class ProjectPageViewTests: XCTestCase {
    func testDefaultIsPlan() {
        let suite = "project-view-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ProjectTab.stored(defaults), .plan)
        defaults.set("board", forKey: "projectLayout")
        XCTAssertEqual(ProjectTab.stored(defaults), .plan, "the old key does not count")
        defaults.set("list", forKey: ProjectTab.key)
        XCTAssertEqual(ProjectTab.stored(defaults), .list)

        let old = UserDefaults.standard.object(forKey: ProjectTab.key)
        defer { UserDefaults.standard.set(old, forKey: ProjectTab.key) }
        UserDefaults.standard.removeObject(forKey: ProjectTab.key)
        let d = TestAppData()
        d.projectStore.seed(EpicFixture.snap())
        let page = ProjectPage(.project("ENG"), data: d, router: Router())
        XCTAssertEqual(page.tab, .plan)
        let ids = page.sections()?.flatMap { s in s.rows.map { "\(s.id)/\($0.id)" } } ?? []
        XCTAssertEqual(ids, ["top/header", "plan/plan"])
        XCTAssertFalse(page.fillsHeight, "the Summary scrolls with the page")
    }
}
