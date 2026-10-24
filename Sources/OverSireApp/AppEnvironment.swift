import Foundation
import OverSireCore
import OverSireSync
import GitHubKit
import TrackerPlane
import CodeHostGitHub
import CIGitHubActions
import RuntimeDaemon

// ─── Composition root ────────────────────────────────────────────────────────
// Only this file names the concrete adapters. The rest of the app uses the protocols.

/// The registered providers, the accounts and one adapter for each account.
/// Adapters are made on first use, because a token read can ask for Keychain access.
final class AppEnvironment: @unchecked Sendable {
    static let changed = Notification.Name("AppEnvironmentChanged")

    let registry = ProviderRegistry()
    let secrets: KeychainSecrets
    private let lock = NSLock()
    private var configs: [AccountConfig] = []
    private var made: [AccountID: (config: AccountConfig, provider: any Provider)] = [:]
    private var failed: [AccountID: String] = [:]

    init(secrets: KeychainSecrets = KeychainSecrets()) {
        self.secrets = secrets
        for d in [PlaneTracker.descriptor, GitHubCodeHost.descriptor, ActionsCI.descriptor] {
            registry.register(d)
        }
    }

    /// GitHub adapters get the gh environment and no redirects, as the gh CLI does.
    func io(_ p: ProviderID, secrets other: (any SecretReader)? = nil) -> ProviderEnvironment {
        let gh = p == .github || p == .githubActions
        return ProviderEnvironment(http: gh ? URLSessionTransport.noRedirects : URLSessionTransport(),
                                   commands: ProcessRunner(environment: gh ? GitHubClient.environment : nil), secrets: other ?? secrets, log: AppLog())
    }

    /// Runs after the Providers page removes an account, for example to delete its webhook.
    var onRemove: ((AccountID) -> Void)?

    // MARK: Accounts

    /// Keeps the adapters of accounts that did not change.
    func load(_ accounts: [AccountConfig]) {
        lock.withLock {
            configs = accounts
            let keep = Set(accounts)
            made = made.filter { keep.contains($0.value.config) }
            failed = [:]
        }
    }

    var accounts: [AccountConfig] { lock.withLock { configs } }

    func accounts(_ layer: Layer) -> [AccountConfig] {
        accounts.filter { registry.descriptor($0.account.provider)?.layer == layer }
    }

    func descriptor(_ a: AccountID) -> ProviderDescriptor? { registry.descriptor(a.provider) }

    /// The daemons of the group. Each machine is one runtime account (provider `daemon`, id the machine name).
    weak var machines: MachineHub?

    /// nil when the account is unknown or its adapter cannot be made. `error(_:)` then tells why.
    func provider(_ id: AccountID) -> (any Provider)? {
        if id.provider == .daemon { return machines?.runtime(id.id) }
        guard let c = accounts.first(where: { $0.account == id }) else { return nil }
        return provider(c)
    }

    private func provider(_ c: AccountConfig) -> (any Provider)? {
        if let p = lock.withLock({ made[c.account].flatMap { $0.config == c ? $0.provider : nil } }) { return p }
        do {
            let p = try registry.make(c, environment: io(c.account.provider))
            lock.withLock {
                made[c.account] = (c, p)
                failed[c.account] = nil
            }
            return p
        } catch {
            let text = (error as? ProviderError)?.message ?? error.localizedDescription
            lock.withLock { failed[c.account] = text }
            return nil
        }
    }

    func error(_ id: AccountID) -> String? { lock.withLock { failed[id] } }

    // MARK: Layers

    func trackers() -> [any Tracker] { accounts(.tracker).compactMap { provider($0) as? any Tracker } }

    /// The tracker account with this id, for example a Plane workspace slug.
    func tracker(_ id: String) -> (any Tracker)? {
        accounts(.tracker).first { $0.account.id == id }.flatMap { provider($0) as? any Tracker }
    }

