import Foundation
import OverSireCore

/// An in-memory agent runtime. A launch makes a workspace with one session. A send adds lines to the session.
/// Host files stay in memory.
public final class FakeRuntime: AgentRuntime, SessionIO, Revealing, HostFileWriting, @unchecked Sendable {
    public let base: FakeProvider
    public var id: ProviderID { base.id }
    public var account: AccountID { base.account }
    public var capabilities: Set<Capability> { base.capabilities }
    public var pollPolicy: PollPolicy { base.pollPolicy }

    private var cards: [Workspace] = []
    private var terminals: [String: [RuntimeSession]] = [:]
    private var screens: [String: [String]] = [:]
    private var shown: [SessionRef] = []
    private var written: [String: Data] = [:]

    public init(account: String = "local", capabilities: Set<Capability> = [.sessionInput, .sessionTail, .reveal, .hostFiles]) {
        base = FakeProvider(id: "fake-runtime", account: account, capabilities: capabilities)
    }

    public var revealed: [SessionRef] { (try? base.locked { shown }) ?? [] }
    /// The host files by path.
    public var hostFiles: [String: Data] { base.lockedValue { written } }

    public func probe() async throws -> Identity { try await base.probe() }
    public func poll(since: Cursor?) async throws -> EventPage { try await base.poll(since: since) }

    public func environments() async throws -> [RuntimeEnvironment] { try base.locked { [.local] } }

    public func repos(in env: RuntimeEnvironment?) async throws -> [RuntimeRepo] {
        try base.locked { [RuntimeRepo(id: "r1", name: "app", path: "/fake/app", folder: false)] }
    }

    public func workspaces() async throws -> [Workspace] { try base.locked { cards } }

    public func sessions(_ w: WorkspaceRef) async throws -> [RuntimeSession] {
        try base.locked {
            guard cards.contains(where: { $0.id == w.id }) else { throw ProviderError.notFound }
            return terminals[w.id] ?? []
        }
    }

    public func launch(_ r: LaunchRequest) async throws -> Launch {
        try base.locked {
            guard let name = r.workspaceName else { throw ProviderError.decoding("a launch needs a name or an item") }
            let card = cards.first(where: { $0.name == name })?.id ?? "w\(cards.count + 1)"
            if !cards.contains(where: { $0.id == card }) {
                cards.append(Workspace(id: card, repo: r.repo, path: r.repo, name: name, comment: r.note, liveTerminals: 1,
                                       lastActivity: base.now(), agents: []))
            }
            let n = (terminals[card]?.count ?? 0) + 1
            let ref = SessionRef(workspace: WorkspaceRef(account: account, id: card), id: "\(card)-t\(n)")
            terminals[card, default: []].append(RuntimeSession(ref: ref, title: name, paneKey: "\(card):\(n)", orphaned: false))
            screens[ref.id] = ["$ \(r.agent.rawValue)", r.prompt]
            base.emit(.session, "started", .session(ref), title: name)
            return Launch(card: card, handle: ref.id, paneKey: "\(card):\(n)", turnStarted: true)
        }
    }

    @discardableResult
    public func send(_ s: SessionRef, text: String) async throws -> Bool {
        guard capabilities.contains(.sessionInput) else { throw ProviderError.unsupported(.sessionInput) }
        return try base.locked {
            guard screens[s.id] != nil else { throw ProviderError.notFound }
            screens[s.id]!.append(text)
            return true
        }
    }

    public func tail(_ s: SessionRef, lines: Int) async throws -> [String] {
        guard capabilities.contains(.sessionTail) else { throw ProviderError.unsupported(.sessionTail) }
        return try base.locked {
            guard let screen = screens[s.id] else { throw ProviderError.notFound }
            return Array(screen.suffix(lines))
        }
    }

    public func output(_ s: SessionRef, lines: Int) async throws -> [String] { try await tail(s, lines: lines) }

    public func close(_ s: SessionRef) async throws {
        try base.locked {
            guard screens.removeValue(forKey: s.id) != nil else { throw ProviderError.notFound }
            terminals[s.workspace.id]?.removeAll { $0.ref == s }
            base.emit(.session, "closed", .session(s))
        }
    }

    public func reveal(_ s: SessionRef) async throws {
        guard capabilities.contains(.reveal) else { throw ProviderError.unsupported(.reveal) }
        try base.locked { shown.append(s) }
    }

    public func writeFiles(_ files: [HostFile], workspacePath: String, dir: String,
                           progress: @escaping @Sendable (Int, Int) -> Void) async throws -> [String] {
        guard capabilities.contains(.hostFiles) else { throw ProviderError.unsupported(.hostFiles) }
        let total = files.reduce(0) { $0 + $1.data.count }
        let paths = try base.locked {
            files.map { f in
                let p = dir + "/" + f.name
                written[p] = f.data
                return p
            }
        }
        progress(total, total)
        return paths
    }
}
