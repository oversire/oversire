import OverSireCore
import XCTest
@testable import OverSireApp

/// A client sends the changes of the shared sections to home (OVERSIRE-529).
final class ClientSettingsTests: XCTestCase {
    /// The settings of this Mac, in place of the globals.
    final class Mac: @unchecked Sendable {
        var settings: HomeSettings
        init(_ s: HomeSettings) { settings = s }
    }

    final class Calls: @unchecked Sendable {
        var sent: [MemberCallRequest] = []
        var answer: @Sendable () throws -> AppCallResult = { AppCallResult(id: "1", status: .ok, summary: "saved") }
    }

    private let base = homeSettings(from: AppConfig(repos: ["o/r"]))

    private func rig() throws -> (ClientSettings, Mac, Calls) {
        let cs = ClientSettings()
        let mac = Mac(base), calls = Calls()
        cs.current = { mac.settings }
        cs.adopt = { mac.settings = $0 }
        cs.changed = {}
        cs.sent = {}
        cs.sourceName = { "mbp" }
        cs.call = { [calls] req in
            calls.sent.append(req)
            return try calls.answer()
        }
        cs.received(try MirrorCodec.body(base))
        return (cs, mac, calls)
    }

    private func flip(_ mac: Mac) {
        var c = AppConfig(repos: ["o/r"])
        var a = AgentsConfig()
        a.autoStart = !base.agents.autoStart
        c.agents = a
        mac.settings = homeSettings(from: c)
    }

    private func wait(_ cs: ClientSettings, until ok: (ClientSettings.SaveState) -> Bool) async {
        for _ in 0..<400 where !ok(cs.state) { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testSendsOnlyTheChangedSection() async throws {
        let (cs, mac, calls) = try rig()
        flip(mac)
        cs.sync()
        XCTAssertEqual(cs.state, .saving)
        await wait(cs) { $0 == .idle }
        XCTAssertEqual(cs.state, .idle)
        XCTAssertEqual(calls.sent.count, 1)
        let args = calls.sent[0].args
        XCTAssertEqual(calls.sent[0].action, "settings.patch")
        XCTAssertEqual(args["section"]?.string, "agents")
        XCTAssertEqual(args["baseHash"]?.string, base.hashes["agents"])
        XCTAssertEqual(cs.home?.agents.autoStart, mac.settings.agents.autoStart)
        cs.sync()
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(calls.sent.count, 1)
    }

    func testOverlayLaysTheCachedValueOverAConfig() throws {
        let cs = ClientSettings()
        let body = try MirrorCodec.body(base)
        cs.cached = { body }
        var c = AppConfig(repos: ["old/old"])
        cs.overlay(&c)
        XCTAssertEqual(c.repos, ["o/r"])
        XCTAssertEqual(cs.home?.repos, ["o/r"])
        cs.cached = { nil }
        var d = AppConfig(repos: ["old/old"])
        ClientSettings().overlay(&d)
        XCTAssertEqual(d.repos, ["old/old"])
    }

    func testSendsNothingForALocalChange() throws {
        let (cs, _, calls) = try rig()
        cs.sync()
        XCTAssertEqual(cs.state, .idle)
        XCTAssertTrue(calls.sent.isEmpty)
    }

    func testConflictRestoresHomeValue() async throws {
        let (cs, mac, calls) = try rig()
        calls.answer = { AppCallResult(id: "1", status: .failed, summary: "Changed on mbp. Look again.", data: .object(["conflict": .bool(true)])) }
        flip(mac)
        cs.sync()
        await wait(cs) { $0 == .conflict }
        XCTAssertEqual(cs.state, .conflict)
        XCTAssertEqual(mac.settings.agents.autoStart, base.agents.autoStart)
    }

    func testFailureKeepsTheValueAndRetrySendsAgain() async throws {
        let (cs, mac, calls) = try rig()
        calls.answer = { throw ProviderError.transport("down") }
        flip(mac)
        let mine = mac.settings.agents.autoStart
        cs.sync()
        await wait(cs) { if case .failed = $0 { return true } else { return false } }
        XCTAssertEqual(cs.state, .failed("mbp did not answer. Try again."))
        XCTAssertEqual(mac.settings.agents.autoStart, mine)
        // A new home value does not undo the change that is not saved.
        cs.received(try MirrorCodec.body(base))
        XCTAssertEqual(mac.settings.agents.autoStart, mine)
        calls.answer = { AppCallResult(id: "2", status: .ok, summary: "saved") }
        cs.retry()
        await wait(cs) { $0 == .idle }
        XCTAssertEqual(cs.state, .idle)
        XCTAssertEqual(calls.sent.count, 2)
    }

    func testRefusalShowsItsText() async throws {
        let (cs, mac, calls) = try rig()
        calls.answer = { AppCallResult(id: "1", status: .notAllowed, summary: "Unknown section.") }
        flip(mac)
        cs.sync()
        await wait(cs) { $0 != .saving }
        XCTAssertEqual(cs.state, .failed("Unknown section."))
    }

    func testReceivedLaysTheHomeValueOverTheMac() throws {
        let (cs, mac, _) = try rig()
        var c = AppConfig(repos: ["o/r", "x/y"])
        c.agents = AgentsConfig()
        try cs.received(MirrorCodec.body(homeSettings(from: c)))
        XCTAssertEqual(mac.settings.repos, ["o/r", "x/y"])
    }

    func testSkipsABodyOfANewerVersion() throws {
        let (cs, mac, _) = try rig()
        var body = try MirrorCodec.body(homeSettings(from: AppConfig(repos: ["z/z"])))
        var o = body.object ?? [:]
        o["v"] = .int(HomeSettings.version + 1)
        body = .object(o)
        cs.received(body)
        XCTAssertEqual(mac.settings.repos, ["o/r"])
    }
}
