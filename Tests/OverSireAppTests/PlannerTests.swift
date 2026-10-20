import OverSireCore
import OverSireSync
import XCTest
import OverSireAI
@testable import OverSireApp

final class PlannerTests: XCTestCase {
    private let project = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "OVERSIRE")

    private func ref(_ n: Int) -> ItemRef {
        ItemRef(project: project, id: "i\(n)", key: "OVERSIRE-\(n)", url: URL(string: "https://app.plane.so/ocral/browse/OVERSIRE-\(n)/")!)
    }

    private func writes() -> StoreWrites {
        StoreWrites(store: LocalStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")))
    }

    private func suggestion(_ draft: PlanDraft) -> Suggestion {
        Suggestion(id: "s1", subject: .project(project), kind: .plan, title: "Plan change for OVERSIRE", body: "",
                   proposal: .plan(draft), subjectVersion: "v1", createdAt: Date(), expiresAt: Date().addingTimeInterval(86400))
    }

    private var draft: PlanDraft {
        PlanDraft(order: [PlanDraft.OrderLine(item: ref(3), lane: project.storeKey, after: nil, reason: "r0")],
                  relations: [PlanDraft.RelationLine(item: ref(2), add: [ItemRelation(kind: .blockedBy, item: ref(1))], reason: "r1")],
                  areas: [PlanDraft.AreaLine(item: ref(2), add: ["api"], reason: "r2"), PlanDraft.AreaLine(item: ref(3), remove: ["ui"], reason: "r3")])
    }

    func testAcceptSendsTheClearedLines() {
        XCTAssertEqual(draft.lines.count, 4)
        let book = SuggestionBook(writes: writes())
        book.seed(suggestion(draft))
        XCTAssertEqual(book.openPlan(lane: project.storeKey)?.id, "s1")
        XCTAssertEqual(book.openPlan(naming: "oversire-3")?.id, "s1")
        XCTAssertNil(book.openPlan(naming: "OVERSIRE-9"))
        let at = Date(timeIntervalSince1970: 100)
        book.accept("s1", drop: [3, 1], by: "dev-1", now: at)
        let s = book.all[0]
        XCTAssertEqual(s.state, .accepted)
        XCTAssertEqual(s.edit, SuggestionEdit(drop: [1, 3]), "the indexes of the cleared lines, sorted")
        XCTAssertEqual(s.decidedAt, at)
        XCTAssertEqual(s.decidedBy, "dev-1")
        let kept = draft.dropping(Set(s.edit!.drop))
        XCTAssertEqual(kept.order, draft.order)
        XCTAssertTrue(kept.relations.isEmpty)
        XCTAssertEqual(kept.areas.map(\.reason), ["r2"])
        XCTAssertNil(book.openPlan(lane: project.storeKey))
        book.dismiss("s1", by: nil)
        XCTAssertEqual(book.all[0].state, .accepted, "a decided suggestion stays decided")
    }

    func testAcceptAllAndDismiss() {
        let book = SuggestionBook(writes: writes())
        book.seed(suggestion(draft))
        book.accept("s1", drop: [], by: nil)
        XCTAssertNil(book.all[0].edit, "no cleared line, no edit")
        let other = SuggestionBook(writes: writes())
        other.seed(suggestion(draft))
        other.dismiss("s1", by: nil)
        XCTAssertEqual(other.all[0].state, .dismissed)
        XCTAssertNil(other.all[0].edit)
    }

    func testBoardModelAppliesThePlan() {
        let lane = QueueLane(project: project.storeKey, identifier: "OVERSIRE",
                             entries: [1, 2, 3].map { QueueEntry(key: "OVERSIRE-\($0)", title: "", added: Date()) })
        let areas = ["OVERSIRE-1": ["api"], "OVERSIRE-2": ["api"], "OVERSIRE-3": ["ui"], "OVERSIRE-9": ["db"]]
        let now = QueueBoard.plan(lane: lane, running: ["OVERSIRE-9"], areas: { areas[$0] ?? [] }, slots: 2, draft: nil)
        XCTAssertEqual(now.cards(.now).map(\.key), ["OVERSIRE-9", "OVERSIRE-1"])
        XCTAssertEqual(now.cards(.next).map(\.key), ["OVERSIRE-2", "OVERSIRE-3"])
        let after = QueueBoard.plan(lane: lane, running: ["OVERSIRE-9"], areas: { areas[$0] ?? [] }, slots: 2, draft: draft)
        XCTAssertEqual(after.cards(.now).map(\.key), ["OVERSIRE-9", "OVERSIRE-3"])
        XCTAssertEqual(after.cards(.now)[1].areas, [], "the areas line removes ui")
        XCTAssertEqual(after.cards(.next).first { $0.key == "OVERSIRE-2" }?.areas, ["api"])
    }

    func testBoardColumns() {
        let lane = QueueLane(project: project.storeKey, identifier: "OVERSIRE",
                             entries: [1, 2, 3, 4, 5].map { QueueEntry(key: "OVERSIRE-\($0)", title: "", added: Date()) })
        let areas = ["OVERSIRE-1": ["api"], "OVERSIRE-9": ["api"], "OVERSIRE-4": ["ui"]]
        let holds: [String: QueueHold] = ["OVERSIRE-2": .waits(on: ["OVERSIRE-1"]), "OVERSIRE-3": .area("api", runs: "OVERSIRE-9"), "OVERSIRE-5": .unknown]
        let hold = WorkOrderHold(blockers: [ref(84)], since: Date())
        let b = QueueBoard(lane: lane, running: ["OVERSIRE-9"], slots: 3, holds: holds,
                           held: [("OVERSIRE-85", hold), ("OVERSIRE-90", WorkOrderHold(areas: ["contract"], since: Date())), ("OVERSIRE-91", nil)],
                           areas: { areas[$0] ?? [] }, kind: { _ in .core })
        XCTAssertEqual(b.running.map(\.key), ["OVERSIRE-9"])
        XCTAssertEqual(b.free, 2)
        XCTAssertEqual(b.next.map(\.key), ["OVERSIRE-1", "OVERSIRE-4"], "an entry with no hold is up next, in lane order")
        XCTAssertEqual(b.waits.map(\.key), ["OVERSIRE-2", "OVERSIRE-3", "OVERSIRE-5"])
        XCTAssertEqual(b.waits.map(\.note), ["⏸ Waits for OVERSIRE-1", "⊘ Area used by OVERSIRE-9", "Reads the relations…"])
        XCTAssertEqual(b.held.map(\.note), ["⏸ Waits for OVERSIRE-84", "⊘ Area busy: contract", nil])
        XCTAssertEqual(b.held[1].areas, ["contract"])
        XCTAssertEqual(b.running[0].clash, "OVERSIRE-1 (api)", "a card that runs at the same time and shares an area clashes")
        XCTAssertEqual(b.next[0].clash, "OVERSIRE-9 (api)")
        XCTAssertNil(b.next[1].clash)
        XCTAssertFalse(b.isEmpty)
        let full = QueueBoard(lane: lane, running: ["OVERSIRE-7", "OVERSIRE-8"], slots: 1, holds: [:], areas: { _ in [] }, kind: { _ in .core })
        XCTAssertEqual(full.free, 0, "more sessions than slots give no free slot")
        let empty = QueueBoard(lane: QueueLane(project: "p", identifier: "X", entries: []), running: [], slots: 2, holds: [:],
                               areas: { _ in [] }, kind: { _ in .core })
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(empty.free, 2)
    }

    func testBoardFollowsTheDraft() {
        let lane = QueueLane(project: project.storeKey, identifier: "OVERSIRE",
                             entries: [1, 2, 3].map { QueueEntry(key: "OVERSIRE-\($0)", title: "", added: Date()) })
        let b = QueueBoard(lane: lane, running: [], slots: 2, holds: [:], areas: { $0 == "OVERSIRE-3" ? ["ui"] : [] }, kind: { _ in .core }, draft: draft)
        XCTAssertEqual(b.next.map(\.key), ["OVERSIRE-3", "OVERSIRE-1", "OVERSIRE-2"])
        XCTAssertEqual(b.next[0].areas, [])
        XCTAssertEqual(b.next[2].areas, ["api"])
    }

    func testApproveAllTakesTheDoneStatusesOfQuietSessions() {
        func s(_ id: String, _ v: StatusReply.State, _ phase: SessionState? = .quiet) -> SessionStatus {
            SessionStatus(id: id, key: "K-\(id)", reply: StatusReply(state: v, headline: ""), ticks: [], at: Date(), trigger: .idle,
                          byAI: true, phase: phase, read: "")
        }
        let list = [s("1", .done), s("2", .stuck), s("3", .done, .working), s("4", .done, nil), s("5", .unfinished)]
        XCTAssertEqual(list.filter(StatusJob.frees).map(\.id), ["1", "4"])
    }

    func testReviewSentences() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)").path
        let store = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                 statePath: dir + "/state.json", activityPath: dir + "/activity.jsonl")
        let lines = draft.lines.map { PlanReviewView.sentence($0, store: store, kind: { $0 == "api" ? .core : .feature }) }
        XCTAssertEqual(lines, ["Start OVERSIRE-3 first.", "Mark OVERSIRE-2 as blocked by OVERSIRE-1.",
                               "Add the area ◆ api to OVERSIRE-2.", "Remove the area ◇ ui from OVERSIRE-3."])
        let o = PlanDraft.OrderLine(item: ref(3), lane: "l", after: ref(1), reason: "")
        XCTAssertEqual(PlanReviewView.sentence(.order(o), store: store, kind: { _ in .core }), "Start OVERSIRE-3 after OVERSIRE-1.")
    }

    func testPlannerBookDefaultsAndSharable() {
        let book = PlannerBook(writes: writes())
        let pk = project.storeKey
        XCTAssertEqual(book.settings(pk).mode, .hourly)
        XCTAssertEqual(book.settings(pk).sharedFeature, .serial)
        book.seed(AreaCatalog(project: pk, areas: [AreaDef(name: "ui", kind: .feature), AreaDef(name: "core", kind: .core)], updatedAt: Date()))
        XCTAssertFalse(book.sharable("ui", project: pk))
        book.update(pk) { $0.sharedFeature = .parallel }
        XCTAssertTrue(book.sharable("ui", project: pk))
        XCTAssertFalse(book.sharable("core", project: pk))
        XCTAssertFalse(book.sharable("unknown", project: pk), "an area outside the catalog is core")
    }

    func testQueueSkipsASharableArea() {
        let lane = QueueLane(project: "p", identifier: "OVERSIRE", entries: [QueueEntry(key: "OVERSIRE-2", title: "", added: Date())])
        var w = QueueWorld(busy: { _ in 1 }, slots: { _ in 3 }, ciPassed: { _ in true }, done: { _ in false }, now: Date(),
                           areas: { _ in ["ui"] }, busyAreas: { _ in ["ui": "OVERSIRE-1"] })
        XCTAssertEqual(lane.pick(state: nil, world: w).holds["OVERSIRE-2"], .area("ui", runs: "OVERSIRE-1"))
        w.sharable = { _, a in a == "ui" }
        XCTAssertEqual(lane.pick(state: nil, world: w).entry?.key, "OVERSIRE-2")
    }

    func testAreasAndBusy() {
        let book = ItemAreaBook(writes: writes())
        XCTAssertEqual(book.save(["API", "status page", "api", "bad/tag"], for: ref(2)), ["api", "status-page"])
        XCTAssertEqual(book.records[ItemAreas.id(of: ref(2))]?.source, .user)
        book.save(["ui"], for: ref(3))
        XCTAssertEqual(book.areas(key: "oversire-2"), ["api", "status-page"])
        XCTAssertEqual(book.busy(running: ["OVERSIRE-3", "OVERSIRE-2", "OVERSIRE-7"]), ["api": "OVERSIRE-2", "status-page": "OVERSIRE-2", "ui": "OVERSIRE-3"])
    }

    func testHoldText() {
        XCTAssertEqual(WorkOrderHold(blockers: [ref(1)], areas: ["api"], since: Date()).text, "Held: waits on OVERSIRE-1")
        XCTAssertEqual(WorkOrderHold(areas: ["api"], since: Date()).text, "Held: area api busy")
    }
}
