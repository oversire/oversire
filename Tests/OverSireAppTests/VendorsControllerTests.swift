import XCTest
import OverSireCore
@testable import OverSireApp

@MainActor
final class VendorsControllerTests: XCTestCase {
    private var clock = Date(timeIntervalSince1970: 2_000_000)
    private var offerCalls: [String] = []

    private func row(_ version: String = "0.2.2", job: VendorJob? = nil) -> VendorCLIRow {
        VendorCLIRow(provider: "plane", vendor: "Plane", binary: "plane-cli", path: "/x/\(version)/plane-cli", version: version,
                     minVersion: "0.2.0", source: .oversire, state: .ok, accounts: ["plane:ocral"], projects: [], ownVersion: version, job: job)
    }

    private func controller(rows: [VendorCLIRow]) -> VendorsController {
        let c = VendorsController()
        c.list = { rows }
        c.offer = { [unowned self] id in
            self.offerCalls.append(id)
            return .success("0.2.3")
        }
        c.changed = {}
        c.now = { [unowned self] in self.clock }
        return c
    }

    func testCheckAtMostOncePerHour() async {
        let c = controller(rows: [row()])
        await c.reload()
        XCTAssertEqual(offerCalls, ["plane"])
        XCTAssertEqual(c.offers["plane"], "0.2.3")
        XCTAssertEqual(c.checkedAt, clock)
        clock = clock.addingTimeInterval(600)
        await c.checkNow(force: false)
        XCTAssertEqual(offerCalls.count, 1, "a second check 10 min later makes no call")
        await c.checkNow(force: true)
        XCTAssertEqual(offerCalls.count, 2)
        clock = clock.addingTimeInterval(3601)
        await c.reload()
        XCTAssertEqual(offerCalls.count, 3, "an hour later a load checks again")
    }

    func testCheckSkipsHomebrewVendors() async {
        let gh = VendorCLIRow(provider: "github", vendor: "GitHub", binary: "gh", path: "/opt/homebrew/bin/gh", version: "2.102.0",
                              source: .path, state: .ok, accounts: [], projects: [])
        let c = controller(rows: [gh])
        await c.reload()
        XCTAssertTrue(offerCalls.isEmpty)
        XCTAssertNil(c.checkedAt)
    }

    func testInstallSetsBusyThenReloads() async {
        var rows = [row()]
        let c = controller(rows: [])
        c.list = { rows }
        await c.reload()
        var seen: VendorJob?
        c.installCall = { id in
            seen = c.busy[id]
            rows = [self.row("0.2.3")]
            return VendorOutcome(status: .ok, summary: "Updated plane-cli from 0.2.2 to 0.2.3.", change: nil)
        }
        await c.run(.installing, "plane")
        XCTAssertEqual(seen, .installing)
        XCTAssertNil(c.busy["plane"])
        XCTAssertNil(c.errors["plane"])
        XCTAssertEqual(c.rows.first?.version, "0.2.3")
    }

    func testInstallErrorIsKept() async {
        let c = controller(rows: [row()])
        await c.reload()
        let text = "The SHA-256 of plane-cli_darwin_arm64.tar.gz does not match. OverSire installs nothing."
        c.installCall = { _ in VendorOutcome(status: .failed, summary: text, change: nil) }
        await c.run(.installing, "plane")
        XCTAssertEqual(c.errors["plane"], VendorsModel.Failure(job: .installing, text: text))
        XCTAssertEqual(c.model(client: nil).lines.first?.badge, .failed("Install failed"))

        // A long install goes on in the app: the row shows its job, not an error.
        let slow = controller(rows: [row(job: .installing)])
        slow.installCall = { _ in VendorOutcome(status: .failed, summary: "The install of plane-cli goes on in the app.", change: nil) }
        await slow.run(.installing, "plane")
        XCTAssertNil(slow.errors["plane"])
    }

    func testRemoveCallsRemove() async {
        let c = controller(rows: [row()])
        var removed: [String] = []
        c.installCall = { _ in XCTFail("no install"); return VendorOutcome(status: .ok, summary: "", change: nil) }
        c.removeCall = { id in
            removed.append(id)
            return VendorOutcome(status: .ok, summary: "Removed the OverSire copy of plane-cli 0.2.2.", change: nil)
        }
        await c.run(.removing, "plane")
        XCTAssertEqual(removed, ["plane"])
        XCTAssertNil(c.busy["plane"])
        XCTAssertNil(c.errors["plane"])
    }
}
