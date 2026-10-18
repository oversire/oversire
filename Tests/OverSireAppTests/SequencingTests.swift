import OverSireCore
import OverSireSync
import XCTest
@testable import OverSireApp

final class SequencingTests: XCTestCase {
    private let project = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "OVERSIRE")

    private func ref(_ n: Int) -> ItemRef {
        ItemRef(project: project, id: "i\(n)", key: "OVERSIRE-\(n)", url: URL(string: "https://app.plane.so/ocral/browse/OVERSIRE-\(n)/")!)
    }

    private func writes() -> StoreWrites {
        StoreWrites(store: LocalStore(dir: FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")))
    }

    private func suggestion(_ draft: SequenceDraft) -> Suggestion {
        Suggestion(id: "s1", subject: .item(ref(2)), kind: .sequence, title: "Order OVERSIRE-2 after OVERSIRE-1", body: "",
                   proposal: .sequence(draft), subjectVersion: "v1", createdAt: Date(), expiresAt: Date().addingTimeInterval(86400))
    }

    func testAcceptSendsTheClearedLines() {
        let draft = SequenceDraft(relations: RelationPatch(add: [ItemRelation(kind: .blockedBy, item: ref(1)), ItemRelation(kind: .relatesTo, item: ref(4))],
                                                           remove: [ItemRelation(kind: .blocks, item: ref(5))]),
                                  areas: ["api"])
        XCTAssertEqual(draft.lines.count, 4)
        let book = SuggestionBook(writes: writes())
        book.seed(suggestion(draft))
        XCTAssertEqual(book.openSequence(for: "oversire-2")?.id, "s1")
        let at = Date(timeIntervalSince1970: 100)
        book.accept("s1", drop: [3, 1], by: "dev-1", now: at)
        let s = book.all[0]
        XCTAssertEqual(s.state, .accepted)
        XCTAssertEqual(s.edit, SuggestionEdit(drop: [1, 3]), "the indexes of the cleared lines, sorted")
        XCTAssertEqual(s.decidedAt, at)
        XCTAssertEqual(s.decidedBy, "dev-1")
        XCTAssertEqual(draft.dropping(Set(s.edit!.drop)), SequenceDraft(relations: RelationPatch(add: [ItemRelation(kind: .blockedBy, item: ref(1))],
                                                                                                remove: [ItemRelation(kind: .blocks, item: ref(5))])))
        XCTAssertNil(book.openSequence(for: "OVERSIRE-2"))
        book.dismiss("s1", by: nil)
        XCTAssertEqual(book.all[0].state, .accepted, "a decided suggestion stays decided")
    }

    func testAcceptAllAndDismiss() {
        let book = SuggestionBook(writes: writes())
        book.seed(suggestion(SequenceDraft(areas: ["api"])))
        book.accept("s1", drop: [], by: nil)
        XCTAssertNil(book.all[0].edit, "no cleared line, no edit")
        let other = SuggestionBook(writes: writes())
        other.seed(suggestion(SequenceDraft(areas: ["api"])))
        other.dismiss("s1", by: nil)
        XCTAssertEqual(other.all[0].state, .dismissed)
        XCTAssertNil(other.all[0].edit)
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
