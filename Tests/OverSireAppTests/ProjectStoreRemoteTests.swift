import XCTest
import OverSireCore
import OverSireSync
@testable import OverSireApp

/// The tracker reads of a client go through the home (OVERSIRE-535).
@MainActor
final class ProjectStoreRemoteTests: XCTestCase {
    private final class Seen: @unchecked Sendable { var calls: [(what: String, args: JSONValue)] = [] }

    private final class NoTrackers: TrackerDirectory {
        var trackerIds: [String] { [] }
        func tracker(_ id: String) -> (any Tracker)? { nil }
    }

    private let ref = ProjectRef(account: AccountID(provider: "plane", id: "ws"), id: "p1", key: "ONE")
    private let at = Date(timeIntervalSince1970: 1_700_000_000)

    private func clientStore() throws -> ProjectStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let s = ProjectStore(trackers: NoTrackers(), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                             statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        s.client = true
        return s
    }

    private func answer<T: Codable & Sendable>(_ rows: T, _ seen: Seen) throws -> ((String, JSONValue) async throws -> JSONValue) {
        let body = try MirrorCodec.body(MirrorRows(rows: rows))
        return { what, args in seen.calls.append((what, args)); return body }
    }

    private func read<T>(_ call: (@escaping (T) -> Void) -> Void) async -> T {
        await withCheckedContinuation { c in call { c.resume(returning: $0) } }
    }

    func testRemoteProjectSettingsOnClient() async throws {
        let seen = Seen()
        let s = try clientStore()
        let value = ProjectSettingsRead(settings: ProjectSettings(name: "From mbp", features: [.intake: true]), editable: [.name, .features])
        s.remote = try answer(value, seen)
        let r: Result<ProjectSettingsRead, ProviderError> = await read { s.projectSettings(projectKey: "ONE", done: $0) }
        let got = try r.get()
        XCTAssertEqual(got.settings.name, "From mbp")
        XCTAssertEqual(got.settings.features, [.intake: true])
        XCTAssertEqual(got.editable, [.name, .features])
        XCTAssertEqual(seen.calls.map(\.what), ["projectSettings"])
        XCTAssertEqual(seen.calls.first?.args["project"], .string("ONE"))
    }

    func testRemoteAttachmentsOnClient() async throws {
        let seen = Seen()
        let s = try clientStore()
        let item = ItemRef(project: ref, id: "i1", key: "ONE-1", url: URL(string: "https://t.example/ONE-1")!)
        let file = ItemAttachment(id: "a1", name: "shot.png", size: 3, mimeType: "image/png", createdAt: at)
        s.remote = try answer([file], seen)
        let list: Result<[ItemAttachment], ProviderError> = await read { s.attachments(of: item, done: $0) }
        XCTAssertEqual(try list.get(), [file])
        XCTAssertEqual(seen.calls.first?.what, "attachments")
        XCTAssertEqual(seen.calls.first?.args["ref"]?["id"], .string("i1"))

        s.remote = try answer("https://files.example/a1?sig=1", seen)
        let link: Result<URL, ProviderError> = await read { s.attachmentLink(file, of: item, done: $0) }
        XCTAssertEqual(try link.get(), URL(string: "https://files.example/a1?sig=1"))
        XCTAssertEqual(seen.calls.last?.what, "attachmentLink")
        XCTAssertEqual(seen.calls.last?.args["attachment"]?["id"], .string("a1"))
    }

    func testRemoteIntakeKeysOnClient() async throws {
        let seen = Seen()
        let s = try clientStore()
        let summary = ProjectSummary(ref: ref, identifier: "ONE", title: "One", url: "", closed: false)
        let pending = IntakeItem(id: "n1", workItemId: "wi-1", name: "Idea", priority: nil, createdAt: at, author: nil, source: nil)
        var delta = MirrorDelta()
        delta.projects[ref.storeKey] = ProjectSnapshot(summary: summary, statusOptions: [], items: [], fetchedAt: Date(), intake: [pending])
        s.mirrored(delta)
        s.remote = try answer(["wi-1": 12], seen)
        await read { (done: @escaping (()) -> Void) in s.loadIntakeKeys(projectKey: ref.storeKey) { done(()) } }
        XCTAssertEqual(s.intakeKeys, ["wi-1": 12])
        XCTAssertEqual(seen.calls.map(\.what), ["intakeKeys"])
        XCTAssertEqual(seen.calls.first?.args["project"], .string(ref.storeKey))
    }

    func testIntakeURLOnClientComesFromTheCatalog() throws {
        let s = try clientStore()
        let summary = ProjectSummary(ref: ref, identifier: "ONE", title: "One", url: "https://plane.example/one", closed: false)
        let snap = ProjectSnapshot(summary: summary, statusOptions: [], items: [], fetchedAt: Date())
        s.catalog = ClientCatalog(projects: [CatalogProject(summary: summary, capabilities: [.intake])], capabilities: [:], trackers: [])
        XCTAssertEqual(s.intakeURL(of: snap), "https://plane.example/one", "an old home gives the page of the project")
        s.catalog = ClientCatalog(projects: [CatalogProject(summary: summary, capabilities: [.intake], intakeURL: "https://plane.example/one/intake")],
                                  capabilities: [:], trackers: [])
        XCTAssertEqual(s.intakeURL(of: snap), "https://plane.example/one/intake")
    }

    func testRemoteImagesOnClient() async throws {
        let seen = Seen()
        let s = try clientStore()
        s.remote = try answer("![a](https://files.example/asset-1?sig=1)", seen)
        let out: String = await read { s.resolveImages("![a](asset-1)", projectKey: "ONE", done: $0) }
        XCTAssertEqual(out, "![a](https://files.example/asset-1?sig=1)")
        XCTAssertEqual(seen.calls.first?.what, "images")
        XCTAssertEqual(seen.calls.first?.args["markdown"], .string("![a](asset-1)"))

        s.remote = { _, _ in throw ProviderError.transport("offline") }
        let kept: String = await read { s.resolveImages("![a](asset-1)", projectKey: "ONE", done: $0) }
        XCTAssertEqual(kept, "![a](asset-1)", "a failed read keeps the text")
    }
}
