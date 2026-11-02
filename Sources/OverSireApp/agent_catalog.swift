import Foundation
import OverSireCore

// The agents of the user (OVERSIRE-399): the shared agents of the home store, for all Macs of the group,
// and the agents of this Mac only, in config.json. A local agent hides a shared agent of the same name on this Mac.

/// One row of Settings › Agents.
struct CatalogAgent: Equatable {
    enum Scope: String { case shared, local }

    var scope: Scope
    var def: AgentDef
    /// A shared agent that a local agent of the same name hides on this Mac.
    var shadowed = false

    var name: String { def.name }
}

enum CatalogError: LocalizedError, Equatable {
    case env([EnvProblem])
    case exists(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .env(let p): return p.map(\.description).joined(separator: " ")
        case .exists(let n): return "An agent with the name \(n) is in this list. Use another name."
        case .missing(let n): return "No agent \(n)."
        }
    }
}

/// Main thread only.
final class AgentCatalog {
    static let changed = Notification.Name("AgentCatalogChanged")

    private let writes: StoreWrites
    private var records: [String: AgentDef] = [:]
    private var observer: NSObjectProtocol?

    var config: () -> RuntimeConfig = { PROJECTS_CFG.runtime }
    var setConfig: (RuntimeConfig) -> Void = { PROJECTS_CFG.runtime = $0; saveConfig() }
    /// The machine name for "edited on".
    var machine: () -> String = { ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac" }
    var now: () -> Date = Date.init
    var record: (_ summary: String, _ payload: [String: JSONValue]) -> Void = { s, p in
        EVENTS.action(.agentChanged, item: nil, verb: "agent", s, payload: p)
    }

    init(writes: StoreWrites) {
        self.writes = writes
        reload()
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard let self, n.userInfo?["collection"] as? String == AgentDef.collection else { return }
            self.reload()
            self.post()
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func reload() {
        records = Dictionary(writes.load(AgentDef.self).map { ($0.name, $0) }, uniquingKeysWith: { a, b in a.updatedAt >= b.updatedAt ? a : b })
        publish()
    }

    // MARK: Lists

    /// The shared agents, by name.
    var shared: [CatalogAgent] {
        let cfg = config()
        return records.values.filter { $0.name != AgentDef.allAgents }.sorted { $0.name < $1.name }
            .map { CatalogAgent(scope: .shared, def: $0, shadowed: cfg.isLocal($0.name)) }
    }

    /// The agents of this Mac only, by name. A built-in CLI with no change is not in the list.
    var local: [CatalogAgent] {
        let cfg = config()
        return localNames(cfg).compactMap { cfg.localDef($0) }.map { CatalogAgent(scope: .local, def: $0) }
    }

    var agents: [CatalogAgent] { shared + local }

    /// The env for all agents: the shared record `*`.
    var allEnv: [EnvVar] { records[AgentDef.allAgents]?.env ?? [] }

    var allEnvRecord: AgentDef? { records[AgentDef.allAgents] }

    func agent(_ name: String, scope: CatalogAgent.Scope) -> AgentDef? {
        scope == .shared ? records[name] : config().localDef(name)
    }

    /// The banner offers Share all while the user has local agents and did not close it.
    var needsShareOffer: Bool { !config().shareOfferClosed && local.contains { !isPlainBuiltIn($0.def) } }

    func closeShareOffer() {
        var cfg = config()
        cfg.shareOfferClosed = true
        setConfig(cfg)
        post()
    }

    // MARK: Changes

    /// Saves the agent in the list. The env must have no errors. A shared save with no change writes nothing.
    func save(_ d: AgentDef, scope: CatalogAgent.Scope) throws {
        let errors = AgentEnv.errors(d.env)
        guard errors.isEmpty else { throw CatalogError.env(errors) }
        switch scope {
        case .shared:
            if let old = records[d.name], old.sameDefinition(as: d) { return }
            put(d)
        case .local:
            var cfg = config()
            cfg.setLocal(d)
            setConfig(cfg)
        }
        changed(d.name, scope, "saved")
    }

    /// Saves the env for all agents.
    func saveAllEnv(_ env: [EnvVar]) throws {
        try save(AgentDef(name: AgentDef.allAgents, env: env), scope: .shared)
    }

    func remove(_ name: String, scope: CatalogAgent.Scope) {
        switch scope {
        case .shared:
            guard records.removeValue(forKey: name) != nil else { return }
            writes.delete(AgentDef.self, id: name)
            publish()
        case .local:
            var cfg = config()
            guard cfg.isLocal(name) else { return }
            cfg.remove(name)
            setConfig(cfg)
        }
        changed(name, scope, "removed")
    }

    /// Moves a local agent to the shared list. A secret value stays under the scope of this Mac:
    /// the result names the keys that need a value again.
    @discardableResult
    func share(_ name: String) throws -> [String] {
        var cfg = config()
        guard let d = cfg.localDef(name) else { throw CatalogError.missing(name) }
        let errors = AgentEnv.errors(d.env)
        guard errors.isEmpty else { throw CatalogError.env(errors) }
        put(d)
        cfg.remove(name)
        setConfig(cfg)
        changed(name, .shared, "moved")
        return d.env.filter(\.secret).map(\.key)
    }

    func shareAll() throws {
        for a in local { try share(a.name) }
        closeShareOffer()
    }

    /// Moves a shared agent to this Mac only. The other Macs lose it. Secret keys need a value again.
    @discardableResult
    func keepLocal(_ name: String) throws -> [String] {
        guard let d = records[name] else { throw CatalogError.missing(name) }
        var cfg = config()
        cfg.setLocal(d)
        setConfig(cfg)
        records[name] = nil
        writes.delete(AgentDef.self, id: name)
        publish()
        changed(name, .local, "moved")
        return d.env.filter(\.secret).map(\.key)
    }

    /// A copy in the same list. Secret rows come with no value.
    func duplicate(_ name: String, scope: CatalogAgent.Scope, as new: String) throws {
        guard var d = agent(name, scope: scope) else { throw CatalogError.missing(name) }
        guard agent(new, scope: scope) == nil else { throw CatalogError.exists(new) }
        d.name = new
        try save(d, scope: scope)
    }

    // MARK: Private

    private func put(_ d: AgentDef) {
        var r = d
        r.updatedAt = now()
        r.updatedBy = machine()
        records[r.name] = r
        writes.put(r)
        publish()
    }

    private func localNames(_ cfg: RuntimeConfig) -> [String] {
        Set(cfg.commands.keys).union(cfg.profiles.keys).union(cfg.env.keys).union(cfg.runsOn.keys)
            .subtracting([RuntimeConfig.intakeKey]).sorted()
    }

    /// A built-in CLI at its defaults. The share offer skips it.
    private func isPlainBuiltIn(_ d: AgentDef) -> Bool {
        RuntimeConfig.baseCLI(d.name) == d.name && d.cli == d.name && d.command == nil && d.model == nil && d.effort == nil
            && d.runsOn == nil && d.env.isEmpty
    }

    private func changed(_ name: String, _ scope: CatalogAgent.Scope, _ action: String) {
        let label = name == AgentDef.allAgents ? "The env for all agents" : "Agent \(name)"
        record("\(label) \(action) (\(scope.rawValue))", ["agent": .string(name), "scope": .string(scope.rawValue), "action": .string(action)])
        post()
    }

    /// RuntimeConfig reads the shared agents for each start.
    private func publish() { RuntimeConfig.shared = SharedAgents(Array(records.values)) }

    private func post() { NotificationCenter.default.post(name: Self.changed, object: self) }
}

/// The secret env values on the home daemon. The app sets, replaces and removes them. It never reads a value back.
final class AgentSecrets {
    enum Failure: LocalizedError {
        case noHome
        case homeOffline(String)

        var errorDescription: String? {
            switch self {
            case .noHome: return "Secrets live on the home daemon. Install the daemon and make a group in Settings › Machines."
            case .homeOffline(let m): return "The home daemon on \(m) does not answer. Try again when \(m) is online."
            }
        }
    }

    /// The home daemon: the home of the group, else the daemon of this Mac when it has no group.
    var home: () -> Result<(machine: String, client: DaemonClient), Failure>
    /// The secret scope of an agent of this Mac only.
    let device: String

    init(device: String = AppEnvironment.appDevice, home: @escaping () -> Result<(machine: String, client: DaemonClient), Failure>) {
        self.device = device
        self.home = home
    }

    func scope(_ s: CatalogAgent.Scope) -> String { s == .shared ? AgentSecretRef.shared : device }

    func set(_ agent: String, scope: CatalogAgent.Scope, key: String, value: String) async throws {
        try await home().get().client.setAgentSecret(scope: self.scope(scope), agent: agent, key: key, value: value)
    }

    func remove(_ agent: String, scope: CatalogAgent.Scope, key: String) async throws {
        try await home().get().client.removeAgentSecret(scope: self.scope(scope), agent: agent, key: key)
    }

    /// The keys on home, with the machine name. A key has no value here.
    func list() async throws -> (machine: String, keys: [AgentSecretKey]) {
        let h = try home().get()
        return (h.machine, try await h.client.agentSecrets().secrets)
    }
}
