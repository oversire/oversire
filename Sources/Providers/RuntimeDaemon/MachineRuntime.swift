import Foundation
import OverSireCore

extension ProviderID {
    public static let daemon: ProviderID = "daemon"
}

/// The agent runtimes of one machine, through its oversire daemon. The account id is the machine name.
/// The daemon talks to the runtimes of its machine. This adapter talks only to the daemon.
/// The capabilities come from GET /v1/runtimes: call `refresh()` or `probe()` first.
public class MachineRuntime: AgentRuntime, SessionIO, HostFileWriting, WorkspaceRemoving, SessionHistoryReading,
                             @unchecked Sendable {
    /// The runtime of a workspace that the adapter did not see in a listing.
    public static let defaultRuntime = "orca"
    /// The runtime that drives the agent over agent-wire. Its sessions have turns, not a terminal.
    public static let chatRuntime = "oversire"
    /// The longest time of one work order. A start of Orca can take a minute.
    public static let orderTimeout: TimeInterval = 300

    public let id: ProviderID = .daemon
    public let account: AccountID
    public let pollPolicy = PollPolicy(minInterval: .seconds(10), requestsPerHour: 3_600)
    public var machine: String { account.id }

    let client: DaemonClient
    let pushes: Pushes?
    private let now: @Sendable () -> Date
    private let newID: @Sendable () -> String
    private let pause: @Sendable (Duration) async throws -> Void
    private let lock = NSLock()
    private var known: [DaemonRuntime] = []
    private var runtimeOf: [String: String] = [:]   // workspace id → runtime id

    /// `pushes` wakes the question board when an event of the machine names a question.
    public init(machine: String, client: DaemonClient, pushes: Pushes? = nil, now: @escaping @Sendable () -> Date = Date.init,
                newID: @escaping @Sendable () -> String = { WorkOrder.newID() },
                pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        account = AccountID(provider: .daemon, id: machine)
        self.client = client
        self.pushes = pushes
        self.now = now
        self.newID = newID
        self.pause = pause
    }

    /// Only the runtime on this Mac can show a session.
    var reveals: Bool { false }

    public var capabilities: Set<Capability> {
        var caps: Set<Capability> = [.questions]
        for r in runtimes where r.reachable { caps.formUnion(r.capabilities.map(Capability.init(rawValue:))) }
        let parts: Set<Capability> = [.sessionInput, .sessionTail, .sessionHistory, .hostFiles, .removeWorkspace, .sessionKey, .questions, .sessionStream]
        return caps.intersection(reveals ? parts.union([.reveal]) : parts)
    }

    /// The runtimes of the last GET /v1/runtimes.
    public var runtimes: [DaemonRuntime] { lock.withLock { known } }

    @discardableResult
    public func refresh() async throws -> [DaemonRuntime] {
        let page = try await client.runtimes()
        lock.withLock { known = page.runtimes }
        return page.runtimes
    }

    public func probe() async throws -> Identity {
        let me = try await client.whoami()
        _ = try? await refresh()
        return Identity(person: PersonRef(id: me.machine.rawValue, name: "oversire \(me.version) on \(me.machine)"))
    }

    // MARK: AgentRuntime

    public func environments() async throws -> [RuntimeEnvironment] {
        [reveals ? .local : RuntimeEnvironment(id: machine, name: machine, kind: .ssh)]
    }

    public func repos(in env: RuntimeEnvironment? = nil) async throws -> [RuntimeRepo] {
        try await client.repos().repos.map { RuntimeRepo(id: $0.id, name: $0.name, path: $0.path, folder: $0.folder) }
    }

    /// The workspaces with their agent sessions. A runtime that fails drops out; all of them failing is an error.
    public func workspaces() async throws -> [Workspace] {
        async let pageCall = client.workspaces()
        async let sessionsCall = client.sessions()
        let (page, live) = try await (pageCall, sessionsCall)
        if page.workspaces.isEmpty, let errs = page.errors, !errs.isEmpty {
            throw ProviderError.transport(errs.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "; "))
        }
        remember(page)
        let byWorkspace = Dictionary(grouping: live.sessions.filter { $0.workspace != nil }, by: { $0.workspace! })
        return page.workspaces.map { w in
            let repo = w.repo ?? ""
            let agents = (byWorkspace[w.id] ?? []).filter { $0.runtime == w.runtime }.map { s in
                AgentSession(phase: Self.phase(s), since: s.stateSince, card: w.id, paneKey: s.id, agent: AgentName(rawValue: s.harness),
                             repo: repo, prompt: s.prompt, message: s.lastMessage, key: s.key, startedAt: s.startedAt,
                             profile: s.profile, model: s.model, effort: s.effort)
            }
            return Workspace(id: w.id, repo: repo, path: w.path, name: w.name ?? "", comment: w.comment, liveTerminals: w.liveTerminals,
                             lastActivity: w.lastActivity, agents: agents, kind: Self.kind(w.kind), branch: w.branch ?? "")
        }
    }

    public func sessions(_ w: WorkspaceRef) async throws -> [RuntimeSession] {
        let page = try await client.workspaces()
        remember(page)
        let terminals = page.workspaces.first { $0.id == w.id }?.terminals ?? []
        return terminals.map { RuntimeSession(ref: SessionRef(workspace: w, id: $0.id), title: $0.title, paneKey: $0.session ?? "", orphaned: $0.orphaned) }
    }

    /// Starts the session on the first reachable runtime with workspaces, else on the first reachable runtime.
    public func launch(_ r: LaunchRequest) async throws -> Launch {
        let rts = try await refresh().filter(\.reachable)
        guard let rt = (rts.first { $0.capabilities.contains("workspaces") } ?? rts.first)?.id else {
            throw ProviderError.transport("\(machine) has no agent runtime that runs")
        }
        let res = try await run(.start(r), runtime: rt)
        guard let s = res.session else { throw ProviderError.decoding("\(machine) started no session") }
        // A reused session can be on another runtime than the one asked.
        let owner = rts.contains { $0.id == s.workspace.account.provider.rawValue } ? s.workspace.account.provider.rawValue : rt
        lock.withLock { runtimeOf[s.workspace.id] = owner }
        return Launch(card: s.workspace.id, handle: s.id, paneKey: res.paneKey ?? "", turnStarted: res.turnStarted ?? false, reused: res.reused ?? false)
    }

    // MARK: SessionIO

    @discardableResult
    public func send(_ s: SessionRef, text: String) async throws -> Bool {
        let rt = await runtime(of: s.workspace.id)
        return try await run(.send(onDaemon(s, rt), text: text), runtime: rt).turnStarted ?? false
    }

    public func tail(_ s: SessionRef, lines: Int) async throws -> [String] {
        let rt = await runtime(of: s.workspace.id)
        return try await run(.read(onDaemon(s, rt), lines: lines), runtime: rt).lines ?? []
    }

    public func output(_ s: SessionRef, lines: Int) async throws -> [String] {
        let rt = await runtime(of: s.workspace.id)
        return try await run(.read(onDaemon(s, rt), lines: lines, scrollback: true), runtime: rt).lines ?? []
    }

    public func close(_ s: SessionRef) async throws {
        let rt = await runtime(of: s.workspace.id)
        _ = try await run(.stop(onDaemon(s, rt)), runtime: rt)
    }

    // MARK: Session stream

    /// The live view of a session. nil when the session has no id or its runtime gives no stream.
    public func stream(of s: AgentSession) async -> (request: URLRequest, view: StreamView)? {
        guard let id = s.paneKey, !id.isEmpty, let card = s.card else { return nil }
        let rt = await runtime(of: card)
        guard runtimes.contains(where: { $0.id == rt && $0.reachable && $0.capabilities.contains(Capability.sessionStream.rawValue) }) else { return nil }
        return (client.streamRequest(session: id), rt == Self.chatRuntime ? .chat : .terminal)
    }

    /// The daemon record of a session: its folder and the session id of its harness.
    public func session(id: String) async throws -> DaemonSession { try await client.session(id: id) }

    /// The models of an agent CLI on this machine.
    public func models(agent: String) async throws -> AgentModels { try await client.models(agent: agent) }

    // MARK: HostFileWriting

    /// The daemon chooses the folder. `dir` has no effect.
    public func writeFiles(_ files: [HostFile], workspacePath: String, dir: String,
                           progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [String] {
        guard !files.isEmpty else { return [] }
        let total = files.reduce(0) { $0 + $1.data.count }
        progress(0, total)
        let names = Self.safeNames(files.map(\.name))
        let r = try await client.writeFiles(WorkspaceFiles(files: zip(names, files).map { WorkspaceFile(name: $0, data: $1.data) }))
        progress(total, total)
        return r.paths
    }

    /// Plain file names that the daemon accepts: ASCII letters, digits and "._-", no leading dot, no two the same.
    static func safeNames(_ names: [String]) -> [String] {
        var seen: Set<String> = []
        return names.map { n in
            var base = String(n.unicodeScalars.map { s -> Character in
                s.isASCII && (CharacterSet.alphanumerics.contains(s) || "._-".unicodeScalars.contains(s)) ? Character(s) : "-"
            })
            base = String(base.drop { $0 == "." })
            if base.isEmpty { base = "file" }
            let ext = (base as NSString).pathExtension
            let stem = ext.isEmpty ? base : String(base.dropLast(ext.count + 1))
            var name = base
            var i = 2
            while seen.contains(name) {
                name = stem + "-\(i)" + (ext.isEmpty ? "" : "." + ext)
                i += 1
            }
            seen.insert(name)
            return name
        }
    }

    // MARK: WorkspaceRemoving

    public func remove(_ w: Workspace, force: Bool, runHooks: Bool) async throws -> WorkspaceRemoval {
        let rt = await runtime(of: w.id)
        let r = try await client.removeWorkspace(w.id, WorkspaceRemove(runtime: rt, force: force, runHooks: runHooks))
        lock.withLock { _ = runtimeOf.removeValue(forKey: w.id) }
        return r
    }

    // MARK: SessionHistoryReading

    public func history(of session: AgentSession, in workspace: Workspace, budget: HistoryBudget) async throws -> SessionDigest {
        guard let pane = session.paneKey else { throw ProviderError.notFound }
        let ws = WorkspaceRef(account: account, id: workspace.id)
        guard let terminal = try await sessions(ws).first(where: { $0.paneKey == pane })?.ref else { throw ProviderError.notFound }
        let rt = await runtime(of: workspace.id)
        guard let d = try await run(.history(onDaemon(terminal, rt), budget: budget), runtime: rt).digest else {
            throw ProviderError.decoding("\(machine) gave no history")
        }
        return d
    }

    // MARK: Work orders

    /// Sends one direct work order and waits for its end.
    func run(_ order: SessionOrder, runtime rt: String) async throws -> WorkOrderResult {
        // A direct order has no suggestion. The daemon needs one, so the order names itself, as the daemon does.
        let id = newID()
        let o = WorkOrderDraft(runtime: ProviderID(rawValue: rt), order: order.onTarget).order(suggestion: id, runner: machine, id: id, now: now())
        var state = try await client.start(o)
        var wait = Duration.milliseconds(200)
        let end = now().addingTimeInterval(Self.orderTimeout)
        while true {
            if let st = state, [.done, .failed, .expired].contains(st.state) {
                guard st.state == .done else {
                    throw ProviderError.vendor(code: st.state.rawValue, message: st.result?.error ?? "The order \(st.state) on \(machine).")
                }
                return st.result ?? WorkOrderResult()
            }
            guard now() < end else { throw ProviderError.transport("\(machine) did not end the order in time") }
            try await pause(wait)
            wait = min(wait * 2, .seconds(2))
            state = try await client.order(id: o.id)
        }
    }

    /// The session as the daemon knows it: the account is the runtime on the machine.
    func onDaemon(_ s: SessionRef, _ rt: String) -> SessionRef {
        SessionRef(workspace: WorkspaceRef(account: AccountID(provider: ProviderID(rawValue: rt), id: "local"), id: s.workspace.id), id: s.id)
    }

    /// The runtime of a workspace. An unknown workspace reads the list once.
    func runtime(of workspace: String) async -> String {
        if let rt = lock.withLock({ runtimeOf[workspace] }) { return rt }
        if let page = try? await client.workspaces() { remember(page) }
        return lock.withLock { runtimeOf[workspace] } ?? Self.defaultRuntime
    }

    private func remember(_ page: DaemonWorkspacesPage) {
        lock.withLock { for w in page.workspaces { runtimeOf[w.id] = w.runtime } }
    }

    /// A question keeps a done session done: AgentSession.needsInput shows it as needs input.
    static func phase(_ s: DaemonSession) -> AgentSession.Phase {
        switch s.state {
        case .starting: return .starting
        case .working: return s.reason == .question ? .waiting : .working
        case .waiting: return .waiting
        case .done: return .done
        case .failed: return .failed
        }
    }

    static func kind(_ k: DaemonWorkspace.Kind) -> Workspace.Kind {
        switch k {
        case .worktree: return .worktree
        case .folder: return .folder
        case .main: return .main
        }
    }
}

/// The runtimes of this Mac. Only this Mac can show a session in the runtime UI.
public final class LocalMachineRuntime: MachineRuntime, Revealing, @unchecked Sendable {
    override var reveals: Bool { true }

    public func reveal(_ s: SessionRef) async throws {
        try await client.reveal(onDaemon(s, await runtime(of: s.workspace.id)))
    }
}
