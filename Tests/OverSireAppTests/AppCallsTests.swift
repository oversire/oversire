import OverSireAssistant
import OverSireCore
import XCTest
@testable import OverSireApp

final class AppCallsTests: XCTestCase {
    actor Posted {
        var results: [AppCallResult] = []
        var callers: [ActionCaller] = []
        func add(_ r: AppCallResult) { results.append(r) }
        func saw(_ c: ActionCaller) { callers.append(c) }
    }

    func testRunsAllowedAction() async throws {
        let rig = try await EpicRig()
        let posted = Posted()
        let calls = AppCalls(catalog: rig.d.actions) { await posted.add($0) }
        await calls.handle(AppCall(id: "c1", action: "epic.list", args: .object(["project": .string("FAKE")])))
        let r = await posted.results
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.id, "c1")
        XCTAssertEqual(r.first?.status, .ok)
        XCTAssertEqual(r.first?.data?.array?.first?["title"]?.string, "Review desk")
    }

    func testAllowsItemReads() {
        for id in ["item.get", "item.list", "item.markdown"] { XCTAssertTrue(AppCalls.allowed.contains(id), id) }
    }

    func testAllowsItemWrites() {
        let ids = ["item.setStatus", "item.setPriority", "item.update", "item.edit", "item.comment", "item.assignMe", "item.assign", "item.start",
                   "item.reopen", "item.create", "item.relate", "item.link", "item.attach", "project.statuses", "project.labels", "project.people", "search.all"]
        for id in ids { XCTAssertTrue(AppCalls.allowed.contains(id), id) }
        for id in ["item.closeSubItems", "intake.delete", "pr.merge"] { XCTAssertFalse(AppCalls.allowed.contains(id), id) }
    }

    func testCIReadsAllowed() async {
        for id in ["ci.log", "ci.jobs", "ci.workflows", "ci.refresh", "ci.explain"] { XCTAssertTrue(AppCalls.allowed.contains(id), id) }
        XCTAssertFalse(AppCalls.allowed.contains("ci.rerun"))
        let posted = Posted()
        let read = ActionSpec(id: "ci.log", title: "Log", help: "", kind: .read) { _ in .ok(summary: "log") }
        let write = ActionSpec(id: "ci.rerun", title: "Rerun", help: "", kind: .change) { _ in .ok(summary: "ran") }
        let calls = AppCalls(catalog: ActionList([read, write])) { await posted.add($0) }
        await calls.handle(AppCall(id: "a", action: "ci.log", args: .object([:])))
        await calls.handle(AppCall(id: "b", action: "ci.rerun", args: .object([:])))
        let r = await posted.results
        XCTAssertEqual(r.map(\.status), [.ok, .notAllowed])
    }

    func testRunsItemCommentForCli() async throws {
        let rig = try await EpicRig()
        let item = rig.items[0]
        let posted = Posted()
        let calls = AppCalls(catalog: rig.d.actions) { await posted.add($0) }
        await calls.handle(AppCall(id: "c5", action: "item.comment", args: .object(["key": .string(item.key), "body": .string("Done in the CLI.")]), agent: "codex"))
        let r = await posted.results
        XCTAssertEqual(r.first?.status, .ok, r.first?.summary ?? "")
        let comments = try await rig.fake.comments(item)
        XCTAssertEqual(comments.map(\.body), ["Done in the CLI."])
    }

    func testRunsItemMarkdown() async throws {
        let rig = try await EpicRig()
        let key = rig.items[0].key
        let posted = Posted()
        let calls = AppCalls(catalog: rig.d.actions) { await posted.add($0) }
        await calls.handle(AppCall(id: "c4", action: "item.markdown", args: .object(["key": .string(key)])))
        let r = await posted.results
        XCTAssertEqual(r.first?.status, .ok, r.first?.summary ?? "")
        XCTAssertEqual(r.first?.data?["key"]?.string, key)
        XCTAssertEqual(r.first?.data?["markdown"]?.string?.hasPrefix("# "), true)
    }

    func testMemberActorVia() {
        let c = ActionCaller.member(machine: "mba", name: "Fritz")
        XCTAssertEqual(c.actor, EventActor(type: .human, name: nil, via: "app@mba"))
        XCTAssertEqual(c.actor.via, "app@mba")
        XCTAssertNil(ActionCaller.user.actor.via)
    }

    func testRefusesOtherAction() async {
        let posted = Posted()
        let spec = ActionSpec(id: "pr.merge", title: "Merge", help: "", kind: .outward) { a in
            await posted.saw(a.caller)
            return .ok(summary: "merged")
        }
        let calls = AppCalls(catalog: ActionList([spec])) { await posted.add($0) }
        await calls.handle(AppCall(id: "c2", action: "pr.merge", agent: "codex"))
        let r = await posted.results
        XCTAssertEqual(r, [AppCallResult(id: "c2", status: .notAllowed, summary: "The app does not run pr.merge from the CLI.")])
        let ran = await posted.callers
        XCTAssertEqual(ran, [])
    }

    func testCallerIsCli() async {
        let posted = Posted()
        let spec = ActionSpec(id: "epic.close", title: "Close", help: "", kind: .change) { a in
            await posted.saw(a.caller)
            return .failed("no")
        }
        let calls = AppCalls(catalog: ActionList([spec])) { await posted.add($0) }
        await calls.handle(AppCall(id: "c3", action: "epic.close", agent: "codex"))
        let seen = await posted.callers
        XCTAssertEqual(seen, [.cli(agent: "codex")])
        XCTAssertEqual(seen.first?.actor, EventActor(type: .agent, name: "codex"))
        XCTAssertEqual(ActionCaller.cli(agent: nil).actor, .user)
        let r = await posted.results
        XCTAssertEqual(r.first?.status, .failed)
    }
}
