import OverSireCore
import OverSireSync
import XCTest
@testable import OverSireApp

final class ProjectMemoryTests: XCTestCase {
    private let ref = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "OVERSIRE")
    private let other = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p2", key: "SLING")

    private func memory(_ dir: URL) -> ProjectMemory { ProjectMemory(writes: StoreWrites(store: LocalStore(dir: dir))) }

    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
    }

    func testRoute() {
        let r = Route.projectSettings("OVERSIRE", .memory)
        XCTAssertEqual(r.path, "project/OVERSIRE/settings/memory")
        XCTAssertEqual(Route(path: r.path), r)
        XCTAssertTrue(ProjectSettingsSection.memory.local)
        XCTAssertEqual(ProjectSettingsSection.memory.title, "Vision and memory")
    }

    func testVisionLimit() {
        let m = memory(tempDir())
        XCTAssertThrowsError(try m.saveVision(String(repeating: "a", count: 501), of: ref)) {
            XCTAssertEqual($0 as? ProjectMemory.SaveError, .tooLong(501))
        }
        XCTAssertNil(m.vision(of: ref))
        XCTAssertNoThrow(try m.saveVision(" " + String(repeating: "a", count: 500) + "\n", of: ref), "the limit counts the trimmed text")
        XCTAssertEqual(m.vision(of: ref)?.text.count, 500)
    }

    func testOneVisionForEachProject() throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = memory(dir)
        try m.saveVision("Small and native.", of: ref)
        try m.saveVision("Small, native and accessible.", of: ref)
        try m.saveVision("Fast syncs.", of: other)
        let visions = m.entries.filter { $0.kind == .vision }
        XCTAssertEqual(visions.count, 2)
        let v = try XCTUnwrap(m.vision(of: ref))
        XCTAssertEqual(v.id, "vision-ocral/p1")
        XCTAssertEqual(v.id, MemoryEntry.visionID(of: ref))
        XCTAssertEqual(v.text, "Small, native and accessible.")
        XCTAssertEqual(v.source, .user)
        try m.saveVision("  ", of: ref)
        XCTAssertNil(m.vision(of: ref), "an empty text removes the vision")
        XCTAssertNotNil(m.vision(of: other))
    }

    func testFacts() throws {
        let m = memory(tempDir())
        XCTAssertThrowsError(try m.saveFact(" ", of: ref)) { XCTAssertEqual($0 as? ProjectMemory.SaveError, .empty) }
        let a = try m.saveFact("Swift 6.", of: ref, now: Date(timeIntervalSince1970: 1))
        try m.saveFact("AppKit only.", of: ref, now: Date(timeIntervalSince1970: 2))
        try m.saveVision("North.", of: ref)
        XCTAssertEqual(m.facts(of: ref).map(\.text), ["Swift 6.", "AppKit only."], "facts leave out the vision")
        try m.saveFact("Swift 6 strict.", id: a.id, of: ref, now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(m.facts(of: ref).map(\.text), ["AppKit only.", "Swift 6 strict."])
        m.remove(id: a.id)
        XCTAssertEqual(m.facts(of: ref).count, 1)
        XCTAssertTrue(m.facts(of: other).isEmpty)
    }
}
