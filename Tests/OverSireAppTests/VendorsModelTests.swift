import XCTest
import OverSireCore
@testable import OverSireApp

private let now = Date(timeIntervalSince1970: 2_000_000)
private let ownPath = "/Users/me/.config/oversire/vendors/plane/0.2.2/plane-cli"

private func plane(_ version: String? = "0.2.2", source: VendorSource? = .oversire, state: VendorState? = .ok, path: String? = ownPath,
                   ownVersion: String? = nil, job: VendorJob? = nil) -> VendorCLIRow {
    VendorCLIRow(provider: "plane", vendor: "Plane", binary: "plane-cli", path: path, version: version, minVersion: "0.2.0",
                 source: source, state: state, accounts: ["plane:ocral"], projects: [],
                 ownVersion: ownVersion ?? (source == .oversire ? version : nil), job: job)
}

private func bigtimer(_ version: String? = "1.0.11", source: VendorSource? = .path, state: VendorState? = .old,
                      path: String? = "/opt/homebrew/bin/big-timer-cli") -> VendorCLIRow {
    VendorCLIRow(provider: "bigtimer", vendor: "Big Timer", binary: "big-timer-cli", path: path, version: version, minVersion: "1.0.12",
                 source: source, state: state, accounts: ["bigtimer:bt"], projects: [])
}

private func gh(installed: Bool) -> VendorCLIRow {
    VendorCLIRow(provider: "github", vendor: "GitHub", binary: "gh", path: installed ? "/opt/homebrew/bin/gh" : nil,
                 version: installed ? "2.102.0" : nil, source: installed ? .path : nil, state: installed ? .ok : .missing,
                 accounts: ["github:flarco"], projects: [])
}

private func model(_ rows: [VendorCLIRow], offers: [String: String] = ["plane": "0.2.3", "bigtimer": "1.0.12"], offerError: String? = nil,
                   busy: [String: VendorJob] = [:], errors: [String: VendorsModel.Failure] = [:], checkedAt: Date? = nil,
                   client: String? = nil) -> VendorsModel {
    VendorsModel(rows: rows, offers: offers, offerError: offerError, busy: busy, errors: errors, checkedAt: checkedAt, now: now, client: client)
}

private func line(_ row: VendorCLIRow, offers: [String: String] = ["plane": "0.2.3", "bigtimer": "1.0.12"]) -> VendorsModel.Line {
    model([row], offers: offers).lines[0]
}

final class VendorsModelTests: XCTestCase {
    func testOwnCopyUpToDate() {
        let l = line(plane("0.2.3", path: "/x/0.2.3/plane-cli"))
        XCTAssertEqual(l.badge, .ok)
        XCTAssertEqual(l.title, "plane-cli 0.2.3")
        XCTAssertEqual(l.buttons.map(\.kind), [.remove])
        XCTAssertEqual(l.buttons.first?.title, "Remove…")
    }

    func testOwnCopyWithUpdate() {
        let l = line(plane())
        XCTAssertEqual(l.badge, .ok)
        XCTAssertEqual(l.symbol, "paperplane")
        XCTAssertEqual(l.detail, "Plane · OverSire copy · \(ownPath)")
        XCTAssertEqual(l.buttons.map(\.title), ["Update to 0.2.3", "Remove…"])
        XCTAssertEqual(l.buttons.map(\.primary), [true, false])
        XCTAssertEqual(l.buttons.map(\.kind), [.update, .remove])
    }

    func testPathCopyOk() {
        let l = line(plane(source: .path, path: "/usr/local/bin/plane-cli", ownVersion: nil))
        XCTAssertEqual(l.badge, .ok)
        XCTAssertEqual(l.detail, "Plane · PATH copy · /usr/local/bin/plane-cli")
        XCTAssertEqual(l.buttons.map(\.title), ["Install"])
        XCTAssertEqual(l.buttons.first?.primary, false)
        XCTAssertEqual(l.buttons.first?.tip, "Install an OverSire copy. The PATH copy stays.")
    }

    func testPathCopyOld() {
        let l = line(bigtimer())
        XCTAssertEqual(l.badge, .old("Old: needs 1.0.12"))
        XCTAssertEqual(l.badge.word, "Old: needs 1.0.12")
        XCTAssertEqual(l.symbol, "timer")
        XCTAssertEqual(l.buttons.map(\.title), ["Install 1.0.12"])
        XCTAssertEqual(l.buttons.first?.primary, true)
        XCTAssertFalse(l.buttons.contains { $0.kind == .remove })
    }

    func testPathWinsOverOldOwn() {
        let l = line(plane(source: .path, path: "/usr/local/bin/plane-cli", ownVersion: "0.2.1"))
        XCTAssertEqual(l.badge, .ok)
        XCTAssertEqual(l.detail, "Plane · PATH copy · /usr/local/bin/plane-cli · OverSire copy 0.2.1 is old")
        XCTAssertEqual(l.buttons.map(\.title), ["Update to 0.2.3", "Remove…"])
        XCTAssertEqual(l.buttons.first?.primary, true)
    }

    func testMissing() {
        let row = plane(nil, source: nil, state: .missing, path: nil)
        let l = line(row, offers: ["plane": "0.2.2"])
        XCTAssertEqual(l.badge, .missing)
        XCTAssertEqual(l.title, "plane-cli")
        XCTAssertEqual(l.detail, "Plane · Not installed. vendor run refuses plane.")
        XCTAssertEqual(l.buttons.map(\.title), ["Install 0.2.2"])
        XCTAssertEqual(l.buttons.first?.primary, true)
        XCTAssertEqual(line(row, offers: [:]).buttons.map(\.title), ["Install"])
    }

