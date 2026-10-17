import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class ProjectSettingsPageTests: XCTestCase {
    private let ref = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "SLING")

    private func item(_ key: String) -> Item {
        Item(id: "i1", key: key, title: "Fix the sync", url: "https://plane/\(key)", statusOptionId: nil, fields: [:],
             assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(),
             commentCount: 0, lastComment: nil, mentionsMe: false)
    }

    func testRouteRoundTrip() {
        let r = Route.projectSettings("SLING", .workflow)
        XCTAssertEqual(Route(path: r.path), r)
        XCTAssertEqual(r.sidebarKey, Route.project("SLING").sidebarKey)
    }

    func testEmptySettingsShowOnlyGeneral() {
        let v = TrackerSettingsView(settings: ProjectSettings(name: "Sling"), editable: [])
        XCTAssertEqual(v.sections, [.general])
        XCTAssertEqual(v.generalFields, [.name])
    }

    func testEditableFieldsShowWhenEmpty() {
        let v = TrackerSettingsView(settings: ProjectSettings(name: "Sling"), editable: [.description, .lead, .labels])
        XCTAssertEqual(v.sections, [.general, .labels])
        XCTAssertEqual(v.generalFields, [.name, .description, .lead])
    }

    func testReadOnlyFeatureCannotToggle() {
        let s = ProjectSettings(name: "Sling", features: [.iterations: true, .intake: false], readOnlyFeatures: [.intake])
        let v = TrackerSettingsView(settings: s, editable: [.features])
        XCTAssertTrue(v.canToggle(.iterations))
        XCTAssertFalse(v.canToggle(.intake))
        XCTAssertFalse(TrackerSettingsView(settings: s, editable: []).canToggle(.iterations))
    }

    func testFakeTrackerFeedsTheView() async throws {
        let t = FakeTracker()
        t.editableSettings = [.name]
        let v = TrackerSettingsView(settings: try await t.settings(t.project), editable: t.editableSettings)
        XCTAssertTrue(v.sections.contains(.workflow))
        XCTAssertFalse(v.canEdit(.features))
    }

    func testLocalCategoryWins() {
        var cfg = ProjectsConfig()
        let todo = StatusOption(id: "s1", name: "Todo", color: "#000", group: "unstarted")
        var l = ProjectLocalSettings()
        l.categories["s1"] = .blocked
        cfg.setLocal("SLING", l)
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "SLING", title: "Sling", url: "", closed: false),
                                   statusOptions: [todo], items: [], fetchedAt: Date())
        let out = ProjectStore.localized(snap, cfg: cfg).statusOptions[0]
        XCTAssertEqual(out.category, .blocked)
        XCTAssertEqual(out.autoCategory, todo.category)
        let data = try! JSONEncoder().encode(out)
        XCTAssertNil(try! JSONDecoder().decode(StatusOption.self, from: data).localCategory)
    }

    func testMutedProjectHasNoNotifications() {
        var cfg = ProjectsConfig()
        var l = ProjectLocalSettings()
        XCTAssertEqual(cfg.notifications(for: "SLING"), cfg.notifications)
        l.notifications = ProjectNotificationSettings()
        l.notifications?.mention = false
        cfg.setLocal("SLING", l)
        XCTAssertEqual(cfg.notifications(for: "sling")?.mention, false)
        l.muted = true
        cfg.setLocal("SLING", l)
        XCTAssertNil(cfg.notifications(for: "SLING"))
    }

    func testProjectAgentAndPrompt() {
        var cfg = ProjectsConfig()
        XCTAssertEqual(cfg.launch(for: item("SLING-7")).agent, cfg.orca.agent)
        var l = ProjectLocalSettings()
        l.agent = "codex"
        l.prompt = "fix {KEY}"
        cfg.setLocal("SLING", l)
        let r = cfg.launch(for: item("SLING-7"))
        XCTAssertEqual(r.agent, "codex")
        XCTAssertEqual(r.prompt, "fix SLING-7")
        XCTAssertEqual(cfg.launch(for: item("OTHER-1")).prompt, cfg.orca.prompt(for: item("OTHER-1")))
    }
}
