import Foundation
import OverSireCore

// ─── Orca CLI ────────────────────────────────────────────────────────────────
// OverSire starts Plane items in Orca terminals. It calls the Orca CLI by its full
// path with an argument array, always with --json. On a client Mac, --environment
// sends each command to the paired Orca server.

struct OrcaError: Error, Equatable {
    let code: String
    let message: String
}

struct OrcaTerminal: Equatable {
    let handle: String
    let card: String
    let title: String
    let paneKey: String
    let orphaned: Bool
}

final class OrcaClient {
    static let defaultPath = "/Applications/Orca.app/Contents/Resources/bin/orca"

    let exe: String
    let environment: String?

    init(exe: String = OrcaClient.defaultPath, environment: String?) {
        self.exe = exe
        self.environment = environment?.isEmpty == true ? nil : environment
    }

    var installed: Bool { FileManager.default.isExecutableFile(atPath: exe) }

    // MARK: Reads

    func version() -> Result<String, OrcaError> {
        run(["status"]).flatMap { r in
            let rt = r["runtime"] as? [String: Any]
            guard rt?["reachable"] as? Bool ?? false else {
                return .failure(OrcaError(code: "unreachable", message: "Orca is not reachable" + (environment.map { " on \($0)" } ?? "")))
            }
            return .success(rt?["appVersion"] as? String ?? "?")
        }
    }

