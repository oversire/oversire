import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireApp

@MainActor
final class AttachmentBookTests: XCTestCase {
    private var tracker: FakeTracker!
    private var ref: ItemRef!
    private var dir: URL!

    override func setUp() async throws {
        tracker = FakeTracker()
        ref = try await tracker.create(ItemDraft(title: "Shots"), in: tracker.project)
        _ = try await tracker.attach(AttachmentUpload(name: "a.png", mimeType: "image/png", data: Data([1])), to: ref)
        _ = try await tracker.attach(AttachmentUpload(name: "b.pdf", mimeType: "application/pdf", data: Data([2])), to: ref)
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("attachment-book-\(UUID().uuidString)")
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    private func book(asks: (() -> Void)? = nil, download: @escaping (URL) async throws -> Data) -> AttachmentBook {
        let t = tracker!
        let b = AttachmentBook(reader: { _ in asks?(); return t }, download: download)
        b.dir = dir
        return b
    }

    private func list(_ b: AttachmentBook, changedAt: Date = .distantPast) async -> [ItemAttachment]? {
        if let have = b.files(of: ref, changedAt: changedAt) { return have }
        await fulfillment(of: [expectation(forNotification: AttachmentBook.changed, object: b)], timeout: 2)
        return b.files(of: ref, changedAt: changedAt)
    }

    func testListThenOneDownload() async throws {
        var gets = 0
        let b = book { _ in gets += 1; return Data([7, 8]) }
        XCTAssertNil(b.files(of: ref, changedAt: .distantPast), "no list before the first answer")
        let got = await list(b)
        let files = try XCTUnwrap(got)
        XCTAssertEqual(files.map(\.name), ["a.png", "b.pdf"])
        let a = files[0]
        let done = expectation(description: "fetch")
        b.fetch(a, of: ref) { u in
            XCTAssertEqual(u.flatMap { try? Data(contentsOf: $0) }, Data([7, 8]))
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertNotNil(b.local(a))
        b.fetch(a, of: ref)
        XCTAssertEqual(gets, 1, "a local copy needs no second download")
    }

    func testFailedDownloadMarksTheFile() async throws {
        let b = book { _ in throw URLError(.timedOut) }
        let got = await list(b)
        let a = try XCTUnwrap(got?.first)
        let done = expectation(description: "fetch")
        b.fetch(a, of: ref) { u in XCTAssertNil(u); done.fulfill() }
        await fulfillment(of: [done], timeout: 2)
        XCTAssertTrue(b.failed.contains(a.id))
        XCTAssertNil(b.local(a))
    }

    func testANewerItemAsksAgain() async throws {
        var asks = 0
        let b = book(asks: { asks += 1 }) { _ in Data() }
        _ = await list(b)
        XCTAssertEqual(asks, 1)
        _ = b.files(of: ref, changedAt: .distantPast)
        XCTAssertEqual(asks, 1, "a new list needs no second call")
        _ = b.files(of: ref, changedAt: Date().addingTimeInterval(60))
        XCTAssertEqual(asks, 2, "the item changed after the list")
    }

    func testOpenStateIsPerItem() {
        let b = book { _ in Data() }
        XCTAssertFalse(b.isOpen(ref))
        b.toggle(ref)
        XCTAssertTrue(b.isOpen(ref))
        b.toggle(ref)
        XCTAssertFalse(b.isOpen(ref))
    }
}
