import OverSireCore
import XCTest
@testable import OverSireApp

final class PaletteEpicTests: XCTestCase {
    func testEpicEntries() {
        var opened: (String, EpicID)?
        let e = CommandPalette.epicEntries(["w/p": EpicFixture.snap(), "x": EpicFixture.snap(epics: false)]) { opened = ($0, $1) }
        XCTAssertEqual(e.map(\.title), ["Epics", "Review desk", "Planned", "Old"])
        XCTAssertEqual(Set(e.map(\.kind)), ["Epic"])
        let desk = e[1]
        XCTAssertEqual(desk.detail, "ENG · 6 of 8 done")
        desk.run()
        XCTAssertEqual(opened?.0, "ENG")
        XCTAssertEqual(opened?.1, EpicFixture.deskId)
        XCTAssertEqual(CommandPalette.match(e, query: "epic review", picking: false).map(\.title), ["Review desk"])
    }

    func testMoveToEpicOnlyOnItemPageWithCapability() {
        var ran = 0
        let item = Route.item("ENG-1", .overview)
        let e = CommandPalette.moveToEpicEntry(route: item, capable: true) { ran += 1 }
        XCTAssertEqual(e?.title, "Move to epic…")
        XCTAssertEqual(e?.kind, "Action")
        e?.run()
        XCTAssertEqual(ran, 1)
        XCTAssertNil(CommandPalette.moveToEpicEntry(route: item, capable: false) {}, "no capability")
        XCTAssertNil(CommandPalette.moveToEpicEntry(route: .project("ENG"), capable: true) {}, "not an item page")
        XCTAssertNil(CommandPalette.moveToEpicEntry(route: .work(.epics), capable: true) {})
    }
}
