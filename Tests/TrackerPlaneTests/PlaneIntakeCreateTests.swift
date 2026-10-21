import XCTest
import OverSireCore
import OverSireTestKit
@testable import TrackerPlane

/// Intake create and the attachment upload, from answers recorded on 2026-10-18.
final class PlaneIntakeCreateTests: XCTestCase {
    let ws = "/api/v1/workspaces/acme"
    let project = "9ba476d7-ad30-44cf-b9ef-3fa1e42ed926"
    let work = "553b085e-f612-47c9-8432-d754e14b9b1c"
    let asset = "02117ec0-db93-479b-a6c8-02d8cc4a27c6"
    var http: RecordedPlane!
    var plane: PlaneTracker!
    var ref: ProjectRef { ProjectRef(account: plane.account, id: project, key: "OVERSIRE") }
    var attachments: String { "/api/v2/workspaces/acme/projects/\(project)/work-items/\(work)/attachments/" }

    override func setUp() async throws {
        http = RecordedPlane()
        plane = PlaneTracker(workspace: PlaneWorkspace(slug: "acme"), token: "tok", http: http)
        let dir = fixtureDir("plane")
        func fixture(_ name: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(name + ".json"), encoding: .utf8) }
        http.on("POST", "\(ws)/projects/\(project)/intake-issues/", try fixture("intake-create"))
        http.on("POST", attachments, try fixture("attachment-presign"))
        http.on("PATCH", attachments + "\(asset)/", try fixture("attachment-confirm"))
        let storage = try JSONSerialization.jsonObject(with: Data(try fixture("attachment-storage").utf8)) as? [String: Any]
        http.on("POST", "/", status: storage?["status"] as? Int ?? 0, storage?["body"] as? String ?? "")
        http.on("DELETE", "\(ws)/projects/\(project)/intake-issues/\(work)/", status: 204, "")
    }

    func testCreateIntakeGivesTheKeyAndTheIntakeId() async throws {
        let made = try await plane.createIntake(ItemDraft(title: "Snap basket", bodyMarkdown: "**two** shots"), in: ref)
        XCTAssertEqual(made.item.key, "OVERSIRE-118")
        XCTAssertEqual(made.item.id, work)
        XCTAssertEqual(made.intake.id, "37259b68-394f-41dd-a45d-d1adf005d688")
        XCTAssertEqual(made.intake.workItemId, work)
        let issue = try XCTUnwrap(http.body("POST", "\(ws)/projects/\(project)/intake-issues/")?["issue"] as? [String: Any])
        XCTAssertEqual(issue["name"] as? String, "Snap basket")
        XCTAssertEqual(issue["description_html"] as? String, "<p><strong>two</strong> shots</p>")
    }

    func testAttachRunsTheThreeSteps() async throws {
        let item = ItemRef(project: ref, id: work, key: "OVERSIRE-118", url: URL(string: "https://app.plane.so/acme/browse/OVERSIRE-118/")!)
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let id = try await plane.attach(AttachmentUpload(name: "snap-1.png", mimeType: "image/png", data: png), to: item)
        XCTAssertEqual(id, asset)
        let presign = try XCTUnwrap(http.body("POST", attachments))
        XCTAssertEqual(presign["name"] as? String, "snap-1.png")
        XCTAssertEqual(presign["size"] as? Int, 4)
        XCTAssertEqual(presign["type"] as? String, "image/png")
        XCTAssertEqual(http.body("PATCH", attachments + "\(asset)/")?["is_uploaded"] as? Bool, true)

        let storage = try XCTUnwrap(http.requests.first { $0.url?.host == "planefs-uploads.s3.amazonaws.com" })
        XCTAssertNil(storage.value(forHTTPHeaderField: "X-Api-Key"), "the API key must not go to storage")
        let form = String(decoding: storage.httpBody ?? Data(), as: UTF8.self)
        let key = try XCTUnwrap(form.range(of: "name=\"key\""))
        let file = try XCTUnwrap(form.range(of: "name=\"file\"; filename=\"snap-1.png\"\r\nContent-Type: image/png"))
        XCTAssertLessThan(key.lowerBound, file.lowerBound, "S3 needs the fields before the file")
        XCTAssertEqual(http.requests.map { $0.httpMethod ?? "" }, ["POST", "POST", "PATCH"])
    }

    func testStorageFailureThrows() async throws {
        http.on("POST", "/", status: 403, "<Error>AccessDenied</Error>")
        let item = ItemRef(project: ref, id: work, key: "OVERSIRE-118", url: URL(string: "https://app.plane.so/acme/browse/OVERSIRE-118/")!)
        do {
            _ = try await plane.attach(AttachmentUpload(name: "snap-1.png", mimeType: "image/png", data: Data([1])), to: item)
            XCTFail("no error")
        } catch { XCTAssertEqual((error as? ProviderError).map { if case .vendor(let c, _) = $0 { return c } else { return "" } }, "403") }
    }

    func testIntakeOffGivesAClearError() async throws {
        http.on("POST", "\(ws)/projects/\(project)/intake-issues/", status: 400, #"{"error":"Intake is not enabled for this project"}"#)
        http.on("GET", "\(ws)/projects/\(project)/", try String(contentsOf: fixtureDir("plane").appendingPathComponent("project-intake-off.json"), encoding: .utf8))
        do {
            _ = try await plane.createIntake(ItemDraft(title: "Snap basket", bodyMarkdown: "x"), in: ref)
            XCTFail("no error")
        } catch let e as ProviderError {
            XCTAssertTrue(e.isIntakeOff)
            XCTAssertEqual(e.localizedDescription, "Intake is off for OVERSIRE in Plane.")
        }
    }

    func testOtherFailureKeepsItsError() async throws {
        http.on("POST", "\(ws)/projects/\(project)/intake-issues/", status: 400, #"{"error":"bad name"}"#)
        http.on("GET", "\(ws)/projects/\(project)/", try String(contentsOf: fixtureDir("plane").appendingPathComponent("project.json"), encoding: .utf8))
        do {
            _ = try await plane.createIntake(ItemDraft(title: "Snap basket", bodyMarkdown: "x"), in: ref)
            XCTFail("no error")
        } catch let e as ProviderError {
            XCTAssertFalse(e.isIntakeOff)
        }
    }

    func testConformance() async {
        http.on("GET", "\(ws)/projects/\(project)/", #"{"id":"\#(project)","identifier":"OVERSIRE"}"#)
        let r = await TrackerConformance.intakeAndAttachments(plane, project: ref)
        XCTAssertTrue(r.passed, r.description)
    }
}
