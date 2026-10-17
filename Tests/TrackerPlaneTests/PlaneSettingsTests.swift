import XCTest
import OverSireCore
import OverSireTestKit
@testable import TrackerPlane

/// Project settings from answers recorded on the real oversire project (read-only GET calls).
final class PlaneSettingsTests: XCTestCase {
    let pid = "9ba476d7-ad30-44cf-b9ef-3fa1e42ed926"
    let lead = "6008c025-3b03-4263-89fc-62f1153bfa27"
    var ws: String { "/api/v1/workspaces/ocral" }
    var http: RecordedPlane!
    var plane: PlaneTracker!
    var project: ProjectRef { ProjectRef(account: plane.account, id: pid, key: "OVERSIRE") }

    override func setUpWithError() throws {
        http = RecordedPlane()
        plane = PlaneTracker(workspace: PlaneWorkspace(slug: "ocral"), token: "tok", http: http)
        let dir = fixtureDir("plane")
        func fixture(_ name: String) throws -> String { try String(contentsOf: dir.appendingPathComponent(name + ".json"), encoding: .utf8) }
        let p = "\(ws)/projects/\(pid)/"
        http.on("GET", p, try fixture("project"))
        http.on("GET", p + "states/", try fixture("states"))
        http.on("GET", p + "labels/", try fixture("labels"))
        http.on("GET", p + "members/", try fixture("project-members"))
        http.on("GET", "\(ws)/projects/", "[" + (try fixture("project")) + "]")
        http.on("PATCH", p, "{}")
        http.on("POST", p + "labels/", #"{"id":"l-new"}"#)
    }

    func testLogoProps() {
        XCTAssertEqual(PlaneTracker.logo(["in_use": "emoji", "emoji": ["value": "129302"]]), ProjectLogo(kind: .emoji, value: "🤖"))
        XCTAssertEqual(PlaneTracker.logo(["in_use": "emoji", "emoji": ["value": "11088-65039"]]), ProjectLogo(kind: .emoji, value: "⭐️"))
        XCTAssertEqual(PlaneTracker.logo(["in_use": "icon", "icon": ["name": "dataset", "color": "#6d7b8a"]]),
                       ProjectLogo(kind: .icon, value: "dataset", color: "#6d7b8a"))
        XCTAssertNil(PlaneTracker.logo(nil))
        XCTAssertNil(PlaneTracker.logo(NSNull()))
        XCTAssertNil(PlaneTracker.logo(["in_use": "emoji"]))
        XCTAssertNil(PlaneTracker.logo(["in_use": "icon", "icon": ["name": ""]]))
    }

    func testEmojiRoundTrip() throws {
        let props = try ProjectLogo(kind: .emoji, value: "⭐️").planeProps
        XCTAssertEqual((props["emoji"] as? [String: Any])?["value"] as? String, "11088-65039")
        XCTAssertEqual(PlaneTracker.logo(props), ProjectLogo(kind: .emoji, value: "⭐️"))
        XCTAssertThrowsError(try ProjectLogo(kind: .image, value: "https://x.dev/a.png").planeProps)
    }

    func testProjectsCarryTheLogo() async throws {
        let list = try await plane.projects()
        XCTAssertEqual(list.first?.logo, ProjectLogo(kind: .icon, value: "check_circle", color: "#02b5ed"))
    }

    func testSettingsFromFixtures() async throws {
        let s = try await plane.settings(project)
        XCTAssertEqual(s.name, "oversire")
        XCTAssertEqual(s.key, "OVERSIRE")
        XCTAssertNil(s.description, "the project has no description")
        XCTAssertEqual(s.logo, ProjectLogo(kind: .icon, value: "check_circle", color: "#02b5ed"))
        XCTAssertEqual(s.lead?.id, lead)
        XCTAssertEqual(s.lead?.name, "flarco")
        XCTAssertEqual(s.defaultAssignee?.id, lead)
        XCTAssertEqual(s.visibility, .public)
        XCTAssertEqual(s.statuses.map(\.name), ["Backlog", "Todo", "In Progress", "Done", "Cancelled"])
        XCTAssertEqual(s.labels.map(\.name), ["session:done", "session:needs-input", "session:working"])
        XCTAssertEqual(s.priorities, ["urgent", "high", "medium", "low", "none"])
        XCTAssertEqual(s.members.map(\.person.name), ["flarco"], "the intake bot is not a member")
        XCTAssertEqual(s.members.first?.role, "admin")
        XCTAssertEqual(s.features, [.iterations: false, .modules: false, .intake: true, .pages: true, .estimates: false, .timeTracking: false])
        XCTAssertEqual(s.readOnlyFeatures, [.estimates])
    }

    func testPatchBodyForEachField() throws {
        func body(_ p: ProjectSettingsPatch) throws -> [String: Any] { try p.planeFields }
        XCTAssertEqual(try body(ProjectSettingsPatch(name: "New"))["name"] as? String, "New")
        XCTAssertEqual(try body(ProjectSettingsPatch(description: "**b**"))["description_html"] as? String, "<p><strong>b</strong></p>")
        let icon = try body(ProjectSettingsPatch(logo: ProjectLogo(kind: .icon, value: "bolt", color: "#e9a21a")))["logo_props"] as? [String: Any]
        XCTAssertEqual(icon?["in_use"] as? String, "icon")
        XCTAssertEqual((icon?["icon"] as? [String: Any])?["name"] as? String, "bolt")
        XCTAssertEqual((icon?["icon"] as? [String: Any])?["color"] as? String, "#e9a21a")
        XCTAssertEqual(try body(ProjectSettingsPatch(lead: "u2"))["project_lead"] as? String, "u2")
        XCTAssertTrue(try body(ProjectSettingsPatch(lead: .some(nil)))["project_lead"] is NSNull, "nil clears the lead")
        XCTAssertEqual(try body(ProjectSettingsPatch(defaultAssignee: "u3"))["default_assignee"] as? String, "u3")
        XCTAssertEqual(try body(ProjectSettingsPatch(visibility: .private))["network"] as? Int, 0)
        XCTAssertEqual(try body(ProjectSettingsPatch(visibility: .public))["network"] as? Int, 2)
        let f = try body(ProjectSettingsPatch(features: [.iterations: true, .modules: false, .intake: true, .pages: false,
                                                         .timeTracking: true, .estimates: false]))
        XCTAssertEqual(f["cycle_view"] as? Bool, true)
        XCTAssertEqual(f["module_view"] as? Bool, false)
        XCTAssertEqual(f["intake_view"] as? Bool, true)
        XCTAssertEqual(f["page_view"] as? Bool, false)
        XCTAssertEqual(f["is_time_tracking_enabled"] as? Bool, true)
        XCTAssertTrue(f["estimate"] is NSNull, "estimates off clears the scheme")
        XCTAssertNil(try body(ProjectSettingsPatch(features: [.estimates: true]))["estimate"], "estimates on is read only")
        XCTAssertTrue(try body(ProjectSettingsPatch(newLabels: [LabelDraft(name: "x", color: "#000")])).isEmpty, "labels use their own call")
        XCTAssertEqual(ProjectSettingsPatch(name: "a", lead: .some(nil), newLabels: []).fields, [.name, .lead, .labels])
    }

    func testUpdateSendsOnePatchAndMakesLabels() async throws {
        try await plane.update(project, ProjectSettingsPatch(name: "OverSire", newLabels: [LabelDraft(name: "ui", color: "#0072B2")]))
        XCTAssertEqual(http.body("PATCH", "\(ws)/projects/\(pid)/")?["name"] as? String, "OverSire")
        XCTAssertEqual(http.body("POST", "\(ws)/projects/\(pid)/labels/")?["name"] as? String, "ui")
        let before = http.requests.count
        try await plane.update(project, ProjectSettingsPatch())
        XCTAssertEqual(http.requests.count, before, "an empty patch makes no call")
    }

    func testSettingsConformance() async {
        let r = await TrackerConformance.settings(plane, project: project)
        XCTAssertTrue(r.passed, r.description)
        XCTAssertTrue(ProviderConformance.capabilities(plane).passed)
    }
}
