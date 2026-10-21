import Cocoa
import OverSireCore
import OverSireSync
import Network

// ─── Live sync ───────────────────────────────────────────────────────────────
// Polling and the cloud give one event stream. The events are hints: they name
// the repos and projects to refresh, and the refresh reads the data.

let CURSORS_PATH = (CONFIG_DIR as NSString).appendingPathComponent("cursors.json")
let FALLBACK_CURSORS_PATH = (CONFIG_DIR as NSString).appendingPathComponent("cursors-fallback.json")

// The consumer of the events. GHActionsBar implements it.
protocol RelaySink: AnyObject {
    func relayRefresh(repos: [String], includePRs: Bool, completedRuns: [(String, String)], done: @escaping (Bool) -> Void)
    func relayProjectRefresh(_ events: [(workspace: String, project: String?)], done: @escaping (Bool) -> Void)
    func relayFullRefresh(done: @escaping (Bool) -> Void)
    func relayStateChanged()
}

// Splits a batch of events into a repo refresh and a project refresh.
struct RefreshPlan {
    var repos: [String] = []
    var includePRs = false
    var completedRuns: [(String, String)] = []
    var projects: [(workspace: String, project: String?)] = []   // nil project: all projects of the tracker account

    /// resyncs: tracker accounts that must refresh all their projects.
    init(_ events: [ProviderEvent], resyncs: [AccountID] = [], knownRepos: [String]) {
        let byLower = Dictionary(knownRepos.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        for a in resyncs { project(a.id, nil) }
        for e in events {
            if e.kind == .change { includePRs = true }
            switch e.subject {
            case .run(let r):
                if let path = repo(r.repo?.path, byLower), e.kind == .run, e.action == "completed" { completedRuns.append((path, r.id)) }
            case .job(let j): _ = repo(j.run.repo?.path, byLower)
            case .change(let c): _ = repo(c.repo.path, byLower)
            case .repo(let r): _ = repo(r.path, byLower)
            case .project(let p): project(p.account.id, p.id)
            case .item(let i): project(i.project.account.id, i.project.id)
            default: break
            }
        }
    }

    var wantsRepoRefresh: Bool { !repos.isEmpty }
    var wantsProjectRefresh: Bool { !projects.isEmpty }

    private mutating func repo(_ path: String?, _ byLower: [String: String]) -> String? {
        guard let r = path.flatMap({ byLower[$0.lowercased()] }) else { return nil }
        if !repos.contains(r) { repos.append(r) }
        return r
    }

    private mutating func project(_ account: String, _ id: String?) {
        if projects.contains(where: { $0.workspace == account && ($0.project == nil || $0.project == id) }) { return }
        if id == nil { projects.removeAll { $0.workspace == account } }
        projects.append((account, id))
    }
}

/// Runs the event sources and turns their events into refreshes. Main thread only.
/// The code host and CI accounts poll. Trackers keep the slower ProjectStore poll, and the cloud pushes their changes.
final class LiveSync {
    enum State: Equatable { case off, connecting, live, error(String) }

    weak var sink: RelaySink?
    let secrets: SecretStore
    let cursors: CursorStore

    /// The state of the cloud. Polling has no state here: it always runs.
    private(set) var state: State = .off {
        didSet {
            guard state != oldValue else { return }
            log.info("Cloud: \(String(describing: self.state), privacy: .public)")
            sink?.relayStateChanged()
            bus.post(DataChange(.connection, origin: .event))
        }
    }
    private(set) var lastEventAt: Date?
    /// The last burst of events. The window footer shows one ring for it.
    private(set) var lastBurstAt: Date?
    var bus: ChangeBus = .shared
    /// The last poll that succeeded. The footer shows it.
    private(set) var lastPoll: Date?
    /// Repos without a webhook. They poll at the normal interval while the cloud is live.
    var unhooked: () -> [String] = { [] }

