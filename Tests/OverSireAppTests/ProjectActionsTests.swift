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

    // OVERSIRE-535
    private func update(_ rig: EpicRig, _ patch: ProjectSettingsPatch) async throws -> ActionResult {
        let spec = ProjectActions(link: ActionLink(rig.d)).specs.first { $0.id == "project.updateSettings" }!
        let args: [String: JSONValue] = ["project": .string("FAKE"), "patch": try MirrorCodec.body(patch)]
        return await spec.perform(ActionArgs(.object(args), caller: .member(machine: "mba", name: "Fritz")))
    }

    func testUpdateSettingsWritesTheEvent() async throws {
        let rig = try await EpicRig()
        let r = try await update(rig, ProjectSettingsPatch(features: [.intake: false]))
        guard case .ok = r else { return XCTFail("\(r)") }
        XCTAssertEqual(rig.fake.patches.count, 1)
        XCTAssertEqual(rig.fake.patches.first?.features, [.intake: false])
        let rows = await rig.rows(count: 1).filter { $0.kind == .projectSettingsChanged }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.via, "app@mba")
        XCTAssertEqual(rows.first?.payload?["fields"], .array([.string("features")]))
        XCTAssertEqual(rows.first?.project, "fake")
    }

    func testUpdateSettingsRefusesAFieldThatIsNotEditable() async throws {
        let rig = try await EpicRig()
        rig.fake.editableSettings = [.name]
        let r = try await update(rig, ProjectSettingsPatch(visibility: .public))
        guard case .notAllowed = r else { return XCTFail("\(r)") }
        let empty = try await update(rig, ProjectSettingsPatch())
        XCTAssertEqual(empty, .notAllowed("Give a change."))
        XCTAssertEqual(rig.fake.patches.count, 0, "no tracker call")
        let rows = await rig.outlet.rows.filter { $0.kind == .projectSettingsChanged }
        XCTAssertTrue(rows.isEmpty)
    }
}
