import OverSireCore
import XCTest
@testable import OverSireApp

final class RelationDiskTests: XCTestCase {
    private var folder: URL!

    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("relation-disk-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRoundTrip() throws {
        let disk = RelationDisk(folder: folder)
        let p = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "OVERSIRE")
        let b = ItemRef(project: p, id: "i2", key: "OVERSIRE-2", url: URL(string: "https://plane.example/i2")!)
        let entries = [
            "OVERSIRE-1": RelationDisk.Entry(relations: [ItemRelation(kind: .blockedBy, item: b)],
                                             at: Date(timeIntervalSince1970: 1_700_000_000.123), itemUpdatedAt: Date(timeIntervalSince1970: 1_699_999_999.5)),
            "OVERSIRE-3": RelationDisk.Entry(relations: [], at: Date(timeIntervalSince1970: 1_700_000_100), itemUpdatedAt: nil),
        ]
        try disk.save(project: p.storeKey, entries)
        XCTAssertEqual(disk.load(project: p.storeKey), entries)
        XCTAssertTrue(FileManager.default.fileExists(atPath: disk.file(p.storeKey).path))
        XCTAssertEqual(disk.file(p.storeKey).deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL,
                       "the slash of the store key does not make a sub-folder")
    }

    func testMissingFileIsEmpty() {
        XCTAssertEqual(RelationDisk(folder: folder).load(project: "ocral/none"), [:])
    }
}
