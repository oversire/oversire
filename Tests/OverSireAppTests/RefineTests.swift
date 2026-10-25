import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class RefineTests: XCTestCase {
    private final class Trackers: TrackerDirectory {
        let fake: FakeTracker
        init(_ fake: FakeTracker) { self.fake = fake }
        var trackerIds: [String] { [fake.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == fake.account.id ? fake : nil }
    }

    private var fake: FakeTracker!
    private var rt: FakeRuntime!
    private var agents: AgentIndex!
    private var cfg = ProjectsConfig()

    override func setUp() {
        fake = FakeTracker()
        rt = FakeRuntime()
        agents = AgentIndex(writes: nil)
        let rt = rt!
        agents.runtime = { rt }
        cfg = ProjectsConfig()
    }

    private func starter() -> RefineStarter {
        var s = RefineStarter(agents)
        let fake = fake!, cfg = cfg
        s.tracker = { _ in fake }
        s.root = { _ in "/src/fake" }
        s.cfg = { cfg }
        return s
    }

    private func start(_ t: RefineTarget) async throws -> LaunchRequest {
        let summary = try await fake.projects()[0]
        let done = expectation(description: "start")
        var err: String?
        let s = starter()
        await MainActor.run { s.start(t, in: summary) { err = $0; done.fulfill() } }
        await fulfillment(of: [done], timeout: 5)
        XCTAssertNil(err)
        let launches = rt.launches
        XCTAssertEqual(launches.count, 1)
        return try XCTUnwrap(launches.first)
    }

    private func intake(_ title: String, body: String) async throws -> IntakeItem {
        try await fake.createIntake(ItemDraft(title: title, bodyMarkdown: body), in: fake.project).intake
    }

    func testIntakeRouteRoundTrips() {
        let r = Route.intakeItem("FAKE", "n-1")
        XCTAssertEqual(Route(url: r.url), r)
        XCTAssertEqual(Route(url: URL(string: "oversire://intake/fake/n-1")!), r)
        XCTAssertEqual(Route(url: URL(string: "oversire://intake/fake")!), .intake("FAKE"))
        XCTAssertTrue(r.samePage(.intakeItem("FAKE", "n-2")), "a step to the next item replaces the history entry")
        XCTAssertFalse(r.samePage(.intakeItem("SLING", "n-1")))
    }

    func testRouterAsksBeforeItLeavesADraft() {
        let router = Router()
        router.go(.intakeItem("FAKE", "n-1"))
        var proceed: (() -> Void)?
        router.holdLeave = { _, go in proceed = go; return true }
        router.go(.home)
        XCTAssertEqual(router.current, .intakeItem("FAKE", "n-1"), "the move waits for an answer")
        router.go(.intakeItem("FAKE", "n-2"))
        XCTAssertEqual(router.current, .intakeItem("FAKE", "n-2"), "the same page does not ask")
        router.go(.home)
        proceed?()
        XCTAssertEqual(router.current, .home)
    }

    func testIntakeRefineOpensATerminalInTheFolder() async throws {
        let i = try await intake("Labels drop", body: "The sync drops labels.")
        let r = try await start(.intake(i, key: "FAKE-1", body: nil))
        XCTAssertEqual(r.repo, "/src/fake")
        XCTAssertEqual(r.inPlace, true)
        XCTAssertEqual(r.title, "refine-fake-1")
        XCTAssertNil(r.item, "no worktree for an item")
        XCTAssertTrue(r.prompt.hasPrefix("Labels drop\n\nThe sync drops labels."), "the start reads the body: \(r.prompt)")
        XCTAssertTrue(r.prompt.contains("plane-cli intake update \(i.id) -w fake -p FAKE --status 1"), r.prompt)
        XCTAssertTrue(r.prompt.contains("FAKE-1"), r.prompt)
        XCTAssertFalse(r.prompt.contains("attachment download"), "no files: no download line")
        let items = try await fake.items(fake.project, since: nil, limit: 10)
        XCTAssertEqual(items.count, 1, "Refine makes no item")
        XCTAssertTrue(fake.uploads.isEmpty)
        await MainActor.run { XCTAssertNotNil(starter().session("fake-1"), "the Refine button opens the session") }
    }

    func testIntakeRefineWithFilesKeepsTheDownloadLine() async throws {
        let i = try await intake("Labels drop", body: "")
        let ref = ItemRef(project: fake.project, id: i.workItemId, key: "FAKE-1", url: URL(string: "https://tracker.fake/FAKE-1")!)
        _ = try await fake.attach(AttachmentUpload(name: "shot.png", mimeType: "image/png", data: Data("png".utf8)), to: ref)
        let r = try await start(.intake(i, key: "FAKE-1", body: "Known body"))
        XCTAssertTrue(r.prompt.hasPrefix("Labels drop\n\nKnown body"), r.prompt)
        XCTAssertTrue(r.prompt.contains("plane-cli wi attachment download \(i.workItemId) -w fake -p FAKE --dir .oversire/FAKE-1"), r.prompt)
    }

    func testItemRefineUsesTheEditedTemplate() async throws {
        let ref = try await fake.create(ItemDraft(title: "Fix the sync", bodyMarkdown: "It is slow."), in: fake.project)
        let item = try await fake.detail(ref).item
        cfg.runtime.refinePrompt = "Refine {key}: {text}"
        let r = try await start(.item(item))
        XCTAssertEqual(r.prompt, "Refine \(item.key): Fix the sync\n\nIt is slow.")
        XCTAssertEqual(r.note, item.url)
    }

    func testRefinePromptDecodesAndKeepsAnEdit() throws {
        let old = try JSONDecoder().decode(RuntimeConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(old.refinePrompt, SessionPrompt.refineDefault)
        var c = RuntimeConfig()
        c.refinePrompt = "Talk about {key}."
        let back = try JSONDecoder().decode(RuntimeConfig.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back.refinePrompt, "Talk about {key}.")
    }

    func testNoRootDoesNotStart() async throws {
        var s = starter()
        s.root = { _ in nil }
        let summary = try await fake.projects()[0]
        let i = try await intake("Labels drop", body: "")
        var err: String?
        await MainActor.run { s.start(.intake(i, key: "FAKE-1", body: ""), in: summary) { err = $0 } }
        XCTAssertNotNil(err)
        XCTAssertTrue(rt.launches.isEmpty)
    }

    func testDetailPageWritesBodyAndPriorityAsIntakeEdits() async throws {
        let i = try await intake("Labels drop", body: "old")
        let summary = try await fake.projects()[0]
        let d = await MainActor.run { () -> TestAppData in
            let d = TestAppData()
            d.projectStore = ProjectStore(trackers: Trackers(fake), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                          statePath: d.tmp + "/s.json", activityPath: d.tmp + "/a.jsonl")
            d.projectStore.seed(ProjectSnapshot(summary: summary, statusOptions: [], items: [], fetchedAt: Date(), intake: [i]))
            return d
        }
        let page = await MainActor.run { IntakeDetailPage(.intakeItem("FAKE", i.id), data: d, router: Router()) }
        for (patch, what) in [(ItemPatch(bodyMarkdown: "## New body"), "body"), (ItemPatch(priority: "high"), "priority")] {
            let saved = expectation(description: what)
            await MainActor.run { page.update(i, patch, what: what) { saved.fulfill() } }
            await fulfillment(of: [saved], timeout: 5)
        }
        XCTAssertEqual(fake.intakeEdits.map(\.patch), [ItemPatch(bodyMarkdown: "## New body"), ItemPatch(priority: "high")])
        let still = try await fake.intake(fake.project)
        XCTAssertEqual(still.map(\.id), [i.id], "an edit keeps the item in the intake")
    }
}