    private var merger: EventMerger?
    private var polling: PollingSource?
    private var fallback: PollingSource?
    private var cloud: CloudSource?
    private var consumer: Task<Void, Never>?
    private var watching = false
    private var buffer: [ProviderEvent] = []
    private var resyncs: [AccountID] = []
    private var fullResync = false
    private var flushWork: DispatchWorkItem?
    private var pathMonitor: NWPathMonitor?
    private var plan: Plan?
    // Callbacks of stopped sources can still come. They carry an old generation.
    private var generation = 0

    /// What the sources poll. A change starts them again.
    private struct Plan: Equatable {
        var polled: [String]
        var fallback: [String]
        var accounts: [AccountConfig]
        var cloud: Bool
        var normal: TimeInterval
        var active: TimeInterval
        var safety: TimeInterval?
    }

    init(secrets: SecretStore, cursors: CursorStore = CursorStore(url: URL(fileURLWithPath: CURSORS_PATH))) {
        self.secrets = secrets
        self.cursors = cursors
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
    }

    /// The cloud cursor was a user default before the sync sources.
    static func migrateCursor(into cursors: CursorStore, defaults: UserDefaults = .standard) {
        let old = defaults.integer(forKey: "relayCursor")
        defaults.removeObject(forKey: "relayCursor")
        if old > 0, cursors[CloudSource.cursorKey] == nil { cursors[CloudSource.cursorKey] = Cursor(rawValue: String(old)) }
    }

    var canRun: Bool { RELAY.enabled && !RELAY.workerURL.isEmpty && !RELAY.deviceID.isEmpty }
    var isHealthy: Bool { state == .live }

    // MARK: Lifecycle

    /// Makes the sources again from the accounts, the repos and the cloud settings.
    func start() {
        stopSources()
        generation += 1
        let gen = generation
        let p = currentPlan()
        plan = p
        let polled = p.polled
        let onPolled: @Sendable (AccountID) -> Void = { _ in
            DispatchQueue.main.async { [weak self] in if self?.generation == gen { self?.lastPoll = Date() } }
        }
        let polling = PollingSource(providers: ENV.pollers(repos: polled), cursors: cursors, intervals: intervals, onPolled: onPolled)
        // Their own cursor file: two pollers of one account must not write the same cursor.
        let fallback = p.fallback.isEmpty ? nil
            : PollingSource(providers: ENV.pollers(repos: p.fallback),
                            cursors: CursorStore(url: URL(fileURLWithPath: FALLBACK_CURSORS_PATH)),
                            intervals: PollIntervals(normal: .seconds(POLL_NORMAL), active: .seconds(POLL_NORMAL)), onPolled: onPolled)
        let cloud = makeCloud(generation: gen)
        let merger = EventMerger(polling: polling, cloud: cloud, others: fallback.map { [$0] } ?? [], onCloudHealth: { h in
            DispatchQueue.main.async { [weak self] in if self?.generation == gen { self?.cloudHealth(h) } }
        })
        self.polling = polling
        self.fallback = fallback
        self.cloud = cloud
        self.merger = merger
        if cloud == nil { state = .off } else { watchNetwork() }
        let stream = merger.events()
        consumer = Task { @MainActor [weak self] in
            for await e in stream { self?.received(e) }
        }
    }

    /// Starts the sources again when the repos, the accounts, the hooks or the cloud settings changed.
    func update() {
        guard plan != nil, currentPlan() != plan else { return }
        start()
    }

    private func currentPlan() -> Plan {
        let fallback = canRun ? Set(unhooked()) : []
        return Plan(polled: REPOS.filter { !fallback.contains($0) }, fallback: REPOS.filter(fallback.contains),
                    accounts: ENV.accounts, cloud: canRun,
                    normal: POLL_NORMAL, active: POLL_ACTIVE, safety: RELAY.reconcileInterval)
    }

    func stop() {
        plan = nil
        generation += 1
        stopSources()
        pathMonitor?.cancel()
        pathMonitor = nil
        state = .off
    }

    /// The cloud starts over from the first event.
    func forgetCloudCursor() { cursors[CloudSource.cursorKey] = nil }

    private func stopSources() {
        consumer?.cancel()
        consumer = nil
        if let merger { Task { await merger.stop() } }
        merger = nil
        polling = nil
        fallback = nil
        cloud = nil
    }

