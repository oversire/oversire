import XCTest
import OverSireAI
import OverSireCore
import OverSireSync
import OverSireTestKit
@testable import OverSireApp

/// Groom Apply writes one item at a time, and Undo puts the old values back (OVERSIRE-341, OVERSIRE-342).
final class GroomApplierTests: XCTestCase {
    typealias P = GroomResult.Proposal

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private var fake: FakeTracker!
    private var journal: GroomJournal!
    private var refs: [String: ItemRef] = [:]
    private var intake: IntakeItem!

    override func setUp() async throws {
        fake = FakeTracker()
        let t0 = t0
        fake.base.now = { t0 }
        fake.addStatus(StatusOption(id: "s-cancel", name: "Cancelled", color: "#9CA3AF", group: "cancelled"))
        let block = "\(OverSireBlock.start)\n- Session: done\n\(OverSireBlock.end)"
        refs["FAKE-1"] = try await fake.create(ItemDraft(title: "One", bodyMarkdown: "Old text.\n\n" + block), in: fake.project)
        refs["FAKE-2"] = try await fake.create(ItemDraft(title: "Two"), in: fake.project)
        refs["FAKE-3"] = try await fake.createIntake(ItemDraft(title: "A note"), in: fake.project).item
        for n in 4...6 { refs["FAKE-\(n)"] = try await fake.create(ItemDraft(title: "Item \(n)"), in: fake.project) }
        intake = try await fake.intake(fake.project).first
        XCTAssertEqual(intake.workItemId, refs["FAKE-3"]?.id)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("groom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        journal = GroomJournal(store: LocalStore(dir: dir))
        await journal.begin("p1", project: fake.project, at: t0)
    }

    private func applier() async throws -> GroomApplier {
        let summary = try await fake.projects()[0]
        let snap = ProjectSnapshot(summary: summary, statusOptions: try await fake.statuses(fake.project),
                                   items: try await fake.items(fake.project, since: nil, limit: 50), fetchedAt: t0)
        var targets: [String: GroomApplier.Target] = [:]
        for (k, r) in refs { targets[k] = .init(ref: r, intake: r.id == intake.workItemId ? intake : nil) }
        let t0 = t0
        return GroomApplier(tracker: fake, snapshot: snap, targets: targets, journal: journal, projectKey: "p1", now: { t0 })
    }

    private func item(_ k: String) async throws -> Item { try await fake.detail(refs[k]!).item }
    private func comments(_ k: String) async throws -> [String] { try await fake.comments(refs[k]!).compactMap(\.body) }

    private let merge = P(kind: .merge, keys: ["FAKE-1", "FAKE-2", "FAKE-3"], keep: "FAKE-1", reason: "Same cause.", description: "## New\nOne text.")

    func testMergeKeepsTheBlockAndClosesTheOthers() async throws {
        let out = try await applier().apply([merge])
        XCTAssertEqual(out.written, [merge.id])
        let v1 = try await item("FAKE-1").body
        XCTAssertEqual(v1, "## New\nOne text.\n\n\(OverSireBlock.start)\n- Session: done\n\(OverSireBlock.end)")
        let v2 = try await item("FAKE-2").statusOptionId
        XCTAssertEqual(v2, "s-cancel")
        let v3 = try await comments("FAKE-2")
        XCTAssertEqual(v3, ["Merged into FAKE-1 by Groom. Same cause."])
        let v4 = try await fake.relations(of: refs["FAKE-2"]!).map(\.kind)
        XCTAssertEqual(v4, [.duplicate])
        let v5 = try await comments("FAKE-3")
        XCTAssertEqual(v5, ["Merged into FAKE-1 by Groom. Same cause."])
        XCTAssertEqual(fake.triages.last?.action, .duplicate(of: refs["FAKE-1"]!.id))
        let v6 = try await fake.intake(fake.project).isEmpty
        XCTAssertTrue(v6)

        let again = try await applier().apply([merge])
        XCTAssertEqual(again.written, [merge.id])
        let v7 = try await comments("FAKE-2").count
        XCTAssertEqual(v7, 1, "a second Apply writes no second comment")
        XCTAssertEqual(fake.triages.filter { if case .duplicate = $0.action { return true } else { return false } }.count, 1)
    }

    func testEachKind() async throws {
        let lines = [P(kind: .done, keys: ["FAKE-4"], reason: "The ring shows.", evidence: ["a41f9c2"]),
                     P(kind: .obsolete, keys: ["FAKE-3"], reason: "No remote Orca."),
                     P(kind: .fold, keys: ["FAKE-5"], parent: "FAKE-1", reason: "Part of it."),
                     P(kind: .relate, keys: ["FAKE-6"], relation: .init(kind: "blocked_by", key: "FAKE-1"), reason: "Same file."),
                     P(kind: .vague, keys: ["fake-2"], reason: "Only a title.")]
        let out = try await applier().apply(lines)
        XCTAssertEqual(out.written, lines.dropLast().map(\.id))
        XCTAssertEqual(out.vague, ["FAKE-2"])
        let v8 = try await item("FAKE-4").statusOptionId
        XCTAssertEqual(v8, "s-done")
        let v9 = try await comments("FAKE-4")
        XCTAssertEqual(v9, ["Done: The ring shows.\na41f9c2"])
        XCTAssertEqual(fake.triages.last?.action, .decline)
        let v10 = try await item("FAKE-5").parentId
        XCTAssertEqual(v10, refs["FAKE-1"]!.id)
        let v11 = try await fake.relations(of: refs["FAKE-6"]!)
        XCTAssertEqual(v11, [ItemRelation(kind: .blockedBy, item: refs["FAKE-1"]!)])
        let v12 = try await item("FAKE-2").statusOptionId
        XCTAssertEqual(v12, "s-todo", "vague writes nothing")
    }

    func testAFailedLineStaysAndTryAgainWritesOnce() async throws {
        fake.failWrites(to: refs["FAKE-2"]!.id)
        let done = P(kind: .done, keys: ["FAKE-4"], reason: "r")
        let out = try await applier().apply([merge, done])
        XCTAssertEqual(out.written, [done.id])
        XCTAssertEqual(out.failed[merge.id], "Plane said 403 for this project")
        let again = try await applier().apply([merge])
        XCTAssertEqual(again.written, [merge.id])
        let v13 = try await comments("FAKE-2")
        XCTAssertEqual(v13, ["Merged into FAKE-1 by Groom. Same cause."])
        let v14 = try await item("FAKE-2").statusOptionId
        XCTAssertEqual(v14, "s-cancel")
    }

    func testUndoPutsBackTheOldValues() async throws {
        let lines = [merge, P(kind: .done, keys: ["FAKE-4"], reason: "r"), P(kind: .fold, keys: ["FAKE-5"], parent: "FAKE-1", reason: "r")]
        _ = try await applier().apply(lines)
        let v15 = await journal.changed("p1", tracker: fake).isEmpty
        XCTAssertTrue(v15)

        let out = await journal.undo("p1", tracker: fake)
        XCTAssertEqual(Set(out.undone), ["FAKE-1", "FAKE-2", "FAKE-3", "FAKE-4", "FAKE-5"])
        XCTAssertTrue(out.failed.isEmpty, "\(out.failed)")
        let v16 = try await item("FAKE-1").body?.hasPrefix("Old text.")
        XCTAssertEqual(v16, true)
        let v17 = try await item("FAKE-2").statusOptionId
        XCTAssertEqual(v17, "s-todo")
        let v18 = try await fake.relations(of: refs["FAKE-2"]!).isEmpty
        XCTAssertTrue(v18)
        let v19 = try await item("FAKE-4").statusOptionId
        XCTAssertEqual(v19, "s-todo")
        let v20 = try await item("FAKE-5").parentId
        XCTAssertNil(v20)
        let v21 = try await fake.intake(fake.project).map(\.id)
        XCTAssertEqual(v21, [intake.id], "the intake item is back")
        let v22 = try await comments("FAKE-4")
        XCTAssertEqual(v22, ["Done: r", "Groom undone."], "the Groom comments stay")
        let last = await journal.last("p1")
        XCTAssertNil(last, "Undo deletes the journal")
    }

    func testUndoLeavesAnItemThatChangedAfterGroom() async throws {
        _ = try await applier().apply([P(kind: .done, keys: ["FAKE-4"], reason: "r"), P(kind: .done, keys: ["FAKE-5"], reason: "r")])
        let later = t0.addingTimeInterval(GroomJournal.grace + 60)
        fake.base.now = { later }
        try await fake.update(refs["FAKE-4"]!, ItemPatch(title: "Changed by the user"))
        let v23 = await journal.changed("p1", tracker: fake)
        XCTAssertEqual(v23, ["FAKE-4"])
        let out = await journal.undo("p1", tracker: fake)
        XCTAssertEqual(out.left, ["FAKE-4"])
        XCTAssertEqual(out.undone, ["FAKE-5"])
        let v24 = try await item("FAKE-4").statusOptionId
        XCTAssertEqual(v24, "s-done")
    }

    func testTheJournalLivesInTheStore() async throws {
        _ = try await applier().apply([P(kind: .done, keys: ["FAKE-4"], reason: "r")])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("groom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = LocalStore(dir: dir)
        let one = GroomJournal(store: store)
        await one.begin("p1", project: fake.project, at: t0)
        await one.record(before: .init(key: "FAKE-4", ref: refs["FAKE-4"]!, status: "s-todo"), in: "p1")
        await one.written("FAKE-4", at: t0, in: "p1")
        let two = GroomJournal(store: store)
        let last = await two.last("p1")
        XCTAssertEqual(last?.entries.map(\.status), ["s-todo"])
    }
}