    func testGhMissingShowsBrew() {
        let l = line(gh(installed: false))
        XCTAssertEqual(l.badge, .missing)
        XCTAssertEqual(l.detail, "GitHub · Not installed. Install it with Homebrew.")
        XCTAssertEqual(l.buttons.map(\.title), ["Install in Terminal…"])
        XCTAssertEqual(l.buttons.first?.kind, .brew("brew install gh"))
    }

    func testGhOkHasNoButtons() {
        let l = line(gh(installed: true))
        XCTAssertEqual(l.badge, .ok)
        XCTAssertEqual(l.detail, "GitHub · PATH copy · /opt/homebrew/bin/gh · gh keeps its own login")
        XCTAssertTrue(l.buttons.isEmpty)
    }

    func testBusyDisablesOnlyThatRow() {
        let m = model([plane(), bigtimer()], busy: ["plane": .installing])
        XCTAssertEqual(m.lines[0].badge, .installing)
        XCTAssertEqual(m.lines[0].buttons.map(\.title), ["Installing…", "Remove…"])
        XCTAssertTrue(m.lines[0].buttons.allSatisfy { !$0.enabled })
        XCTAssertTrue(m.lines[1].buttons.allSatisfy(\.enabled))
        let removing = model([plane()], busy: ["plane": .removing]).lines[0]
        XCTAssertEqual(removing.badge, .removing)
        XCTAssertEqual(removing.badge.word, "Removing…")
        XCTAssertTrue(removing.buttons.allSatisfy { !$0.enabled })
    }

    func testAgentJobShowsBusy() {
        let l = line(plane(job: .installing))
        XCTAssertEqual(l.badge, .installing)
        XCTAssertEqual(l.badge.word, "Installing…")
        XCTAssertTrue(l.badge.tone.spins)
    }

    func testFailedShowsErrorText() {
        let text = "The SHA-256 of plane-cli_darwin_arm64.tar.gz does not match. OverSire installs nothing."
        let l = model([plane()], errors: ["plane": .init(job: .installing, text: text)]).lines[0]
        XCTAssertEqual(l.badge, .failed("Install failed"))
        XCTAssertEqual(l.error, text)
        XCTAssertEqual(l.buttons.map(\.title), ["Try again", "Remove…"])
        XCTAssertEqual(l.buttons.first?.primary, true)
        let missing = model([plane(nil, source: nil, state: .missing, path: nil)], errors: ["plane": .init(job: .installing, text: text)]).lines[0]
        XCTAssertEqual(missing.buttons.map(\.title), ["Try again"], "no Remove without an OverSire copy")
        XCTAssertNil(model([plane()], busy: ["plane": .installing], errors: ["plane": .init(job: .installing, text: text)]).lines[0].error,
                     "a new job hides the old error")
    }

    func testOldAppRowsWithoutState() {
        let installed = line(VendorCLIRow(provider: "plane", vendor: "Plane", binary: "plane-cli", path: "/usr/local/bin/plane-cli", accounts: [], projects: []))
        XCTAssertEqual(installed.badge, .ok)
        XCTAssertEqual(installed.title, "plane-cli")
        let missing = line(VendorCLIRow(provider: "plane", vendor: "Plane", binary: "plane-cli", accounts: [], projects: []))
        XCTAssertEqual(missing.badge, .missing)
    }

    func testLabelsHaveStateWords() {
        let rows = [plane(), bigtimer(), gh(installed: true), gh(installed: false), plane(nil, source: nil, state: .missing, path: nil)]
        for l in model(rows).lines {
            XCTAssertTrue(l.label.contains(l.badge.word), l.label)
            let binary = l.title.split(separator: " ").first.map(String.init) ?? ""
            for b in l.buttons { XCTAssertTrue(b.label.contains(binary), b.label) }
        }
        XCTAssertEqual(model([plane()]).lines[0].label, "plane-cli 0.2.2, OverSire copy, OK, update to 0.2.3")
        XCTAssertEqual(model([plane()]).lines[0].buttons.map(\.label), ["Update plane-cli to 0.2.3", "Remove the OverSire copy of plane-cli"])
    }

    func testFooterTexts() {
        let m = model([plane()], checkedAt: now.addingTimeInterval(-300))
        XCTAssertEqual(m.footer, VendorsModel.footerText + " Last check for updates: 5 min ago.")
        XCTAssertNil(m.checkError)
        XCTAssertEqual(model([plane()]).footer, VendorsModel.footerText)
        let failed = model([plane()], offerError: VendorInstallError.rateLimited.description)
        XCTAssertEqual(failed.checkError, "Could not check for updates: GitHub allows 60 calls in one hour without a login. Try again later.")
    }

    func testClientAndEmptyTexts() {
        let empty = model([])
        XCTAssertTrue(empty.lines.isEmpty)
        XCTAssertEqual(empty.empty, "Add a Plane or Big Timer account to use its vendor CLI.")
        let client = model([plane()], client: "mbp")
        XCTAssertTrue(client.lines.isEmpty)
        XCTAssertEqual(client.empty, "OverSire runs the vendor CLIs on mbp. Install them there.")
        XCTAssertNil(model([plane()]).empty)
    }

    func testRemoveQuestion() {
        let q = VendorsModel.removeQuestion(plane(), pathCopy: ("/usr/local/bin/plane-cli", "0.2.2"))
        XCTAssertEqual(q.title, "Remove the OverSire copy of plane-cli 0.2.2?")
        XCTAssertEqual(q.info, "OverSire then uses /usr/local/bin/plane-cli 0.2.2 from PATH.")
        XCTAssertEqual(VendorsModel.removeQuestion(plane(), pathCopy: nil).info, "Then vendor run refuses plane until you install it again.")
    }
}
