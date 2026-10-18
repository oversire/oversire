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

    /// Read-only: lists the relations of OVERSIRE-82, which waits on OVERSIRE-80.
    func testReadRelations() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSIRE_LIVE"] == "1", let token = env["PLANE_TOKEN_ocral"] else {
            throw XCTSkip("set OVERSIRE_LIVE=1 and PLANE_TOKEN_ocral")
        }
        let plane = PlaneTracker(workspace: PlaneWorkspace(slug: "ocral"), token: token, http: LiveHTTP())
        let projects = try await plane.projects()
        let project = try XCTUnwrap(projects.first { $0.identifier == "OVERSIRE" })
        let items = try await plane.items(project.ref, since: nil, limit: 200)
        let item = try XCTUnwrap(items.first { $0.key == "OVERSIRE-82" }?.ref(in: project.ref))
        let rels = try await plane.relations(of: item)
        XCTAssertTrue(rels.contains { $0.kind == .blockedBy && $0.item.key == "OVERSIRE-80" }, "\(rels)")
    }

    /// Writes: makes an intake item with 2 PNGs, reads the files back, then deletes the intake item.
    func testIntakeWithAttachments() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSIRE_LIVE"] == "1", let token = env["PLANE_TOKEN_ocral"] else {
            throw XCTSkip("set OVERSIRE_LIVE=1 and PLANE_TOKEN_ocral")
        }
        let plane = PlaneTracker(workspace: PlaneWorkspace(slug: "ocral"), token: token, http: LiveHTTP())
        let projects = try await plane.projects()
        let project = try XCTUnwrap(projects.first { $0.identifier == "OVERSIRE" }).ref
        let made = try await plane.createIntake(ItemDraft(title: "OverSire live test (delete me)", bodyMarkdown: "Made by LiveTests."),
                                                in: project)
        do {
            XCTAssertTrue(made.item.key.hasPrefix("OVERSIRE-"), made.item.key)
            let files = [AttachmentUpload(name: "snap-1.png", mimeType: "image/png", data: Self.png(seed: 1)),
                         AttachmentUpload(name: "snap-1-clean.png", mimeType: "image/png", data: Self.png(seed: 2))]
            for f in files {
                let id = try await plane.attach(f, to: made.item)
                let path = "/api/v1/workspaces/ocral/projects/\(project.id)/work-items/\(made.item.id)/attachments/\(id)/"
                var req = URLRequest(url: URL(string: PlaneWorkspace.cloudHost + path)!)
                req.setValue(token, forHTTPHeaderField: "X-Api-Key")
                let (data, resp) = try await URLSession.shared.data(for: req)
                XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200)
                XCTAssertEqual(data, f.data, "the bytes of \(f.name) differ")
            }
        } catch {
            try? await plane.triage(made.intake, in: project, .delete)
            throw error
        }
        try await plane.triage(made.intake, in: project, .delete)
    }

    // The PNG signature and some bytes. Plane and the storage do not read the image.
    static func png(seed: UInt8) -> Data { Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: seed, count: 64)) }
}

struct LiveHTTP: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await URLSession.shared.data(for: request)
        return (data, resp as! HTTPURLResponse)
    }
}
