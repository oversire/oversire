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
    private let http: any HTTPTransport
    private var group: Group?
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
            let g = await machines.group
            await MainActor.run {
                self?.group = g
                self?.apply()
            }
        }
    }

    /// The links whose daemon source is live.
    var live: [MachineLink] { hub.links.filter { hub.isLive($0.machine) } }

    func apply() {
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
    func frame(_ text: String, from machine: String) { desk.received(text, from: machine) }

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
