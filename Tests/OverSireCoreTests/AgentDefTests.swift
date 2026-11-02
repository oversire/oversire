import XCTest
@testable import OverSireCore

/// The env rules of an agent and the merge with the env for all agents (OVERSIRE-399).
final class AgentDefTests: XCTestCase {
    private let shared = AgentSecretRef(agent: "claude", scope: AgentSecretRef.shared)

    func testKeyRules() {
        for k in ["A", "_x", "PLANE_ITEM", "a1_b2"] { XCTAssertTrue(AgentEnv.validKey(k), k) }
        for k in ["", "1A", "A-B", "A B", "É", "A=B"] { XCTAssertFalse(AgentEnv.validKey(k), k) }
        XCTAssertEqual(AgentEnv.problems([EnvVar(key: "1A", value: "x")]), [.badKey("1A")])
    }

    func testReservedKeys() {
        for k in ["OVERSIRE_SESSION", "AGENT_VISOR_HOME", "ORCA_PANE_KEY"] {
            XCTAssertEqual(AgentEnv.problems([EnvVar(key: k, value: "x")]), [.reserved(k)], k)
        }
        XCTAssertTrue(AgentEnv.problems([EnvVar(key: "OVERSIRE", value: "x")]).isEmpty, "only the prefix with _ is reserved")
    }

    func testDuplicateTooLongNoValueAndTooMany() {
        let env = [EnvVar(key: "A", value: "1"), EnvVar(key: "A", value: "2"), EnvVar(key: "B"),
                   EnvVar(key: "C", value: String(repeating: "x", count: AgentEnv.maxValue + 1))]
        XCTAssertEqual(AgentEnv.problems(env), [.duplicate("A"), .noValue("B"), .tooLong("C")])
        let many = (0...AgentEnv.maxRows).map { EnvVar(key: "K\($0)", value: "v") }
        XCTAssertEqual(AgentEnv.problems(many), [.tooMany])
    }

    func testPathWithoutPathIsAWarningOnly() {
        let p = AgentEnv.problems([EnvVar(key: "PATH", value: "/opt/bin")])
        XCTAssertEqual(p, [.pathReplaced])
        XCTAssertTrue(p[0].isWarning)
        XCTAssertTrue(AgentEnv.errors([EnvVar(key: "PATH", value: "/opt/bin")]).isEmpty)
        XCTAssertTrue(AgentEnv.problems([EnvVar(key: "PATH", value: "/opt/bin:$PATH")]).isEmpty)
    }

    func testPlaceholders() {
        XCTAssertEqual(AgentEnv.problems([EnvVar(key: "A", value: "{key}-{url}")]), [.unknownPlaceholder(key: "A", name: "url")])
        XCTAssertTrue(AgentEnv.problems([EnvVar(key: "A", value: #"${HOME} {"a":1} { name }"#)]).isEmpty, "a shell var and JSON are not placeholders")
        XCTAssertEqual(AgentEnv.fill("{name}|{KEY}|{key}|{title}|${HOME}|{other}", name: "n", key: "ENG-4", title: "A \"t\""),
                       #"n|ENG-4|eng-4|A "t"|${HOME}|{other}"#, "no shell quotes in an env value")
    }

    func testASecretRowHasNoValue() {
        let v = EnvVar(key: "TOKEN", value: "leak", secret: true)
        XCTAssertNil(v.value)
        XCTAssertTrue(AgentEnv.problems([v]).isEmpty)
    }

    func testMergeTheAgentWins() {
        let all = [EnvVar(key: "A", value: "all"), EnvVar(key: "B", value: "all"), EnvVar(key: "T", secret: true), EnvVar(key: "S", secret: true)]
        let own = [EnvVar(key: "B", value: "own {KEY}"), EnvVar(key: "T", value: "plain"), EnvVar(key: "S", secret: true), EnvVar(key: "N", secret: true)]
        let m = AgentEnv.merged(shared: all, agent: own, agentRef: shared, name: "x", key: "ENG-4", title: "t")
        XCTAssertEqual(m.env, ["A": "all", "B": "own ENG-4", "T": "plain"])
        XCTAssertEqual(m.secrets, ["S": shared, "N": shared])
    }

    func testMergeSecretRefs() {
        let local = AgentSecretRef(agent: "mine", scope: "app-1234")
        let m = AgentEnv.merged(shared: [EnvVar(key: "G", secret: true)], agent: [EnvVar(key: "L", secret: true)], agentRef: local,
                                name: "n", key: "K-1", title: "t")
        XCTAssertEqual(m.secrets["G"], AgentSecretRef(agent: AgentDef.allAgents, scope: AgentSecretRef.shared))
        XCTAssertEqual(m.secrets["L"], local, "a local agent keeps its secrets under the device of its Mac")
        XCTAssertTrue(m.env.isEmpty)
    }

    func testMergeSkipsBadRows() {
        let m = AgentEnv.merged(shared: [], agent: [EnvVar(key: "OVERSIRE_X", value: "1"), EnvVar(key: "1A", value: "1"), EnvVar(key: "OK", value: "1")],
                                agentRef: shared, name: "n", key: "k", title: "t")
        XCTAssertEqual(m.env, ["OK": "1"])
    }

    func testRunsOn() {
        XCTAssertTrue(AgentDef(name: "a").runs(on: "mba"))
        let d = AgentDef(name: "a", runsOn: ["mini"])
        XCTAssertTrue(d.runs(on: "mini"))
        XCTAssertFalse(d.runs(on: "mba"))
    }

    func testSameDefinitionIgnoresTheStamp() {
        let a = AgentDef(name: "a", model: "m", updatedAt: Date(timeIntervalSince1970: 1), updatedBy: "mba")
        var b = a
        b.updatedAt = Date(timeIntervalSince1970: 2)
        b.updatedBy = "mini"
        XCTAssertTrue(a.sameDefinition(as: b))
        b.model = "n"
        XCTAssertFalse(a.sameDefinition(as: b))
    }

    func testCommandSetsEnv() {
        XCTAssertTrue(AgentEnv.commandSetsEnv("FOO=1 claude"))
        XCTAssertFalse(AgentEnv.commandSetsEnv("claude --x=1"))
        XCTAssertFalse(AgentEnv.commandSetsEnv(""))
    }

    func testDaemonFeatures() {
        var i = DaemonInfo(machine: "mba", version: "1", contract: 1, roles: [], runtimes: [], harnesses: [], features: [DaemonInfo.launchEnv], listen: .init(loopback: "127.0.0.1:7690"))
        XCTAssertTrue(i.has(DaemonInfo.launchEnv))
        XCTAssertFalse(i.has(DaemonInfo.agentSecrets))
        i.features = nil
        XCTAssertFalse(i.has(DaemonInfo.launchEnv), "an old daemon has no features")
    }
}
