import Foundation
import OverSireCore
import OverSireSync
import RuntimeOrca

// ─── Machine hub ─────────────────────────────────────────────────────────────
// The daemons of the group in the app. It keeps the links from Machines, the health of the source of each machine,
// and the question channel of each machine. LiveSync runs the sources. Main thread only.

extension SecretStore: CredentialKeeping, @unchecked Sendable {}

/// The sessions of a daemon for AgentIndex.
struct DaemonSessions: AgentSessionsReading {
    let client: DaemonClient
    func sessions() async throws -> [DaemonSession] { try await client.sessions().sessions }
}

final class MachineHub {
    static let changed = Notification.Name("MachineHubChanged")

    let machines: Machines
    let http: any HTTPTransport
    /// The daemon on this Mac. It trusts loopback.
    let local: DaemonClient
    /// All links of the group. `active` leaves out the muted machines.
    private(set) var links: [MachineLink] = []
    /// The source health of each machine. A machine with no entry has no source yet.
    private(set) var health: [String: SourceHealth] = [:]
    private var channels: [String: DaemonQuestions] = [:]
    private var pushes: [String: DaemonQuestions.Pushes] = [:]
    private var watcher: Task<Void, Never>?

    var config: () -> MachinesConfig = { MACHINES }
    /// The Orca environments of this app. An environment with the name of a machine is its default account.
    var environments: () -> [String] = { ENV.accounts(.runtime).filter { $0.account.provider == .orca }.map(\.account.id) }
    var orca: (AccountID) -> OrcaRuntime? = { ENV.provider($0) as? OrcaRuntime }
    /// The links changed: the sources and the question channels start again.
    var onLinks: () -> Void = {}
    /// The sessions of the account changed, or its daemon came or went.
    var onSessions: (AccountID) -> Void = { _ in }

    init(local: DaemonClient = DaemonClient(base: DaemonClient.loopback, token: nil, http: URLSessionTransport()),
         keychain: any CredentialKeeping = SecretStore(), http: any HTTPTransport = URLSessionTransport(),
         cache: URL? = URL(fileURLWithPath: (CONFIG_DIR as NSString).appendingPathComponent("machines-group.json"))) {
        self.http = http
        self.local = local
        machines = Machines(local: local, keychain: keychain, http: http, cache: cache)
    }

    // MARK: Joins

    @MainActor lazy var joins: JoinFlow = {
        let f = JoinFlow(local: local, machines: machines, http: http)
        f.onJoined = { [weak self] in self?.refresh() }
        return f
    }()

    @MainActor lazy var approvals: ApproveCenter = {
        let a = ApproveCenter(local: local, notifier: UserJoinNotifier())
        a.groupName = { [weak self] in self?.groupName ?? "My machines" }
        return a
    }()

    /// The name of the group at the last read.
    private(set) var groupName: String?

    /// A frame of the local daemon that is not a poke.
    @MainActor func frame(_ text: String) {
        switch DaemonFrame.parse(text) {
        case .joinRequest(let r)?: approvals.handle(r)
        case .joinResult(let r)?: joins.received(r)
        case nil: break
        }
    }

    /// Reads the group now and each 5 minutes, and follows the changes of the links.
    func start() {
        watcher?.cancel()
        let m = machines
        watcher = Task { [weak self] in
            for await links in await m.changes() {
                await MainActor.run { self?.use(links) }
            }
        }
        Task { await m.start() }
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        Task { [machines] in await machines.stop() }
    }

    /// A {"type":"group"} frame: the roster changed.
    func refresh() { Task { [machines] in await machines.refresh() } }

    /// For tests and `--uishots`: links without a daemon.
    func use(_ links: [MachineLink]) {
        Task { [weak self, machines] in
            let name = await machines.group?.name
            await MainActor.run { self?.groupName = name }
        }
        guard links != self.links else { return }
        self.links = links
        health = health.filter { h in links.contains { $0.machine == h.key } }
        channels = [:]
        applyScreens()
        onLinks()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// The links that the app reads: none when the user turned the machines off.
    var active: [MachineLink] {
        let c = config()
        return c.enabled ? links.filter { !c.muted.contains($0.machine) } : []
    }

    // MARK: Accounts

    func runtimeAccount(_ link: MachineLink) -> AccountID? {
        config().runtimeAccount(link, environments: environments()).map { AccountID(provider: .orca, id: $0) }
    }

    /// machine → the Orca account id. RefreshPlan uses it.
    var accountsByMachine: [String: String] {
        Dictionary(active.compactMap { l in runtimeAccount(l).map { (l.machine, $0.id) } }, uniquingKeysWith: { a, _ in a })
    }

    /// The live link of the account, if any.
    func liveLink(for account: AccountID) -> MachineLink? {
        active.first { health[$0.machine] == .live && runtimeAccount($0) == account }
    }

    func isLive(_ machine: String) -> Bool { health[machine] == .live }

    // MARK: Sources

    /// LiveSync reports the health of the source of each machine.
    func setHealth(_ machine: String, _ h: SourceHealth) {
        let was = health[machine] == .live
        health[machine] = h
        guard was != (h == .live) else { return }
        applyScreens()
        if let link = links.first(where: { $0.machine == machine }), let a = runtimeAccount(link) { onSessions(a) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// Without a live daemon, OrcaRuntime finds the forms on the screen. With one, it gives only the asks.
    func applyScreens() {
        for c in ENV.accounts(.runtime) where c.account.provider == .orca {
            orca(c.account)?.screenQuestions = liveLink(for: c.account) == nil
        }
    }

    func sessionsReader(for account: AccountID) -> (any AgentSessionsReading)? {
        liveLink(for: account).map { DaemonSessions(client: $0.client(http: http)) }
    }

    // MARK: Questions

    /// One channel for each active link with an Orca account.
    func questionChannels() -> [any QuestionChannel] {
        active.compactMap { l -> DaemonQuestions? in
            guard let account = runtimeAccount(l) else { return nil }
            if let c = channels[l.machine], c.account == account, c.link == l { return c }
            let p = pushes[l.machine] ?? DaemonQuestions.Pushes()
            pushes[l.machine] = p
            let orca = self.orca
            let c = DaemonQuestions(link: l, account: account, client: l.client(http: http), supervised: {
                (try? await orca(account)?.supervised()) ?? []
            }, pushes: p)
            channels[l.machine] = c
            return c
        }
    }

    /// The question board reads the daemon of the machine at once.
    func pushQuestions(_ machine: String) { pushes[machine]?.push() }

    /// An event of a daemon named a session of the Orca account.
    func sessionsChanged(_ account: String) { onSessions(AccountID(provider: .orca, id: account)) }

    /// The event log of the machine has a gap: read its sessions and questions again.
    func logGap(_ machine: String) {
        pushQuestions(machine)
        if let link = links.first(where: { $0.machine == machine }), let a = runtimeAccount(link) { onSessions(a) }
    }
}
