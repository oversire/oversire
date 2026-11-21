import OverSireCore
import XCTest
@testable import OverSireApp

/// The shared settings of a client are the home settings (OVERSIRE-529).
final class HomeSettingsTests: XCTestCase {
    private var agents: AgentsConfig!
    private var general: GeneralConfig!

    override func setUp() {
        agents = AGENTS
        general = GENERAL
    }

    override func tearDown() {
        AGENTS = agents
        GENERAL = general
    }

    func testAgentsConfigWithoutCIDecodesDefaults() throws {
        let c = try JSONDecoder().decode(AgentsConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(c.ci, AgentCIRights(cancel: true, approve: false))
        let off = try JSONDecoder().decode(AgentsConfig.self, from: Data(#"{"ci":{"approve":true}}"#.utf8))
        XCTAssertEqual(off.ci, AgentCIRights(cancel: true, approve: true))
    }

    func testHasNoSecrets() throws {
        var c = AppConfig(repos: ["o/r"])
        c.accounts = [AccountConfig(account: AccountID(provider: "plane", id: "ocral"), values: ["token": "sk-secret-token"], secretKeys: ["token"])]
        var ai = AIConfig()
        ai.baseURL = "https://ai.example.com/secret-base"
        ai.model = "secret-model"
        c.ai = ai
        let list = [AccountSummary(kind: "tracker", provider: "plane", displayName: "Plane", detail: "ocral", status: "ok", features: ["intake"])]
        let h = homeSettings(from: c, accounts: list)
        let text = String(decoding: MirrorCodec.bytes(try MirrorCodec.body(h)), as: UTF8.self)
        XCTAssertFalse(text.contains("sk-secret-token"))
        XCTAssertFalse(text.contains("secret-base"))
        XCTAssertFalse(text.contains("secret-model"))
        XCTAssertTrue(text.contains("ocral"))
    }

    func testApplyKeepsLocalSections() {
        var c = AppConfig(repos: ["a/b"])
        var g = GeneralConfig()
        g.openWindowAtLaunch = true
        c.general = g
        c.mode = .client
        var p = ProjectsConfig()
        p.menuDot = false
        p.order = ["X/1"]
        c.projects = p
        var other = AppConfig(repos: ["c/d"])
        var shared = ProjectsConfig()
        shared.pollMinutes = 9
        other.projects = shared
        var a = AgentsConfig()
        a.autoStart = false
        other.agents = a
        apply(homeSettings(from: other), to: &c)
        XCTAssertEqual(c.repos, ["c/d"])
        XCTAssertEqual(c.agents?.autoStart, false)
        XCTAssertEqual(c.projects?.pollMinutes, 9)
        XCTAssertEqual(c.general, g)
        XCTAssertEqual(c.mode, .client)
        XCTAssertEqual(c.projects?.menuDot, false)
        XCTAssertEqual(c.projects?.order, ["X/1"])
    }

    func testChangedSectionsByHash() {
        let before = homeSettings(from: currentConfig())
        AGENTS.autoStart.toggle()
        XCTAssertEqual(homeSettings(from: currentConfig()).changed(since: before), [.agents])
        AGENTS = agents
        GENERAL.openWindowAtLaunch.toggle()
        XCTAssertEqual(homeSettings(from: currentConfig()).changed(since: before), [])
    }

    func testClientMergeKeepsSharedFromFile() {
        let file = currentConfig()
        AGENTS.autoStart.toggle()
        GENERAL.openWindowAtLaunch.toggle()
        let memory = currentConfig()
        let merged = memory.clientMerge(file: file)
        XCTAssertEqual(merged.agents, file.agents)
        XCTAssertEqual(merged.general, memory.general)
        XCTAssertNotEqual(merged.general, file.general)
    }

    func testSectionHashesAreStableAfterTheWire() throws {
        var c = AppConfig(repos: ["o/r"])
        c.repoColors = ["o/r": 3]
        let h = homeSettings(from: c)
        let back = try MirrorCodec.value(HomeSettings.self, from: try MirrorCodec.body(h))
        XCTAssertEqual(back, h)
        for s in SettingsSection.allCases { XCTAssertEqual(HomeSettings.hash(back.value(s)), h.hashes[s.rawValue], "\(s)") }
    }

    func testAdoptingTakesOneSection() {
        var a = AppConfig(repos: ["a/a"])
        var b = AppConfig(repos: ["b/b"])
        var ag = AgentsConfig()
        ag.autoStart = false
        b.agents = ag
        let merged = homeSettings(from: a).adopting(.agents, from: homeSettings(from: b))
        XCTAssertEqual(merged.repos, ["a/a"])
        XCTAssertEqual(merged.agents.autoStart, false)
        XCTAssertEqual(merged.changed(since: homeSettings(from: a)), [.agents])
        a.agents = ag
        XCTAssertEqual(merged.hashes, homeSettings(from: a).adopting(.repos, from: homeSettings(from: AppConfig(repos: ["a/a"]))).hashes)
    }

    func testKeysOfASection() {
        let old = homeSettings(from: AppConfig(repos: []))
        var c = AppConfig(repos: [])
        var a = AgentsConfig()
        a.autoStart = false
        a.quietMinutes = 20
        c.agents = a
        XCTAssertEqual(homeSettings(from: c).keys(of: .agents, since: old), ["autoStart", "quietMinutes"])
    }
}
