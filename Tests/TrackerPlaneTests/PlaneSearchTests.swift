import XCTest
import OverSireCore
import OverSireTestKit
@testable import TrackerPlane

/// Search and members from answers recorded on the real ocral workspace (read-only GET calls).
final class PlaneSearchTests: XCTestCase {
    let pid = "9ba476d7-ad30-44cf-b9ef-3fa1e42ed926"
    var ws: String { "/api/v1/workspaces/ocral" }
    var http: RecordedPlane!
    var plane: PlaneTracker!
    var project: ProjectRef { ProjectRef(account: plane.account, id: pid, key: "OVERSIRE") }

    override func setUpWithError() throws {
        http = RecordedPlane()
        plane = PlaneTracker(workspace: PlaneWorkspace(slug: "ocral"), token: "tok", http: http)
        let dir = fixtureDir("plane")
        func fixture(_ name: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(name + ".json"), encoding: .utf8) }
        http.on("GET", "\(ws)/work-items/search/", try fixture("search"))
        http.on("GET", "\(ws)/members/", try fixture("project-members"))
    }

    func query() -> [String: String] {
        let items = http.requests.last.flatMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    func testSearchInOneProject() async throws {
        let hits = try await plane.search(" contract ", in: [project], limit: 3)
        XCTAssertEqual(query(), ["search": "contract", "project_id": pid, "workspace_search": "false", "limit": "3"])
        XCTAssertEqual(hits.map(\.key), ["OVERSIRE-263", "OVERSIRE-243", "OVERSIRE-180"])
        XCTAssertEqual(hits.first?.title, "Assistant 1: contract for threads, parts, chat events and tool specs")
        XCTAssertEqual(hits.first?.url, "https://app.plane.so/ocral/browse/OVERSIRE-263/")
        XCTAssertEqual(hits.first?.ref(in: project)?.id, "b4785bff-c675-4daa-9f2b-ea5da62b4f8c")
        XCTAssertNil(hits.first?.statusOptionId, "a hit that is not cached has no status")
        XCTAssertTrue(plane.capabilities.contains(.itemSearch))
    }

    func testSearchInManyProjectsFiltersTheWorkspace() async throws {
        let all = try await plane.search("contract", in: nil, limit: 2)
        XCTAssertEqual(query(), ["search": "contract", "workspace_search": "true", "limit": "2"])
        XCTAssertEqual(all.count, 2, "the limit holds")
        let other = ProjectRef(account: plane.account, id: "other")
        let some = try await plane.search("contract", in: [other, project], limit: 5)
        XCTAssertEqual(query()["limit"], "50", "a filtered search asks for more rows")
        XCTAssertEqual(some.count, 3)
        let none = try await plane.search("contract", in: [other, ProjectRef(account: plane.account, id: "other2")], limit: 5)
        XCTAssertTrue(none.isEmpty)
    }

    func testEmptySearchSendsNothing() async throws {
        let blank = try await plane.search("  ", in: nil, limit: 5)
        let noProjects = try await plane.search("contract", in: [], limit: 5)
        XCTAssertTrue(blank.isEmpty && noProjects.isEmpty)
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testMemberDetailsSkipBots() async {
        let people = await plane.memberDetails()
        XCTAssertEqual(people, [PersonDetail(id: "6008c025-3b03-4263-89fc-62f1153bfa27", name: "flarco", login: "flarco",
                                             email: "user@example.com", sources: ["plane:ocral"])])
        let names = await plane.memberNames()
        XCTAssertEqual(names.count, 2, "the names keep the bot for the activity rows")
        XCTAssertEqual(http.requests.count, 1, "one call fills both")
    }
}
