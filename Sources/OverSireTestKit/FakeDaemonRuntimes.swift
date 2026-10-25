import Foundation
import OverSireCore

/// The runtime routes of a FakeDaemon: runtimes, repos, workspaces, files, reveal and direct work orders.
/// The default values are the ones of the contract fixtures. A start makes a workspace with one terminal and one session.
/// A start with a key gives the live session of the key, as the daemon does.
public final class FakeDaemonRuntimes: @unchecked Sendable {
    private let lock = NSLock()
    private var _runtimes: [DaemonRuntime] = [DaemonRuntime(id: "orca", name: "Orca", installed: true, reachable: true, version: "1.4.223",
                                                            capabilities: ["sessionInput", "sessionTail", "sessionHistory", "hostFiles",
                                                                           "workspaces", "reveal", "removeWorkspace", "sessionKey"])]
    private var _repos: [DaemonRepo] = [DaemonRepo(id: "r-towertail", runtime: "orca", name: "towertail", path: "/Users/ada/Projects/towertail", folder: false)]
    private var _workspaces: [DaemonWorkspace] = []
    private var _orders: [WorkOrder] = []
    private var _states: [String: DaemonOrderState] = [:]
    private var _reads: [String: Int] = [:]
    private var _screen: [String: [String]] = [:]
    private var _history: [String: String] = [:]
    private var _files: [[WorkspaceFile]] = []
    private var _reveals: [SessionRef] = []
    private var _fail: [SessionOrder.Op: String] = [:]
    private var made = 0

    public init() {}

    private func with<T>(_ f: () throws -> T) rethrows -> T { try lock.withLock(f) }

    public var runtimes: [DaemonRuntime] { get { with { _runtimes } } set { with { _runtimes = newValue } } }
    public var repos: [DaemonRepo] { get { with { _repos } } set { with { _repos = newValue } } }
    public var workspaces: [DaemonWorkspace] { get { with { _workspaces } } set { with { _workspaces = newValue } } }
    /// The orders of POST /v1/orders.
    public var orders: [WorkOrder] { with { _orders } }
    /// The files of each POST /v1/files.
    public var files: [[WorkspaceFile]] { with { _files } }
    /// The sessions of POST /v1/reveal.
    public var reveals: [SessionRef] { with { _reveals } }
    /// The screen lines of a terminal for sessionRead.
    public func screen(_ terminal: String, _ lines: [String]) { with { _screen[terminal] = lines } }
    /// The text of the last turn that sessionHistory gives for a terminal.
    public func history(_ terminal: String, _ text: String) { with { _history[terminal] = text } }
    /// Orders with this op fail with the text.
    public func fail(_ op: SessionOrder.Op, _ error: String?) { with { _fail[op] = error } }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func ok<T: Encodable>(_ v: T) throws -> (Int, Data) { (200, try Self.encoder.encode(v)) }
    private func error(_ code: Int, _ text: String) -> (Int, Data) {
        (code, (try? Self.encoder.encode(["error": text])) ?? Data())
    }

    /// nil: not a runtime route. `sessions` are the sessions of the FakeDaemon.
    func route(_ method: String, _ p: [String], body: Data?, machine: MachineName, sessions: inout [DaemonSession]) throws -> (Int, Data)? {
        try with {
            switch (method, p) {
            case ("GET", ["v1", "runtimes"]): return try ok(DaemonRuntimesPage(runtimes: _runtimes))
            case ("POST", let p) where p.count == 4 && p[1] == "runtimes" && p[3] == "retry":
                guard let rt = _runtimes.first(where: { $0.id == p[2] }) else { return error(404, "no runtime \(p[2])") }
                return try ok(rt)
            case (let m, let p) where (m == "POST" || m == "DELETE") && p.count == 4 && p[1] == "runtimes" && p[3] == "pair":
                guard let i = _runtimes.firstIndex(where: { $0.id == p[2] }) else { return error(404, "no runtime \(p[2])") }
                // As the daemon: the link "bad" does not pair.
                if m == "POST", try Self.decoder.decode(RuntimePair.self, from: body ?? Data()).link == "bad" { return error(400, "Orca refused the device token.") }
                _runtimes[i].stream = m == "POST" ? RuntimeStream(state: .live, pairable: true, paired: true)
                    : RuntimeStream(state: .textOnly, reason: "Pair Orca to see the live terminal.", pairable: true, paired: false)
                return try ok(_runtimes[i])
            case ("GET", ["v1", "repos"]): return try ok(DaemonReposPage(repos: _repos))
            case ("GET", ["v1", "workspaces"]): return try ok(DaemonWorkspacesPage(workspaces: _workspaces))
            case ("DELETE", let p) where p.count == 3 && p[1] == "workspaces":
                let rm = try Self.decoder.decode(WorkspaceRemove.self, from: body ?? Data())
                guard let w = _workspaces.first(where: { $0.id == p[2] && $0.runtime == rm.runtime }) else { return error(404, "no workspace \(p[2])") }
                guard w.kind != .main else { return error(502, "OverSire does not remove the main checkout of a repo.") }
                _workspaces.removeAll { $0.id == w.id }
                sessions.removeAll { $0.workspace == w.id }
                return try ok(WorkspaceRemoval(warning: nil))
            case ("POST", ["v1", "files"]):
                let f = try Self.decoder.decode(WorkspaceFiles.self, from: body ?? Data())
                _files.append(f.files)
                let dir = "/Users/ada/.oversire/files/\(String(format: "%016x", _files.count))"
                return try ok(WorkspaceFilesResult(paths: f.files.map { dir + "/" + $0.name }))
            case ("POST", ["v1", "reveal"]):
                _reveals.append(try Self.decoder.decode(SessionRef.self, from: body ?? Data()))
                return (204, Data())
            case ("POST", ["v1", "orders"]):
                let o = try Self.decoder.decode(WorkOrder.self, from: body ?? Data())
                // As the daemon: wire.WorkOrder.UnmarshalJSON.
                guard !o.id.isEmpty, !o.runner.isEmpty, !o.suggestion.isEmpty else { return error(400, "wire: order needs id, runner and suggestion") }
                if let st = _states[o.id] { return try ok(st) }
                _orders.append(o)
                _states[o.id] = run(o, machine: machine, sessions: &sessions)
                return (202, try Self.encoder.encode(["order": o]))
            case ("GET", let p) where p.count == 3 && p[1] == "orders":
                guard let st = _states[p[2]] else { return error(404, "not found") }
                // The first read gives acked: the order runs.
                _reads[p[2], default: 0] += 1
                return try ok(_reads[p[2]] == 1 ? DaemonOrderState(state: .acked) : st)
            default: return nil
            }
        }
    }

