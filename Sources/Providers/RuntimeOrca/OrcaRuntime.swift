import Foundation
import OverSireCore

/// Orca terminals through the Orca CLI. Each call has an argument array and --json.
/// With an environment, --environment sends the command to the paired Orca server.
public final class OrcaRuntime: AgentRuntime, SessionIO, Revealing, @unchecked Sendable {
    public static let defaultPath = "/Applications/Orca.app/Contents/Resources/bin/orca"

    public let id: ProviderID = .orca
    public let account: AccountID
    public let exe: String
    public let environment: String?
    public var capabilities: Set<Capability> { [.remoteEnvironments, .sessionInput, .sessionTail, .reveal, .hostFiles] }
    public var pollPolicy: PollPolicy { PollPolicy(minInterval: .seconds(15), requestsPerHour: 3600) }

    let commands: any CommandRunner
    /// The wait between two looks for the shell of a new workspace.
    var shellWait: Duration = .milliseconds(300)
    /// The marker id of a host file upload.
    var uploadId: @Sendable () -> String = { UUID().uuidString }

    public init(exe: String = OrcaRuntime.defaultPath, environment: String?, commands: any CommandRunner) {
        self.exe = exe
        self.environment = environment?.isEmpty == true ? nil : environment
        self.commands = commands
        account = AccountID(provider: .orca, id: self.environment ?? "local")
    }

    public var installed: Bool { FileManager.default.isExecutableFile(atPath: exe) }

    public func workspaceRef(_ id: String) -> WorkspaceRef { WorkspaceRef(account: account, id: id) }

    public func sessionRef(workspace: String, handle: String) -> SessionRef { SessionRef(workspace: workspaceRef(workspace), id: handle) }

    // MARK: Provider

    public func probe() async throws -> Identity {
        Identity(person: PersonRef(id: account.id, name: "Orca " + (try await version())))
    }

    public func version() async throws -> String {
        let rt = try await run(["status"])["runtime"] as? [String: Any]
        guard rt?["reachable"] as? Bool ?? false else {
            throw ProviderError.transport("Orca is not reachable" + (environment.map { " on \($0)" } ?? ""))
        }
        return rt?["appVersion"] as? String ?? "?"
    }

    // MARK: AgentRuntime

    /// This Mac and the paired Orca servers. `host list` refuses --environment.
    public func environments() async throws -> [RuntimeEnvironment] {
        let hosts = try await run(["host", "list"], routed: false)["hosts"] as? [[String: Any]] ?? []
        return [.local] + hosts.filter { $0["kind"] as? String == "environment" }.compactMap { h in
            (h["name"] as? String).map { RuntimeEnvironment(id: $0, name: $0, kind: .ssh) }
        }
    }

    public func repos(in env: RuntimeEnvironment? = nil) async throws -> [RuntimeRepo] {
        let target = env.map { $0.kind == .local ? nil : $0.id } ?? environment
        let r = try await run(["repo", "list"], environment: target)
        return (r["repos"] as? [[String: Any]] ?? []).compactMap { d in
            guard let id = d["id"] as? String, let path = d["path"] as? String else { return nil }
            return RuntimeRepo(id: id, name: d["displayName"] as? String ?? (path as NSString).lastPathComponent,
                               path: path, folder: d["kind"] as? String == "folder")
        }
    }

    public func workspaces() async throws -> [Workspace] {
        Self.cards(from: try await run(["worktree", "ps", "--limit", "500"]))
    }

