import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class EpicBoardTests: XCTestCase {
    private let none: (String) -> (needsInput: Bool, working: Bool) = { _ in (false, false) }

    /// Four epics: e1 active with an open item, e2 with all items done, e3 planned with no item, e4 done.
    private func rig() async throws -> (EpicRig, ProjectSnapshot) {
        let rig = try await EpicRig(items: 3, epics: ["Active", "Ready", "Planned", "Finished"], tracking: false)
        let past = Date().addingTimeInterval(-3 * 86_400)
        let e = try await rig.fake.epics(in: rig.fake.project)
        _ = try await rig.fake.updateEpic(e[0], EpicPatch(state: .active, targetDate: past))
        _ = try await rig.fake.updateEpic(e[1], EpicPatch(state: .active))
        _ = try await rig.fake.updateEpic(e[2], EpicPatch(state: .planned))
        _ = try await rig.fake.updateEpic(e[3], EpicPatch(state: .done))
        try await rig.fake.setEpic(e[0].id, for: rig.items[0])
        try await rig.fake.setEpic(e[1].id, for: rig.items[1])
        try await rig.fake.update(rig.items[1], ItemPatch(status: "s-done"))
        try await rig.track()
        let found = await rig.snapshot()
        let snap = try XCTUnwrap(found)
        return (rig, snap)
    }

    func testSections() async throws {
        let (_, snap) = try await rig()
        let groups = EpicBoard.build([snap], filter: .init(), sessions: none, now: Date())
        XCTAssertEqual(groups.map(\.0), [.inProgress, .readyToClose, .planned])
        XCTAssertEqual(groups[0].1.map(\.epic.title), ["Active"])
        XCTAssertEqual(groups[1].1.map(\.epic.title), ["Ready"])
        let all = EpicBoard.build([snap], filter: .init(showDone: true), sessions: none, now: Date())
        XCTAssertEqual(all.last?.0, .done)
        XCTAssertEqual(all.last?.1.map(\.epic.title), ["Finished"])
    }

    func testFilters() async throws {
        let (_, snap) = try await rig()
        let late = EpicBoard.build([snap], filter: .init(late: true), sessions: none, now: Date())
        XCTAssertEqual(late.flatMap(\.1).map(\.epic.title), ["Active"])
        let other = EpicBoard.build([snap], filter: .init(project: "NOPE"), sessions: none, now: Date())
        XCTAssertTrue(other.isEmpty)
        let this = EpicBoard.build([snap], filter: .init(project: snap.summary.identifier.lowercased()), sessions: none, now: Date())
        XCTAssertEqual(this.flatMap(\.1).count, 3)
    }

    func testRowAction() async throws {
        let (rig, snap) = try await rig()
        let rows = EpicBoard.build([snap], filter: .init(showDone: true), sessions: none, now: Date()).flatMap(\.1)
        let by = Dictionary(uniqueKeysWithValues: rows.map { ($0.epic.title, $0) })
        XCTAssertEqual(by["Active"]?.action, .startNext(rig.items[0].key))
        XCTAssertEqual(by["Ready"]?.action, .close)
        XCTAssertEqual(by["Planned"]?.action, .open)
        XCTAssertEqual(by["Finished"]?.action, .open)
        XCTAssertTrue(by["Active"]?.dueText.contains("late") == true)
        XCTAssertEqual(by["Ready"]?.progressText, "1 of 1 done")
        let busy = EpicBoard.build([snap], filter: .init(), sessions: { $0 == rig.items[0].key ? (true, false) : (false, false) }, now: Date())
        XCTAssertEqual(busy[0].1[0].sessionText, "▲ 1 needs input")
    }
}
