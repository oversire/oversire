import Foundation
import OverSireCore
import OverSireSync

// ─── Group sync ──────────────────────────────────────────────────────────────
// The roles of the machine group without the cloud: the runner path of the work orders (OVERSIRE-252)
// and the home store (OVERSIRE-253). Both follow the links and the health of MachineHub. Main thread only.

/// The runner path of the orders and the answers. Its records go into the store files, as the hub records do.
let RUNNER_DESK: RunnerDesk = {
    let d = RunnerDesk(store: STORE_WRITES.files ?? STORE_WRITES.store,
                       hub: RelayAnswers { RelayAPI(base: RELAY.workerURL, token: SecretStore().get(SecretStore.deviceToken)) },
                       http: URLSessionTransport())
    d.onWrite = { c in DispatchQueue.main.async { STORE_WRITES.changed(c) } }
    return d
}()

final class GroupSync {
    let hub: MachineHub
    let writes: StoreWrites
    let desk: RunnerDesk
    /// The app that runs the automatic actions (OVERSIRE-319).
    let owner: AutomationOwner
    private let leases: LeaseDirectory
    private let http: any HTTPTransport
    private var group: Group?
    // True when the group came after the first read of the daemons. Before it, nil does not mean solo.
    private var loaded = false
    private var runtimes: [String: [ProviderID]] = [:]
    private var reading: Set<String> = []
    private var observer: NSObjectProtocol?

    /// The paired cloud. LiveSync sets it. nil: free mode, or the old relay with no store.
    var cloud: CloudLink? {
        didSet { if cloud != oldValue { apply() } }
    }

    init(hub: MachineHub, writes: StoreWrites = STORE_WRITES, desk: RunnerDesk = RUNNER_DESK, http: any HTTPTransport = URLSessionTransport()) {
        self.hub = hub
        self.writes = writes
        self.desk = desk
        self.http = http
        let leases = LeaseDirectory(http: http)
        self.leases = leases
        owner = AutomationOwner(home: { leases.home($0) }, device: AppEnvironment.appDevice, name: { leases.selfName })
        writes.group = { [weak self] in self?.group?.id }
        writes.rehome = { [weak self] e in await MainActor.run { self?.rehome(e) } }
        observer = NotificationCenter.default.addObserver(forName: MachineHub.changed, object: hub, queue: .main) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// Reads the group that Machines knows, then applies it.
    func refresh() { load(again: false) }

    /// A {"type":"group"} frame: Machines reads the group from the daemons, then it applies.
    func reread() { load(again: true) }

    private func load(again: Bool) {
        let machines = hub.machines
        Task { [weak self] in
            if again { await machines.refresh() }
            // refreshed first: a group read after it is the group of the daemons.
            let read = await machines.refreshed
            let g = await machines.group
            await MainActor.run {
                self?.group = g
                self?.loaded = read
                self?.apply()
            }
        }
    }

    /// The links whose daemon source is live.
    var live: [MachineLink] { hub.links.filter { hub.isLive($0.machine) } }

    func apply() {
        if leases.update(read: loaded, group: group, links: hub.links, live: live.map(\.machine)) {
            Task { [owner] in await owner.refresh() }
        }
        writes.use(storeHome(group: group, cloud: cloud, links: live))
        desk.update(choice)
        readRuntimes()
    }

    var choice: RunnerChoice {
        RunnerChoice(targets: hub.links.map { l in
            RunnerTarget(link: l, live: hub.isLive(l.machine), runtimes: runtimes[l.machine])
        }, cloud: cloud != nil)
    }

    /// A text frame of the WebSocket of a machine: the ack, result and session frames of the direct orders.
    func frame(_ text: String, from machine: String) {
        if case .lease? = DaemonFrame.parse(text) {
            Task { [owner] in await owner.refresh() }
            return
        }
        desk.received(text, from: machine)
    }

    /// The old home answered 409. The named home, when it is live. The group is read again in all cases.
    func rehome(_ e: StoreNotHome) -> StoreReplica? {
        log.info("Store: \(e.message, privacy: .public)")
        reread()
        guard let home = e.home, let link = live.first(where: { $0.machine == home }), cloud == nil else { return nil }
        return StoreHome.member(link).replica(http: http, group: group?.id)
    }

    // The runtimes of a live daemon come from its whoami, once for each link.
    private func readRuntimes() {
        for l in live where runtimes[l.machine] == nil && !reading.contains(l.machine) {
            reading.insert(l.machine)
            let client = l.client(http: http)
            Task { [weak self] in
                let info = try? await client.whoami()
                await MainActor.run {
                    guard let self else { return }
                    self.reading.remove(l.machine)
                    guard let info else { return }
                    self.runtimes[l.machine] = info.runtimes
                    self.desk.update(self.choice)
                }
            }
        }
    }
}

/// The home of the automations lease: the home member of the group, also when the group has a cloud. Any thread.
final class LeaseDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private let http: any HTTPTransport
    private var read = false
    private var group: Group?
    private var links: [MachineLink] = []
    private var live: Set<String> = []

    init(http: any HTTPTransport) { self.http = http }

    /// True when the home or its link changed, or it went live.
    func update(read: Bool, group: Group?, links: [MachineLink], live: [String]) -> Bool {
        lock.withLock {
            let before = (self.read, self.group?.home, self.homeLink, self.live.contains(self.group?.home.rawValue ?? ""))
            self.read = read
            self.group = group
            self.links = links
            self.live = Set(live)
            return before != (read, group?.home, homeLink, self.live.contains(group?.home.rawValue ?? ""))
        }
    }

    private var homeLink: MachineLink? { links.first { $0.machine == group?.home.rawValue } }

    /// The machine name of this Mac: its daemon, else the host name, as a join of the app sends it.
    var selfName: String {
        lock.withLock { links.first(where: \.local)?.machine } ?? ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac"
    }

    /// Before the first read of the group, the automations wait. hint: the home that a 409 named.
    func home(_ hint: String?) -> LeaseHome {
        lock.withLock {
            guard read else { return .unreachable("") }
            guard let group else { return .none }
            let m = hint ?? group.home.rawValue
            guard let l = links.first(where: { $0.machine == m }) else { return .unreachable(m) }
            return .member(m, l.client(http: http))
        }
    }
}

extension SuggestionBook {
    /// A workOrder proposal goes straight to a live member daemon. Else the hub makes the order, or the suggestion fails at once.
    /// The direct path writes only the end state, so the hub never sees it as accepted.
    func acceptOrder(_ s: Suggestion, draft: WorkOrderDraft, by device: String?, now: Date, desk: RunnerDesk) -> Bool {
        let route: RunnerRoute
        do { route = try desk.route(draft) } catch {
            var failed = s
            failed.state = .failed
            failed.decidedAt = now
            failed.decidedBy = device
            failed.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            replace(failed, write: true)
            return true
        }
        guard case .daemon(let link) = route else { return false }
        var accepted = s
        accepted.state = .accepted
        accepted.decidedAt = now
        accepted.decidedBy = device
        replace(accepted, write: false)
        Task { [weak self] in
            let end = await desk.run(accepted, draft: draft, on: link)
            await MainActor.run { self?.replace(end, write: true) }
        }
        return true
    }
}
