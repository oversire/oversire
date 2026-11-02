import XCTest
import OverSireCore
@testable import OverSireApp

/// The text of Settings › Agents and the table on Settings › Machines (OVERSIRE-399).
final class AgentsModelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_650_000)
    private var places: AgentPlaces {
        AgentPlaces(this: "mbp", home: "mini", homeOnline: true, machines: [
            AgentPlace(name: "mbp", features: [DaemonInfo.launchEnv, DaemonInfo.agentSecrets]),
            AgentPlace(name: "mini", home: true, features: [DaemonInfo.launchEnv, DaemonInfo.agentSecrets]),
            AgentPlace(name: "mba", sessions: true, features: [DaemonInfo.launchEnv]),
        ])
    }
    private var claude: CatalogAgent {
        CatalogAgent(scope: .shared, def: AgentDef(name: "claude", cli: "claude", env: [EnvVar(key: "BASE", value: "x"), EnvVar(key: "TOKEN", secret: true)],
                                                   updatedAt: now.addingTimeInterval(-7200), updatedBy: "mba"))
    }
    private var mine: CatalogAgent {
        CatalogAgent(scope: .local, def: AgentDef(name: "mine", cli: "claude", runsOn: ["mbp"], updatedAt: .distantPast))
    }

    private func model(keys: [AgentSecretKey]? = nil, places p: AgentPlaces? = nil, offer: [String] = []) -> AgentsModel {
        AgentsModel(shared: [claude], local: [mine], offer: offer, places: p ?? places, keys: keys, device: "app-1", now: now)
    }

    func testRows() {
        let m = model()
        XCTAssertEqual(m.shared.first?.env, "Env 2 · 1 secret")
        XCTAssertEqual(m.shared.first?.edited, "edited on mba · 2 h ago")
        XCTAssertEqual(m.shared.first?.runs, "any machine")
        XCTAssertNil(m.shared.first?.refusal)
        XCTAssertEqual(m.local.first?.runs, "only on mbp")
        XCTAssertEqual(m.local.first?.refusal, "mine runs only on mbp. Run sessions on is mba.")
        XCTAssertNil(m.local.first?.edited)
        XCTAssertEqual(m.localTitle, "This Mac only · mbp")
        XCTAssertEqual(m.localCount, "1 agent · only this app sees them")
        XCTAssertEqual(m.sharedCount, "1 agent")
        XCTAssertTrue(m.shared[0].missing.isEmpty, "keys not read: nothing is missing")
    }

    func testEnvChip() {
        XCTAssertNil(AgentsModel.envChip([]))
        XCTAssertEqual(AgentsModel.envChip([EnvVar(key: "A", value: "1")]), "Env 1")
        XCTAssertEqual(AgentsModel.envChip([EnvVar(key: "A", secret: true), EnvVar(key: "B", secret: true)]), "Env 2 · 2 secrets")
    }

    func testHomeChipAndOffline() {
        XCTAssertEqual(model().homeChip.text, "Home: mini · synced")
        XCTAssertNil(model().offline)
        var p = places
        p.homeOnline = false
        let off = model(places: p)
        XCTAssertEqual(off.homeChip.text, "Home: mini · offline")
        XCTAssertFalse(off.homeChip.ok)
        XCTAssertTrue(off.offline?.contains("only mini has the value") == true)
        p.home = nil
        XCTAssertEqual(model(places: p).homeChip.text, "No home daemon")
        XCTAssertTrue(model(places: p).intro.contains("Make a group"))
    }

    func testOffer() {
        XCTAssertNil(model().offer)
        XCTAssertEqual(model(offer: ["mine"]).offer, "1 agent is on this Mac only: mine. Share it with all your Macs?")
        XCTAssertEqual(model(offer: ["a", "b"]).offer, "2 agents are on this Mac only: a, b. Share them with all your Macs?")
    }

    func testMissingSecretAndNote() {
        let key = AgentSecretKey(scope: AgentSecretRef.shared, agent: "claude", key: "TOKEN", setAt: now.addingTimeInterval(-3 * 86400))
        XCTAssertEqual(model(keys: []).shared[0].missing, ["TOKEN"])
        let m = model(keys: [key])
        XCTAssertTrue(m.shared[0].missing.isEmpty)
        XCTAssertEqual(m.secretNote(agent: "claude", scope: AgentSecretRef.shared, key: "TOKEN").text, "kept on mini · set 3 d ago")
        XCTAssertTrue(m.secretNote(agent: "claude", scope: "app-1", key: "TOKEN").missing, "another scope has no value")
        XCTAssertEqual(model().secretNote(agent: "claude", scope: AgentSecretRef.shared, key: "TOKEN").text, "kept on mini")
        XCTAssertTrue(m.missingText("TOKEN").hasPrefix("mini has no value for TOKEN."))
    }

    func testPreviewHidesSecretValues() {
        var l = AgentLaunch(profile: "claude", cli: "claude")
        XCTAssertEqual(AgentsModel.preview(l, places: places).on, "on mba (Run sessions on)")
        XCTAssertNil(AgentsModel.preview(l, places: places).env)
        l.env = ["B": "a b", "A": "1"]
        l.envSecrets = ["TOKEN": AgentSecretRef(agent: "claude", scope: AgentSecretRef.shared)]
        let p = AgentsModel.preview(l, places: places)
        XCTAssertEqual(p.on, "on mba (Run sessions on) · secrets from mini")
        XCTAssertEqual(p.env, "A=1 B='a b' TOKEN=••••••")
        l.runsOn = ["mbp"]
        XCTAssertTrue(AgentsModel.preview(l, places: places).on.hasPrefix("✕ claude runs only on mbp."))
    }

    func testMachineTable() {
        var p = places
        p.machines.append(AgentPlace(name: "old", online: false))
        let t = AgentMachineTable(agents: [claude, mine], defaults: ["codex"], places: p, this: "mbp")
        XCTAssertEqual(t.columns.map(\.name), ["mbp", "mini", "mba", "old"])
        XCTAssertEqual(t.columns[0].note, "this Mac · live")
        XCTAssertEqual(t.columns[2].note, "sessions · live")
        XCTAssertEqual(t.columns[3].note, "offline")
        XCTAssertEqual(t.lines.map(\.name), ["claude", "mine", "codex", "secrets"])
        XCTAssertEqual(t.lines[0].cells, ["✓ ready", "✓ ready", "✕ old oversire: no secrets", "○ offline"])
        XCTAssertEqual(t.lines[1].note, "this Mac only")
        XCTAssertEqual(t.lines[1].cells, ["✓ ready", "— not on its list", "— not on its list", "— not on its list"])
        XCTAssertEqual(t.lines[2].note, "default")
        XCTAssertEqual(t.lines[3].note, "from mini")
        XCTAssertEqual(t.lines[3].cells, ["✓ reaches mini", "✓ keeps them", "✕ old oversire", "○ offline"])

        p.homeOnline = false
        p.machines[1].online = false
        let off = AgentMachineTable(agents: [claude], places: p, this: "mbp")
        XCTAssertEqual(off.lines[0].cells[0], "△ home offline")
        XCTAssertEqual(off.lines[1].cells[0], "△ mini offline")
    }
}
