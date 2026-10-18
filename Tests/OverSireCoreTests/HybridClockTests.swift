import XCTest
import OverSireCore

final class HybridClockTests: XCTestCase {
    final class Wall: @unchecked Sendable {
        var ms: Double = 1_790_000_000_000
        var date: Date { Date(timeIntervalSince1970: ms / 1000) }
    }

    func testFormat() {
        XCTAssertEqual(HybridClock.stamp(ms: 1_790_000_000_000, counter: 2, device: "mac-ada"), "001790000000000-000002-mac-ada")
        XCTAssertEqual(HybridClock.parse("001790000000000-000002-mac-ada")?.ms, 1_790_000_000_000)
        XCTAssertEqual(HybridClock.parse("001790000000000-000002-mac-ada")?.counter, 2)
        XCTAssertNil(HybridClock.parse("1790000000000-2-mac"))
    }

    func testSameMillisecondCounts() {
        let wall = Wall()
        let c = HybridClock(device: "a", now: { wall.date })
        let s = (0..<3).map { _ in c.next() }
        XCTAssertEqual(s, ["001790000000000-000000-a", "001790000000000-000001-a", "001790000000000-000002-a"])
        wall.ms += 1
        XCTAssertEqual(c.next(), "001790000000001-000000-a", "a new millisecond starts the counter again")
    }

    func testClockSkew() {
        let wall = Wall()
        let c = HybridClock(device: "a", now: { wall.date })
        let first = c.next()
        wall.ms -= 5000
        let back = c.next()
        XCTAssertGreaterThan(back, first, "the wall clock went back")

        let remote = HybridClock.stamp(ms: 1_790_000_060_000, counter: 4, device: "phone")
        c.observe(remote)
        let after = c.next()
        XCTAssertGreaterThan(after, remote, "a stamp after a remote one from a fast clock is larger")
        XCTAssertEqual(HybridClock.parse(after)?.counter, 5)
    }

    func testDeviceBreaksATie() {
        XCTAssertLessThan(HybridClock.stamp(ms: 1, counter: 0, device: "mac-ada"), HybridClock.stamp(ms: 1, counter: 0, device: "phone-ada"))
        XCTAssertLessThan(HybridClock.stamp(ms: 9, counter: 0, device: "z"), HybridClock.stamp(ms: 10, counter: 0, device: "a"))
    }
}