    private func makeCloud(generation gen: Int) -> CloudSource? {
        guard canRun, let base = URL(string: RELAY.workerURL) else { STORE_WRITES.use(nil); return nil }
        guard let token = secrets.get(SecretStore.deviceToken) else {
            STORE_WRITES.use(nil)
            state = .error("This Mac has not joined the cloud")
            return nil
        }
        // The old single-tenant relay has no store.
        STORE_WRITES.use(RELAY.hookRoute == nil ? nil : CloudLink(base: base, token: token, device: RELAY.deviceID))
        return CloudSource(base: base, token: token, http: URLSessionTransport(), socket: URLSessionWebSockets(), cursors: cursors,
                           onResync: { a in
            DispatchQueue.main.async { [weak self] in if self?.generation == gen { self?.resync(a) } }
        }, onStore: { DispatchQueue.main.async { STORE_WRITES.syncNow() } })
    }

    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            DispatchQueue.main.async {
                STORE_WRITES.syncNow()
                if let self, self.cloud != nil, self.state != .live { self.start() }
            }
        }
        m.start(queue: .main)
        pathMonitor = m
    }

    @objc private func didWake() { if merger != nil { start() } }

    private func cloudHealth(_ h: SourceHealth) {
        guard cloud != nil else { return }
        switch h {
        case .off: state = .off
        case .connecting: state = .connecting
        case .live: state = .live
        case .failed(let m): state = .error(m)
        }
    }

    // MARK: Intervals

    private var intervals: PollIntervals {
        PollIntervals(normal: .seconds(POLL_NORMAL), active: .seconds(watching ? POLL_ACTIVE : POLL_NORMAL),
                      safety: .seconds(RELAY.reconcileInterval ?? 600))
    }

    /// The fast cadence is for the person who looks at a run in progress. Without one, a busy repo polls at the normal interval.
    func setWatching(_ on: Bool) {
        guard on != watching else { return }
        watching = on
        let i = intervals
        if let polling { Task { await polling.setIntervals(i) } }
    }

    /// Reads the cloud log now.
    func sync() {
        if let cloud { Task { await cloud.sync() } }
    }

    // MARK: Events

    private func received(_ e: ProviderEvent) {
        lastEventAt = Date()
        buffer.append(e)
        scheduleFlush()
    }

    /// nil: the cloud log has a gap, so all repos and projects refresh.
    private func resync(_ a: AccountID?) {
        if let a { resyncs.append(a) } else { fullResync = true }
        scheduleFlush()
    }

    // A burst of events gives one refresh.
    private func scheduleFlush() {
        flushWork?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.flush() }
        flushWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    private func flush() {
        guard let sink else { return }
        let events = buffer, accounts = resyncs, full = fullResync
        buffer = []
        resyncs = []
        fullResync = false
        if full || !events.isEmpty {
            lastBurstAt = Date()
            bus.post(DataChange(.connection, origin: .event))
        }
        if full {
            log.info("Cloud log gap, full refresh")
            sink.relayFullRefresh { _ in }
            return
        }
        let trackers = Set(ENV.trackerIds)
        let plan = RefreshPlan(events, resyncs: accounts.filter { trackers.contains($0.id) }, knownRepos: REPOS)
        if plan.wantsRepoRefresh {
            log.info("Sync: \(events.count) event(s) for \(plan.repos.count) repo(s)")
            sink.relayRefresh(repos: plan.repos, includePRs: plan.includePRs, completedRuns: plan.completedRuns) { _ in }
        }
        if plan.wantsProjectRefresh {
            log.info("Sync: refresh \(plan.projects.count) project(s)")
            sink.relayProjectRefresh(plan.projects) { _ in }
        }
    }

    // Footer dot: colour, tooltip.
    var statusDot: (NSColor, String)? {
        switch state {
        case .off: return nil
        case .live: return (C_SUCCESS, "Live updates connected")
        case .connecting: return (.systemGray, "Live updates: connecting, polling meanwhile")
        case .error(let m): return (C_QUEUED, "Cloud error: \(m). Polling meanwhile.")
        }
    }
}
