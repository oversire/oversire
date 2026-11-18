import OverSireCore
import XCTest
@testable import OverSireApp

final class EpicPickerModelTests: XCTestCase {
    private var epics: [EpicRollup] {
        let snap = EpicFixture.snap()
        return (snap.epics ?? []).map { snap.rollup($0) }
    }

    func testRowsOrderAndSearch() {
        let m = EpicPickerModel(epics: epics, current: nil)
        XCTAssertEqual(m.rows(query: "").map(\.title), ["Review desk", "Epics", "Planned", "Old", "No epic", "New epic…"],
                       "open epics by target date, then the closed epics; the two fixed rows last")
        XCTAssertEqual(m.rows(query: "rev").map(\.title), ["Review desk", "No epic", "New epic…"])
        XCTAssertEqual(m.rows(query: "DESK rev").map(\.title), ["Review desk", "No epic", "New epic…"])
        XCTAssertEqual(m.rows(query: "zzz").map(\.title), ["No epic", "New epic…"])
    }

    func testCurrentIsSelected() {
        XCTAssertEqual(EpicPickerModel(epics: epics, current: "e2").rows(query: "").filter(\.isSelected).map(\.title), ["Epics"])
        XCTAssertEqual(EpicPickerModel(epics: epics, current: nil).rows(query: "").filter(\.isSelected).map(\.title), ["No epic"])
        XCTAssertEqual(EpicPickerModel(epics: epics, current: "gone").rows(query: "").filter(\.isSelected).map(\.title), [], "an unknown epic selects no row")
    }

    func testDetailAndLabel() {
        let rows = Dictionary(uniqueKeysWithValues: EpicPickerModel(epics: epics, current: EpicFixture.deskId).rows(query: "").map { ($0.title, $0) })
        XCTAssertEqual(rows["Planned"]?.detail, "No items · Planned")
        XCTAssertEqual(rows["Review desk"]?.detail, "6 of 8 done · ▲ 2 days late")
        XCTAssertEqual(rows["Review desk"]?.label, "Review desk, 6 of 8 done · ▲ 2 days late, selected")
        XCTAssertTrue(rows["Epics"]?.detail?.hasPrefix("0 of 1 done · Due ") == true)
        XCTAssertEqual(rows["Old"]?.detail, "1 of 1 done · Done")
        XCTAssertNil(rows["New epic…"]?.detail)
        XCTAssertEqual(rows["No epic"]?.label, "No epic")
    }
}