    // Runs under the lock.
    private func run(_ o: WorkOrder, machine: MachineName, sessions: inout [DaemonSession]) -> DaemonOrderState {
        if let e = _fail[o.order.op] { return DaemonOrderState(state: .failed, result: WorkOrderResult(error: e)) }
        func terminal(_ s: SessionRef) -> (ws: Int, t: Int)? {
            guard let i = _workspaces.firstIndex(where: { $0.id == s.workspace.id }),
                  let j = _workspaces[i].terminals?.firstIndex(where: { $0.id == s.id }) else { return nil }
            return (i, j)
        }
        let gone = DaemonOrderState(state: .failed, result: WorkOrderResult(error: "terminal_not_found"))
        switch o.order {
        case .start(let r):
            if let k = r.key, let s = sessions.first(where: { $0.key == k }), let ws = s.workspace {
                let ref = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: o.runtime, id: "local"), id: ws), id: s.terminal ?? s.id)
                return DaemonOrderState(state: .done, result: WorkOrderResult(session: ref, paneKey: s.id))
            }
            made += 1
            let name = r.workspaceName ?? "session-\(made)"
            let path = r.inPlace == true ? r.repo : r.repo + "-wt/" + name
            let ws = _workspaces.first { $0.path == path }?.id ?? "r-\(made)::\(path)"
            let term = DaemonTerminal(id: "term_\(made)", title: r.title ?? r.agent.rawValue, session: "tab-\(made):leaf-1", orphaned: false)
            if let i = _workspaces.firstIndex(where: { $0.id == ws }) {
                _workspaces[i].terminals = (_workspaces[i].terminals ?? []) + [term]
                _workspaces[i].liveTerminals += 1
            } else {
                _workspaces.append(DaemonWorkspace(id: ws, runtime: o.runtime.rawValue, repo: (r.repo as NSString).lastPathComponent, path: path,
                                                   name: name, comment: r.note ?? r.item?.url.absoluteString, kind: r.inPlace == true ? .folder : .worktree,
                                                   branch: r.branch ?? name.lowercased(), liveTerminals: 1, lastActivity: o.createdAt, terminals: [term]))
            }
            sessions.append(DaemonSession(id: term.session!, machine: machine, runtime: o.runtime.rawValue, harness: r.agent.rawValue, workspace: ws,
                                          terminal: term.id, cwd: path, state: .working, prompt: r.prompt, stateSince: o.createdAt, startedAt: o.createdAt,
                                          updatedAt: o.createdAt, sources: ["orca"], key: r.key))
            let ref = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: o.runtime, id: "local"), id: ws), id: term.id)
            return DaemonOrderState(state: .done, result: WorkOrderResult(session: ref, paneKey: term.session, turnStarted: !r.prompt.isEmpty))
        case .send(let s, _, _, _):
            guard terminal(s) != nil else { return gone }
            return DaemonOrderState(state: .done, result: WorkOrderResult(turnStarted: true))
        case .read(let s, let lines, _):
            guard terminal(s) != nil else { return gone }
            return DaemonOrderState(state: .done, result: WorkOrderResult(lines: Array((_screen[s.id] ?? ["❯ Conformance input"]).suffix(lines))))
        case .stop(let s):
            guard let (i, j) = terminal(s) else { return gone }
            let pane = _workspaces[i].terminals?.remove(at: j).session
            _workspaces[i].liveTerminals = max(0, _workspaces[i].liveTerminals - 1)
            sessions.removeAll { $0.id == pane }
            return DaemonOrderState(state: .done, result: WorkOrderResult())
        case .history(let s, _):
            guard terminal(s) != nil else { return gone }
            let d = SessionDigest(harness: .claude, sessionId: "7f3c2a10", source: .orcaTerminal, turns: 1,
                                  last: [SessionDigest.LastTurn(prompt: "Say hello.", text: _history[s.id] ?? "Hello.", tools: 0)])
            return DaemonOrderState(state: .done, result: WorkOrderResult(digest: d))
        }
    }
}
