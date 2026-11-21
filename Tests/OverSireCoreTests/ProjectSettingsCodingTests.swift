import XCTest
@testable import OverSireCore

final class ProjectSettingsCodingTests: XCTestCase {
    private func object(_ d: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    func testSettingsRoundTrip() throws {
        let ada = PersonRef(id: "u1", name: "Ada", login: "ada")
        let s = ProjectSettings(name: "Core", key: "CORE", description: "# Core", logo: ProjectLogo(kind: .emoji, value: "x"),
                                lead: ada, visibility: .private, priorities: ["urgent"],
                                members: [ProjectMember(person: ada, role: "admin")],
                                features: [.intake: true, .modules: false], readOnlyFeatures: [.pages])
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(ProjectSettings.self, from: data), s)
        let features = try XCTUnwrap(try object(data)["features"] as? [String: Bool])
        XCTAssertEqual(features, ["intake": true, "modules": false])
    }

    func testPatchNullClears() throws {
        let clear = try JSONDecoder().decode(ProjectSettingsPatch.self, from: Data(#"{"lead":null}"#.utf8))
        XCTAssertEqual(clear.lead, .some(nil))
        XCTAssertNil(clear.defaultAssignee)
        XCTAssertEqual(clear.fields, [.lead])
        let none = try JSONDecoder().decode(ProjectSettingsPatch.self, from: Data("{}".utf8))
        XCTAssertNil(none.lead)
        XCTAssertTrue(none.isEmpty)
        let again = try object(JSONEncoder().encode(clear))
        XCTAssertEqual(again.keys.sorted(), ["lead"])
        XCTAssertTrue(again["lead"] is NSNull)
        XCTAssertEqual(try object(JSONEncoder().encode(none)).count, 0)
    }

    func testPatchRoundTrip() throws {
        let p = ProjectSettingsPatch(name: "New", logo: .some(ProjectLogo(kind: .icon, value: "bolt", color: "#fff")), lead: .some("u2"),
                                     visibility: .public, features: [.intake: true], newLabels: [LabelDraft(name: "bug", color: "#f00")])
        let back = try JSONDecoder().decode(ProjectSettingsPatch.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back, p)
    }
}
