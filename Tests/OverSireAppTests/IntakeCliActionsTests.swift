import OverSireAssistant
import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

extension FakeTracker: IntakeStatusListing, IntakeKeying {}

/// The intake actions that the `oversire` CLI runs through app calls.
final class IntakeCliActionsTests: XCTestCase {
    /// A rig with two pending intake items. Their work items are FAKE-1 and FAKE-2.
    func makeRig(capabilities: Set<Capability>? = nil) async throws -> (rig: EpicRig, intake: [IntakeItem]) {
        let rig = try await EpicRig(items: 0, epics: [], tracking: false, capabilities: capabilities)
        var made: [IntakeItem] = []
        for t in ["Add export", "Fix login"] { made.append(try await rig.fake.createIntake(ItemDraft(title: t), in: rig.fake.project).intake) }
        try await rig.track()
        return (rig, made)
    }

    func run(_ rig: EpicRig, _ id: String, _ args: [String: JSONValue], caller: ActionCaller = .cli(agent: "codex s1")) async -> ActionResult {
        await rig.d.actions.run(id, ActionArgs(.object(args), caller: caller))
    }

    func rows(_ r: ActionResult) -> [JSONValue] {
        guard case .ok(_, let data, _) = r, case .array(let items)? = data?["items"] else { return [] }
        return items
    }

    func assertNotAllowed(_ r: ActionResult, _ text: String, file: StaticString = #filePath, line: UInt = #line) {
        guard case .notAllowed(let m) = r else { return XCTFail("not a refusal: \(r)", file: file, line: line) }
        XCTAssertTrue(m.contains(text), m, file: file, line: line)
    }

    // MARK: List

