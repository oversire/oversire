import XCTest
@testable import OverSireApp

final class HealthCountsTests: XCTestCase {
    private func counts(_ ok: Int, _ warn: Int, _ bad: Int) -> HealthCounts {
        HealthCounts([.init(count: ok, kind: .ok, word: "live"), .init(count: warn, kind: .warning, word: "missing"),
                      .init(count: bad, kind: .failure, word: "failed")])
    }

    func testFractions() {
        let c = counts(48, 2, 1)
        XCTAssertEqual(c.total, 51)
        XCTAssertEqual(c.fractions.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(c.fractions[0], 48.0 / 51, accuracy: 1e-9)
        XCTAssertEqual(c.fractions[2], 1.0 / 51, accuracy: 1e-9)
    }

    func testLabel() {
        XCTAssertEqual(counts(48, 2, 1).label, "48 live, 2 missing, 1 failed")
        XCTAssertEqual(counts(51, 0, 0).label, "51 live", "a zero part is not in the label")
    }

    func testZero() {
        let c = counts(0, 0, 0)
        XCTAssertEqual(c.total, 0)
        XCTAssertEqual(c.fractions, [0, 0, 0])
        XCTAssertEqual(c.label, "None")
    }
}
