import OverSireAssistant
import OverSireCore
import XCTest
@testable import OverSireApp

final class ProjectActionsTests: XCTestCase {
    private func call(_ rig: EpicRig, _ id: String, _ args: [String: JSONValue]) async -> ActionResult {
        let spec = ProjectActions(link: ActionLink(rig.d)).specs.first { $0.id == id }!
        return await spec.perform(ActionArgs(.object(args)))
    }

    func testSetNorthStarSavesAndRecords() async throws {
        let rig = try await EpicRig()
        let text = "One quiet place that shows where all my work stands."
        let r = await call(rig, "project.setNorthStar", ["project": .string("FAKE"), "text": .string(text)])
        guard case .ok = r else { return XCTFail("\(r)") }
        let ref = try await rig.summary.ref
        let saved = await MainActor.run { rig.d.memory.vision(of: ref)?.text }
        XCTAssertEqual(saved, text)
        let rows = await rig.rows(count: 1).filter { $0.kind == .projectNorthStarSet }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.actorType, .human)
        XCTAssertEqual(rows.first?.payload?["length"], .int(text.count))
        XCTAssertEqual(rows.first?.project, "fake")

        let read = await call(rig, "project.northStar", ["project": .string("FAKE")])
        XCTAssertEqual(read, .ok(summary: text, data: .object(["text": .string(text)])))
    }

    func testSetNorthStarTooLong() async throws {
        let rig = try await EpicRig()
        let r = await call(rig, "project.setNorthStar", ["project": .string("FAKE"), "text": .string(String(repeating: "a", count: 501))])
        guard case .failed = r else { return XCTFail("\(r)") }
        let empty = await call(rig, "project.setNorthStar", ["project": .string("FAKE"), "text": .string("  ")])
        guard case .notAllowed = empty else { return XCTFail("\(empty)") }
        let unknown = await call(rig, "project.setNorthStar", ["project": .string("NOPE"), "text": .string("x")])
        guard case .notAllowed = unknown else { return XCTFail("\(unknown)") }
    }
}