    /// The workspaces in the result of `worktree ps`.
    public static func cards(from r: [String: Any]) -> [Workspace] {
        func date(_ v: Any?) -> Date { Date(timeIntervalSince1970: ((v as? Double) ?? 0) / 1000) }
        return (r["worktrees"] as? [[String: Any]] ?? []).compactMap { w in
            guard let id = w["worktreeId"] as? String, w["isArchived"] as? Bool != true else { return nil }
            let repo = w["repo"] as? String ?? ""
            let agents = (w["agents"] as? [[String: Any]] ?? []).compactMap { a -> AgentSession? in
                guard let pane = a["paneKey"] as? String else { return nil }
                let phase: AgentSession.Phase
                switch a["state"] as? String {
                case "working": phase = .working
                case "waiting": phase = .waiting
                case "done": phase = .done
                default: return nil
                }
                return AgentSession(phase: phase, since: date(a["stateStartedAt"]), card: id, paneKey: pane,
                                    agent: AgentName(rawValue: a["agentType"] as? String ?? "agent"), repo: repo,
                                    prompt: a["prompt"] as? String, message: a["lastAssistantMessage"] as? String)
            }
            return Workspace(id: id, repo: repo, path: w["path"] as? String ?? "",
                             name: w["displayName"] as? String ?? "", comment: w["comment"] as? String,
                             liveTerminals: w["liveTerminalCount"] as? Int ?? 0, lastActivity: date(w["lastActivityAt"]),
                             agents: agents)
        }
    }

    public func sessions(_ w: WorkspaceRef) async throws -> [RuntimeSession] {
        let r = try await run(["terminal", "list", "--worktree", "id:" + w.id])
        return (r["terminals"] as? [[String: Any]] ?? []).compactMap { t in
            guard let h = t["handle"] as? String else { return nil }
            return RuntimeSession(ref: sessionRef(workspace: t["worktreeId"] as? String ?? w.id, handle: h), title: t["title"] as? String ?? "",
                                  paneKey: "\(t["tabId"] as? String ?? ""):\(t["leafId"] as? String ?? "")",
                                  orphaned: t["orphaned"] as? Bool ?? false)
        }
    }

