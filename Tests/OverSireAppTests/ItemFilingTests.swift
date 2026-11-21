import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

// OVERSIRE-536
final class ItemFilingTests: XCTestCase {
    func testCatalogFilingCreatesIntakeThenAttaches() async throws {
        let rig = try await EpicRig(items: 0, epics: [])
        let calls = ForwardCalls()
        rig.d.actions.forward = calls.forward
        let filing = ItemFiling.catalog(rig.d.actions, store: rig.d.projectStore)
        let p = rig.fake.project
        let made = try await filing.createIntake(ItemDraft(title: "Snap", bodyMarkdown: "Body"), p)
        XCTAssertEqual(made.item.key, "FAKE-9")
        XCTAssertEqual(made.intake.id, "n1")
        for name in ["a.png", "b.png"] {
            let id = try await filing.attach(AttachmentUpload(name: name, mimeType: "image/png", data: Data(name.utf8)), made.item)
            XCTAssertEqual(id, "a1")
        }
        XCTAssertEqual(calls.actions, ["intake.create", "item.attach", "item.attach"])
        XCTAssertEqual(calls.args[0]["title"], .string("Snap"))
        XCTAssertEqual(calls.args[0]["body"], .string("Body"))
        XCTAssertEqual(calls.args[2]["project"], .string(p.storeKey))
        XCTAssertEqual(calls.args[2]["id"], .string("w1"))
        XCTAssertEqual(calls.args[2]["key"], .string("FAKE-9"))
        XCTAssertEqual(calls.args[2]["data"], .string(Data("b.png".utf8).base64EncodedString()))
    }

    func testCatalogFilingMapsRefusals() async throws {
        let rig = try await EpicRig(items: 0, epics: [])
        rig.d.actions.forward = { _ in AppCallResult(id: "m", status: .notAllowed, summary: "x") }
        let filing = ItemFiling.catalog(rig.d.actions, store: rig.d.projectStore)
        do {
            _ = try await filing.create(ItemDraft(title: "T"), rig.fake.project)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.message, "x")
        }
        rig.d.actions.forward = { _ in AppCallResult(id: "m", status: .failed, summary: "The tracker is down.") }
        do {
            try await filing.enableIntake(rig.fake.project)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.message, "The tracker is down.")
        }
    }

    func testHomeFilingMakesItemsAndFiles() async throws {
        let rig = try await EpicRig(items: 0, epics: [])
        let filing = ItemFiling.catalog(rig.d.actions, store: rig.d.projectStore)
        let p = rig.fake.project
        XCTAssertTrue(filing.can(p, .attachments))
        XCTAssertFalse(filing.can(p, .webhooks))
        let item = try await filing.create(ItemDraft(title: "Made", bodyMarkdown: "Text", status: "s-todo"), p)
        let items = try await rig.fake.items(p, since: nil, limit: 10)
        XCTAssertEqual(items.map(\.title), ["Made"])
        XCTAssertEqual(item.id, items.first?.id)
        let made = try await filing.createIntake(ItemDraft(title: "Ask"), p)
        let intake = try await rig.fake.intake(p)
        XCTAssertEqual(intake.map(\.id), [made.intake.id])
        _ = try await filing.attach(AttachmentUpload(name: "a.png", mimeType: "image/png", data: Data("a".utf8)), made.item)
        XCTAssertEqual(rig.fake.uploads.map(\.item), [made.item])
        let on = await filing.intakeOn(p)
        XCTAssertEqual(on, true)
    }
}

final class AttachmentUploaderTests: XCTestCase {
    func testOneFailingFileLandsInMissing() async {
        let item = ItemRef(project: ProjectRef(account: AccountID(provider: "fake", id: "fake"), id: "p1", key: "FAKE"), id: "i1", key: "FAKE-1", url: URL(string: "https://x")!)
        final class Sent: @unchecked Sendable { var names: [String] = [] }
        let sent = Sent()
        let files = ["a", "b", "c"].map { AttachmentUpload(name: $0, mimeType: "text/plain", data: Data($0.utf8)) }
        let missing = await AttachmentUploader(retries: 1).upload(files, to: item) { f in
            sent.names.append(f.name)
            if f.name == "b" { throw ProviderError.notFound }
            return "id"
        }
        XCTAssertEqual(missing, ["b"])
        XCTAssertEqual(sent.names, ["a", "b", "c", "b"])
    }
}
