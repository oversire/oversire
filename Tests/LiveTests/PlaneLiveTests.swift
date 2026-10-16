import XCTest
import OverSireCore
import TrackerPlane

/// Calls the real Plane API. Run with OVERSIRE_LIVE=1 and PLANE_TOKEN_ocral set.
final class PlaneLiveTests: XCTestCase {
    func testListProjectsAndReadOneItem() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSIRE_LIVE"] == "1", let token = env["PLANE_TOKEN_ocral"] else {
            throw XCTSkip("set OVERSIRE_LIVE=1 and PLANE_TOKEN_ocral")
        }
        let plane = PlaneTracker(workspace: PlaneWorkspace(slug: "ocral"), token: token, http: LiveHTTP())
        let projects = try await plane.projects()
        let project = try XCTUnwrap(projects.first { $0.identifier == "OVERSIRE" })
        let items = try await plane.items(project.ref, since: nil, limit: 5)
        let first = try XCTUnwrap(items.first?.ref(in: project.ref))
        let detail = try await plane.detail(first)
        XCTAssertEqual(detail.item.id, first.id)
    }
}

struct LiveHTTP: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await URLSession.shared.data(for: request)
        return (data, resp as! HTTPURLResponse)
    }
}
