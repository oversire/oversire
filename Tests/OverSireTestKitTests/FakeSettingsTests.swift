import XCTest
import OverSireCore
@testable import OverSireTestKit

final class FakeSettingsTests: XCTestCase {
    func testPatchChangesSettingsAndSummary() async throws {
        let t = FakeTracker()
        try await t.update(t.project, ProjectSettingsPatch(name: "Renamed", logo: .some(nil), lead: .some(nil),
                                                           features: [.modules: true, .estimates: true],
                                                           newLabels: [LabelDraft(name: "ui", color: "#0072B2")]))
        let s = try await t.settings(t.project)
        XCTAssertEqual(s.name, "Renamed")
        XCTAssertNil(s.logo)
        XCTAssertNil(s.lead)
        XCTAssertEqual(s.features[.modules], true)
        XCTAssertEqual(s.features[.estimates], false, "a read-only feature stays")
        XCTAssertEqual(s.labels.map(\.name), ["bug", "ui"])
        let title = try await t.projects().first?.title
        XCTAssertEqual(title, "Renamed")
        XCTAssertEqual(t.patches.count, 1)
    }

    func testFieldThatIsNotEditableFails() async {
        let t = FakeTracker()
        t.editableSettings = [.name]
        let r = await TrackerConformance.settings(t, project: t.project)
        XCTAssertTrue(r.passed, r.description)
        do { try await t.update(t.project, ProjectSettingsPatch(description: "x")); XCTFail("no error") }
        catch { XCTAssertEqual(error as? ProviderError, .unsupported(.projectSettingsEdit)) }
        XCTAssertTrue(t.patches.isEmpty)
    }

    func testCapabilitiesMustMatch() {
        let r = ProviderConformance.capabilities(FakeTracker(capabilities: []))
        XCTAssertEqual(Set(r.problems), ["ProjectSettingsReading needs the capability projectSettings",
                                         "ProjectSettingsEditing needs the capability projectSettingsEdit",
                                         "RelationManaging needs the capability relations",
                                         "IntakeTriaging needs the capability intake",
                                         "IntakeCreating needs the capability intakeCreate",
                                         "AttachmentUploading needs the capability attachments"])
    }
}
