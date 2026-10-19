import XCTest
@testable import OverSireApp

final class SettingsIndexTests: XCTestCase {
    private let sample = [
        SettingsIndex.Entry("Hide Done items", .runs),
        SettingsIndex.Entry("Poll every", .live, "polling"),
        SettingsIndex.Entry("Théme", .appearance),
        SettingsIndex.Entry("Explain failures", .use, "ci"),
    ]

    func testRanking() {
        let titles = { (q: String) in SettingsIndex.search(q, in: self.sample).map(\.title) }
        XCTAssertEqual(titles("poll"), ["Poll every"], "title prefix")
        XCTAssertEqual(titles("done"), ["Hide Done items"], "word prefix")
        XCTAssertEqual(titles("ail"), ["Explain failures"], "contains")
        let ranked = SettingsIndex.search("e", in: [SettingsIndex.Entry("Hide", .runs), SettingsIndex.Entry("Model engine", .engine), SettingsIndex.Entry("Endpoint", .engine)])
        XCTAssertEqual(ranked.map(\.title), ["Endpoint", "Model engine", "Hide"])
        XCTAssertTrue(titles("  ").isEmpty)
    }

    func testCaseAndAccentFolding() {
        XCTAssertEqual(SettingsIndex.search("THEME", in: sample).map(\.title), ["Théme"])
        XCTAssertEqual(SettingsIndex.search("théme", in: sample).map(\.title), ["Théme"])
    }

    func testEachPageAndAnchorHasEntries() {
        let anchors = Set(SettingsIndex.entries.map(\.anchor))
        XCTAssertEqual(anchors, Set(SettingsAnchor.allCases))
        XCTAssertEqual(Set(SettingsIndex.entries.map(\.anchor.page)), Set(Route.SettingsPage.allCases))
        for a in SettingsAnchor.allCases where a.page == .projects { XCTAssertNotNil(a.tab, a.rawValue) }
    }

    func testAnchorRoutesRoundTrip() {
        for a in SettingsAnchor.allCases {
            XCTAssertEqual(Route(path: a.route.path), a.route, a.rawValue)
        }
    }

    func testCommonSearches() {
        for (q, a) in [("webhook", SettingsAnchor.live), ("theme", .appearance), ("poll", .live), ("quiet", .queue)] {
            XCTAssertEqual(SettingsIndex.search(q).first?.anchor, a, q)
        }
    }
}
