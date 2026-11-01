import OverSireAI
import OverSireAssistant
import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

private extension ActionResult {
    var data: JSONValue? { if case .ok(_, let d, _) = self { return d }; return nil }
}

final class RunbookActionsTests: XCTestCase {
    private let summary = ProjectSummary(ref: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "SLING"),
                                         identifier: "SLING", title: "Sling", url: "", closed: false)
    private var saved = ProjectsConfig()
    private var d: TestAppData!
    private var rt: FakeRuntime!
    private var book: RunbookBook!
    private var actions: RunbookActions!

    override func setUp() {
        saved = PROJECTS_CFG
        var cfg = ProjectsConfig()
        cfg.runtime.add("claude-max", cli: "claude")
        cfg.runtime.runbooks = cfg.runtime.oldRunbooks
        cfg.setOrcaRoot(summary, "/src/sling")
        PROJECTS_CFG = cfg
        d = TestAppData()
        let items = (1...2).map { n in
            Item(id: "i\(n)", key: "SLING-\(n)", title: "Item \(n)", url: "https://app.plane.so/ocral/browse/SLING-\(n)/", statusOptionId: "s1", fields: [:],
                 assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)
        }
        d.projectStore.seed(ProjectSnapshot(summary: summary, statusOptions: [StatusOption(id: "s1", name: "Todo", color: "#000", group: "unstarted")],
                                            items: items, fetchedAt: Date()))
        let rt = FakeRuntime()
        self.rt = rt
        book = RunbookBook(runtime: { rt }, bus: d.bus)
        var a = RunbookActions(link: ActionLink(d))
        a.runtime = { rt }
        a.undo = RunbookUndo(bus: d.bus)
        a.book = book
        actions = a
    }

    override func tearDown() { PROJECTS_CFG = saved }

    private func call(_ id: String, _ args: [String: JSONValue] = [:]) async -> ActionResult {
        guard let s = actions.specs.first(where: { $0.id == id }) else { XCTFail("no action \(id)"); return .failed("") }
        return await s.perform(ActionArgs(.object(args)))
    }

    private func refused(_ r: ActionResult) -> String? { if case .notAllowed(let m) = r { return m }; return nil }

    private func expectRefused(_ id: String, _ args: [String: JSONValue], _ text: String, line: UInt = #line) async {
        let r = await call(id, args)
        XCTAssertEqual(refused(r), text, line: line)
    }

    private func expectSummary(_ id: String, _ text: String, line: UInt = #line) async { await expectSummary(id, [:], text, line: line) }
    private func expectRefused(_ id: String, _ text: String, line: UInt = #line) async { await expectRefused(id, [:], text, line: line) }

    private func expectSummary(_ id: String, _ args: [String: JSONValue], _ text: String, line: UInt = #line) async {
        let r = await call(id, args)
        XCTAssertEqual(r.summary, text, line: line)
    }
    private var ids: [String] { PROJECTS_CFG.runtime.runbooks.map(\.id) }
    private func steps(_ id: String) -> [String] { PROJECTS_CFG.runtime.runbook(id)?.steps.map(\.id) ?? [] }

    private let quick: JSONValue = .object(["name": .string("Quick fix"), "steps": .array([
        .object(["name": .string("Fix it"), "agent": .string("claude"), "prompt": .string("Fix {url}. End with {done}.")]),
    ])])

    // MARK: Runbooks

    func testListGetAndValidate() async throws {
        let list = await call("runbook.list")
        let full = try XCTUnwrap(list.data?.array?.first { $0["id"]?.string == "full" })
        XCTAssertEqual(full["defaultOf"], .array([.string("SLING")]), "Full is the default with no project setting")
        let get = await call("runbook.get", ["id": .string("small")])
        XCTAssertTrue(get.data?["agents"]?.array?.contains(.string("claude-max")) ?? false)
        XCTAssertNotNil(get.data?["steps"])
        await expectRefused("runbook.get", ["id": .string("gone")], "There is no runbook gone. The runbooks: full, small, plan-only.")

        let bad: JSONValue = .object(["name": .string("Bad"), "steps": .array([.object(["name": .string("Do"), "agent": .string("gone"), "prompt": .string("Hi {who}")])])])
        let v = await call("runbook.validate", ["runbook": bad])
        XCTAssertEqual(v.data?["valid"], .bool(false))
        XCTAssertEqual(v.data?["problems"]?.array?.compactMap { $0["text"]?.string },
                       ["Do: there is no agent gone.", "Do: the prompt has no {done}.", "Do: {who} is not a placeholder."])
        await expectSummary("runbook.validate", ["id": .string("full")], "✓ Valid: Plan & Refine → Review Plan → Implement Plan Fixes → Implement → Review Implementation → Implement Fixes.")
    }

    func testCreateRefusesProblemsAndTakesIdsFromNames() async throws {
        let ok = await call("runbook.create", ["runbook": quick])
        XCTAssertEqual(ok.summary, "Quick fix is saved (id quick-fix).")
        XCTAssertEqual(steps("quick-fix"), ["fix-it"])
        await expectRefused("runbook.create", ["runbook": quick], "There is a runbook with the id quick-fix already. Use runbook.update.")

        let text = JSONValue.string(#"{"name":"No done","steps":[{"name":"A","agent":"claude","prompt":"x"}]}"#)
        let made = await call("runbook.create", ["runbook": text])
        let m = try XCTUnwrap(refused(made), "a runbook as JSON text decodes too")
        XCTAssertEqual(m, "No done has problems. Nothing is saved.\n! A: the prompt has no {done}.")
        XCTAssertNil(PROJECTS_CFG.runtime.runbook("no-done"))
    }

    func testUpdateWithAPatch() async throws {
        let add: JSONValue = .object(["op": .string("add"), "after": .string("implement"),
                                      "step": .object(["name": .string("Docs"), "agent": .string("claude"), "prompt": .string("Docs of {key}. {done}")])])
        var r = await call("runbook.update", ["id": .string("full"), "patch": .array([add])])
        XCTAssertNil(refused(r), r.summary)
        XCTAssertEqual(steps("full"), ["plan", "review-plan", "plan-fixes", "implement", "docs", "review", "fixes"])

        r = await call("runbook.update", ["id": .string("full"), "patch": .array([
            .object(["op": .string("move"), "step": .string("docs"), "after": .string("fixes")]),
            .object(["op": .string("set"), "step": .string("implement"), "pauseBefore": .bool(false), "agent": .string("claude-max")]),
            .string(#"{"op":"rename","name":"Full and docs"}"#),
        ])])
        XCTAssertEqual(r.summary, "Full and docs is saved: Plan & Refine → Review Plan → Implement Plan Fixes → Implement → Review Implementation → Implement Fixes → Docs.")
        let implement = try XCTUnwrap(PROJECTS_CFG.runtime.runbook("full")?.step("implement"))
        XCTAssertEqual(implement.agent, "claude-max")
        XCTAssertFalse(implement.pauses)

        r = await call("runbook.update", ["id": .string("full"), "patch": .array([.object(["op": .string("remove"), "step": .string("docs")])])])
        XCTAssertEqual(steps("full"), ["plan", "review-plan", "plan-fixes", "implement", "review", "fixes"])

        let removed = await call("runbook.update", ["id": .string("full"), "patch": .array([.object(["op": .string("remove"), "step": .string("fixes")])])])
        XCTAssertEqual(refused(removed), "Full and docs has problems. Nothing is saved.\n! Review Implementation: the fix step must be a step after the review.")
        XCTAssertEqual(steps("full").last, "fixes")
        await expectRefused("runbook.update", ["id": .string("full"), "patch": .array([.object(["op": .string("remove"), "step": .string("x")])])],
                       "Full and docs has no step x.")
    }

    func testUpdateWithTheFullRunbookKeepsTheId() async {
        let r = await call("runbook.update", ["id": .string("small"), "runbook": quick])
        XCTAssertNil(refused(r), r.summary)
        XCTAssertEqual(PROJECTS_CFG.runtime.runbook("small")?.name, "Quick fix")
        XCTAssertNil(PROJECTS_CFG.runtime.runbook("quick-fix"))
    }

    func testDeleteRefusesTheLastAndAnOpenRunAndClearsTheDefault() async throws {
        _ = await call("runbook.setDefault", ["project": .string("SLING"), "id": .string("small")])
        XCTAssertEqual(PROJECTS_CFG.runbook(for: "SLING")?.id, "small")
        _ = await call("runbook.start", ["key": .string("SLING-1")])
        await expectRefused("runbook.delete", ["id": .string("small")], "SLING-1 has an open run of Small. Stop the run first.")
        _ = await call("runbook.stop", ["key": .string("SLING-1")])
        let deleted = await call("runbook.delete", ["id": .string("small")])
        XCTAssertNil(refused(deleted))
        XCTAssertNil(PROJECTS_CFG.local("SLING").runbook)
        XCTAssertEqual(PROJECTS_CFG.runbook(for: "SLING")?.id, "full")
        _ = await call("runbook.delete", ["id": .string("plan-only")])
        await expectRefused("runbook.delete", ["id": .string("full")], "Full is the last runbook.")
    }

    func testUndoRevertsEachChange() async {
        let start = PROJECTS_CFG.runtime.runbooks
        _ = await call("runbook.create", ["runbook": quick])
        _ = await call("runbook.update", ["id": .string("full"), "patch": .array([.object(["op": .string("remove"), "step": .string("plan-fixes")]),
                                                                                  .object(["op": .string("set"), "step": .string("review-plan"), "review": .null])])])
        _ = await call("runbook.setDefault", ["project": .string("SLING"), "id": .string("small")])
        _ = await call("runbook.delete", ["id": .string("small")])
        XCTAssertEqual(ids, ["full", "plan-only", "quick-fix"])
        await expectSummary("runbook.undo", "Undid: Delete Small.")
        XCTAssertEqual(PROJECTS_CFG.local("SLING").runbook, "small", "the undo of a delete brings the default back")
        await expectSummary("runbook.undo", "Undid: Default of SLING.")
        XCTAssertNil(PROJECTS_CFG.local("SLING").runbook)
        await expectSummary("runbook.undo", "Undid: Change Full.")
        await expectSummary("runbook.undo", "Undid: New Quick fix.")
        XCTAssertEqual(PROJECTS_CFG.runtime.runbooks, start)
        await expectRefused("runbook.undo", "There is no runbook change to undo.")
    }

    func testUndoKeepsTwentyChanges() {
        let undo = RunbookUndo(bus: d.bus)
        for n in 0..<25 { undo.change("Change \(n)") { $0.runtime.runbooks[0].name = "Full \(n)" } }
        var count = 0
        while undo.undo() != nil { count += 1 }
        XCTAssertEqual(count, RunbookUndo.limit)
        XCTAssertEqual(PROJECTS_CFG.runtime.runbooks[0].name, "Full 4")
    }

    // MARK: Runs

    func testStartAndDriveARun() async throws {
        let started = await call("runbook.start", ["key": .string("SLING-1"), "id": .string("small")])
        XCTAssertEqual(started.data?["state"], .string("running"), started.summary)
        XCTAssertEqual(started.data?["runbook"], .string("Small"))
        await expectRefused("runbook.start", ["key": .string("SLING-1")], "SLING-1 has an open run of Small. Stop it first.")
        await expectRefused("runbook.start", ["key": .string("SLING-2"), "at": .string("nope")], "Full has no step nope.")
        await expectRefused("runbook.start", ["key": .string("SLING-9")], "OverSire has no loaded item SLING-9.")

        let paused = await call("runbook.pause", ["key": .string("SLING-1")])
        XCTAssertEqual(paused.data?["state"], .string("paused"))
        XCTAssertEqual(book.run(for: "SLING-1")?.state, .paused, "the reply goes into the book")
        let resumed = await call("runbook.resume", ["key": .string("SLING-1")])
        XCTAssertEqual(resumed.data?["state"], .string("running"))

        let first = try XCTUnwrap(PROJECTS_CFG.runtime.runbook("small")?.steps.first)
        await expectRefused("runbook.markDone", ["key": .string("SLING-1"), "verdict": .string("pass")], "Only a review ends with pass or gaps.")
        let done = await call("runbook.markDone", ["key": .string("SLING-1"), "note": .string("In.")])
        let step = try XCTUnwrap(done.data?["steps"]?.array?.first { $0["id"]?.string == first.id })
        XCTAssertEqual(step["state"], .string("done"))
        XCTAssertEqual(step["note"], .string("In."))
        XCTAssertNil(step["prompt"], "the status has no prompts")

        let status = await call("runbook.status", ["key": .string("SLING-1")])
        XCTAssertEqual(status.data?["current"], done.data?["current"])
        let stopped = await call("runbook.stop", ["key": .string("SLING-1")])
        XCTAssertEqual(stopped.data?["state"], .string("stopped"))
        await expectRefused("runbook.pause", ["key": .string("SLING-1")], "SLING-1 has no open runbook run.")
    }

    func testTheRunActionsNeedRunbooks() {
        let run = Set(["runbook.start", "runbook.status", "runbook.approve", "runbook.pause", "runbook.resume", "runbook.stop",
                       "runbook.retry", "runbook.skip", "runbook.markDone"])
        for s in actions.specs { XCTAssertEqual(s.capability, run.contains(s.id) ? .runbooks : nil, s.id) }
        let kinds = Dictionary(uniqueKeysWithValues: actions.specs.map { ($0.id, $0.kind) })
        XCTAssertEqual(kinds.filter { $0.value == .outward }.keys.sorted(), ["runbook.delete", "runbook.start", "runbook.stop"])
        XCTAssertFalse(kinds.values.contains(.settings), "the assistant does not see settings actions")
    }

    func testTheItemPaletteHasTheRunActions() {
        d.caps = [.runbooks]
        let ids = d.actions.palette(.item("SLING-1", .runbook), data: d).map(\.0.id)
        XCTAssertTrue(ids.contains("runbook.start"))
        XCTAssertTrue(ids.contains("runbook.approve"))
        XCTAssertFalse(ids.contains("runbook.status"), "a read is not a palette entry")
    }

    // MARK: Assistant

    func testTheAssistantChangesARunbook() async throws {
        let e = FakeChatEngine()
        e.reply(.toolCall(ToolCall(id: "c1", tool: "runbook_update", args: .object([
            "id": .string("full"), "patch": .array([.object(["op": .string("set"), "step": .string("implement"), "pauseBefore": .bool(false)])]),
        ]))))
        e.reply(.textDelta("Implement does not pause now."))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("runbook-assistant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let loop = AssistantLoop(router: ChatRouter(engines: [e]), catalog: ActionList(actions.specs), policy: RuleConfirmPolicy { AssistantPermissions() },
                                 store: ThreadStore(store: MemoryStore(), blobDir: dir), system: { _, _ in "system" },
                                 redactor: { Redactor(secrets: []) }, log: { _ in }, turnLog: { _ in })
        var seen: [DataChange] = []
        let watch = d.bus.observe { seen.append($0) }
        let t = AssistantThread(id: "t-1", title: ThreadStore.newTitle, createdAt: Date(timeIntervalSince1970: 0), engine: "fake-chat")
        var events: [ChatEvent] = []
        for await ev in await loop.send([.text("Do not pause before Implement in Full.")], in: t) {
            events.append(ev)
            if case .approvalNeeded(let c, _) = ev { await loop.answer(c.id, .approve) }
        }
        XCTAssertEqual(events.last, .end(.done))
        XCTAssertEqual(PROJECTS_CFG.runtime.runbook("full")?.step("implement")?.pauses, false)
        await MainActor.run { d.clock.advance(1) }
        XCTAssertTrue(seen.contains { $0.domains.contains(.config) }, "the pages get the config change")
        watch.cancel()
    }
}