    func testIntakeListPendingWithKeys() async throws {
        let (rig, made) = try await makeRig()
        let r = await run(rig, "intake.list", ["project": .string("FAKE")])
        let list = rows(r)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.compactMap { $0["key"]?.string }, ["FAKE-1", "FAKE-2"])
        XCTAssertEqual(list.first?["id"]?.string, made[0].id)
        XCTAssertEqual(list.first?["workItemId"]?.string, made[0].workItemId)
        XCTAssertEqual(list.first?["status"]?.string, "pending")
        XCTAssertEqual(list.first?["title"]?.string, "Add export")
        XCTAssertEqual(r.summary, "2 intake items.")
    }

    func testIntakeListSnoozedReadsTheTracker() async throws {
        let (rig, made) = try await makeRig()
        try await rig.fake.triage(made[0], in: rig.fake.project, .snooze(until: Date().addingTimeInterval(86400)))
        await rig.reload()
        let snoozed = rows(await run(rig, "intake.list", ["project": .string("FAKE"), "status": .string("snoozed")]))
        XCTAssertEqual(snoozed.count, 1)
        XCTAssertEqual(snoozed.first?["key"]?.string, "FAKE-1")
        XCTAssertEqual(snoozed.first?["status"]?.string, "snoozed")
        XCTAssertNotNil(snoozed.first?["snoozedUntil"]?.string)
        let pending = rows(await run(rig, "intake.list", ["project": .string("FAKE")]))
        XCTAssertEqual(pending.compactMap { $0["title"]?.string }, ["Fix login"])
    }

    func testIntakeListAllIsPendingAndSnoozed() async throws {
        let (rig, made) = try await makeRig()
        try await rig.fake.triage(made[0], in: rig.fake.project, .snooze(until: Date().addingTimeInterval(86400)))
        let r = await run(rig, "intake.list", ["status": .string("all")])
        XCTAssertEqual(rows(r).compactMap { $0["status"]?.string }.sorted(), ["pending", "snoozed"])
        guard case .ok(_, let data, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(data?["total"], .int(2))
        let limited = await run(rig, "intake.list", ["status": .string("all"), "limit": .int(1)])
        XCTAssertEqual(rows(limited).count, 1)
    }

    func testIntakeListBadStatus() async throws {
        let (rig, _) = try await makeRig()
        assertNotAllowed(await run(rig, "intake.list", ["status": .string("done")]), "No intake status done. Use: pending, snoozed or all.")
    }

    func testIntakeListDetailHasBodyAndLabels() async throws {
        let (rig, _) = try await makeRig()
        let r = await run(rig, "intake.list", ["project": .string("FAKE"), "id": .string("FAKE-2"), "detail": .bool(true)])
        let list = rows(r)
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?["title"]?.string, "Fix login")
        XCTAssertNotNil(list.first?["body"]?.string)
        XCTAssertNotNil(list.first?["labels"])
        let none = await run(rig, "intake.list", ["project": .string("FAKE"), "id": .string("FAKE-9")])
        assertNotAllowed(none, "No intake item FAKE-9 in FAKE.")
    }

    func testIntakeHasNoIntakeOnATrackerWithoutIt() async throws {
        let rig = try await EpicRig(capabilities: [.epics])
        assertNotAllowed(await run(rig, "intake.list", ["project": .string("FAKE")]), "has no intake.")
        assertNotAllowed(await run(rig, "intake.list", [:]), "has no intake.")
        assertNotAllowed(await run(rig, "intake.accept", ["project": .string("FAKE"), "id": .string("FAKE-1")]), "has no intake.")
    }

    // MARK: Triage

    func testTriageByKey() async throws {
        let (rig, made) = try await makeRig()
        let r = await run(rig, "intake.accept", ["project": .string("FAKE"), "id": .string("FAKE-2")])
        guard case .ok = r else { return XCTFail("\(r)") }
        XCTAssertEqual(rig.fake.triages.map(\.intake), [made[1].id])
        XCTAssertEqual(rig.fake.triages.map(\.action), [.accept])
    }

    func testTriageByIntakeIdStillWorks() async throws {
        let (rig, made) = try await makeRig()
        let byId = await run(rig, "intake.decline", ["project": .string("FAKE"), "id": .string(made[0].id)])
        guard case .ok = byId else { return XCTFail("\(byId)") }
        let byWork = await run(rig, "intake.accept", ["project": .string("FAKE"), "id": .string(made[1].workItemId)])
        guard case .ok = byWork else { return XCTFail("\(byWork)") }
        XCTAssertEqual(rig.fake.triages.map(\.action), [.decline, .accept])
        assertNotAllowed(await run(rig, "intake.accept", ["project": .string("FAKE"), "id": .string("zzz")]), "No intake item zzz in FAKE.")
    }

    func testTriageSnoozedItemByKey() async throws {
        let (rig, made) = try await makeRig()
        try await rig.fake.triage(made[0], in: rig.fake.project, .snooze(until: Date().addingTimeInterval(86400)))
        await rig.reload()
        let r = await run(rig, "intake.accept", ["project": .string("FAKE"), "id": .string("FAKE-1")])
        guard case .ok = r else { return XCTFail("\(r)") }
        XCTAssertEqual(rig.fake.triages.last?.intake, made[0].id)
        XCTAssertEqual(rig.fake.triages.last?.action, .accept)
    }

    func testCommentGoesOnTheWorkItemBeforeTheTriage() async throws {
        let (rig, made) = try await makeRig()
        let ok = await run(rig, "intake.accept", ["project": .string("FAKE"), "id": .string("FAKE-1"), "comment": .string("Out of scope.")])
        guard case .ok = ok else { return XCTFail("\(ok)") }
        let comments = try await rig.fake.comments(ItemRef(project: rig.fake.project, id: made[0].workItemId, key: "FAKE-1", url: URL(string: "https://tracker.fake/FAKE-1")!))
        XCTAssertEqual(comments.map(\.body), ["Out of scope."])
        XCTAssertEqual(rig.fake.triages.map(\.action), [.accept])
    }

    func testFailedCommentStopsTheDecline() async throws {
        let (rig, made) = try await makeRig()
        rig.fake.failWrites(to: made[1].workItemId)
        let r = await run(rig, "intake.decline", ["project": .string("FAKE"), "id": .string("FAKE-2"), "comment": .string("No.")])
        guard case .ok = r else { return }
        XCTFail("a failed comment must stop the decline: \(r)")
    }

    func testSnoozeDateAndBadUntil() async throws {
        let (rig, _) = try await makeRig()
        let r = await run(rig, "intake.snooze", ["project": .string("FAKE"), "id": .string("FAKE-1"), "until": .string("2099-03-04")])
        guard case .ok = r else { return XCTFail("\(r)") }
        guard case .snooze(let until)? = rig.fake.triages.last?.action else { return XCTFail("no snooze") }
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: until)
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2099, 3, 4, 9, 0])
        let bad = await run(rig, "intake.snooze", ["project": .string("FAKE"), "id": .string("FAKE-2"), "until": .string("next week")])
        assertNotAllowed(bad, "Give until as YYYY-MM-DD or an ISO 8601 time.")
        XCTAssertEqual(rig.fake.triages.count, 1)
        let days = await run(rig, "intake.snooze", ["project": .string("FAKE"), "id": .string("FAKE-2"), "days": .int(3)])
        guard case .ok = days else { return XCTFail("\(days)") }
    }

    func testMergeOfAnIntakeKey() async throws {
        let (rig, made) = try await makeRig()
        let r = await run(rig, "intake.merge", ["project": .string("FAKE"), "id": .string("FAKE-2"), "of": .string("FAKE-1")])
        guard case .ok = r else { return XCTFail("\(r)") }
        XCTAssertEqual(rig.fake.triages.last?.action, .duplicate(of: made[0].workItemId))
        let self_ = await run(rig, "intake.merge", ["project": .string("FAKE"), "id": .string("FAKE-1"), "of": .string("FAKE-1")])
        assertNotAllowed(self_, "An item cannot duplicate itself.")
    }

    func testEditParentAndRelationByKey() async throws {
        let (rig, made) = try await makeRig()
        let r = await run(rig, "intake.edit", ["project": .string("FAKE"), "id": .string("FAKE-2"), "parent": .string("FAKE-1"),
                                               "kind": .string("blocks"), "other": .string("FAKE-1"), "patch": .object(["title": .string("New title")])])
        guard case .ok = r else { return XCTFail("\(r)") }
        let edit = try XCTUnwrap(rig.fake.intakeEdits.last)
        XCTAssertEqual(edit.patch.parent, made[0].workItemId)
        XCTAssertEqual(edit.patch.title, "New title")
        XCTAssertEqual(edit.relations.map(\.item.id), [made[0].workItemId])
        XCTAssertEqual(edit.relations.first?.kind, .blocks)
        let none = await run(rig, "intake.edit", ["project": .string("FAKE"), "id": .string("FAKE-2"), "parent": .string("none")])
        guard case .ok = none else { return XCTFail("\(none)") }
        XCTAssertEqual(rig.fake.intakeEdits.last?.patch.parent, "")
        let bad = await run(rig, "intake.edit", ["project": .string("FAKE"), "id": .string("FAKE-2"), "kind": .string("loves"), "other": .string("FAKE-1")])
        assertNotAllowed(bad, "No relation kind loves.")
    }

    // MARK: Events

    func testTriageRowsNameAgent() async throws {
        let (rig, _) = try await makeRig()
        _ = await run(rig, "intake.decline", ["project": .string("FAKE"), "id": .string("FAKE-1"), "comment": .string("No.")])
        _ = await run(rig, "intake.snooze", ["project": .string("FAKE"), "id": .string("FAKE-2"), "days": .int(2)])
        let declined = await rig.row(.intakeDeclined)
        XCTAssertEqual(declined?.actorType, .agent)
        XCTAssertEqual(declined?.actor, "codex s1")
        XCTAssertEqual(declined?.item, "FAKE-1")
        XCTAssertEqual(declined?.payload?["commented"], .bool(true))
        XCTAssertEqual(declined.map { EventCatalog.repo.problems($0) }, [])
        let snoozed = await rig.row(.intakeSnoozed)
        XCTAssertEqual(snoozed?.actorType, .agent)
        XCTAssertEqual(snoozed?.item, "FAKE-2")
        XCTAssertNotNil(snoozed?.payload?["until"])
        XCTAssertEqual(snoozed.map { EventCatalog.repo.problems($0) }, [])
    }

    func testUITriageKeepsHuman() async throws {
        let (rig, made) = try await makeRig()
        _ = await run(rig, "intake.list", ["project": .string("FAKE")])   // the intake page has the keys loaded
        let r = await run(rig, "intake.accept", ["project": .string("FAKE"), "id": .string(made[0].id), "of": .string(made[0].workItemId)], caller: .user)
        guard case .ok = r else { return XCTFail("\(r)") }
        let row = await rig.row(.intakeAccepted)
        XCTAssertEqual(row?.actorType, .human)
        XCTAssertEqual(row?.item, "FAKE-1")
        XCTAssertEqual(row.map { EventCatalog.repo.problems($0) }, [])
    }

    func testDeleteAndEditWriteRows() async throws {
        let (rig, _) = try await makeRig()
        _ = await run(rig, "intake.edit", ["project": .string("FAKE"), "id": .string("FAKE-1"), "priority": .string("high")])
        _ = await run(rig, "intake.delete", ["project": .string("FAKE"), "id": .string("FAKE-2")])
        let updated = await rig.row(.intakeUpdated)
        XCTAssertEqual(updated?.payload?["fields"], .array([.string("priority")]))
        XCTAssertEqual(updated.map { EventCatalog.repo.problems($0) }, [])
        let deleted = await rig.row(.intakeDeleted)
        XCTAssertEqual(deleted?.item, "FAKE-2")
        XCTAssertEqual(deleted.map { EventCatalog.repo.problems($0) }, [])
    }
}