    // Names of the paired Orca servers. `host list` refuses --environment.
    func environments() -> Result<[String], OrcaError> {
        run(["host", "list"], routed: false).map { r in
            (r["hosts"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "environment" }.compactMap { $0["name"] as? String }
        }
    }

    func repos() -> Result<[RuntimeRepo], OrcaError> {
        run(["repo", "list"]).map { r in
            (r["repos"] as? [[String: Any]] ?? []).compactMap { d in
                guard let id = d["id"] as? String, let path = d["path"] as? String else { return nil }
                return RuntimeRepo(id: id, name: d["displayName"] as? String ?? (path as NSString).lastPathComponent,
                                path: path, folder: d["kind"] as? String == "folder")
            }
        }
    }

    func cards() -> Result<[Workspace], OrcaError> {
        run(["worktree", "ps", "--limit", "500"]).map { OrcaClient.cards(from: $0) }
    }

    static func cards(from r: [String: Any]) -> [Workspace] {
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

    func terminals(card: String) -> Result<[OrcaTerminal], OrcaError> {
        run(["terminal", "list", "--worktree", "id:" + card]).map { r in
            (r["terminals"] as? [[String: Any]] ?? []).compactMap { t in
                guard let h = t["handle"] as? String else { return nil }
                return OrcaTerminal(handle: h, card: t["worktreeId"] as? String ?? card, title: t["title"] as? String ?? "",
                                    paneKey: "\(t["tabId"] as? String ?? ""):\(t["leafId"] as? String ?? "")",
                                    orphaned: t["orphaned"] as? Bool ?? false)
            }
        }
    }

    // The last lines of a terminal, as the screen shows them.
    func tail(handle: String, lines: Int = 8) -> Result<[String], OrcaError> {
        run(["terminal", "read", "--terminal", handle, "--screen"]).map { r in
            let all = ((r["terminal"] as? [String: Any])?["tail"] as? [String] ?? [])
                .map { $0.replacingOccurrences(of: "\u{a0}", with: " ").trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.allSatisfy { $0 == "─" } }
            return Array(all.suffix(lines))
        }
    }

    // MARK: Writes

    func send(handle: String, text: String) -> Result<Bool, OrcaError> {
        run(["terminal", "send", "--terminal", handle, "--text", text, "--enter", "--wait-submit", "15"], timeout: 30).map { r in
            let stages = ((r["send"] as? [String: Any])?["prompt"] as? [String: Any])?["stages"] as? [String] ?? []
            return stages.contains("turn_started")
        }
    }

    // Brings the terminal to the front of the Orca window, then shows Orca on this Mac.
    func reveal(handle: String) {
        _ = run(["terminal", "switch", "--terminal", handle])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", "Orca"]
        try? p.run()
    }

    // Opens a Claude session named `key` in the card for the item, then sends the prompt.
    // An existing card with that name in the root is used again. A new card gets a
    // fallback shell; OverSire types the agent command into it. It never sends the prompt twice.
    func start(root: String, key: String, url: String, agent: String, prompt: String) -> Result<Launch, OrcaError> {
        let command = OrcaClient.agentCommand(agent, key: key)
        var cardId: String
        var shell: OrcaTerminal?
        switch cards() {
        case .failure(let e): return .failure(e)
        case .success(let list):
            if let c = list.first(where: { $0.path == root && $0.name.caseInsensitiveCompare(key) == .orderedSame }) {
                cardId = c.id
            } else {
                switch run(["worktree", "create", "--repo", "path:" + root, "--name", key, "--comment", url], timeout: 30) {
                case .failure(let e) where e.code == "repo_not_found":
                    return .failure(OrcaError(code: e.code, message: "Orca has no workspace at \(root)"))
                case .failure(let e): return .failure(e)
                case .success(let r):
                    guard let id = (r["worktree"] as? [String: Any])?["id"] as? String else {
                        return .failure(OrcaError(code: "bad_reply", message: "Orca made no card"))
                    }
                    cardId = id
                    // The fallback shell shows up a moment after the card.
                    for _ in 0..<10 {
                        if case .success(let ts) = terminals(card: id), let t = ts.first(where: { !$0.orphaned }) { shell = t; break }
                        Thread.sleep(forTimeInterval: 0.3)
                    }
                }
            }
        }
        let term: OrcaTerminal
        if let shell {
            if case .failure(let e) = run(["terminal", "send", "--terminal", shell.handle, "--text", command, "--enter"]) { return .failure(e) }
            term = shell
        } else {
            switch run(["terminal", "create", "--worktree", "id:" + cardId, "--title", key, "--command", command]) {
            case .failure(let e): return .failure(e)
            case .success(let r):
                guard let t = r["terminal"] as? [String: Any], let h = t["handle"] as? String else {
                    return .failure(OrcaError(code: "bad_reply", message: "Orca made no terminal"))
                }
                term = OrcaTerminal(handle: h, card: cardId, title: key, paneKey: t["paneKey"] as? String ?? "", orphaned: false)
            }
        }
        // A cold start of the agent can take longer than one wait.
        var idle = false
        for _ in 0..<2 where !idle {
            if case .success(let r) = run(["terminal", "wait", "--terminal", term.handle, "--for", "tui-idle", "--timeout-ms", "45000"], timeout: 60) {
                idle = (r["wait"] as? [String: Any])?["satisfied"] as? Bool ?? false
            }
        }
        guard idle else { return .failure(OrcaError(code: "not_started", message: "The agent did not start in \(key)")) }
        return send(handle: term.handle, text: prompt).map {
            Launch(card: cardId, handle: term.handle, paneKey: term.paneKey, turnStarted: $0)
        }
    }

    // A new terminal in the checkout at `path`. It runs `command` and gets `prompt` when the agent is idle.
    func openTerminal(path: String, title: String, command: String, prompt: String) -> Result<String, OrcaError> {
        switch run(["terminal", "create", "--worktree", "path:" + path, "--title", title, "--command", command], timeout: 30) {
        case .failure(let e): return .failure(e)
        case .success(let r):
            guard let h = (r["terminal"] as? [String: Any])?["handle"] as? String else {
                return .failure(OrcaError(code: "bad_reply", message: "Orca made no terminal"))
            }
            var idle = false
            for _ in 0..<2 where !idle {
                if case .success(let w) = run(["terminal", "wait", "--terminal", h, "--for", "tui-idle", "--timeout-ms", "45000"], timeout: 60) {
                    idle = (w["wait"] as? [String: Any])?["satisfied"] as? Bool ?? false
                }
            }
            guard idle else { return .failure(OrcaError(code: "not_started", message: "The agent did not start in \(title)")) }
            return send(handle: h, text: prompt).map { _ in h }
        }
    }

    // The output of a terminal as text, the last `limit` lines.
    func output(handle: String, limit: Int = 400) -> Result<[String], OrcaError> {
        run(["terminal", "read", "--terminal", handle, "--limit", "\(limit)"]).map { r in
            ((r["terminal"] as? [String: Any])?["tail"] as? [String] ?? []).map { $0.replacingOccurrences(of: "\u{a0}", with: " ") }
        }
    }

    func close(handle: String) { _ = run(["terminal", "close", "--terminal", handle]) }

    static func agentCommand(_ agent: String, key: String) -> String {
        agent == "claude" ? "claude -n '\(key)'" : agent
    }

    // MARK: Process

    func run(_ args: [String], routed: Bool = true, timeout: TimeInterval = 20) -> Result<[String: Any], OrcaError> {
        guard installed else { return .failure(OrcaError(code: "not_installed", message: "Orca CLI not found at \(exe)")) }
        var full = args + ["--json"]
        if routed, let environment { full += ["--environment", environment] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = full
        proc.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do { try proc.run() } catch { return .failure(OrcaError(code: "launch", message: error.localizedDescription)) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            if proc.isRunning { proc.terminate() }
        }
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        proc.waitUntilExit()
        return OrcaClient.parse(data, stderr: String(data: errData, encoding: .utf8) ?? "", command: args.prefix(2).joined(separator: " "))
    }

    static func parse(_ data: Data, stderr: String, command: String) -> Result<[String: Any], OrcaError> {
        guard let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(OrcaError(code: "bad_reply", message: "orca \(command): " + (text.isEmpty ? "no JSON reply" : text)))
        }
        if d["ok"] as? Bool == true { return .success(d["result"] as? [String: Any] ?? [:]) }
        let e = d["error"] as? [String: Any]
        return .failure(OrcaError(code: e?["code"] as? String ?? "error", message: e?["message"] as? String ?? "orca \(command) failed"))
    }
}
