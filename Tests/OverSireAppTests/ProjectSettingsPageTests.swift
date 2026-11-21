import AppKit
import OverSireAssistant
import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class ProjectSettingsPageTests: XCTestCase {
    private let ref = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "SLING")

    private func item(_ key: String, url: String? = nil) -> Item {
        Item(id: "i1", key: key, title: "Fix the sync", url: url ?? "https://plane/\(key)", statusOptionId: nil, fields: [:],
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
        XCTAssertEqual(cfg.launch(for: item("SLING-7")).agent.profile, cfg.runtime.agent)
        var l = ProjectLocalSettings()
        l.agent = "codex"
        l.prompt = "fix {KEY}"
        cfg.setLocal("SLING", l)
        let r = cfg.launch(for: item("SLING-7"))
        XCTAssertEqual(r.agent.profile, "codex")
        XCTAssertEqual(r.prompt, "fix SLING-7\n\n" + SessionPrompt.subItemsRule)
        XCTAssertEqual(cfg.launch(for: item("OTHER-1")).prompt, SessionPrompt.withSubItemsRule(cfg.runtime.prompt(for: item("OTHER-1"))))
    }

    func testStartPromptSnapshot() {
        XCTAssertEqual(ProjectsConfig().launch(for: item("OTHER-1")).prompt, """
            work on https://plane/OTHER-1 in worktree group .wt/other-1

            When you set the parent to Done, set each finished sub-item to Done too. \
            Leave a sub-item open only when it is not done, and say why in a comment.
            """)
        var cfg = ProjectsConfig()
        cfg.runtime.prompt = "{KEY}\n\n" + SessionPrompt.subItemsRule
        XCTAssertEqual(cfg.launch(for: item("OTHER-1")).prompt, "OTHER-1\n\n" + SessionPrompt.subItemsRule, "no second copy")
    }

    func testPromptForBigTimerItem() {
        let it = item("ACME-12", url: "bigtimer://issue/ACME-12")
        XCTAssertEqual(ProjectsConfig().launch(for: it).prompt, """
            work on ACME-12 in worktree group .wt/acme-12

            Read the item with `oversire item show ACME-12`. \
            `big-timer-cli issue get ACME-12` and `big-timer-cli comment list ACME-12` work too.

            When you set the parent to Done, set each finished sub-item to Done too. \
            Leave a sub-item open only when it is not done, and say why in a comment.
            """)
    }

    func testPromptForOtherScheme() {
        let it = item("ABC-1", url: "linear://x/ABC-1")
        XCTAssertEqual(RuntimeConfig().prompt(for: it), "work on ABC-1 in worktree group .wt/abc-1\n\nRead the item with `oversire item show ABC-1`.")
        XCTAssertNil(RuntimeConfig.readHint(for: item("ABC-1")))
    }

    func testPromptHintNotTwice() {
        let it = item("ACME-12", url: "bigtimer://issue/ACME-12")
        var rc = RuntimeConfig()
        rc.prompt = "Run `oversire item show {KEY}` and fix it"
        XCTAssertEqual(rc.prompt(for: it), "Run `oversire item show ACME-12` and fix it")
    }

    // OVERSIRE-535
    private final class NoTrackers: TrackerDirectory {
        var trackerIds: [String] { [] }
        func tracker(_ id: String) -> (any Tracker)? { nil }
    }

    private func texts(_ v: NSView) -> [String] {
        ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts)
    }

    @MainActor
    private func clientData() -> TestAppData {
        let data = TestAppData()
        let store = ProjectStore(trackers: NoTrackers(), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                 statePath: data.tmp + "/s.json", activityPath: data.tmp + "/a.jsonl")
        store.client = true
        let summary = ProjectSummary(ref: ref, identifier: "SLING", title: "Sling", url: "", closed: false)
        var delta = MirrorDelta()
        delta.projects[ref.storeKey] = ProjectSnapshot(summary: summary, statusOptions: [], items: [], fetchedAt: Date())
        store.mirrored(delta)
        store.track([summary], live: [])
        data.projectStore = store
        return data
    }

    @MainActor
    func testClientLoadReadsRemote() async throws {
        let data = clientData()
        let body = try MirrorCodec.body(MirrorRows(rows: ProjectSettingsRead(settings: ProjectSettings(name: "From mbp"), editable: [.name])))
        var asked: [String] = []
        data.projectStore.remote = { what, _ in asked.append(what); return body }
        let page = ProjectSettingsPage(.projectSettings("SLING", .general), data: data, router: Router())
        _ = page.view
        let shown = await Wait.until(timeout: .seconds(3)) { await MainActor.run { self.texts(page.view).contains("From mbp") } }
        XCTAssertTrue(shown, "the page shows the name that the home gave")
        XCTAssertEqual(asked, ["projectSettings"])
    }

    @MainActor
    func testClientSaveForwardsTheAction() async throws {
        let data = clientData()
        var calls: [MemberCallRequest] = []
        data.actions.forward = { calls.append($0); return AppCallResult(id: "m-1", status: .ok, summary: "Changed.") }
        data.actions.sourceName = { "mbp" }
        let patch = try MirrorCodec.body(ProjectSettingsPatch(features: [.intake: true]))
        let r = await data.actions.run("project.updateSettings", ActionArgs(.object(["project": .string("SLING"), "patch": patch])))
        XCTAssertEqual(r, .ok(summary: "Changed."))
        XCTAssertEqual(calls.map(\.action), ["project.updateSettings"])
        let sent = try MirrorCodec.value(ProjectSettingsPatch.self, from: try XCTUnwrap(calls.first?.args["patch"]))
        XCTAssertEqual(sent.features, [.intake: true])
    }
}