    func codeHost(owner: String) -> (any CodeHost)? { adapter(.codeHost, owner: owner) }

    func ci(owner: String) -> (any CIProvider)? { adapter(.ci, owner: owner) }

    /// The runtime of the sessions machine. Work, Intake and cleanup use it.
    var runtime: (any AgentRuntime)? { machines?.sessions }

    /// The account of the owner. An owner with no account (an org in the repo picker) gets
    /// an adapter of the first provider of the layer.
    private func adapter<P>(_ layer: Layer, owner: String) -> P? {
        if let c = accounts(layer).first(where: { $0.account.id.caseInsensitiveCompare(owner) == .orderedSame }) {
            return provider(c) as? P
        }
        guard let d = registry.descriptors(layer).first else { return nil }
        return provider(AccountConfig(account: AccountID(provider: d.id, id: owner), values: ["owner": owner])) as? P
    }

    /// The union of the capabilities of the accounts of a layer, or of all accounts.
    /// The runtime layer is the sessions machine.
    func capabilities(_ layer: Layer? = nil) -> Set<Capability> {
        var caps = (layer.map(accounts) ?? accounts).compactMap(provider).reduce(into: Set<Capability>()) { $0.formUnion($1.capabilities) }
        if layer == nil || layer == .runtime, let rt = runtime { caps.formUnion(rt.capabilities) }
        return caps
    }

    func has(_ c: Capability) -> Bool { capabilities().contains(c) }

    /// New code host and CI adapters that poll these repos, one for each owner and layer.
    /// The repo list is the resolved one, so the repos of an org pick poll too.
    func pollers(repos: [String]) -> [any Provider] {
        let owners = repos.reduce(into: [String: [String]]()) { $0[repoOwner($1), default: []].append($1) }
        return [Layer.codeHost, .ci].flatMap { layer in
            owners.sorted { $0.key < $1.key }.compactMap { owner, list -> (any Provider)? in
                let known = accounts(layer).first { $0.account.id.caseInsensitiveCompare(owner) == .orderedSame }
                guard var c = known ?? registry.descriptors(layer).first.map({
                    AccountConfig(account: AccountID(provider: $0.id, id: owner), values: ["owner": owner])
                }) else { return nil }
                c.values["repos"] = list.joined(separator: ",")
                return try? registry.make(c, environment: io(c.account.provider))
            }
        }
    }

    /// The key formats of the trackers, without repeats. With no tracker, the common PROJECT-12 form.
    var keyFormats: [KeyFormat] {
        var out: [KeyFormat] = []
        for f in trackers().map(\.keyFormat) where !out.contains(f) { out.append(f) }
        return out.isEmpty ? [.projectDash] : out
    }
}

let ENV = AppEnvironment()

extension AppEnvironment: TrackerDirectory {
    var trackerIds: [String] { accounts(.tracker).map(\.account.id) }
}

extension AppEnvironment: RepoAccounts {}

// ─── Optional features of the adapters ───────────────────────────────────────

extension PlaneTracker: MemberListing, SelfAssigning, StatusTimeline, IntakeKeying, LabelIdReading {}

extension PlaneTracker: IntakePage {
    func intakeURL(_ p: ProjectRef) -> String { "\(workspace.webURL)/\(workspace.slug)/projects/\(p.id)/intake" }
}

extension PlaneTracker: HTMLBodies {
    func html(fromMarkdown md: String) -> String { PlaneMarkup.html(fromMarkdown: md) }
}

extension MachineRuntime: SessionStreaming {}

extension MachineRuntime: AgentTerminal {
    func openTerminal(path: String, title: String, agent: AgentName, command: String, prompt: String) async throws -> SessionRef {
        let l = try await launch(LaunchRequest(repo: path, agent: agent, prompt: prompt, command: command, title: title, inPlace: true))
        return SessionRef(workspace: WorkspaceRef(account: account, id: l.card), id: l.handle)
    }

