import OverSireAssistant
import OverSireCore
import XCTest
@testable import OverSireApp

/// A click of a client runs on the source app as a member (OVERSIRE-528).
final class MemberCallsTests: XCTestCase {
    actor Log {
        var lines: [String] = []
        var callers: [ActionCaller] = []
        func add(_ s: String) { lines.append(s) }
        func saw(_ c: ActionCaller) { callers.append(c) }
    }

    private func call(_ action: String) -> MemberCall {
        MemberCall(id: "m-1", action: action, args: .object(["key": .string("OVERSIRE-12")]), from: MemberCaller(machine: "mba", name: "Fritz"))
    }

    func testRunsAsMember() async {
        let log = Log()
        let spec = ActionSpec(id: "item.setStatus", title: "Set status", help: "", kind: .change) { a in
            await log.saw(a.caller)
            return .ok(summary: "OVERSIRE-12 is Done.", data: .object(["x": .int(1)]))
        }
        let r = await MemberCalls().handle(call("item.setStatus"), actions: ActionList([spec])) {}
        let seen = await log.callers
        XCTAssertEqual(seen, [.member(machine: "mba", name: "Fritz")])
        XCTAssertEqual(r, AppCallResult(id: "m-1", status: .ok, summary: "OVERSIRE-12 is Done.", data: .object(["x": .int(1)])))
    }

    func testRefusesLocalAction() async {
        let log = Log()
        let spec = ActionSpec(id: "machine.mode", title: "Mode", help: "", kind: .settings) { _ in
            await log.add("ran")
            return .ok(summary: "x")
        }
        let r = await MemberCalls().handle(call("machine.mode"), actions: ActionList([spec])) { await log.add("flush") }
        XCTAssertEqual(r.status, .notAllowed)
        XCTAssertEqual(r.summary, "machine.mode runs only on the Mac where you click it.")
        let lines = await log.lines
        XCTAssertEqual(lines, [])
    }

    // OVERSIRE-534
    func testCatalogRefreshRefreshesTheWorkspace() async throws {
        let rig = try await EpicRig(tracking: false)
        let ws = rig.fake.account.id
        let r = await rig.d.actions.run("project.catalogRefresh", ActionArgs(.object(["workspace": .string(ws)])))
        guard case .ok = r else { return XCTFail("\(r)") }
        XCTAssertEqual(rig.fake.projectCalls, 1)
        XCTAssertEqual(rig.d.projectCatalog.projects(of: ws).count, 1)
        let all = await rig.d.actions.run("project.catalogRefresh", ActionArgs(.object([:])))
        guard case .ok = all else { return XCTFail("\(all)") }
        XCTAssertEqual(rig.fake.projectCalls, 2)
        let bad = await rig.d.actions.run("project.catalogRefresh", ActionArgs(.object(["workspace": .string("nope")])))
        XCTAssertEqual(bad, .notAllowed("No workspace nope."))
        XCTAssertEqual(rig.fake.projectCalls, 2)
    }

    func testFlushesBeforeResult() async {
        let log = Log()
        let spec = ActionSpec(id: "item.comment", title: "Comment", help: "", kind: .change) { _ in
            await log.add("run")
            return .ok(summary: "ok")
        }
        let r = await MemberCalls().handle(call("item.comment"), actions: ActionList([spec])) { await log.add("flush") }
        await log.add("post \(r.status.rawValue)")
        let lines = await log.lines
        XCTAssertEqual(lines, ["run", "flush", "post ok"])
    }

    func testMapsFailureAndRefusal() async {
        let failing = ActionSpec(id: "item.edit", title: "Edit", help: "", kind: .change) { _ in .failed("The tracker did not take the change.") }
        let refusing = ActionSpec(id: "pr.merge", title: "Merge", help: "", kind: .outward) { _ in .notAllowed("No PR.") }
        let list = ActionList([failing, refusing])
        let a = await MemberCalls().handle(call("item.edit"), actions: list) {}
        XCTAssertEqual(a.status, .failed)
        XCTAssertNil(a.data)
        let b = await MemberCalls().handle(call("pr.merge"), actions: list) {}
        XCTAssertEqual(b.status, .notAllowed)
        XCTAssertEqual(b.summary, "No PR.")
    }

    func testSettingsConflictCarriesAFlag() async {
        let spec = ActionSpec(id: "settings.patch", title: "Patch", help: "", kind: .settings) { _ in .failed("Changed on mbp. Look again.") }
        let r = await MemberCalls().handle(call("settings.patch"), actions: ActionList([spec])) {}
        XCTAssertEqual(r.status, .failed)
        XCTAssertEqual(r.data, .object(["conflict": .bool(true)]))
    }

    func testUnknownActionIsRefused() async {
        let r = await MemberCalls().handle(call("nope.nothing"), actions: ActionList([])) {}
        XCTAssertEqual(r.status, .notAllowed)
    }

    func testLocalIdsAreActions() {
        let ids = Set(TestAppData().actions.all.map(\.id))
        for id in MemberCalls.local { XCTAssertTrue(ids.contains(id), "\(id) is not an action") }
    }

    func testMirrorReadGivesCommentRows() async throws {
        let rig = try await EpicRig()
        let key = rig.items[0].key
        _ = await rig.d.actions.run("item.comment", ActionArgs(.object(["key": .string(key), "body": .string("Hello")])))
        let r = await rig.d.actions.run("mirror.read", ActionArgs(.object(["what": .string("comments"), "item": .string(key)])))
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        let rows = try MirrorCodec.value(MirrorRows<[Comment]>.self, from: data).rows
        XCTAssertEqual(rows.compactMap(\.body), ["Hello"])
    }

    func testMirrorReadGivesOptionsAndRefusesUnknown() async throws {
        let rig = try await EpicRig()
        let project = rig.d.projectStore.snapshots.keys.first ?? ""
        let r = await rig.d.actions.run("mirror.read", ActionArgs(.object(["what": .string("options"), "project": .string(project)])))
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        _ = try MirrorCodec.value(MirrorRows<ItemOptions>.self, from: data)
        let bad = await rig.d.actions.run("mirror.read", ActionArgs(.object(["what": .string("nope")])))
        XCTAssertEqual(bad, .notAllowed("mirror.read has no read nope."))
    }

    func testSetStatusWithSubItemsWritesTheEventVia() async throws {
        let rig = try await EpicRig()
        let key = rig.items[0].key
        let caller = ActionCaller.member(machine: "mba", name: "Fritz")
        let r = await rig.d.actions.run("item.setStatus", ActionArgs(.object(["key": .string(key), "status": .string("done"), "subItems": .bool(true), "force": .bool(true)]), caller: caller))
        guard case .ok = r else { return XCTFail("\(r)") }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let rows = await rig.outlet.rows.filter { $0.kind == .itemStateChanged }
        XCTAssertEqual(rows.first?.via, "app@mba")
    }
}
