import XCTest
import OverSireCore
import OverSireTestKit
@testable import RuntimeOrca

/// Recorded Orca CLI replies, keyed by the first two arguments ("worktree ps"). Each call is kept.
final class ReplayOrca: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [String: [String]] = [:]
    private(set) var calls: [[String]] = []

    /// Replies in order. The last one repeats.
    func on(_ command: String, _ replies: String...) { lock.withLock { answers[command] = replies } }

    func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput {
        lock.withLock {
            calls.append(args)
            let key = args.prefix(2).joined(separator: " ")
            guard var list = answers[key], !list.isEmpty else { return CommandOutput(status: 0, stdout: Data(), stderr: "") }
            let out = list.count > 1 ? list.removeFirst() : list[0]
            answers[key] = list
            return CommandOutput(status: 0, stdout: Data(out.utf8), stderr: "")
        }
    }

    func args(_ command: String) -> [[String]] { lock.withLock { calls.filter { $0.prefix(2).joined(separator: " ") == command } } }
}

final class RuntimeOrcaTests: XCTestCase {
    var orca: ReplayOrca!
    var rt: OrcaRuntime!

    static let ps = #"""
        {"ok":true,"result":{"worktrees":[
         {"worktreeId":"r1::/w::a","repo":"towertail-workspace","path":"/w","displayName":"TOWERTAIL-2","liveTerminalCount":1,"lastActivityAt":1000,
          "agents":[{"paneKey":"t1:l1","state":"working","agentType":"claude","prompt":"go","stateStartedAt":1000000},
                    {"paneKey":"t9:l9","state":"idle","agentType":"claude"}]},
         {"worktreeId":"r4::/y","repo":"y","path":"/y","displayName":"OLD","isArchived":true,"agents":[]}]}}
        """#

    override func setUp() {
        orca = ReplayOrca()
        rt = OrcaRuntime(exe: "/bin/sh", environment: "mbp", commands: orca)
        rt.shellWait = .zero
    }

    func testParse() throws {
        XCTAssertThrowsError(try OrcaRuntime.parse(Data(#"{"ok":false,"error":{"code":"runtime_unavailable","message":"no server"}}"#.utf8),
                                                   stderr: "", command: "worktree ps")) {
            XCTAssertEqual($0 as? ProviderError, .vendor(code: "runtime_unavailable", message: "no server"))
        }
        XCTAssertThrowsError(try OrcaRuntime.parse(Data("boom".utf8), stderr: "connect failed", command: "status")) {
            XCTAssertEqual(($0 as? ProviderError)?.message, "orca status: connect failed")
        }
        XCTAssertEqual(OrcaRuntime.agentCommand(.claude, key: "FRITZ-7"), "claude -n 'FRITZ-7'")
        XCTAssertEqual(OrcaRuntime.agentCommand(.codex, key: "X-1"), "codex")
    }

    func testWorkspacesAndEnvironments() async throws {
        orca.on("worktree ps", Self.ps)
        let ws = try await rt.workspaces()
        XCTAssertEqual(ws.map(\.name), ["TOWERTAIL-2"], "archived cards drop")
        XCTAssertEqual(ws[0].agents.map(\.paneKey), ["t1:l1"], "unknown states drop")
        XCTAssertEqual(ws[0].agents[0].since, Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(orca.calls.last?.suffix(3), ["--json", "--environment", "mbp"])

        orca.on("host list", #"{"ok":true,"result":{"hosts":[{"name":"mbp","kind":"environment"},{"name":"x","kind":"ssh-key"}]}}"#)
        let envs = try await rt.environments()
        XCTAssertEqual(envs, [.local, RuntimeEnvironment(id: "mbp", name: "mbp", kind: .ssh)])
        XCTAssertFalse(orca.calls.last!.contains("--environment"), "host list is not routed")

        orca.on("repo list", #"{"ok":true,"result":{"repos":[{"id":"r1","path":"/w","displayName":"towertail-workspace","kind":"folder"}]}}"#)
        let repos = try await rt.repos(in: .local)
        XCTAssertEqual(repos, [RuntimeRepo(id: "r1", name: "towertail-workspace", path: "/w", folder: true)])
        XCTAssertFalse(orca.calls.last!.contains("--environment"), "the local environment is not routed")
    }

    func testLaunchInANewCardUsesTheShell() async throws {
        orca.on("worktree ps", #"{"ok":true,"result":{"worktrees":[]}}"#)
        orca.on("worktree create", #"{"ok":true,"result":{"worktree":{"id":"c1"}}}"#)
        orca.on("terminal list", #"{"ok":true,"result":{"terminals":[]}}"#,
                #"{"ok":true,"result":{"terminals":[{"handle":"h1","worktreeId":"c1","title":"zsh","tabId":"t1","leafId":"l1"}]}}"#)
        orca.on("terminal wait", #"{"ok":true,"result":{"wait":{"satisfied":false}}}"#, #"{"ok":true,"result":{"wait":{"satisfied":true}}}"#)
        orca.on("terminal send", #"{"ok":true,"result":{}}"#, #"{"ok":true,"result":{"send":{"prompt":{"stages":["typed","turn_started"]}}}}"#)
        let l = try await rt.launch(LaunchRequest(repo: "/w", name: "ENG-4", note: "https://x/ENG-4", agent: .claude, prompt: "go"))
        XCTAssertEqual(l, Launch(card: "c1", handle: "h1", paneKey: "t1:l1", turnStarted: true))
        XCTAssertEqual(orca.args("worktree create").first?.prefix(8),
                       ["worktree", "create", "--repo", "path:/w", "--name", "ENG-4", "--comment", "https://x/ENG-4"])
        let sends = orca.args("terminal send")
        XCTAssertEqual(sends.count, 2, "the agent command, then the prompt once")
        XCTAssertEqual(sends[0][5], "claude -n 'ENG-4'")
        XCTAssertEqual(sends[1][5], "go")
        XCTAssertEqual(orca.args("terminal wait").count, 2, "a second wait for a cold start")
    }

    func testLaunchReusesTheCard() async throws {
        orca.on("worktree ps", Self.ps)
        orca.on("terminal create", #"{"ok":true,"result":{"terminal":{"handle":"h2","paneKey":"t2:l2"}}}"#)
        orca.on("terminal wait", #"{"ok":true,"result":{"wait":{"satisfied":true}}}"#)
        orca.on("terminal send", #"{"ok":true,"result":{}}"#)
        let l = try await rt.launch(LaunchRequest(repo: "/w", name: "towertail-2", agent: .codex, prompt: "go"))
        XCTAssertEqual(l.card, "r1::/w::a")
        XCTAssertFalse(l.turnStarted)
        XCTAssertTrue(orca.args("worktree create").isEmpty)
        XCTAssertEqual(orca.args("terminal create").first?.prefix(8),
                       ["terminal", "create", "--worktree", "id:r1::/w::a", "--title", "towertail-2", "--command", "codex"])
    }

    func testLaunchFailures() async throws {
        orca.on("worktree ps", #"{"ok":true,"result":{"worktrees":[]}}"#)
        orca.on("worktree create", #"{"ok":false,"error":{"code":"repo_not_found","message":"no repo"}}"#)
        do {
            _ = try await rt.launch(LaunchRequest(repo: "/nope", name: "A-1", agent: .claude, prompt: "go"))
            XCTFail("no repo")
        } catch {
            XCTAssertEqual(error as? ProviderError, .vendor(code: "repo_not_found", message: "Orca has no workspace at /nope"))
        }
        let gone = OrcaRuntime(exe: "/no/orca", environment: nil, commands: orca)
        do { _ = try await gone.workspaces(); XCTFail("not installed") } catch {
            XCTAssertEqual((error as? ProviderError)?.message, "Orca CLI not found at /no/orca")
        }
    }

    func testSessionIO() async throws {
        let s = rt.sessionRef(workspace: "c1", handle: "h1")
        orca.on("terminal read", #"{"ok":true,"result":{"terminal":{"tail":["a b","","──────","  done  "]}}}"#)
        let tail = try await rt.tail(s, lines: 8)
        XCTAssertEqual(tail, ["a b", "done"])
        XCTAssertTrue(orca.calls.last!.contains("--screen"))
        let out = try await rt.output(s, lines: 400)
        XCTAssertEqual(out.count, 4, "the scroll back keeps all lines")
        orca.on("terminal close", #"{"ok":true,"result":{}}"#)
        try await rt.close(s)
        XCTAssertEqual(orca.calls.last?.prefix(4), ["terminal", "close", "--terminal", "h1"])

        orca.on("terminal list", #"{"ok":true,"result":{"terminals":[{"handle":"h1","title":"✳ ENG-4","tabId":"t","leafId":"l","orphaned":true}]}}"#)
        let sessions = try await rt.sessions(rt.workspaceRef("c1"))
        XCTAssertEqual(sessions, [RuntimeSession(ref: s, title: "✳ ENG-4", paneKey: "t:l", orphaned: true)])
    }

    func testPoll() async throws {
        orca.on("worktree ps", Self.ps)
        let first = try await rt.poll(since: nil)
        XCTAssertTrue(first.events.isEmpty, "the first poll sets the baseline")
        XCTAssertTrue(first.busy, "a working agent")
        let same = try await rt.poll(since: first.cursor)
        XCTAssertTrue(same.events.isEmpty)

        orca.on("worktree ps", Self.ps.replacingOccurrences(of: #""state":"working","agentType":"claude","prompt":"go","stateStartedAt":1000000"#,
                                                            with: #""state":"waiting","agentType":"claude","prompt":"go","stateStartedAt":2000000"#))
        let page = try await rt.poll(since: same.cursor)
        XCTAssertEqual(page.events.map(\.action), ["waiting"])
        XCTAssertEqual(page.events.first?.subject, .session(SessionRef(workspace: rt.workspaceRef("r1::/w::a"), id: "t1:l1")))
        XCTAssertEqual(page.events.first?.kind, .session)
        XCTAssertFalse(page.busy)
    }

    func testDescriptor() throws {
        struct Secrets: SecretReader { func secret(_ key: String) -> String? { nil } }
        let env = ProviderEnvironment(http: NoHTTP(), commands: orca, secrets: Secrets())
        let made = try OrcaRuntime.descriptor.make(AccountConfig(account: AccountID(provider: .orca, id: "mbp"),
                                                                 values: ["environment": "mbp", "cli": ""]), env)
        XCTAssertEqual((made as? OrcaRuntime)?.environment, "mbp")
        XCTAssertEqual((made as? OrcaRuntime)?.exe, OrcaRuntime.defaultPath)
        XCTAssertEqual(made.account, AccountID(provider: .orca, id: "mbp"))
    }
}
