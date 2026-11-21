import OverSireAI
import OverSireAssistant
import OverSireCore
import OverSireTestKit
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

    // OVERSIRE-536
    func testIntakeCreateGivesTheIntakeItem() async throws {
        let rig = try await EpicRig(items: 0, epics: [])
        let r = await rig.d.actions.run("intake.create", ActionArgs(.object(["project": .string("FAKE"), "title": .string("Ask"), "body": .string("Why?")])))
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        XCTAssertNotNil(data["key"]?.string)
        XCTAssertNotNil(data["id"]?.string)
        XCTAssertNotNil(data["url"]?.string)
        let intake = try MirrorCodec.value(IntakeItem.self, from: try XCTUnwrap(data["intake"]))
        XCTAssertEqual(intake.name, "Ask")
        let pending = try await rig.fake.intake(rig.fake.project)
        XCTAssertEqual(pending.map(\.id), [intake.id])
        let none = await rig.d.actions.run("intake.create", ActionArgs(.object(["project": .string("NOPE"), "title": .string("x")])))
        XCTAssertEqual(none, .notAllowed("OverSire has no loaded project NOPE."))
    }

    // OVERSIRE-536
    func testAttachToAnItemThatIsNotLoaded() async throws {
        let rig = try await EpicRig(items: 0, epics: [])
        let made = try await rig.fake.createIntake(ItemDraft(title: "New"), in: rig.fake.project)
        XCTAssertNil(rig.d.projectStore.item(key: made.item.key), "the poll has not loaded it")
        let args: [String: JSONValue] = ["key": .string(made.item.key), "project": .string("FAKE"), "id": .string(made.item.id), "url": .string(made.item.url.absoluteString),
                                         "name": .string("a.png"), "mimeType": .string("image/png"), "data": .string(Data("png".utf8).base64EncodedString())]
        let caller = ActionCaller.member(machine: "mba", name: "Fritz")
        let r = await rig.d.actions.run("item.attach", ActionArgs(.object(args), caller: caller))
        guard case .ok = r else { return XCTFail("\(r)") }
        XCTAssertEqual(rig.fake.uploads.map(\.file.name), ["a.png"])
        XCTAssertEqual(rig.fake.uploads.first?.item.id, made.item.id)
        let row = await rig.row(.itemAttachmentAdded)
        XCTAssertEqual(row?.item, made.item.key)
        XCTAssertEqual(row?.via, "app@mba")
        var bare = args
        bare["project"] = nil
        bare["id"] = nil
        let none = await rig.d.actions.run("item.attach", ActionArgs(.object(bare)))
        XCTAssertEqual(none, .notAllowed("OverSire has no loaded item \(made.item.key.uppercased())."))
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

    /// A fake that also has intake numbers and asset links.
    private final class AssetFake: Tracker, IntakeKeying, AssetLinking, @unchecked Sendable {
        let fake = FakeTracker()
        var id: ProviderID { fake.id }
        var account: AccountID { fake.account }
        var capabilities: Set<Capability> { fake.capabilities }
        var pollPolicy: PollPolicy { fake.pollPolicy }
        var keyFormat: KeyFormat { fake.keyFormat }

        func probe() async throws -> Identity { try await fake.probe() }
        func poll(since: Cursor?) async throws -> EventPage { try await fake.poll(since: since) }
        func projects() async throws -> [ProjectSummary] { try await fake.projects() }
        func statuses(_ p: ProjectRef) async throws -> [StatusOption] { try await fake.statuses(p) }
        func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item] { try await fake.items(p, since: since, limit: limit) }
        func detail(_ i: ItemRef) async throws -> ItemDetail { try await fake.detail(i) }
        func comments(_ i: ItemRef) async throws -> [Comment] { try await fake.comments(i) }
        func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef { try await fake.create(d, in: p) }
        func update(_ i: ItemRef, _ patch: ItemPatch) async throws { try await fake.update(i, patch) }
        func comment(_ i: ItemRef, markdown: String) async throws { try await fake.comment(i, markdown: markdown) }
        func intakeSequences(_ p: ProjectRef) async throws -> [String: Int] { ["wi-1": 12] }
        func assetURL(_ id: String) async throws -> URL { URL(string: "https://files.example/\(id)?sig=1")! }
        func assetIds(in markdown: String) -> Set<String> { markdown.contains("](asset-1)") ? ["asset-1"] : [] }
    }

    private final class AssetTrackers: TrackerDirectory {
        let t: AssetFake
        init(_ t: AssetFake) { self.t = t }
        var trackerIds: [String] { [t.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == t.account.id ? t : nil }
    }

    private func assetRig() async throws -> (TestAppData, String) {
        let t = AssetFake()
        let summary = try await t.projects()[0]
        let d = await MainActor.run { TestAppData(trackers: AssetTrackers(t)) }
        await MainActor.run { d.projectStore.track([summary], live: []) }
        let seen = await Wait.until { await MainActor.run { d.projectStore.snapshot("FAKE") != nil } }
        XCTAssertTrue(seen, "timeout: the first snapshot")
        return (d, summary.ref.storeKey)
    }

    private func read(_ d: TestAppData, _ args: [String: JSONValue]) async -> ActionResult {
        await d.actions.run("mirror.read", ActionArgs(.object(args)))
    }

    // OVERSIRE-535
    func testMirrorReadGivesProjectSettings() async throws {
        let rig = try await EpicRig()
        let r = await read(rig.d, ["what": .string("projectSettings"), "project": .string("FAKE")])
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        let got = try MirrorCodec.value(MirrorRows<ProjectSettingsRead>.self, from: data).rows
        XCTAssertEqual(got.settings.name, "Fake project")
        XCTAssertTrue(got.editable.contains(.features))
        let none = await read(rig.d, ["what": .string("projectSettings"), "project": .string("NOPE")])
        XCTAssertEqual(none, .notAllowed("OverSire has no loaded project NOPE."))
    }

    func testMirrorReadGivesAttachmentsAndLink() async throws {
        let rig = try await EpicRig()
        let item = rig.items[0]
        _ = try await rig.fake.attach(AttachmentUpload(name: "a.png", mimeType: "image/png", data: Data([1])), to: item)
        let ref = try MirrorCodec.body(item)
        let r = await read(rig.d, ["what": .string("attachments"), "ref": ref])
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        let rows = try MirrorCodec.value(MirrorRows<[ItemAttachment]>.self, from: data).rows
        XCTAssertEqual(rows.map(\.name), ["a.png"])
        let l = await read(rig.d, ["what": .string("attachmentLink"), "ref": ref, "attachment": try MirrorCodec.body(rows[0])])
        guard case .ok(_, let linkData?, _) = l else { return XCTFail("\(l)") }
        let expected = try await rig.fake.attachmentURL(rows[0], of: item).absoluteString
        XCTAssertEqual(try MirrorCodec.value(MirrorRows<String>.self, from: linkData).rows, expected)
        let other = ItemRef(project: ProjectRef(workspace: "other", id: "x"), id: "i", key: "X-1", url: item.url)
        let bad = await read(rig.d, ["what": .string("attachments"), "ref": try MirrorCodec.body(other)])
        guard case .notAllowed = bad else { return XCTFail("\(bad)") }
    }

    func testMirrorReadGivesIntakeKeys() async throws {
        let (d, key) = try await assetRig()
        let r = await read(d, ["what": .string("intakeKeys"), "project": .string(key)])
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(try MirrorCodec.value(MirrorRows<[String: Int]>.self, from: data).rows, ["wi-1": 12])
    }

    func testMirrorReadResolvesImages() async throws {
        let (d, key) = try await assetRig()
        let r = await read(d, ["what": .string("images"), "project": .string(key), "markdown": .string("![a](asset-1)")])
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(try MirrorCodec.value(MirrorRows<String>.self, from: data).rows, "![a](https://files.example/asset-1?sig=1)")
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

    // OVERSIRE-537
    private func apply(_ rig: EpicRig, _ id: String, _ args: [String: JSONValue], as caller: ActionCaller = .member(machine: "mba", name: "Fritz")) async -> ActionResult {
        await rig.d.actions.run(id, ActionArgs(.object(args), caller: caller))
    }

    func testIntakeEditWithPatchAndRelations() async throws {
        let rig = try await EpicRig()
        let made = try await rig.fake.createIntake(ItemDraft(title: "Idea"), in: rig.fake.project)
        await rig.reload()
        let relation = ItemRelation(kind: .blocks, item: rig.items[0])
        let patch = try MirrorCodec.body(ItemPatch(title: "Better", labels: ["l-bug"]))
        let r = await apply(rig, "intake.edit", ["project": .string("FAKE"), "id": .string(made.intake.id), "patch": patch,
                                                 "relations": try JSONValue.encoded([relation])])
        guard case .ok = r else { return XCTFail("\(r)") }
        let edit = try XCTUnwrap(rig.fake.intakeEdits.first)
        XCTAssertEqual(rig.fake.intakeEdits.count, 1)
        XCTAssertEqual(edit.patch.title, "Better")
        XCTAssertEqual(edit.patch.labels, ["l-bug"])
        XCTAssertEqual(edit.relations, [relation])
    }

    func testItemUpdateWithPatch() async throws {
        let rig = try await EpicRig()
        let item = rig.items[0]
        let patch = try MirrorCodec.body(ItemPatch(priority: "high", labels: ["l-bug"]))
        let r = await apply(rig, "item.update", ["key": .string(item.key), "patch": patch])
        guard case .ok = r else { return XCTFail("\(r)") }
        let got = try await rig.fake.detail(item).item
        XCTAssertEqual(got.labels, ["l-bug"])
        let other = rig.items[1]
        let relation = ItemRelation(kind: .blocks, item: other)
        let both = await apply(rig, "item.update", ["key": .string(item.key), "relations": try JSONValue.encoded([relation])])
        guard case .ok = both else { return XCTFail("\(both)") }
        let kinds = try await rig.fake.relations(of: item).map(\.kind)
        XCTAssertEqual(kinds, [.blocks])
        let none = await apply(rig, "item.update", ["key": .string(item.key)])
        XCTAssertEqual(none, .notAllowed("Give a title, a parent, a patch or relations."))
    }

    func testAddLabelWritesTheEvent() async throws {
        let rig = try await EpicRig()
        let r = await apply(rig, "project.addLabel", ["project": .string("FAKE"), "name": .string("groomed"), "color": .string("#3B82F6")])
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        let id = try XCTUnwrap(data["id"]?.string)
        let labels = try await rig.fake.settings(rig.fake.project).labels
        XCTAssertTrue(labels.contains { $0.id == id && $0.name == "groomed" })
        let row = await rig.row(.projectSettingsChanged)
        XCTAssertEqual(row?.payload?["label"], .string("groomed"))
        XCTAssertEqual(row?.via, "app@mba")
        let bad = await apply(rig, "project.addLabel", ["project": .string("FAKE"), "name": .string(" "), "color": .string("#fff")])
        XCTAssertEqual(bad, .notAllowed("Give a name."))
    }

    func testGroomApplyWritesGroomAppliedRows() async throws {
        let rig = try await EpicRig()
        let lines = [GroomResult.Proposal(kind: .done, keys: [rig.items[0].key], reason: "Shipped."),
                     GroomResult.Proposal(kind: .done, keys: [rig.items[1].key], reason: "Also shipped.")]
        let r = await apply(rig, "groom.apply", ["project": .string("FAKE"), "lines": try JSONValue.encoded(lines)])
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        let out = try MirrorCodec.value(GroomOutcome.self, from: try XCTUnwrap(data["outcome"]))
        XCTAssertEqual(out.written, lines.map(\.id))
        XCTAssertEqual(data["undoable"], .bool(true))
        let status = try await rig.fake.detail(rig.items[0]).item.statusOptionId
        XCTAssertEqual(status, "s-done")
        _ = await rig.rows(count: 3)
        let rows = await rig.outlet.rows.filter { $0.kind == .groomApplied }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.map(\.item), rig.items.prefix(2).map(\.key))
        XCTAssertEqual(Set(rows.map(\.via)), ["app@mba"])
        XCTAssertEqual(Set(rows.map(\.actorType)), [.agent])
        let journal = await rig.d.groomAgent.journal.last(rig.fake.project.storeKey)
        XCTAssertNotNil(journal)
        let none = await apply(rig, "groom.apply", ["project": .string("NOPE"), "lines": .array([])])
        XCTAssertEqual(none, .notAllowed("OverSire has no loaded project NOPE."))
    }

    func testGroomUndoWritesGroomUndone() async throws {
        let rig = try await EpicRig()
        let none = await apply(rig, "groom.undo", ["project": .string("FAKE")])
        XCTAssertEqual(none, .notAllowed("No Groom to undo in FAKE."))
        let line = GroomResult.Proposal(kind: .done, keys: [rig.items[0].key], reason: "Shipped.")
        _ = await apply(rig, "groom.apply", ["project": .string("FAKE"), "lines": try JSONValue.encoded([line])])
        let r = await apply(rig, "groom.undo", ["project": .string("FAKE")])
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        let out = try MirrorCodec.value(GroomJournal.UndoOutcome.self, from: data)
        XCTAssertEqual(out.undone.count, 1)
        let status = try await rig.fake.detail(rig.items[0]).item.statusOptionId
        XCTAssertNotEqual(status, "s-done")
        let row = await rig.row(.groomUndone)
        XCTAssertEqual(row?.via, "app@mba")
        XCTAssertEqual(row?.payload?["undone"], .int(1))
    }

    func testMirrorReadGivesIntakeDetailsAndGroomChanged() async throws {
        let rig = try await EpicRig()
        let made = try await rig.fake.createIntake(ItemDraft(title: "Idea", bodyMarkdown: "Text."), in: rig.fake.project)
        await rig.reload()
        let r = await read(rig.d, ["what": .string("intakeDetails"), "project": .string("FAKE"), "intakeItems": try JSONValue.encoded([made.intake])])
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        let rows = try MirrorCodec.value(MirrorRows<[String: IntakeDetail]>.self, from: data).rows
        XCTAssertEqual(rows[made.intake.workItemId]?.body, "Text.")
        let c = await read(rig.d, ["what": .string("groomChanged"), "project": .string("FAKE")])
        guard case .ok(_, let changed?, _) = c else { return XCTFail("\(c)") }
        XCTAssertEqual(try MirrorCodec.value(MirrorRows<[String]>.self, from: changed).rows, [])
        let bad = await read(rig.d, ["what": .string("groomChanged"), "project": .string("NOPE")])
        XCTAssertEqual(bad, .notAllowed("OverSire has no loaded project NOPE."))
    }
}
