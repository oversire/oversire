import XCTest
import OverSireCore
import OverSireSync
@testable import OverSireApp

/// The stream row of Settings and the live word of the service card (OVERSIRE-523).
final class LiveFeedRowTests: XCTestCase {
    private typealias Row = SettingsPage.StreamRowModel

    private func row(_ s: LiveFeedState) -> Row { SettingsPage.streamRow(s, pollMinutes: 5) }

    func testFeedRowTexts() {
        let polls = "Projects poll every 5 min."
        XCTAssertEqual(row(.live), Row(pill: "Live", tone: "ok", symbol: Tone.ok.symbol,
            tip: "Big Timer sends each change to this Mac. A project polls only when its data is older than 30 min.", action: nil))
        XCTAssertEqual(row(.connecting), Row(pill: "Connecting", tone: "running", symbol: Tone.running.symbol,
            tip: "OverSire opens the stream. Projects poll every 5 min meanwhile.", action: nil))
        XCTAssertEqual(row(.retrying(.transport("The connection dropped"))), Row(pill: "Polls · reconnects", tone: "warning", symbol: Tone.warning.symbol,
            tip: "The stream stopped: The connection dropped. \(polls) OverSire connects again soon.", action: "Connect again"))
        XCTAssertEqual(row(.stopped(.unauthorized)), Row(pill: "Token refused", tone: "bad", symbol: Tone.bad.symbol,
            tip: "Big Timer refused the token. \(polls) Edit the token on the Big Timer card.", action: "Connect again"))
        XCTAssertEqual(row(.stopped(.forbidden)), Row(pill: "No access", tone: "bad", symbol: Tone.bad.symbol,
            tip: "The token cannot read the stream. \(polls)", action: "Connect again"))
        XCTAssertEqual(row(.stopped(.notFound)), Row(pill: "Polls · no stream", tone: "idle", symbol: Tone.idle.symbol,
            tip: "This Big Timer server has no live stream. Update the server to get live updates. \(polls)", action: nil))
        XCTAssertEqual(row(.off), Row(pill: "Off", tone: "queued", symbol: Tone.queued.symbol,
            tip: "Add a token for this account to get live updates.", action: nil))
    }

    func testOtherStopsGiveFailed() {
        let m = row(.stopped(.transport("boom")))
        XCTAssertEqual(m.pill, "Failed")
        XCTAssertEqual(m.action, "Connect again")
    }

    func testCardFeedWord() {
        let word = { (s: [LiveFeedState]) in SettingsPage.feedWord(s, pollMinutes: 5) }
        XCTAssertNil(word([]))
        XCTAssertEqual(word([.live]), "Live")
        XCTAssertEqual(word([.connecting]), "Connecting…")
        XCTAssertEqual(word([.retrying(.transport("x"))]), "Polls every 5 min")
        XCTAssertEqual(word([.stopped(.unauthorized)]), "Polls every 5 min")
        XCTAssertEqual(word([.off]), "Polls every 5 min")
        XCTAssertEqual(word([.live, .stopped(.notFound)]), "1 of 2 live")
        XCTAssertEqual(word([.connecting, .off]), "Connecting…")
    }
}