    /// Opens an agent session in the workspace with the request name, then sends the prompt.
    /// A workspace with that name in the repo is used again. A new workspace gets a fallback shell;
    /// the start command goes into it: `r.command`, else the default of the agent. The prompt goes only once.
    public func launch(_ r: LaunchRequest) async throws -> Launch {
        guard let name = r.workspaceName else { throw ProviderError.decoding("a launch needs a name or an item") }
        let command = r.command.flatMap { $0.isEmpty ? nil : $0 } ?? Self.agentCommand(r.agent, key: name)
        var cardId: String
        var shell: RuntimeSession?
        if let c = try await workspaces().first(where: { $0.path == r.repo && $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            cardId = c.id
        } else {
            var args = ["worktree", "create", "--repo", "path:" + r.repo, "--name", name]
            if let note = r.note ?? r.item?.url.absoluteString { args += ["--comment", note] }
            let made: [String: Any]
            do { made = try await run(args, timeout: .seconds(30)) } catch ProviderError.vendor("repo_not_found", _) {
                throw ProviderError.vendor(code: "repo_not_found", message: "Orca has no workspace at \(r.repo)")
            }
            guard let id = (made["worktree"] as? [String: Any])?["id"] as? String else { throw ProviderError.decoding("Orca made no card") }
            cardId = id
            // The fallback shell shows up a moment after the card.
            for i in 0..<10 {
                if let t = try? await sessions(workspaceRef(id)).first(where: { !$0.orphaned }) { shell = t; break }
                if i < 9 { try await Task.sleep(for: shellWait) }
            }
        }
        let term: RuntimeSession
        if let shell {
            _ = try await run(["terminal", "send", "--terminal", shell.ref.id, "--text", command, "--enter"])
            term = shell
        } else {
            let made = try await run(["terminal", "create", "--worktree", "id:" + cardId, "--title", name, "--command", command])
            guard let t = made["terminal"] as? [String: Any], let h = t["handle"] as? String else {
                throw ProviderError.decoding("Orca made no terminal")
            }
            term = RuntimeSession(ref: sessionRef(workspace: cardId, handle: h), title: name, paneKey: t["paneKey"] as? String ?? "", orphaned: false)
        }
        try await waitIdle(term.ref, name: name)
        let started = try await send(term.ref, text: r.prompt)
        return Launch(card: cardId, handle: term.ref.id, paneKey: term.paneKey, turnStarted: started)
    }

    /// A new terminal in the checkout at `path`. It runs `command` and gets `prompt` when the agent is idle.
    public func openTerminal(path: String, title: String, command: String, prompt: String) async throws -> SessionRef {
        let made = try await run(["terminal", "create", "--worktree", "path:" + path, "--title", title, "--command", command],
                                 timeout: .seconds(30))
        guard let t = made["terminal"] as? [String: Any], let h = t["handle"] as? String else {
            throw ProviderError.decoding("Orca made no terminal")
        }
        let ref = sessionRef(workspace: t["worktreeId"] as? String ?? "path:" + path, handle: h)
        try await waitIdle(ref, name: title)
        try await send(ref, text: prompt)
        return ref
    }

    /// A cold start of the agent can take longer than one wait.
    func waitIdle(_ s: SessionRef, name: String) async throws {
        for _ in 0..<2 {
            let r = try? await run(["terminal", "wait", "--terminal", s.id, "--for", "tui-idle", "--timeout-ms", "45000"], timeout: .seconds(60))
            if (r?["wait"] as? [String: Any])?["satisfied"] as? Bool == true { return }
        }
        throw ProviderError.vendor(code: "not_started", message: "The agent did not start in \(name)")
    }

    public static func agentCommand(_ agent: AgentName, key: String) -> String {
        (try? LaunchCommand.defaultFor(agent).resolve(name: key, key: key, title: key)) ?? agent.rawValue
    }

    // MARK: SessionIO

    @discardableResult
    public func send(_ s: SessionRef, text: String) async throws -> Bool {
        let r = try await run(["terminal", "send", "--terminal", s.id, "--text", text, "--enter", "--wait-submit", "15"], timeout: .seconds(30))
        let stages = ((r["send"] as? [String: Any])?["prompt"] as? [String: Any])?["stages"] as? [String] ?? []
        return stages.contains("turn_started")
    }

    public func tail(_ s: SessionRef, lines: Int) async throws -> [String] {
        let r = try await run(["terminal", "read", "--terminal", s.id, "--screen"])
        let all = ((r["terminal"] as? [String: Any])?["tail"] as? [String] ?? [])
            .map { $0.replacingOccurrences(of: "\u{a0}", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.allSatisfy { $0 == "─" } }
        return Array(all.suffix(lines))
    }

    public func output(_ s: SessionRef, lines: Int) async throws -> [String] {
        let r = try await run(["terminal", "read", "--terminal", s.id, "--limit", "\(lines)"])
        return ((r["terminal"] as? [String: Any])?["tail"] as? [String] ?? []).map { $0.replacingOccurrences(of: "\u{a0}", with: " ") }
    }

    public func close(_ s: SessionRef) async throws {
        _ = try await run(["terminal", "close", "--terminal", s.id])
    }

    // MARK: Revealing

    /// Brings the terminal to the front of the Orca window, then shows Orca on this Mac.
    public func reveal(_ s: SessionRef) async throws {
        _ = try await run(["terminal", "switch", "--terminal", s.id])
        _ = try await commands.run("/usr/bin/open", ["-a", "Orca"], stdin: nil, timeout: .seconds(10))
    }

    // MARK: Process

    /// `environment` .some(nil) runs on this Mac. nil uses the environment of the account.
    func run(_ args: [String], routed: Bool = true, environment env: String?? = nil,
             timeout: Duration = .seconds(20)) async throws -> [String: Any] {
        guard installed else { throw ProviderError.transport("Orca CLI not found at \(exe)") }
        var full = args + ["--json"]
        if routed, let e = env ?? environment { full += ["--environment", e] }
        let out: CommandOutput
        do { out = try await commands.run(exe, full, stdin: nil, timeout: timeout) } catch let e as ProviderError { throw e } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        return try Self.parse(out.stdout, stderr: out.stderr, command: args.prefix(2).joined(separator: " "))
    }

    static func parse(_ data: Data, stderr: String, command: String) throws -> [String: Any] {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProviderError.transport("orca \(command): " + (text.isEmpty ? "no JSON reply" : text))
        }
        if d["ok"] as? Bool == true { return d["result"] as? [String: Any] ?? [:] }
        let e = d["error"] as? [String: Any]
        throw ProviderError.vendor(code: e?["code"] as? String ?? "error", message: e?["message"] as? String ?? "orca \(command) failed")
    }
}
