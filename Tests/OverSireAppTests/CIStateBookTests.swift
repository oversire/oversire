import XCTest
import OverSireCore
@testable import OverSireApp

@MainActor
final class CIStateBookTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func book(_ quota: CIQuota, repos: [String] = ["o/r", "o/none"]) -> CIStateBook {
        CIStateBook(quota: quota, repos: { repos },
                    info: { $0 == "o/r" ? ("GitHub Actions", [.logs, .rerun]) : nil }, clock: { [t0] in t0 })
    }

    private func state(_ b: CIStateBook) throws -> CIStateDoc {
        let d = b.doc()
        XCTAssertEqual(d.kind, .ciState)
        XCTAssertEqual(d.id, "home")
        return try MirrorCodec.value(CIStateDoc.self, from: XCTUnwrap(d.body))
    }

    func testListsReposWithInfoAndSortedCapabilities() throws {
        let b = book(CITestQuota.make())
        b.polled(["o/r"], at: t0.addingTimeInterval(5))
        let s = try state(b)
        XCTAssertEqual(s.repos.map(\.repo), ["o/r"], "a repo with no CI info is left out")
        XCTAssertEqual(s.repos[0].ci, "GitHub Actions")
        XCTAssertEqual(s.repos[0].capabilities, [Capability.logs.rawValue, Capability.rerun.rawValue].sorted())
        XCTAssertEqual(s.repos[0].polledAt, t0.addingTimeInterval(5))
    }

    func testQuotaFieldsAndSource() throws {
        let s = try state(book(CITestQuota.make(remaining: 100, live: { true })))
        XCTAssertTrue(s.degraded)
        XCTAssertEqual(s.source, .webhook)
        XCTAssertEqual(s.budget?.remaining, 100)
    }

    func testUnpolledRepoHasNoTime() throws {
        XCTAssertNil(try state(book(CITestQuota.make())).repos.first?.polledAt)
    }

    func testChangedMovesAsOf() throws {
        var now = t0
        let b = CIStateBook(quota: CITestQuota.make(), repos: { [] }, info: { _ in nil }, clock: { now })
        XCTAssertEqual(try state(b).asOf, t0)
        now = t0.addingTimeInterval(30)
        b.changed()
        XCTAssertEqual(try state(b).asOf, t0.addingTimeInterval(30))
    }

    func testSameStateGivesSameHash() {
        let b = book(CITestQuota.make())
        XCTAssertEqual(b.doc().hash, b.doc().hash)
    }
}
