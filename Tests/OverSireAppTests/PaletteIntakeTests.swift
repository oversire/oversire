import OverSireCore
import XCTest
@testable import OverSireApp

final class PaletteIntakeTests: XCTestCase {
    private func snap(_ id: String, intake: [IntakeItem]?, items: [Item] = []) -> ProjectSnapshot {
        ProjectSnapshot(summary: ProjectSummary(ref: ProjectRef(workspace: "ocral", id: id.lowercased()), identifier: id, title: id, url: "", closed: false),
                        statusOptions: [], items: items, fetchedAt: Date(), intake: intake)
    }

    private let pending = IntakeItem(id: "in1", workItemId: "w240", name: "Intake items in search", priority: "medium",
                                     createdAt: Date(), author: nil, source: nil)

    func testOneEntryForEachPendingIntakeItem() {
        var opened: (String, String)?
        let e = CommandPalette.intakeEntries(["ov": snap("OVERSIRE", intake: [pending]), "x": snap("X", intake: nil)],
                                             keys: ["w240": 240]) { opened = ($0, $1) }
        XCTAssertEqual(e.map(\.title), ["OVERSIRE-240  Intake items in search"])
        XCTAssertEqual(e[0].detail, "Intake · medium")
        XCTAssertEqual(e[0].kind, "Intake")
        XCTAssertEqual(e[0].key, "OVERSIRE-240")
        e[0].run()
        XCTAssertEqual(opened?.0, "ov")
        XCTAssertEqual(opened?.1, "w240")
    }

    func testNameOnlyWhileTheKeyLoads() {
        let e = CommandPalette.intakeEntries(["ov": snap("OVERSIRE", intake: [pending])], keys: [:]) { _, _ in }
        XCTAssertEqual(e[0].title, "Intake items in search")
        XCTAssertEqual(e[0].key, "")
    }

    func testSearchFindsIntakeByWordAndKey() {
        let intake = CommandPalette.intakeEntries(["ov": snap("OVERSIRE", intake: [pending])], keys: ["w240": 240]) { _, _ in }
        let other = CommandPalette.Entry(title: "OVERSIRE-12  Search speed", detail: "Todo", symbol: "", kind: "Item", key: "OVERSIRE-12") {}
        let all = [other] + intake
        XCTAssertEqual(CommandPalette.match(all, query: "intake items", picking: false).map(\.key), ["OVERSIRE-240"])
        XCTAssertEqual(CommandPalette.match(all, query: "oversire-240", picking: false).first?.key, "OVERSIRE-240")
        XCTAssertEqual(CommandPalette.match(all, query: "search", picking: false).map(\.key), ["OVERSIRE-12", "OVERSIRE-240"])
        XCTAssertTrue(CommandPalette.match(all, query: "", picking: false).isEmpty, "the empty query shows only pages, projects and actions")
    }
}
