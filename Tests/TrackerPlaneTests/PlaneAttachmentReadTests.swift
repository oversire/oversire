import XCTest
import OverSireCore
import OverSireTestKit
@testable import TrackerPlane

/// The attachment list of OVERSIRE-308, recorded on 2026-10-24.
final class PlaneAttachmentReadTests: XCTestCase {
    let project = "9ba476d7-ad30-44cf-b9ef-3fa1e42ed926"
    let work = "d8138b63-f32b-46e6-a2fc-53df92b8833c"
    var http: RecordedPlane!
    var plane: PlaneTracker!
    var item: ItemRef {
        ItemRef(project: ProjectRef(account: plane.account, id: project, key: "OVERSIRE"), id: work, key: "OVERSIRE-308",
                url: URL(string: "https://app.plane.so/ocral/browse/OVERSIRE-308/")!)
    }

    override func setUp() async throws {
        http = RecordedPlane()
        plane = PlaneTracker(workspace: PlaneWorkspace(slug: "ocral"), token: "tok", http: http)
        let list = try String(contentsOf: fixtureDir("plane").appendingPathComponent("attachments.json"), encoding: .utf8)
        http.on("GET", "/api/v2/workspaces/ocral/projects/\(project)/work-items/\(work)/attachments/", list)
    }

    func testListIsOldestFirst() async throws {
        let list = try await plane.attachments(of: item)
        XCTAssertEqual(list.map(\.name), ["pasted-7.png", "pasted-8.png"])
        XCTAssertEqual(list.last?.id, "3033dfe9-9db9-47f5-ab83-aea7967495b5")
        XCTAssertEqual(list.last?.size, 129295)
        XCTAssertEqual(list.last?.mimeType, "image/png")
        XCTAssertTrue(list.allSatisfy(\.isImage))
    }

    func testLinkUsesTheAssetRoute() async throws {
        let list = try await plane.attachments(of: item)
        let a = try XCTUnwrap(list.first)
        http.on("GET", "/api/v1/workspaces/ocral/assets/\(a.id)/",
                #"{"asset_id":"\#(a.id)","asset_name":"\#(a.name)","asset_type":"image/png","asset_url":"https://uploads.plane.so/\#(a.id)?X-Amz-Expires=3600"}"#)
        let u = try await plane.attachmentURL(a, of: item)
        XCTAssertEqual(u.host, "uploads.plane.so")
    }

    func testConformance() async throws {
        let list = try await plane.attachments(of: item)
        let a = try XCTUnwrap(list.first)
        http.on("GET", "/api/v1/workspaces/ocral/assets/\(a.id)/", #"{"asset_url":"https://uploads.plane.so/x"}"#)
        let r = await TrackerConformance.attachments(plane, item: item)
        XCTAssertTrue(r.passed, r.description)
    }
}
