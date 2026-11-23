import XCTest
import OverSireCore
import OverSireAssistant
import OverSireSync
import OverSireTestKit
@testable import OverSireApp

final class WorktreeBinderTests: XCTestCase {
    func bind(_ rig: EpicRig, _ key: String, parent: String? = nil, _ r: BindRequest = BindRequest()) async throws -> Result<WorktreeBinding, BindError> {
        let s = try await rig.summary
        return await MainActor.run { rig.d.binder.bind(key: key, title: "Add quick capture", parent: parent, project: s, r, source: .create, actor: .user) }
    }

    func testABindGivesTheDefaultGroupTheBranchTemplateAndOneEvent() async throws {
        let rig = try await EpicRig()
        let b = try await bind(rig, "X-1").get()
        XCTAssertEqual(b.group, ".wt/x-1")
        XCTAssertEqual(b.dir, "/w/.wt/x-1")
        XCTAssertEqual(b.branch, "x-1/add-quick-capture")
        XCTAssertEqual(b.mode, .own)
        XCTAssertEqual(b.machine, "mbp")
        let row = await rig.row(.itemWorktreeBound)
        XCTAssertEqual(row?.summary, ".wt/x-1 on mbp")
        XCTAssertEqual(row.map { EventCatalog.repo.problems($0) }, [])
        let saved = await MainActor.run { rig.d.bindings.binding("x-1") }
        XCTAssertEqual(saved, b)
    }

    func testParentModeUsesTheGroupAndBranchOfTheParent() async throws {
        let rig = try await EpicRig()
        _ = try await bind(rig, "X-1").get()
        let b = try await bind(rig, "X-2", parent: "X-1", BindRequest(shareParentGroup: true)).get()
        XCTAssertEqual(b.group, ".wt/x-1")
        XCTAssertEqual(b.branch, "x-1/add-quick-capture")
        XCTAssertEqual(b.mode, .parent)
        XCTAssertEqual(b.parent, "X-1")
        let row = await rig.rows(count: 2).last
        XCTAssertEqual(row?.parentItem, "X-1")
    }

    func testASecondOwnBindingOfTheSameFolderIsRefused() async throws {
        let rig = try await EpicRig()
        _ = try await bind(rig, "X-1").get()
        let r = try await bind(rig, "X-2", BindRequest(worktree: ".wt/x-1"))
        XCTAssertEqual(r, .failure(.taken(dir: "/w/.wt/x-1", by: "X-1")))
        let bad = try await bind(rig, "X-3", BindRequest(worktree: "../out"))
        XCTAssertEqual(bad, .failure(.badPath("../out")))
    }

    func testCreateWithNoRootStillMakesTheItemAndWarns() async throws {
        let rig = try await EpicRig()
        rig.d.bindRoot = nil
        let r = await rig.d.actions.run("item.create", ActionArgs(.object(["project": .string("FAKE"), "title": .string("No root")]), caller: .cli(agent: "codex s1")))
        guard case .ok(let summary, let data, _) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(summary.hasPrefix("FAKE-4 is made. No worktree binding: the project"), summary)
        XCTAssertNil(data?["worktree"])
    }

    func testCreateAnswersTheWorktree() async throws {
        let rig = try await EpicRig()
        let r = await rig.d.actions.run("item.create", ActionArgs(.object(["project": .string("FAKE"), "title": .string("Child"),
                                                                           "parent": .string(rig.items[0].key), "worktree": .string("/tmp/{key}")]),
                                                                caller: .cli(agent: "codex s1")))
        guard case .ok(let summary, let data, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(summary, "FAKE-4 is made under \(rig.items[0].key).")
        XCTAssertEqual(data?["worktree"]?["dir"]?.string, "/tmp/fake-4")
        XCTAssertEqual(data?["worktree"]?["parent"]?.string, rig.items[0].key)
    }

    func testBindWorktreeRefusesATakenFolder() async throws {
        let rig = try await EpicRig()
        let k0 = rig.items[0].key, k1 = rig.items[1].key
        let args = { (k: String) in ActionArgs(.object(["key": .string(k), "worktree": .string(".wt/shared")]), caller: .cli(agent: "codex s1")) }
        guard case .ok = await rig.d.actions.run("item.bindWorktree", args(k0)) else { return XCTFail() }
        let r = await rig.d.actions.run("item.bindWorktree", args(k1))
        guard case .notAllowed(let m) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(m.contains("\(k0) has the folder /w/.wt/shared"), m)
    }
}

final class WorktreeBindingBookTests: XCTestCase {
    func b(_ key: String, parent: String? = nil) -> WorktreeBinding {
        WorktreeBinding(key: key, machine: "mbp", root: "/w", group: ".wt/\(key.lowercased())", parent: parent)
    }

    func testChildrenOfAParentAreSortedByKey() {
        let d = TestAppData()
        for r in [b("P-3", parent: "P"), b("P-2", parent: "P"), b("Q-1", parent: "Q")] { d.bindings.save(r) }
        XCTAssertEqual(d.bindings.children(of: "p").map(\.key), ["P-2", "P-3"])
        XCTAssertEqual(d.bindings.owner(of: "/w/.wt/p-2/oversire", machine: "mbp")?.key, "P-2")
        XCTAssertNil(d.bindings.owner(of: "/w/.wt/p-2", machine: "mba"))
    }

    func testARemoteChangeReloadsTheRecords() async throws {
        let d = TestAppData()
        XCTAssertNil(d.bindings.binding("P-1"))
        try await d.writes.store.put(b("P-1"))
        let seen = expectation(forNotification: WorktreeBindingBook.changed, object: d.bindings)
        d.writes.changed(WorktreeBinding.collection)
        await fulfillment(of: [seen], timeout: 2)
        XCTAssertEqual(d.bindings.binding("p-1")?.group, ".wt/p-1")
    }

    func testTheBlockHasTheBindingLines() {
        let md = PlaneWriteBack.blockMarkdown(Workstream(key: "P-2"), binding: b("P-2", parent: "P"))
        XCTAssertTrue(md.contains("- Worktree: `.wt/p-2` on mbp"), md)
        XCTAssertTrue(md.contains("- Review in: P"), md)
        XCTAssertTrue(md.hasSuffix("- Open in OverSire: oversire://item/P-2"), md)
    }
}