    func show(_ s: SessionRef) async throws { try await (self as? any Revealing)?.reveal(s) }
}

extension GitHubCodeHost: RepoAddressing {}
extension ActionsCI: RepoAddressing, KnownJobFailures, RawLogReading {}

extension PlaneTracker: AssetLinking {
    func assetIds(in markdown: String) -> Set<String> {
        let ns = markdown as NSString
        return Set(PlaneMarkup.assetRE.matches(in: markdown, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 2)) })
    }
}

// ─── Account owners ──────────────────────────────────────────────────────────
// The Providers page owns the tracker and runtime accounts. GitHub and GitHub Actions follow
// the repo picker, so their accounts come from the picked repos and orgs.

extension AppEnvironment {
    static let repoProviders: Set<ProviderID> = [.github, .githubActions]

    /// The secret key of a field. Plane keeps its old key names.
    static func secretKey(_ a: AccountID, field: String) -> String {
        a.provider == .plane ? "PLANE_TOKEN_\(a.id)" : "\(a.provider.rawValue.uppercased())_\(field.uppercased())_\(a.id)"
    }

    /// The accounts of the config. A config with no list gets the list from the old fields.
    static func accounts(from c: AppConfig) -> [AccountConfig] {
        let own = (c.accounts ?? LegacyMigration.accounts(from: c)).filter { !repoProviders.contains($0.account.provider) }
        return own + repoAccounts(repos: c.repos.filter(isValidRepo), orgs: c.orgs ?? [])
    }

    /// One GitHub and one GitHub Actions account for each owner of a picked repo or org.
    static func repoAccounts(repos: [String], orgs: [String]) -> [AccountConfig] {
        var owners: [String] = []
        var byOwner: [String: [String]] = [:]
        for r in repos {
            let o = String(r.split(separator: "/")[0])
            if byOwner[o] == nil { owners.append(o) }
            byOwner[o, default: []].append(r)
        }
        for o in orgs where byOwner[o] == nil {
            owners.append(o)
            byOwner[o] = []
        }
        return [ProviderID.github, .githubActions].flatMap { p in
            owners.map { o in
                let id = AccountID(provider: p, id: o)
                return AccountConfig(account: id, values: ["owner": o, "repos": byOwner[o]!.joined(separator: ",")],
                                     secretKeys: [secretKey(id, field: "token")])
            }
        }
    }

    /// Writes the old fields from the accounts, so older code and older app versions see the same state.
    static func applyLegacyFields(_ accounts: [AccountConfig], to p: inout ProjectsConfig) {
        p.workspaces = accounts.filter { $0.account.provider == .plane }.map { a in
            PlaneWorkspace(slug: a.values["workspace"] ?? a.account.id,
                           host: a.values["host"].flatMap { $0.isEmpty ? nil : $0 } ?? PlaneWorkspace.cloudHost)
        }
    }

