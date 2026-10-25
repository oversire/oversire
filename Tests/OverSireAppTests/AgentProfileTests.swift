import OverSireCore
import XCTest
@testable import OverSireApp

final class AgentProfileTests: XCTestCase {
    private func config(_ json: String) throws -> RuntimeConfig {
        try JSONDecoder().decode(RuntimeConfig.self, from: Data(json.utf8))
    }

    func testAnOldAgentGetsItsCLIFromTheCommand() throws {
        let r = try config(#"{"agent":"work","commands":{"work":"claude --dangerously-skip-permissions","fast":"/opt/bin/codex --full-auto","wild":"my-tool"}}"#)
        XCTAssertTrue(r.profiles.isEmpty, "the decode does not change the config")
        XCTAssertEqual(r.profile("work"), AgentProfile(cli: "claude"))
        XCTAssertEqual(r.profile("fast").cli, "codex", "a path gives its last part")
        XCTAssertNil(r.profile("wild").cli, "an unknown program is terminal only")
        XCTAssertEqual(r.profile("gemini"), AgentProfile(cli: "gemini"), "a built-in CLI is its own agent")
        XCTAssertEqual(RuntimeConfig.baseCLI("cursor-agent"), "cursor")
        let again = try JSONDecoder().decode(RuntimeConfig.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(again, r)
    }

    func testABuiltInCLIAtAutoSavesNoEntry() {
        var r = RuntimeConfig()
        r.setProfile("claude", AgentProfile(cli: "claude", model: "claude-opus-5-5", effort: "high"))
        XCTAssertEqual(r.profiles["claude"]?.effort, "high")
        r.setProfile("claude", AgentProfile(cli: "claude"))
        XCTAssertNil(r.profiles["claude"])
        r.add("claude-max", cli: "claude")
        r.setProfile("claude-max", AgentProfile(cli: "claude"))
        XCTAssertNotNil(r.profiles["claude-max"], "an added agent keeps its entry")
    }

    func testDuplicateCopiesTheCommandModelAndEffort() {
        var r = RuntimeConfig()
        r.setCommand("claude", "claude --dangerously-skip-permissions")
        r.setProfile("claude", AgentProfile(cli: "claude", model: "claude-opus-5-5", effort: "high"))
        r.duplicate("claude", as: "claude-max")
        XCTAssertEqual(r.command(for: "claude-max").template, "claude --dangerously-skip-permissions")
        XCTAssertEqual(r.profile("claude-max"), AgentProfile(cli: "claude", model: "claude-opus-5-5", effort: "high"))
        r.remove("claude-max")
        XCTAssertNil(r.commands["claude-max"])
        XCTAssertNil(r.profiles["claude-max"])
        XCTAssertFalse(r.agents.contains("claude-max"))
    }

    func testAddStartsWithTheDefaultCommandOfTheCLI() {
        var r = RuntimeConfig()
        r.add("codex-deep", cli: "codex")
        XCTAssertEqual(r.command(for: "codex-deep").template, LaunchCommand.defaultFor(.codex).template)
        XCTAssertEqual(r.profile("codex-deep"), AgentProfile(cli: "codex"))
        r.add("gemini-work", cli: nil)
        XCTAssertEqual(r.command(for: "gemini-work").template, "gemini-work")
        XCTAssertNil(r.profile("gemini-work").cli)
        XCTAssertTrue(r.startAgents.contains("codex-deep"))
    }

    func testLaunchCarriesModelAndEffort() {
        var r = RuntimeConfig()
        r.add("claude-max", cli: "claude")
        r.setProfile("claude-max", AgentProfile(cli: "claude", model: "claude-opus-5-5", effort: "max"))
        let l = r.launch("claude-max", name: "x", key: "X-1", title: "t")
        XCTAssertEqual(l, AgentLaunch(profile: "claude-max", cli: "claude", model: "claude-opus-5-5", effort: "max",
                                      command: try? r.command(for: "claude-max").resolve(name: "x", key: "X-1", title: "t")))
        XCTAssertFalse(l.terminalOnly)

        let auto = r.launch("claude", name: "x", key: "X-1", title: "t")
        XCTAssertNil(auto.model)
        XCTAssertNil(auto.effort, "Auto sends no value")

        r.setProfile("opencode", AgentProfile(cli: "opencode", model: "kimi", effort: "high"))
        let oc = r.launch("opencode", name: "x", key: "X-1", title: "t")
        XCTAssertEqual(oc.model, "kimi")
        XCTAssertNil(oc.effort, "opencode has no effort")

        r.add("gemini-work", cli: nil)
        let term = r.launch("gemini-work", name: "x", key: "X-1", title: "t")
        XCTAssertEqual(term.cli, "gemini-work")
        XCTAssertNil(term.model)
        XCTAssertTrue(term.terminalOnly)
    }

    func testApplySetsTheLaunchRequest() {
        var req = LaunchRequest(repo: "/src/r", agent: .claude, prompt: "p")
        req.apply(AgentLaunch(profile: "codex-deep", cli: "codex", model: "gpt-5.5", effort: "high", command: "codex -c x"))
        XCTAssertEqual(req.agent, .codex)
        XCTAssertEqual(req.profile, "codex-deep")
        XCTAssertEqual(req.model, "gpt-5.5")
        XCTAssertEqual(req.effort, "high")
        XCTAssertEqual(req.command, "codex -c x")
        req.apply(AgentLaunch(profile: "claude", cli: "claude"))
        XCTAssertNil(req.model)
        XCTAssertEqual(req.command, "codex -c x", "a nil command keeps the request command")
    }

    func testFlagsFollowTheDaemonAndTheCommandWins() {
        let claude = AgentProfile(cli: "claude", model: "claude-opus-5-5", effort: "max")
        XCTAssertEqual(claude.flags(for: LaunchCommand("claude")), ["--model", "claude-opus-5-5", "--effort", "max"])
        XCTAssertEqual(claude.flags(for: LaunchCommand("claude --model=sonnet")), ["--effort", "max"], "the template wins")
        XCTAssertEqual(claude.flags(for: LaunchCommand("claude --effort low")), ["--model", "claude-opus-5-5"])
        let codex = AgentProfile(cli: "codex", model: "gpt-5.5", effort: "max")
        XCTAssertEqual(codex.flags(for: LaunchCommand("codex")), ["-m", "gpt-5.5", "-c", "model_reasoning_effort=xhigh"])
        XCTAssertEqual(codex.flags(for: LaunchCommand("codex -c 'model_reasoning_effort=low'")), ["-m", "gpt-5.5"])
        XCTAssertEqual(AgentProfile(cli: "gemini", model: "g", effort: "high").flags(for: LaunchCommand("gemini")), ["--model", "g"])
        XCTAssertEqual(AgentProfile(cli: nil, model: "g").flags(for: LaunchCommand("x")), [])
    }

    func testGroupsHoldEachCLIWithMoreAgents() {
        var r = RuntimeConfig()
        r.add("claude-max", cli: "claude")
        r.add("gemini-2", cli: "gemini")
        r.add("gemini-work", cli: nil)
        let g = r.agentGroups
        XCTAssertEqual(g.first?.cli, "claude")
        XCTAssertEqual(g.first?.agents, ["claude", "claude-max"])
        XCTAssertEqual(g.first { $0.cli == "codex" }?.agents, ["codex"], "codex has its own group")
        XCTAssertEqual(g.first { $0.cli == "gemini" }?.agents, ["gemini", "gemini-2"])
        let rest = try? XCTUnwrap(g.last)
        XCTAssertNil(rest?.cli)
        XCTAssertTrue(rest?.agents.contains("opencode") ?? false)
        XCTAssertEqual(rest?.agents.last, "gemini-work", "terminal-only agents go last")
    }

    func testProjectAgentIsTheStandardOfTheChip() {
        var cfg = SessionConfig()
        cfg.lastProject = "ocral/o"
        var m = NewSessionModel(choices: [.init(key: "OVERSIRE", name: "OverSire", store: "ocral/o", root: "/src/o", agent: "codex"),
                                          .init(key: "SLING", name: "Sling", store: "ocral/s", root: "/src/s")],
                                cfg: cfg, agent: "claude")
        XCTAssertEqual(m.standard, "codex")
        XCTAssertEqual(m.agent, "codex")
        m.pickAgent("claude-max")
        XCTAssertEqual(m.agent, "claude-max")
        m.pick("ocral/s")
        XCTAssertEqual(m.standard, "claude")
        XCTAssertEqual(m.agent, "claude-max", "the pick stays for this start")
        m.pickAgent("claude")
        XCTAssertNil(m.picked, "a pick of the standard agent follows the project again")
        XCTAssertEqual(m.termName.prefix(7), "claude-")
    }

    func testModelBookWarnsWhenTheListIsNotFromTheSessionsMachine() {
        let book = AgentModelBook(daemon: { nil }, local: { _ in [] })
        book.seed(["claude": .init(models: [AgentModel(id: "claude-opus-5-5", name: "Opus 5.5")], warning: nil)])
        let p = AgentProfile(cli: "claude", model: "claude-opus-5-5", effort: "max")
        XCTAssertNil(book.warning(p))
        XCTAssertEqual(book.detail(p), "Opus 5.5 · Max")
        XCTAssertEqual(book.label("claude-max", p), "claude-max · Opus 5.5 · Max")
        XCTAssertEqual(book.detail(AgentProfile(cli: "opencode", effort: "high")), "Auto", "no effort for opencode")
        XCTAssertEqual(book.detail(AgentProfile(cli: nil)), "terminal only")
        var other = p
        other.model = "claude-old"
        XCTAssertEqual(book.warning(other), "The sessions machine does not list claude-old. The start still goes.")
        book.seed(["claude": .init(models: [AgentModel(id: "claude-opus-5-5", name: "Opus 5.5")], warning: "mbp gives no models for claude.")])
        XCTAssertEqual(book.warning(p), "mbp gives no models for claude.")
        XCTAssertNil(book.warning(AgentProfile(cli: "claude")), "Auto has no warning")
    }

    func testModelBookFallsBackToThisMac() async {
        let book = AgentModelBook(daemon: { nil }, local: { _ in [AgentModel(id: "default", name: "Default"), AgentModel(id: "m1", name: "M1")] })
        let done = expectation(forNotification: AgentModelBook.changed, object: book)
        book.load("claude")
        await fulfillment(of: [done], timeout: 5)
        XCTAssertEqual(book.lists["claude"]?.models.map(\.id), ["m1"], "the default entry drops")
        XCTAssertEqual(book.lists["claude"]?.warning, "No OverSire daemon runs on the sessions machine. The list is from this Mac.")
    }
}
