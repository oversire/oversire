import Foundation
import OverSireCore
import OverSireSync
import RuntimeDaemon

// ─── Machine hub ─────────────────────────────────────────────────────────────
// The daemons of the group in the app. It keeps the links from Machines, the health of the source of each machine,
// and the runtime of each machine (its sessions and its questions). LiveSync runs the sources. Main thread only.

extension SecretStore: CredentialKeeping, @unchecked Sendable {}

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
    private var runtimes: [String: (link: MachineLink, runtime: MachineRuntime)] = [:]
    private var pushes: [String: MachineRuntime.Pushes] = [:]
    private var watcher: Task<Void, Never>?
    /// True after the first read of the group. Before it, the app does not know if this Mac has a daemon.
    var read = false

    var config: () -> MachinesConfig = { MACHINES }
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
        case .lease?, nil: break
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
            let read = await machines.refreshed
            await MainActor.run {
                guard let self else { return }
                self.groupName = name
                guard read, !self.read else { return }
                self.read = true
                NotificationCenter.default.post(name: Self.changed, object: self)
            }
        }
        guard links != self.links else { return }
        self.links = links
        health = health.filter { h in links.contains { $0.machine == h.key } }
        runtimes = Dictionary(uniqueKeysWithValues: links.map { l in (l.machine, runtimes[l.machine].flatMap { $0.link == l ? $0 : nil } ?? (l, make(l))) })
        onLinks()
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// The links that the app reads: none when the user turned the machines off.
    var active: [MachineLink] {
        let c = config()
        return c.enabled ? links.filter { !c.muted.contains($0.machine) } : []
    }

    // MARK: Runtimes

    private func make(_ l: MachineLink) -> MachineRuntime {
        let p = pushes[l.machine] ?? MachineRuntime.Pushes()
        pushes[l.machine] = p
        let c = l.client(http: http)
        let rt = l.local ? LocalMachineRuntime(machine: l.machine, client: c, pushes: p) : MachineRuntime(machine: l.machine, client: c, pushes: p)
        Task { try? await rt.refresh() }
        return rt
    }

    /// The runtime of the machine, while it has a link.
    func runtime(_ machine: String) -> MachineRuntime? { runtimes[machine]?.runtime }

    /// The runtime of the sessions machine (Settings › Machines). nil: the machine has no link.
    var sessions: MachineRuntime? { config().sessionsLink(links).flatMap { runtime($0.machine) } }

    /// The first read found no daemon on this Mac.
    var noLocalDaemon: Bool { read && !links.contains { $0.local } }

    /// This Mac has no daemon and runs the sessions itself. A Mac that shows the sessions of another machine needs no daemon.
    var needsDaemon: Bool { noLocalDaemon && config().sessions == nil }

    func isLive(_ machine: String) -> Bool { health[machine] == .live }

    // MARK: Sources

    /// LiveSync reports the health of the source of each machine.
    func setHealth(_ machine: String, _ h: SourceHealth) {
        let was = health[machine] == .live
        health[machine] = h
        guard was != (h == .live) else { return }
        if h == .live, let rt = runtime(machine) { Task { try? await rt.refresh() } }
        if let rt = runtime(machine) { onSessions(rt.account) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    // MARK: Questions

    /// One channel for each active link.
    func questionChannels() -> [any QuestionChannel] { active.compactMap { runtime($0.machine) } }

    /// The question board reads the daemon of the machine at once.
    func pushQuestions(_ machine: String) { pushes[machine]?.push() }

    /// An event of a daemon named a session of the machine.
    func sessionsChanged(_ machine: String) { onSessions(AccountID(provider: .daemon, id: machine)) }

    /// The event log of the machine has a gap: read its sessions and questions again.
    func logGap(_ machine: String) {
        pushQuestions(machine)
        sessionsChanged(machine)
    }
}
