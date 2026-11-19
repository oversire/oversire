import XCTest
@testable import OverSireApp

final class PlanVisitsTests: XCTestCase {
    func testSinceFixedDuringVisit() {
        let suite = "plan-visits-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var now = Date(timeIntervalSince1970: 1_000_000)
        let v = PlanVisits(defaults: defaults, now: { now })

        v.enter("oversire")
        XCTAssertNil(v.since("OVERSIRE"), "the first visit has no since")
        now += 3600
        v.leave("OVERSIRE")
        let first = now

        now += 86_400
        v.enter("OVERSIRE")
        XCTAssertEqual(v.since("OVERSIRE"), first)
        now += 600
        v.enter("OVERSIRE")
        XCTAssertEqual(v.since("OVERSIRE"), first, "a second enter in the same visit keeps since")
        v.leave("OVERSIRE")
        XCTAssertNil(v.since("OVERSIRE"), "no visit is open")

        let again = PlanVisits(defaults: defaults, now: { now })
        again.enter("OVERSIRE")
        XCTAssertEqual(again.since("OVERSIRE"), now, "the stamp is in UserDefaults")
    }
}
