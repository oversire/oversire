import XCTest
import OverSireCore
import OverSireAI
import OverSireAssistant
import OverSireTestKit
@testable import OverSireApp

final class ActionCatalogTests: XCTestCase {
    private let ref = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "SLING")

    private func seeded() -> TestAppData {
        let d = TestAppData()
        let items = (1...3).map { n in
            Item(id: "i\(n)", key: "SLING-\(n)", title: "Item \(n)", url: "", statusOptionId: "s1", fields: [:], assignees: [], labels: [],
                 author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)
        }
        d.projectStore.seed(ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "SLING", title: "Sling", url: "", closed: false),
                                            statusOptions: [StatusOption(id: "s1", name: "Todo", color: "#000", group: "unstarted"),
                                                            StatusOption(id: "s2", name: "Done", color: "#000", group: "completed")],
                                            items: items, fetchedAt: Date()))
        return d
    }

    func testIdsAreUnique() {
        let ids = TestAppData().actions.all.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "repeated: \(Dictionary(grouping: ids) { $0 }.filter { $1.count > 1 }.keys.sorted())")
    }

    func testSchemasAreValid() {
        let types: Set<String> = ["string", "integer", "number", "boolean", "array", "object"]
        for s in TestAppData().actions.all {
            XCTAssertTrue(s.id.contains("."), s.id)
            XCTAssertFalse(s.help.isEmpty, s.id)
            XCTAssertEqual(s.input["type"]?.string, "object", s.id)
            let props = s.input["properties"]?.object ?? [:]
            for (k, v) in props {
                XCTAssertTrue(types.contains(v["type"]?.string ?? ""), "\(s.id).\(k)")
                if v["type"]?.string == "array" { XCTAssertNotNil(v["items"], "\(s.id).\(k) has no items") }
            }
            let required = s.input["required"]?.array?.compactMap(\.string) ?? []
            XCTAssertTrue(Set(required).isSubset(of: props.keys), s.id)
        }
    }

    func testKinds() {
        let kind = Dictionary(uniqueKeysWithValues: TestAppData().actions.all.map { ($0.id, $0.kind) })
        for id in ["session.start", "session.send", "pr.approve", "pr.merge", "pr.deleteBranch", "worktree.remove", "intake.delete",
                   "item.closeSubItems", "queue.start"] {
            XCTAssertEqual(kind[id], .outward, id)
        }
        for id in ["queue.setSlots", "machine.installHooks", "machine.remove", "machine.setHome"] { XCTAssertEqual(kind[id], .settings, id) }
        for id in ["session.history", "session.tail", "run.log", "run.explain", "machine.list"] { XCTAssertEqual(kind[id], .read, id) }
    }

    func testEachDomainRowCommandHasASpec() {
        let catalog = TestAppData().actions
        let commands: [RowCommand] = [
            .status(itemId: "i1", optionId: "s2"), .priority(itemId: "i1", priorityId: "high"), .assignMe(itemId: "i1"),
            .startSession(key: "SLING-1"), .run(repo: "o/r", runId: "9", .rerun), .run(repo: "o/r", runId: "9", .rerunFailed),
            .run(repo: "o/r", runId: "9", .cancel), .ignoreFailure(repo: "o/r", runId: "9", true),
            .rerunJob(repo: "o/r", runId: "9", jobId: "3"), .approve(repo: "o/r", number: 1), .merge(repo: "o/r", number: 1),
            .revealCard("c1"), .refreshProject("k"), .favorite(key: "SLING-1", true),
        ]
        for c in commands {
            guard let (id, args) = c.action(key: { _ in "SLING-1" }) else { XCTFail("\(c) has no action"); continue }
            guard let s = catalog.spec(id) else { XCTFail("no spec \(id)"); continue }
            let props = Set(s.input["properties"]?.object?.keys ?? [:].keys)
            let required = Set(s.input["required"]?.array?.compactMap(\.string) ?? [])
            XCTAssertTrue(Set(args.keys).isSubset(of: props), "\(id): \(args.keys.sorted())")
            XCTAssertTrue(required.isSubset(of: args.keys), "\(id) misses \(required.subtracting(args.keys))")
        }
        XCTAssertNil(RowCommand.status(itemId: "gone", optionId: "s2").action(key: { _ in nil }))
        for c: RowCommand in [.open(.home), .copy("x"), .openURL("u"), .sendInput(key: "K"), .explain(repo: "o/r", runId: "1", jobId: nil)] {
            XCTAssertNil(c.action(key: { _ in "K" }), "\(c)")
        }
    }

    func testCapabilityHidesActions() {
        let d = TestAppData()
        XCTAssertFalse(d.actions.supported(d).contains { $0.id == "run.cancel" })
        d.caps = [.cancel]
        XCTAssertTrue(d.actions.supported(d).contains { $0.id == "run.cancel" })
    }

    func testPaletteGivesTheActionsOfThePage() {
        let d = TestAppData()
        let entries = d.actions.palette(.item("SLING-1", .overview), data: d)
        XCTAssertTrue(entries.contains { $0.0.id == "item.setStatus" } == false, "item.setStatus needs a status the route does not give")
        let assign = entries.first { $0.0.id == "item.assignMe" }
        XCTAssertEqual(assign?.1, ["key": .string("SLING-1")])
        XCTAssertFalse(entries.contains { $0.0.kind == .read })
        XCTAssertTrue(d.actions.palette(.home, data: d).isEmpty)
    }

    func testPaletteOnEpicRoute() {
        let d = TestAppData()
        d.caps = [.epics]
        let entries = d.actions.palette(.epic("FAKE", "e1", .overview), data: d)
        let close = entries.first { $0.0.id == "epic.close" }
        XCTAssertEqual(close?.1, ["project": .string("FAKE"), "epic": .string("e1")])
        XCTAssertFalse(entries.contains { $0.0.id == "epic.addItems" }, "epic.addItems needs keys")
    }

    func testQueueActions() async {
        let d = seeded()
        let add = await d.actions.run("queue.add", ActionArgs(.object(["key": .string("sling-1")])))
        XCTAssertEqual(add.summary, "SLING-1 is in the queue of SLING.")
        _ = await d.actions.run("queue.add", ActionArgs(.object(["key": .string("SLING-2")])))
        _ = await d.actions.run("queue.move", ActionArgs(.object(["key": .string("SLING-2"), "by": .int(-1)])))
        let order = await MainActor.run { d.queue.lanes.first?.entries.map(\.key) }
        XCTAssertEqual(order, ["SLING-2", "SLING-1"])
        _ = await d.actions.run("queue.remove", ActionArgs(.object(["key": .string("SLING-2")])))
        let left = await MainActor.run { d.queue.contains("SLING-2") }
        XCTAssertFalse(left)
        let none = await d.actions.run("queue.remove", ActionArgs(.object(["key": .string("SLING-9")])))
        guard case .notAllowed = none else { return XCTFail("\(none)") }
    }

    func testItemActionsExplainBadArgs() async {
        let d = seeded()
        let missing = await d.actions.run("item.setStatus", ActionArgs(.object(["status": .string("Done")])))
        guard case .notAllowed = missing else { return XCTFail("\(missing)") }
        let unknown = await d.actions.run("item.setStatus", ActionArgs(.object(["key": .string("SLING-404"), "status": .string("Done")])))
        XCTAssertEqual(unknown, .notAllowed("OverSire has no loaded item SLING-404."))
        let status = await d.actions.run("item.setStatus", ActionArgs(.object(["key": .string("SLING-1"), "status": .string("Shipped")])))
        XCTAssertEqual(status, .notAllowed("SLING has no status Shipped. It has: Todo, Done."))
        let action = await d.actions.run("no.such", ActionArgs(.object([:])))
        XCTAssertEqual(action, .notAllowed("No action no.such."))
    }

    func testSetStatusRefusesAParentWithOpenSubItems() async {
        let d = seeded()
        let snap = d.projectStore.snapshots.values.first!
        let child = Item(id: "i9", key: "SLING-9", title: "Child", url: "", statusOptionId: "s1", fields: [:], assignees: [], labels: [],
                         author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false,
                         parentId: "i1")
        d.projectStore.seed(ProjectSnapshot(summary: snap.summary, statusOptions: snap.statusOptions, items: snap.items + [child], fetchedAt: Date()))
        let r = await d.actions.run("item.setStatus", ActionArgs(.object(["key": .string("SLING-1"), "status": .string("Done")])))
        XCTAssertEqual(r, .notAllowed("SLING-1 has 1 open sub-item. Close it first. Use item.closeSubItems, or set force to true."))
        let forced = await d.actions.run("item.setStatus", ActionArgs(.object(["key": .string("SLING-1"), "status": .string("Done"), "force": .bool(true)])))
        if case .notAllowed = forced { XCTFail("force passes the check: \(forced)") }
        let open = await d.actions.run("item.setStatus", ActionArgs(.object(["key": .string("SLING-1"), "status": .string("Todo")])))
        if case .notAllowed = open { XCTFail("an open state passes the check: \(open)") }
    }

    func testPageActionsMapToSpecs() {
        let catalog = TestAppData().actions
        let pr: [ChangeAction] = [.approve(nil), .approve("ok"), .requestChanges("fix"), .comment("hi"), .merge(.rebase), .close]
        let intake: [IntakeAction] = [.accept, .decline, .delete, .snooze(until: Date()), .duplicate(of: "i9"),
                                      .update(IntakeEdit(patch: ItemPatch(priority: "high", bodyMarkdown: "## Body")))]
        let pairs = pr.map { $0.action(repo: "o/r", number: 3) } + intake.compactMap { $0.action(project: "k", id: "w1") }
        XCTAssertEqual(pairs.count, pr.count + intake.count)
        for (id, args) in pairs {
            guard let s = catalog.spec(id) else { XCTFail("no spec \(id)"); continue }
            let required = Set(s.input["required"]?.array?.compactMap(\.string) ?? [])
            XCTAssertTrue(required.isSubset(of: args.keys), "\(id) misses \(required.subtracting(args.keys))")
            XCTAssertTrue(Set(args.keys).isSubset(of: s.input["properties"]?.object?.keys ?? [:].keys), id)
        }
        XCTAssertEqual(ChangeAction.merge(.rebase).action(repo: "o/r", number: 3).args["method"], .string("rebase"))
        XCTAssertEqual(IntakeAction.update(IntakeEdit(patch: ItemPatch(priority: "low"))).action(project: "k", id: "w1")?.args["priority"], .string("low"))
        let wide = IntakeAction.update(IntakeEdit(patch: ItemPatch(title: "x"))).action(project: "k", id: "w1")
        XCTAssertEqual(wide?.id, "intake.edit")
        XCTAssertEqual(wide?.args["patch"]?["title"], .string("x"))
        let other = ItemRef(project: ProjectRef(workspace: "w", id: "p"), id: "i2", key: "K-2", url: URL(string: "https://x/K-2")!)
        let related = IntakeAction.update(IntakeEdit(patch: ItemPatch(priority: "low"), relations: [ItemRelation(kind: .blocks, item: other)])).action(project: "k", id: "w1")
        XCTAssertEqual(related?.id, "intake.edit")
        XCTAssertEqual(related?.args["patch"]?["priority"], .string("low"))
        XCTAssertEqual(related?.args["relations"]?.array?.count, 1)
        XCTAssertNil(related?.args["priority"], "an edit with relations sends one patch")
    }

    func testDomainActionsRefuseUnknownTargets() async {
        let d = seeded()
        let cases: [(String, [String: JSONValue], String)] = [
            ("worktree.remove", ["key": .string("SLING-1")], "SLING-1 has nothing to remove that is safe."),
            ("question.answer", ["id": .string("q9"), "answer": .string("yes")], "No open question q9."),
            ("status.approve", ["key": .string("SLING-1")], "No session result for SLING-1."),
            ("pr.deleteBranch", ["repo": .string("o/r"), "number": .int(4)], "OverSire has no loaded PR o/r#4."),
            ("plan.accept", ["id": .string("s9")], "No open plan change s9."),
            ("intake.accept", ["project": .string("SLING"), "id": .string("w1")], "No pending intake item w1 in SLING."),
            ("session.start", ["key": .string("SLING-1"), "machine": .string("far-away-mac")], "session.start runs on this Mac. Use order.start for far-away-mac."),
            ("queue.setSlots", ["project": .string("NOPE"), "slots": .int(2)], "OverSire has no loaded project NOPE."),
        ]
        for (id, args, want) in cases {
            let r = await d.actions.run(id, ActionArgs(.object(args)))
            XCTAssertEqual(r, .notAllowed(want), id)
        }
    }

    // MARK: Epics

    private func args(_ o: [String: JSONValue]) -> ActionArgs { ActionArgs(.object(o)) }

    func testEpicActionsNeedTheCapability() {
        let d = TestAppData()
        let ids = ["item.setEpic", "epic.list", "epic.create", "epic.update", "epic.close", "epic.addItems", "epic.removeItems", "epic.show", "epic.plan"]
        XCTAssertEqual(d.actions.all.filter { $0.id.hasPrefix("epic.") || $0.id == "item.setEpic" }.map(\.id).sorted(), ids.sorted())
        XCTAssertTrue(d.actions.supported(d).filter { ids.contains($0.id) }.isEmpty)
        d.caps = [.epics]
        XCTAssertEqual(d.actions.supported(d).filter { ids.contains($0.id) }.count, ids.count)
    }

    func testSetEpicByTitleAndNone() async throws {
        let rig = try await EpicRig()
        let key = rig.items[0].key
        let set = await rig.d.actions.run("item.setEpic", args(["key": .string(key), "epic": .string("review DESK")]))
        XCTAssertEqual(set, .ok(summary: "\(key) is in Review desk."))
        var snap = await rig.snapshot()
        XCTAssertEqual(snap?.epicId(of: rig.items[0].id), rig.epic.id)
        let none = await rig.d.actions.run("item.setEpic", args(["key": .string(key), "epic": .string("none")]))
        XCTAssertEqual(none, .ok(summary: "\(key) is in no epic."))
        snap = await rig.snapshot()
        XCTAssertNil(snap?.epicId(of: rig.items[0].id))
        let bad = await rig.d.actions.run("item.setEpic", args(["key": .string(key), "epic": .string("Nope")]))
        XCTAssertEqual(bad, .notAllowed("FAKE has no epic Nope. It has: Review desk."))
    }

    func testCloseEpicRefusesOpenItems() async throws {
        let rig = try await EpicRig()
        for i in rig.items.prefix(2) { try await rig.fake.setEpic(rig.epic.id, for: i) }
        await rig.reload()
        let close = args(["project": .string("FAKE"), "epic": .string(rig.epic.id.rawValue)])
        let refused = await rig.d.actions.run("epic.close", close)
        XCTAssertEqual(refused, .notAllowed("2 items are open."))
        for i in rig.items.prefix(2) { try await rig.fake.update(i, ItemPatch(status: "s-done")) }
        await rig.reload()
        let ok = await rig.d.actions.run("epic.close", close)
        XCTAssertEqual(ok, .ok(summary: "Epic Review desk is done."))
        let snap = await rig.snapshot()
        XCTAssertEqual(snap?.epic(rig.epic.id)?.state, .done)
    }

    func testCreateItemWithEpic() async throws {
        let rig = try await EpicRig()
        let r = await rig.d.actions.run("item.create", args(["project": .string("FAKE"), "title": .string("New one"), "epic": .string("Review desk")]))
        guard case .ok(let summary, let data, _) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(summary.hasSuffix(" in Review desk."), summary)
        let key = try XCTUnwrap(data?["key"]?.string)
        await until("the snapshot has the item") { await rig.snapshot()?.items.contains { $0.key == key } == true }
        let snap = await rig.snapshot()
        let made = try XCTUnwrap(snap?.items.first { $0.key == key })
        XCTAssertEqual(made.epicId, rig.epic.id)
        let bad = await rig.d.actions.run("item.create", args(["project": .string("FAKE"), "title": .string("Two"), "epic": .string("Nope")]))
        XCTAssertEqual(bad, .notAllowed("FAKE has no epic Nope. It has: Review desk."))
    }

    func testEpicListCreateUpdateAndAddItems() async throws {
        let rig = try await EpicRig()
        let make = await rig.d.actions.run("epic.create", args(["project": .string("FAKE"), "title": .string("Billing"), "targetDate": .string("2030-01-31")]))
        guard case .ok(_, let data, _) = make else { return XCTFail("\(make)") }
        let id = try XCTUnwrap(data?["id"]?.string)
        let bad = await rig.d.actions.run("epic.create", args(["project": .string("FAKE"), "title": .string("X"), "targetDate": .string("soon")]))
        XCTAssertEqual(bad, .notAllowed("targetDate must be a date as YYYY-MM-DD."))
        let upd = await rig.d.actions.run("epic.update", args(["project": .string("FAKE"), "epic": .string("Billing"), "state": .string("active"), "targetDate": .string("none")]))
        XCTAssertEqual(upd, .ok(summary: "Epic Billing is updated."))
        let snap = await rig.snapshot()
        XCTAssertEqual(snap?.epic(EpicID(rawValue: id))?.state, .active)
        XCTAssertNil(snap?.epic(EpicID(rawValue: id))?.targetDate)
        let none = await rig.d.actions.run("epic.update", args(["project": .string("FAKE"), "epic": .string("Billing")]))
        XCTAssertEqual(none, .notAllowed("Give a field to change."))
        let keys = rig.items.prefix(2).map { JSONValue.string($0.key) }
        let add = await rig.d.actions.run("epic.addItems", args(["project": .string("FAKE"), "epic": .string(id), "keys": .array(keys)]))
        XCTAssertEqual(add, .ok(summary: "2 items are in Billing."))
        let list = await rig.d.actions.run("epic.list", args(["project": .string("FAKE")]))
        guard case .ok(_, let rows?, _) = list else { return XCTFail("\(list)") }
        let billing = try XCTUnwrap(rows.array?.first { $0["title"]?.string == "Billing" })
        XCTAssertEqual(billing["progress"]?.string, "0 of 2 done")
        let missing = await rig.d.actions.run("epic.addItems", args(["project": .string("FAKE"), "epic": .string(id), "keys": .array([.string("FAKE-99")])]))
        XCTAssertEqual(missing, .notAllowed("FAKE has no loaded item FAKE-99."))
    }

    /// An epic made by `epic.create` is usable at once, while the refresh hangs (OVERSIRE-565).
    func testEpicCreateThenAddItemsWhileTheRefreshHangs() async throws {
        let rig = try await EpicRig()
        await MainActor.run { rig.d.projectStore.hold = true }
        let make = await rig.d.actions.run("epic.create", args(["project": .string("FAKE"), "title": .string("Billing")]))
        guard case .ok(_, let data, _) = make, let id = data?["id"]?.string else { return XCTFail("\(make)") }
        let keys = rig.items.prefix(2).map { JSONValue.string($0.key) }
        let add = await rig.d.actions.run("epic.addItems", args(["project": .string("FAKE"), "epic": .string(id), "keys": .array(keys)]))
        XCTAssertEqual(add, .ok(summary: "2 items are in Billing."))
        let list = await rig.d.actions.run("epic.list", args(["project": .string("FAKE")]))
        guard case .ok(_, let rows?, _) = list else { return XCTFail("\(list)") }
        let billing = try XCTUnwrap(rows.array?.first { $0["title"]?.string == "Billing" })
        XCTAssertEqual(billing["progress"]?.string, "0 of 2 done")
        let upd = await rig.d.actions.run("epic.update", args(["project": .string("FAKE"), "epic": .string("Billing"), "state": .string("active")]))
        XCTAssertEqual(upd, .ok(summary: "Epic Billing is updated."))
        _ = await rig.d.actions.run("epic.create", args(["project": .string("FAKE"), "title": .string("Spare")]))
        let close = await rig.d.actions.run("epic.close", args(["project": .string("FAKE"), "epic": .string("Spare")]))
        guard case .ok = close else { return XCTFail("\(close)") }
    }

    private func inEpic(_ rig: EpicRig, _ n: Int) async throws {
        for i in rig.items.prefix(n) { try await rig.fake.setEpic(rig.epic.id, for: i) }
        await rig.reload()
    }

    func testShowGivesSteps() async throws {
        let rig = try await EpicRig()
        try await inEpic(rig, 2)
        let r = await rig.d.actions.run("epic.show", args(["project": .string("FAKE"), "epic": .string("Review desk")]))
        guard case .ok(let summary, let data?, _) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(summary.hasPrefix("Review desk: 0 of 2 done."), summary)
        let steps = try XCTUnwrap(data["steps"]?.array)
        XCTAssertEqual(steps.compactMap { $0["key"]?.string }.sorted(), rig.items.prefix(2).map(\.key).sorted())
        XCTAssertEqual(steps.first?["number"], .int(1))
        XCTAssertNotNil(steps.first?["start"]?.string)
        XCTAssertEqual(data["members"]?.array?.count, 2)
        XCTAssertEqual(data["progress"]?["total"], .int(2))
        XCTAssertNotNil(data["next"]?.string)
        XCTAssertNotNil(data["forecast"]?["end"]?.string)
        let bad = await rig.d.actions.run("epic.show", args(["project": .string("FAKE"), "epic": .string("Nope")]))
        XCTAssertEqual(bad, .notAllowed("FAKE has no epic Nope. It has: Review desk."))
    }

    func testPlanReportsPartialRelations() async throws {
        let rig = try await EpicRig(items: 5)
        try await inEpic(rig, 5)
        await MainActor.run { for i in rig.items.prefix(2) { rig.d.projectStore.relations.prime(i.key, [], at: Date()) } }
        let r = await rig.d.actions.run("epic.plan", args(["project": .string("FAKE")]))
        guard case .ok(let summary, let data?, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(data["relations"]?["loaded"], .int(2))
        XCTAssertEqual(data["relations"]?["total"], .int(5))
        XCTAssertTrue(summary.contains("Relations 2 of 5 loaded"), summary)
        let epics = try XCTUnwrap(data["epics"]?.array)
        XCTAssertEqual(epics.count, 1)
        XCTAssertEqual(epics.first?["steps"]?.array?.count, 5)
        XCTAssertFalse(data["critical"]?.array?.isEmpty ?? true)
        let unknown = await rig.d.actions.run("epic.plan", args(["project": .string("NOPE")]))
        XCTAssertEqual(unknown, .notAllowed("OverSire has no loaded project NOPE."))
    }

    func testRemoveItemsSetsNoEpic() async throws {
        let rig = try await EpicRig()
        try await inEpic(rig, 2)
        let keys = rig.items.prefix(2).map { JSONValue.string($0.key) }
        let cli = ActionArgs(.object(["project": .string("FAKE"), "keys": .array(keys)]), caller: .cli(agent: "codex"))
        let r = await rig.d.actions.run("epic.removeItems", cli)
        XCTAssertEqual(r, .ok(summary: "2 items are in no epic."))
        let snap = await rig.snapshot()
        for i in rig.items.prefix(2) { XCTAssertNil(snap?.epicId(of: i.id)) }
        let rows = await rig.rows(count: 5).filter { $0.kind == .epicItemRemoved }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(Set(rows.map(\.actorType)), [.agent])
        XCTAssertEqual(Set(rows.map(\.actor)), ["codex"])
        let missing = await rig.d.actions.run("epic.removeItems", args(["project": .string("FAKE"), "keys": .array([.string("FAKE-99")])]))
        XCTAssertEqual(missing, .notAllowed("FAKE has no loaded item FAKE-99."))
    }

    func testUpdateEpicWritesTheAgent() async throws {
        let rig = try await EpicRig()
        let cli = ActionArgs(.object(["project": .string("FAKE"), "epic": .string("Review desk"), "state": .string("active")]), caller: .cli(agent: "codex"))
        let r = await rig.d.actions.run("epic.update", cli)
        XCTAssertEqual(r, .ok(summary: "Epic Review desk is updated."))
        let rows = await rig.rows(count: 2).filter { $0.kind == .epicUpdated }
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.actorType, .agent)
        XCTAssertEqual(rows.first?.actor, "codex")
        XCTAssertEqual(rows.first?.payload?["fields"], .array([.string("state")]))
        XCTAssertEqual(rows.first?.item, rig.epic.eventKey)
    }

    /// The run.* writes go through CIOps, so the agent rights and the de-dup hold for them.
    @MainActor
    func testRunActionsUseCIOps() async {
        let rig = CIOpsTests.Rig()
        rig.rights.set(AgentCIRights(cancel: false, approve: false))
        rig.fake.put(FakeCI.run(id: "1", status: "in_progress", conclusion: nil, attempt: 1))
        let catalog = AppActionCatalog(data: TestAppData(), ci: rig.ops)
        let args = ActionArgs(.object(["repo": .string("fake/app"), "runId": .string("1")]), caller: .cli(agent: "codex"))
        let r = await catalog.run("run.cancel", args)
        guard case .notAllowed = r else { return XCTFail("\(r)") }
        XCTAssertEqual(rig.fake.vendorCalls, 0)
        rig.rights.set(AgentCIRights(cancel: true, approve: false))
        let ok = await catalog.run("run.cancel", args)
        guard case .ok = ok else { return XCTFail("\(ok)") }
        XCTAssertEqual(rig.fake.vendorCalls, 1)
        let rows = await rig.rows(count: 1)
        XCTAssertEqual(rows.first?.kind, .ciCancelled)
        XCTAssertEqual(rows.first?.actor, "codex")
    }

    /// All alerts go through AlertConfirm.
    func testNoAlertOutsideTheHelper() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/OverSireApp").standardized
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") && $0 != "alert_confirm.swift" }
        XCTAssertFalse(files.isEmpty)
        let hits = try files.filter { try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8).contains("NSAlert(") }
        XCTAssertEqual(hits, [])
    }

    /// Pages run domain changes through the catalog. A UI-only button (copy, open, a form field) keeps its closure.
    func testPagesDoNotCallDomainMutators() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/OverSireApp").standardized
        let pages = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter {
            ["_page.swift", "_window.swift", "_tab.swift"].contains(where: $0.hasSuffix) || ["needs_you.swift", "glance.swift", "review_desk.swift"].contains($0)
        }
        XCTAssertGreaterThan(pages.count, 10)
        let mutator = try NSRegularExpression(pattern: #"""
            (projectStore|store)\.(setStatus|assignMe|comment|start|reopen|closeSubItems|triage|relate|setEpic|createEpic|updateEpic|edit|create)\(|tracker\??\.(move|post)\(|\
            (projectStore|store)\.update\(itemId|queue\.(add|remove|move|start)\(|agentIndex\.(send|reveal|start)\(|\
            statusJob\.(approve|hold|markBlocked|snooze)\(|job\.(approve|hold|markBlocked|snooze)\(|questions\.(answer|dismiss)\(|\
            cleaner\.run\(|REPO_CLIENT\.(perform|rerunJob)\(|ciOps\.(rerun|rerunJob|cancel|dispatch|approve)\(|suggestions\.(accept|dismiss)\(
            """#)
        var hits: [String] = []
        for f in pages {
            let lines = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated() {
                if mutator.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil { hits.append("\(f):\(i + 1): \(l.trimmingCharacters(in: .whitespaces))") }
            }
        }
        XCTAssertEqual(hits, [], hits.joined(separator: "\n"))
    }

    // OVERSIRE-528
    func testClientForwardsChange() async {
        final class Seen: @unchecked Sendable { var calls: [MemberCallRequest] = [] }
        let d = seeded()
        let seen = Seen()
        d.actions.forward = { r in
            seen.calls.append(r)
            return AppCallResult(id: "m-1", status: .ok, summary: "SLING-1 is Done.")
        }
        d.actions.sourceName = { "mbp" }
        let r = await d.actions.run("item.setStatus", ActionArgs(.object(["key": .string("SLING-1"), "status": .string("Done")])))
        XCTAssertEqual(r, .ok(summary: "SLING-1 is Done."))
        XCTAssertEqual(seen.calls.map(\.action), ["item.setStatus"])
        XCTAssertEqual(seen.calls.first?.args["key"], .string("SLING-1"))
        XCTAssertEqual(d.projectStore.snapshots.values.first?.items.first?.statusOptionId, "s1", "the client changes nothing")
        XCTAssertEqual(d.actions.sentText("item.setStatus"), "Sent to mbp…")
    }

    func testClientKeepsLocalAction() async {
        final class Seen: @unchecked Sendable { var n = 0 }
        let d = seeded()
        let seen = Seen()
        d.actions.forward = { _ in seen.n += 1; return AppCallResult(id: "m", status: .ok, summary: "") }
        for id in ["page.current", "machine.list", "item.get"] {
            _ = await d.actions.run(id, ActionArgs(.object(["key": .string("SLING-1")])))
            XCTAssertNil(d.actions.sentText(id), id)
        }
        XCTAssertEqual(seen.n, 0)
    }

    func testClientMapsErrors() async {
        let d = seeded()
        d.actions.sourceName = { "mbp" }
        let args = ActionArgs(.object(["key": .string("SLING-1"), "body": .string("x")]))
        d.actions.forward = { _ in throw ProviderError.vendor(code: "503", message: "The OverSire app on mbp is not open.") }
        let a = await d.actions.run("item.comment", args)
        XCTAssertEqual(a, .failed("The OverSire app on mbp is not open."))
        d.actions.forward = { _ in throw ProviderError.transport("The Internet connection appears to be offline.") }
        let b = await d.actions.run("item.comment", args)
        XCTAssertEqual(b, .failed("mbp is offline. Try again when it is back."))
        d.actions.forward = { _ in AppCallResult(id: "m", status: .notAllowed, summary: "No.") }
        let c = await d.actions.run("item.comment", args)
        XCTAssertEqual(c, .notAllowed("No."))
    }

    // OVERSIRE-534
    func testClientMapsAnOldHomeRefusal() async throws {
        let d = seeded()
        d.actions.sourceName = { "mbp" }
        let update = "Update OverSire on mbp to use this."
        d.actions.forward = { _ in AppCallResult(id: "m", status: .notAllowed, summary: "No action intake.create.") }
        let a = await d.actions.run("item.comment", ActionArgs(.object([:])))
        XCTAssertEqual(a, .notAllowed(update))
        d.actions.forward = { _ in AppCallResult(id: "m", status: .notAllowed, summary: "mirror.read has no read projectSettings.") }
        let b = await d.actions.run("mirror.read", ActionArgs(.object(["what": .string("projectSettings")])))
        XCTAssertEqual(b, .notAllowed(update))
        do {
            _ = try await d.actions.read(["what": .string("projectSettings")])
            XCTFail("a read of an old home must fail")
        } catch let e as ProviderError {
            XCTAssertEqual(e.message, update)
        }
        d.actions.forward = { _ in AppCallResult(id: "m", status: .notAllowed, summary: "The project is not loaded.") }
        let c = await d.actions.run("item.comment", ActionArgs(.object([:])))
        XCTAssertEqual(c, .notAllowed("The project is not loaded."))
    }

    // OVERSIRE-536
    func testItemCreateGivesIdAndURL() async throws {
        let rig = try await EpicRig(items: 0, epics: [])
        let r = await rig.d.actions.run("item.create", ActionArgs(.object(["project": .string("FAKE"), "title": .string("Made")])))
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        let items = try await rig.fake.items(rig.fake.project, since: nil, limit: 10)
        XCTAssertEqual(data["key"]?.string, items.first?.key)
        XCTAssertEqual(data["id"]?.string, items.first?.id)
        XCTAssertEqual(data["url"]?.string, items.first?.url)
    }

    /// The new item sheet makes items through the catalog. A direct `store.create(` fails on a client.
    func testSheetsDoNotCreateItemsDirectly() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/OverSireApp").standardized
        let sheets = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix("_sheet.swift") }
        XCTAssertFalse(sheets.isEmpty)
        // A sheet reads people through people.list, so a client gets the people of the home.
        let hits = try sheets.filter {
            let text = try String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8)
            return text.contains("tore.create(") || text.contains(".people.details(for:")
        }
        XCTAssertEqual(hits, [])
    }

    /// A client path reads a tracker through the home.
    func testClientPathsDoNotReadTheTrackerDirectly() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Sources/OverSireApp").standardized
        // The home runs these, or they hold the home branch.
        let home: Set<String> = ["project_store.swift", "project_catalog.swift", "mirror_docs.swift", "main.swift", "AppEnvironment.swift", "plane_writeback.swift"]
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter {
            $0.hasSuffix(".swift") && !$0.hasPrefix("actions_") && !home.contains($0)
        }
        XCTAssertGreaterThan(files.count, 50)
        let direct = try NSRegularExpression(pattern: #"(ENV|trackers)\.tracker\(|[sS]tore\??\.tracker\(of:"#)
        var hits: [String] = []
        for f in files {
            let lines = try String(contentsOf: dir.appendingPathComponent(f), encoding: .utf8).components(separatedBy: "\n")
            for (i, l) in lines.enumerated() where direct.firstMatch(in: l, range: NSRange(l.startIndex..., in: l)) != nil {
                hits.append("\(f):\(i + 1): \(l.trimmingCharacters(in: .whitespaces))")
            }
        }
        XCTAssertEqual(hits, [], hits.joined(separator: "\n"))
    }

    // OVERSIRE-530
    func testOfflineRefusesChange() async {
        final class Seen: @unchecked Sendable { var n = 0 }
        let d = seeded()
        let seen = Seen()
        d.actions.forward = { _ in seen.n += 1; return AppCallResult(id: "m", status: .ok, summary: "") }
        d.actions.sourceName = { "mbp" }
        let offline = ClientLink.homeOffline(home: "mbp", since: Date(), data: Date())
        d.actions.linkState = { offline }
        let args = ActionArgs(.object(["key": .string("SLING-1"), "status": .string("Done")]))
        let r = await d.actions.run("item.setStatus", args)
        XCTAssertEqual(r, .notAllowed("mbp is offline. Try again when it is back."))
        XCTAssertEqual(seen.n, 0, "an offline client sends nothing")
        XCTAssertFalse(d.actions.available("item.setStatus"))
        for spec in d.actions.all where d.actions.forwards(spec.id) {
            XCTAssertEqual(d.actions.available(spec.id), spec.kind == .read, spec.id)
        }
        d.actions.linkState = { .appClosed(home: "mbp", data: nil) }
        XCTAssertEqual(d.actions.refusal("item.setStatus"), "The OverSire app on mbp is not open.")
        d.actions.linkState = { .live(updated: Date(), items: 1, repos: 1) }
        XCTAssertTrue(d.actions.available("item.setStatus"))
    }

    func testOfflineAllowsLocal() async {
        let d = seeded()
        d.actions.forward = { _ in AppCallResult(id: "m", status: .ok, summary: "") }
        d.actions.linkState = { .homeOffline(home: "mbp", since: Date(), data: nil) }
        for id in MemberCalls.local where d.actions.spec(id) != nil {
            XCTAssertTrue(d.actions.available(id), id)
        }
        XCTAssertTrue(d.actions.available("item.get"), "a read stays on")
        XCTAssertTrue(d.actions.available("machine.mode"), "a client can switch back to Full")
    }

    func testFullModeRunsHere() async {
        let d = seeded()
        XCTAssertNil(d.actions.sentText("item.setStatus"))
        XCTAssertFalse(d.actions.forwards("item.setStatus"))
    }

    // OVERSIRE-524
    func testMachineModeIsASettingsAction() {
        let spec = TestAppData().actions.all.first { $0.id == "machine.mode" }
        XCTAssertEqual(spec?.kind, .settings)
    }

    func testMachineModeWritesEvent() async {
        actor Outlet: EventOutlet {
            var rows: [EventDraft] = []
            func append(_ drafts: [EventDraft]) async { rows += drafts }
            func link(_ l: [ItemLink]) async {}
        }
        final class Calls: @unchecked Sendable {
            var written: [AppMode] = []
            var relaunches = 0
        }
        let outlet = Outlet(), calls = Calls()
        let desk = EventDesk(outlet: outlet)
        desk.machine = { "mba" }
        let mode = MachinesModel.Mode(mode: .full, home: "mbp", enabled: true, reason: nil, holderIsSelf: false, holder: "mbp", keptAccounts: 2)
        var sw = ModeSwitch(state: { mode }, write: { calls.written.append($0) }, desk: { desk }, relaunch: { calls.relaunches += 1 }, settle: {})
        let client = ActionArgs(.object(["mode": .string("client")]))

        let agent = await sw.run(ActionArgs(.object(["mode": .string("client")]), caller: .assistant(thread: "t")))
        guard case .notAllowed = agent else { return XCTFail("\(agent)") }
        let same = await sw.run(ActionArgs(.object(["mode": .string("full")])))
        XCTAssertEqual(same.summary, "This Mac is in full mode already.")
        XCTAssertTrue(calls.written.isEmpty)

        let done = await sw.run(client)
        guard case .ok = done else { return XCTFail("\(done)") }
        XCTAssertEqual(calls.written, [.client])
        XCTAssertEqual(calls.relaunches, 1)
        for _ in 0..<200 where await outlet.rows.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        let rows = await outlet.rows
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.kind, .appModeChanged)
        XCTAssertEqual(rows.first?.payload?["mode"], .string("client"))
        XCTAssertEqual(rows.first?.payload?["home"], .string("mbp"))

        let off = MachinesModel.Mode(mode: .full, home: nil, enabled: false, reason: "Join a group to use client mode.", holderIsSelf: false, holder: nil, keptAccounts: 0)
        sw.state = { off }
        let blocked = await sw.run(client)
        XCTAssertEqual(blocked, .notAllowed("Join a group to use client mode."))
        XCTAssertEqual(calls.written, [.client], "a disabled switch writes nothing")

        let back = MachinesModel.Mode(mode: .client, home: "mbp", enabled: false, reason: "x", holderIsSelf: false, holder: nil, keptAccounts: 2)
        sw.state = { back }
        let full = await sw.run(ActionArgs(.object(["mode": .string("full")])))
        guard case .ok = full else { return XCTFail("\(full)") }
        XCTAssertEqual(calls.written, [.client, .full], "a client can always go back to Full")
    }
}