    /// Adds or changes an account. `secrets` holds the values of the secret fields.
    /// A repo account changes the repo picker. Call `saveConfig()` after.
    func save(_ c: AccountConfig, secrets values: [String: String], replacing old: AccountID? = nil) {
        var c = c
        let d = registry.descriptor(c.account.provider)
        c.secretKeys = []
        for f in d?.fields ?? [] where f.kind == .secret {
            let key = Self.secretKey(c.account, field: f.key)
            c.secretKeys.append(key)
            if let v = values[f.key] {
                if v.isEmpty { secrets.delete(key) } else { secrets.set(key, v) }
            }
        }
        if let old, old != c.account { remove(old) }
        if Self.repoProviders.contains(c.account.provider) {
            let owner = c.account.id
            let repos = (c.values["repos"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter(isValidRepo)
            PICKED_REPOS.removeAll { repoOwner($0).caseInsensitiveCompare(owner) == .orderedSame }
            PICKED_ORGS.removeAll { $0.caseInsensitiveCompare(owner) == .orderedSame }
            if repos.isEmpty { PICKED_ORGS.append(owner) } else { PICKED_REPOS += repos }
        } else {
            ACCOUNTS.removeAll { $0.account == c.account }
            ACCOUNTS.append(c)
        }
    }

    /// Removes the account, its secrets and, for a repo account, the repos of the owner.
    func remove(_ id: AccountID) {
        onRemove?(id)
        if Self.repoProviders.contains(id.provider) {
            PICKED_REPOS.removeAll { repoOwner($0).caseInsensitiveCompare(id.id) == .orderedSame }
            PICKED_ORGS.removeAll { $0.caseInsensitiveCompare(id.id) == .orderedSame }
            return
        }
        for k in ACCOUNTS.first(where: { $0.account == id })?.secretKeys ?? [] { secrets.delete(k) }
        ACCOUNTS.removeAll { $0.account == id }
        if id.provider == .plane {
            PROJECTS_CFG.allOf.removeAll { $0 == id.id }
            PROJECTS_CFG.picked.removeAll { $0.hasPrefix(id.id + "/") }
        }
    }
}

// ─── OverSire state ──────────────────────────────────────────────────────────

/// The cloud account of a paired Mac.
struct CloudLink: Equatable {
    let base: URL
    let token: String
    let device: String
}

/// The copy of the store that this app syncs with. Contract: the replica table of OVERSIRE-253.
enum StoreHome: Equatable {
    /// The cloud hub of a paired Mac, as before the machine group.
    case cloud(CloudLink)
    /// The home member of a group with no cloud: its daemon, or loopback when this Mac is home.
    case member(MachineLink)
    /// No group, or the home is offline. The outbox keeps the ops.
    case local

    /// The sync identity. One SyncedStore (outbox and clocks) serves all replicas of one identity.
    var identity: String? {
        switch self {
        case .cloud(let c): return c.device
        case .member: return AppEnvironment.appDevice
        case .local: return nil
        }
    }

    func replica(http: any HTTPTransport, group: String?) -> StoreReplica? {
        switch self {
        case .cloud(let c): return StoreReplica(id: SyncedStore.cloudReplica, replication: CloudReplication(base: c.base, token: c.token, http: http))
        case .member(let l):
            return StoreReplica(id: "member:\(group ?? "")/\(l.machine)", replication: CloudReplication(base: l.base, token: l.token, http: http))
        case .local: return nil
        }
    }
}

/// The paired cloud wins. Else the home member of the group, when it is live (`links` holds only the live links). Else local only.
func storeHome(group: Group?, cloud: CloudLink?, links: [MachineLink]) -> StoreHome {
    if let cloud { return .cloud(cloud) }
    guard let group, group.cloud == nil, let home = links.first(where: { $0.machine == group.home.rawValue }) else { return .local }
    return .member(home)
}

extension AppEnvironment {
    /// The device id of this app in the hlc of a group with no cloud. It stays the same after a restart.
    static let appDevice: String = {
        let url = URL(fileURLWithPath: CONFIG_DIR).appendingPathComponent("sync/app/device")
        if let id = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
        let id = "app-" + String(format: "%08x", UInt32.random(in: .min ... .max))
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? id.write(to: url, atomically: true, encoding: .utf8)
        return id
    }()

    /// A SyncedStore over the same files. The sync state of each identity has its own folder, so a new pairing starts clean.
    func store(local: LocalStore, identity: String, replica: StoreReplica?,
               rehome: @escaping @Sendable (StoreNotHome) async -> StoreReplica?) -> SyncedStore {
        let folder = identity == Self.appDevice ? "app" : identity
        let dir = URL(fileURLWithPath: CONFIG_DIR).appendingPathComponent("sync").appendingPathComponent(folder)
        return SyncedStore(local: local, replica: replica, device: identity, dir: dir,
                           cursors: CursorStore(url: dir.appendingPathComponent("cursor.json")), rehome: rehome)
    }
}
