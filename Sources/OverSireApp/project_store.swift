import Cocoa
import OverSireCore
import OverSireSync

struct NewItem {
    var projectKey: String
    var title: String
    var body: String                        // Markdown
    var fieldOptions: [String: String]      // field id ("state", "priority") → option id
    var labels: [String] = []               // label ids
    var parent: String?                     // item id
}

/// A comment event: the project, and the item when the event names it.
struct CommentHint: Equatable {
    let workspace: String
    let project: String
    let item: String?
}

/// The tracker accounts. AppEnvironment gives the real ones. Tests give fakes.
protocol TrackerDirectory: AnyObject {
    /// The tracker account ids, for example the Plane workspace slugs.
    var trackerIds: [String] { get }
    func tracker(_ id: String) -> (any Tracker)?
    /// Why `tracker(id)` is nil, when the directory knows.
    func trackerError(_ id: String) -> String?
}

extension TrackerDirectory {
    func trackerError(_ id: String) -> String? { nil }
}

/// Optional tracker features that the store uses when a tracker has them.
protocol MemberListing: Tracker { func memberNames() async -> [String: String] }
protocol SelfAssigning: Tracker { func assignMe(_ i: ItemRef) async throws }
protocol StatusTimeline: Tracker { func timeline(_ i: ItemRef, statuses: [StatusOption], current: String?) async throws -> [ActivityEntry] }
protocol IntakeKeying: Tracker { func intakeSequences(_ p: ProjectRef) async throws -> [String: Int] }
/// All pending intake bodies in one listing. Work item id → detail.
protocol IntakeListing: Tracker { func intakeDetails(_ p: ProjectRef) async throws -> [String: IntakeDetail] }
/// One item without comments and links, for a read that needs only the fields.
protocol ItemReading: Tracker { func item(_ i: ItemRef) async throws -> Item }
/// A tracker whose Markdown names uploaded files by id.
protocol AssetLinking: AssetResolving { func assetIds(in markdown: String) -> Set<String> }

// Last snapshots, the activity feed, and unread state. Fetches run off the main
// queue. The first snapshot of a project creates no activity, so launch is quiet.

final class ProjectStore {
    static let changed = Notification.Name("ProjectStoreChanged")

    private(set) var snapshots: [String: ProjectSnapshot] = [:] { didSet { keyIndex = nil } }
    /// Upper-case item key → the project and the position in its items. Built on the first lookup after a write.
    private var keyIndex: [String: (project: String, at: Int)]?
    /// The keys that a refresh holds. A refresh lets each key go when its read ends.
    var refreshing: Set<String> { Set(owner.keys) }
    /// Key → the refresh that holds it, and the lane of that refresh.
    private var owner: [String: Hold] = [:]
    /// Key → the read in flight.
    private var reads: [String: Read] = [:]
    private var lastRefresh = 0
    private(set) var lastError: String?
    /// The id of the item that `create` made last.
    private(set) var lastCreated: String?
    /// The last fetch error of each project, by store key. A good fetch clears it.
    private(set) var errors: [String: String] = [:]
    private(set) var tracked: [ProjectSummary] = []
    /// True on a client: the mirror gives the data, and the store reads no tracker.
    var client = MODE == .client
    /// The catalog of the home. A client reads the capabilities of a project from it.
    var catalog: ClientCatalog?
    /// Set on a client. It asks the source app for the reads that need a live tracker. `what` is "comments", "timeline",
    /// "options", "intakeDetail", "labels" or "links". It gives the `data` of the answer.
    var remote: ((_ what: String, _ args: JSONValue) async throws -> JSONValue)?
    /// Items that came before their project doc, by store key.
    private var orphans: [String: [Item]] = [:]
    private(set) var liveKeys: Set<String> = []
    private(set) var intakeKeys: [String: Int] = [:]   // work item id → number, for keys such as TREBI-264
    private var loadingKeys: Set<String> = []
    private var askedKeys: Set<String> = []   // intake work item ids that Plane gave no number for

    private let trackers: TrackerDirectory
    private let notifier: ProjectNotifier
    private let statePath: String
    private let activityPath: String
    private var timer: Timer?
    private var readActivity = Set<String>() { didSet { unread = nil } }
    private var readItems = Set<String>() { didSet { unread = nil } }
    private var activityCache: [ActivityEntry] = [] { didSet { unread = nil } }   // newest first
    /// The kept entries, newest first. The mirror reads them.
    var activityEntries: [ActivityEntry] { activityCache }
    private var unread: (count: Int, items: Set<String>)?
    // Each item that was in a snapshot. An item that comes back over the item limit is not new.
    private var seenItems = Set<String>()
    private var timelineCache: [String: (stamp: String, entries: [ActivityEntry])] = [:]
    private var optionCache: [String: (options: ItemOptions, at: Date)] = [:]
    private var timelineWaiters: [String: [(Result<[ActivityEntry], ProviderError>) -> Void]] = [:]
    private var suppressNotify = Set<String>()
    /// The item ids and epic ids that this app changed, and who changed them. The next poll names that actor in the rows of the change.
    private(set) var writeActors: [String: EventActor] = [:]
    /// Item id → the agent that posted a comment, until the comment read names it in the comment row.
    private var commentActors: [String: (actor: EventActor, until: Date)] = [:]
    /// How long an agent comment waits for its comment read.
    var commentMarkTTL: TimeInterval = 300
    /// Takes the epic rows. Tests set their own desk.
    var events: EventDesk = EVENTS
    private var assetCache: [String: (url: String, at: Date)] = [:]
    private(set) lazy var relations = RelationCache(
        tracker: { [weak self] in self?.trackers.tracker($0.project.workspace) as? any RelationManaging },
        ref: { [weak self] key in self?.item(key: key).flatMap { $0.item.ref(in: $0.snap.summary.ref) } },
        disk: RelationDisk(folder: URL(fileURLWithPath: (statePath as NSString).deletingLastPathComponent).appendingPathComponent("relations")),
        project: { [weak self] in self?.item(key: $0)?.key },
        updatedAt: { [weak self] in self?.item(key: $0)?.item.updatedAt })
    var relayIsLive: () -> Bool = { false }
    /// True while the live feed of the account is up (Big Timer).
    var feedIsLive: (AccountID) -> Bool = { _ in false }
    /// True on the Mac that leads the automations. The other Mac refreshes later on cloud events.
    var leads: () -> Bool = { true }
    var now: () -> Date = Date.init
    /// A forced refresh of a key during its refresh runs once more after it. The callers wait for that run.
    private var again: [String: [(Bool) -> Void]] = [:]
    private var againUser: Set<String> = []
    /// Workspace → the end of the pause after a rate limit.
    private(set) var cooldown: [String: Date] = [:]
    /// Keys that wait for a pause or a delay, by the time of their refresh.
    private var waiting: [Date: Set<String>] = [:]
    /// The shortest pause after a rate limit, and the wait of the Mac that does not lead.
    var cooldownMin: TimeInterval = 60
    /// A live project polls when its snapshot is older than this, also while the relay is live.
    var liveMaxAge: TimeInterval = 1800
    /// A page view reads a project whose snapshot is older than this.
    var viewMaxAge: TimeInterval = 60
    /// A read that runs longer than this lets its key go.
    var maxRead: TimeInterval = 180
    /// The snapshot limit of the last refresh. A new limit forces a refresh.
    private var limitUsed: Int?
    var otherMacDelay: TimeInterval = 60
    var onChange: ((DataChange) -> Void)?
    var busy: BusyTracker?
    var hold = false   // `--uishots` loading mode: fetches never end
    /// The most items that one comment read takes.
    var commentCap = 20
    /// After a break longer than this, a read writes one feed line for the project and reads no comments.
    var awayAfter: TimeInterval = 86400
    /// Store key → the item ids that comment events name.
    private var commentWant: [String: Set<String>] = [:]
    /// Store key → the time of the oldest comment event that names no item.
    private var commentAny: [String: Date] = [:]
    /// Store key → the item ids that wait for a comment read, and the order of the keys.
    private var commentQueue: [String: Set<String>] = [:]
    private var commentOrder: [String] = []
    /// The comment read that runs now. `releaseStuckReads` stops it after `maxRead`.
    private var commentRun: (id: Int, key: String, started: Date, task: Task<Void, Never>)?
    private var commentRuns = 0

    static let noToken = "Add a token for this account in Settings › Accounts and sync."

    init(trackers: TrackerDirectory, notifier: ProjectNotifier, statePath: String, activityPath: String) {
        self.trackers = trackers
        self.notifier = notifier
        self.statePath = statePath
        self.activityPath = activityPath
        load()
    }

    func track(_ projects: [ProjectSummary], live: Set<String>) {
        let changed = Set(tracked.map(\.ref.storeKey)) != Set(projects.map(\.ref.storeKey))
        tracked = projects
        liveKeys = live
        PROJECT_ICONS.track(projects)
        if !client {
            restartTimer()
            let keys = projects.map { $0.ref.storeKey }
            refresh(keys, force: limitUsed != nil && limitUsed != snapshotLimit) { _ in }
        }
        if changed { publish(DataChange(.projects, origin: .event)) }
    }

    func restartTimer() {
        timer?.invalidate()
        let minutes = min(30, max(2, PROJECTS_CFG.pollMinutes))
        let interval = TimeInterval(minutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.poll() }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func poll() {
        guard !client else { return }
        releaseStuckReads()
        let keys = tracked.map(\.ref.storeKey).filter { key in
            // A live project waits for its events, unless its last refresh failed or is old.
            if isLive(key) {
                guard errors[key] == nil, let at = snapshots[key]?.fetchedAt else { return true }
                return now().timeIntervalSince(at) > liveMaxAge
            }
            return true
        }
        refresh(keys, force: false) { _ in }
    }

    /// The tracker read of the keys, for the toolbar menu and the page notes. A tracker polls on its own timer: no retry plan.
    func part(_ keys: [String]) -> PagePart {
        let named = keys.count == 1 ? tracked.first { $0.ref.storeKey == keys[0] }?.identifier ?? keys[0] : nil
        let name = keys.count == 1 ? tracked.first { $0.ref.storeKey == keys[0] }.map { ENV.trackerName($0.ref.account) } ?? ENV.trackerNames() : ENV.trackerNames()
        let title = named.map { "\(name) project \($0)" } ?? "\(name) projects"
        let at = keys.compactMap { snapshots[$0]?.fetchedAt }.min()
        let state: ReadState
        let why = keys.compactMap { errors[$0] }.first
        // With no data, the failure stays while Plane polls again, so the page does not say "no items".
        if at == nil, let why {
            state = .failed(why)
        } else if keys.contains(where: refreshing.contains) {
            state = .busy(shows: at)
        } else if let why {
            state = at.map { .stale($0, error: why) } ?? .failed(why)
        } else {
            state = at.map(ReadState.fresh) ?? .idle
        }
        return PagePart(id: "plane", title: title, state: state, retry: nil,
                        refresh: { [weak self] in self?.refresh(keys, force: true, priority: .user) { _ in } }, auto: false)
    }

    /// The Plane read of all tracked projects.
    var plane: PagePart { part(tracked.map(\.ref.storeKey)) }

    /// One refresh of a project at a time. A forced refresh of a running project runs once more after it.
    /// A forced user refresh takes a key that a running refresh did not read yet, so a write does not wait for the other projects.
    /// A workspace in its rate limit pause refreshes after the pause.
    /// A refresh that joins a running refresh keeps the lane of the running one. Its rerun uses the lane of the last caller.
    func refresh(_ keys: [String], force: Bool, priority: CallPriority = .background, done: @escaping (Bool) -> Void) {
        // A client has no tracker. The mirror pull gives the data.
        guard !client else { done(true); return }
        let takes = force && priority == .user
        let running = keys.filter { owner[$0] != nil && (!takes || reads[$0]?.lane == .user) }
        var todo = keys.filter { !running.contains($0) }
        var done = done
        // The new refresh reads a taken key after their call, so the callers that wait for a rerun of it wait for this refresh.
        // A background read of a taken key stops.
        let taken = todo.filter { owner[$0] != nil }
        for k in taken where reads[k] != nil { abandon(k, .taken) }
        let moved = taken.flatMap { again.removeValue(forKey: $0) ?? [] }
        againUser.subtract(taken)
        if !moved.isEmpty {
            let first = done
            done = { ok in first(ok); moved.forEach { $0(ok) } }
        }
        if force, let first = running.first {
            for k in running where again[k] == nil { again[k] = [] }
            if priority == .user { againUser.formUnion(running) }
            again[first]?.append(done)
            done = { _ in }
        }
        let paused = todo.filter { k in workspace(of: k).flatMap { cooldown[$0] }.map { $0 > now() } ?? false }
        if !paused.isEmpty {
            todo.removeAll { paused.contains($0) }
            for k in paused { later(k, at: cooldown[workspace(of: k)!]!) }
        }
        guard !todo.isEmpty else { done(paused.isEmpty); return }
        lastRefresh += 1
        let id = lastRefresh
        for k in todo { owner[k] = Hold(run: id, lane: priority) }
        for at in waiting.keys { waiting[at]?.subtract(todo) }
        publish(force ? DataChange(.projects, projects: Set(todo), origin: .user) : nil)
        let jobs = ProjectStore.oldestFirst(tracked.filter { todo.contains($0.ref.storeKey) }, snapshots: snapshots).map { p in
            (p, trackers.tracker(p.ref.workspace), snapshots[p.ref.storeKey])
        }
        let limit = snapshotLimit, minPause = cooldownMin
        limitUsed = limit
        let label = { (n: Int) in jobs.count == 1 ? "Loading \(jobs[0].0.identifier)" : "Loading projects: \(n) of \(jobs.count)" }
        let token = busy?.begin(label(0))
        if hold { return }
        CallPriority.task(priority) { [weak self] in
            guard let self = self else { return }
            var error: String?
            var limited: [String: TimeInterval] = [:]   // workspace → the pause
            for (n, (p, client, previous)) in jobs.enumerated() {
                let key = p.ref.storeKey
                guard await MainActor.run(body: { self.owner[key]?.run == id }) else { continue }
                if n > 0, let token { await MainActor.run { self.busy?.update(token, label(n)) } }
                guard limited[p.ref.workspace] == nil else {
                    await MainActor.run { self.endRead(key, .skipped, by: id, force: force, started: nil) }
                    continue
                }
                let r: ProjectRead? = await withCheckedContinuation { (c: CheckedContinuation<ProjectRead?, Never>) in
                    DispatchQueue.main.async {
                        let noClient = client == nil
                            ? self.trackers.trackerError(p.ref.workspace).map { "\(ProjectStore.noToken) (\($0))" } ?? ProjectStore.noToken : ""
                        let started = self.startRead(key, by: id, lane: priority, force: force, resume: { c.resume(returning: $0) }) {
                            await ProjectStore.read(client, p, previous: previous, limit: limit, minPause: minPause, noClient: noClient)
                        }
                        if !started { c.resume(returning: nil) }
                    }
                }
                switch r {
                case .failed(let why):
                    error = "\(p.ref.workspace): " + why
                case .limited(let why, let pause):
                    limited[p.ref.workspace] = pause
                    error = "\(p.ref.workspace): " + why
                case nil, .taken, .timedOut, .fresh, .skipped:
                    break
                }
            }
            DispatchQueue.main.async {
                if let token { self.busy?.end(token) }
                self.lastError = error
                done(error == nil)
            }
        }
    }

    private struct Hold { let run: Int; let lane: CallPriority }

    private struct Read {
        let run: Int
        let lane: CallPriority
        let force: Bool
        let started: Date
        let task: Task<Void, Never>
        /// Lets the loop of the refresh go on.
        let resume: (ProjectRead?) -> Void
    }

    /// The end of the read of one project in a refresh.
    private enum ProjectRead {
        case fresh(ProjectSnapshot, gone: Set<String>)
        case failed(String)
        case limited(String, pause: TimeInterval)
        /// The read did not run: an other project of the workspace hit the rate limit.
        case skipped
        /// A user refresh took the key during the read.
        case taken
        /// The watchdog let the key go.
        case timedOut
    }

    /// One read of a project: the snapshot, the gone items and the log line. A cancelled read writes no line.
    private static func read(_ client: (any Tracker)?, _ p: ProjectSummary, previous: ProjectSnapshot?, limit: Int,
                             minPause: TimeInterval, noClient: String) async -> ProjectRead {
        let started = Date()
        let line = { (level: LogLevel, msg: String) in
            guard !Task.isCancelled else { return }
            var e = LogEntry(level: level, area: .sync, job: "\(ENV.trackerName(p.ref.account)) poll", subject: p.identifier, host: p.ref.workspace,
                             message: msg, ms: Int(Date().timeIntervalSince(started) * 1000))
            e.verbose = level == .ok ? true : nil
            APP_LOG.write(e)
        }
        guard let client else {
            line(.error, noClient)
            return .failed(noClient)
        }
        switch await Result(awaiting: { try await ProjectStore.snapshot(client, p, limit: limit, previous: previous) }) {
        case .success(let s):
            line(.ok, "\(s.items.count) items")
            return .fresh(s, gone: await ProjectStore.gone(client, previous, s))
        case .failure(let e):
            line(.error, e.message)
            if case .rateLimited(let after) = e {
                return .limited(e.message, pause: max(minPause, after.map { Double($0.components.seconds) } ?? 0))
            }
            return .failed(e.message)
        }
    }

    /// Starts the read of a key in its own task. False when a forced refresh took the key.
    private func startRead(_ key: String, by id: Int, lane: CallPriority, force: Bool, resume: @escaping (ProjectRead?) -> Void,
                           read: @escaping @Sendable () async -> ProjectRead) -> Bool {
        guard owner[key]?.run == id else { return false }
        let task = CallPriority.task(lane) { [self] in
            let r = await read()
            await MainActor.run { self.finishRead(key, by: id, r) }
        }
        reads[key] = Read(run: id, lane: lane, force: force, started: now(), task: task, resume: resume)
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + maxRead + 1) { [weak self] in self?.releaseStuckReads() }
        return true
    }

    /// Ends the read, then lets the loop go on. The answer of a read that was taken or timed out is stale: ignore it.
    private func finishRead(_ key: String, by id: Int, _ r: ProjectRead) {
        guard let read = reads[key], read.run == id else { return }
        reads[key] = nil
        endRead(key, r, by: id, force: read.force, started: read.started)
        read.resume(r)
    }

    /// Cancels the read of a key and lets the loop go on at once. The cancelled task may end later: `finishRead` ignores it.
    private func abandon(_ key: String, _ why: ProjectRead) {
        guard let read = reads.removeValue(forKey: key) else { return }
        read.task.cancel()
        read.resume(why)
    }

    /// Lets go of each key whose read runs longer than `maxRead`.
    func releaseStuckReads() {
        let stuck = reads.filter { now().timeIntervalSince($0.value.started) > maxRead }
        for (key, read) in stuck {
            let seconds = Int(now().timeIntervalSince(read.started))
            abandon(key, .timedOut)
            owner[key] = nil
            let p = tracked.first { $0.ref.storeKey == key }
            let name = p.map { ENV.trackerName($0.ref.account) } ?? "the tracker"
            let message = "No answer from \(name) after \(seconds) s. OverSire stopped the read and reads the project again later."
            APP_LOG.write(LogEntry(level: .warn, area: .sync, job: p == nil ? "Tracker poll" : "\(name) poll", subject: p?.identifier ?? key, host: p?.ref.workspace,
                                   message: message, ms: seconds * 1000))
            errors[key] = "No answer from \(name) after \(seconds) s."
            publish(DataChange(.projects, projects: [key]))
            runAgain([key])
        }
        if let run = commentRun, now().timeIntervalSince(run.started) > maxRead {
            let seconds = Int(now().timeIntervalSince(run.started))
            run.task.cancel()
            commentRun = nil
            let p = tracked.first { $0.ref.storeKey == run.key }
            let name = p.map { "\(ENV.trackerName($0.ref.account)) comments" } ?? "Tracker comments"
            APP_LOG.write(LogEntry(level: .warn, area: .sync, job: name, subject: p?.identifier ?? run.key, host: p?.ref.workspace,
                                   message: "No answer from \(p.map { ENV.trackerName($0.ref.account) } ?? "the tracker") after \(seconds) s. OverSire stopped the comment read.", ms: seconds * 1000))
        }
        pumpComments()
    }

    /// A page shows this project. A snapshot older than `viewMaxAge` is read again as a user call.
    func viewed(_ key: String) {
        releaseStuckReads()
        guard tracked.contains(where: { $0.ref.storeKey == key }) else { return }
        if owner[key]?.lane == .user || againUser.contains(key) { return }
        let age = snapshots[key].map { now().timeIntervalSince($0.fetchedAt) } ?? .infinity
        guard age > viewMaxAge else { return }
        refresh([key], force: true, priority: .user) { _ in }
    }

    /// The Mac woke and the network is up. The project in view reads first as a user call, then all the others in the background.
    func wake(first: String?) {
        releaseStuckReads()
        if let first, tracked.contains(where: { $0.ref.storeKey == first }) {
            refresh([first], force: true, priority: .user) { _ in }
        }
        refresh(tracked.map(\.ref.storeKey), force: false) { _ in }
    }

    /// The store key of the tracked project with this identifier.
    func key(identifier: String) -> String? {
        tracked.first { $0.identifier.uppercased() == identifier.uppercased() }?.ref.storeKey
    }

    /// The projects by the age of their snapshot, the oldest first. A project with no snapshot goes first. Ties keep the order.
    static func oldestFirst(_ projects: [ProjectSummary], snapshots: [String: ProjectSnapshot]) -> [ProjectSummary] {
        projects.enumerated().sorted { a, b in
            let x = snapshots[a.element.ref.storeKey]?.fetchedAt ?? .distantPast
            let y = snapshots[b.element.ref.storeKey]?.fetchedAt ?? .distantPast
            return x == y ? a.offset < b.offset : x < y
        }.map(\.element)
    }

    /// Keeps the read, lets the key go and runs the forced refreshes that came during the read.
    private func endRead(_ key: String, _ read: ProjectRead, by id: Int, force: Bool, started: Date?) {
        guard owner[key]?.run == id else { return }
        owner[key] = nil
        reads[key] = nil
        var projects: Set<String> = force ? [key] : []
        var changed = Set<String>()
        switch read {
        case .fresh(var snap, let gone):
            errors[key] = nil
            let prior = snapshots[key]
            snap = ProjectStore.carried(snap, from: prior)
            let old = Dictionary((prior?.items ?? []).map { ($0.id, $0.activityAt) }, uniquingKeysWith: { a, _ in a })
            let moved = snap.items.filter { old[$0.id] != $0.activityAt }
            changed = Set(moved.map(\.key))
            let away = prior.map { now().timeIntervalSince($0.fetchedAt) > awayAfter } ?? false
            if away { snap = ProjectStore.settled(snap) }
            let before = prior.map(ProjectStore.digest)
            absorb(snap, gone: gone, away: away ? Set(moved.map(\.id)) : nil)
            if before != snapshots[key].map(ProjectStore.digest) { projects.insert(key) }
            save()
            queueComments(key, prior: away ? nil : prior, started: started)
        case .failed(let why):
            errors[key] = why
        case .limited(let why, let pause):
            errors[key] = why
            if let ws = workspace(of: key) { cooldown[ws] = now().addingTimeInterval(pause) }
            fallthrough
        case .skipped:
            if let end = workspace(of: key).flatMap({ cooldown[$0] }) { later(key, at: end) }
        case .taken, .timedOut:
            break
        }
        relations.refresh(changed: changed)
        publish(projects.isEmpty ? nil : DataChange([.projects, .intake], projects: projects, origin: force ? .user : .poll))
        runAgain([key])
        pumpComments()
    }

    /// True while comment reads wait or run.
    var commentsPending: Bool { commentRun != nil || !commentOrder.isEmpty }

    /// Picks the items for the comment read after a list read. A first read and a read after a long break pick none.
    private func queueComments(_ key: String, prior: ProjectSnapshot?, started: Date?) {
        guard let prior, let snap = snapshots[key] else {
            commentWant[key] = nil
            commentAny[key] = nil
            commentQueue[key] = nil
            return
        }
        let live = isLive(key)
        let named = commentWant.removeValue(forKey: key) ?? []
        var anyComment = false
        if let at = commentAny[key], let started, at <= started {
            anyComment = true
            commentAny[key] = nil
        }
        let t = ProjectStore.commentTargets(old: prior, new: snap, live: live, named: named, anyComment: anyComment, cap: commentCap)
        if !t.read.isEmpty {
            commentQueue[key, default: []].formUnion(t.read)
            if !commentOrder.contains(key) { commentOrder.append(key) }
        }
        if live && !t.rest.isEmpty { commentWant[key] = Set(t.rest) }
    }

    /// Reads the comments of the queued items, one project at a time, when no list read holds a key.
    private func pumpComments() {
        guard commentRun == nil, owner.isEmpty, !hold else { return }
        while !commentOrder.isEmpty {
            let key = commentOrder.removeFirst()
            guard let ids = commentQueue.removeValue(forKey: key), let snap = snapshots[key],
                  tracked.contains(where: { $0.ref.storeKey == key }),
                  let client = trackers.tracker(snap.summary.ref.workspace) else { continue }
            let live = isLive(key)
            let targets = snap.items.filter { ids.contains($0.id) && (live || $0.commentsDue) }
                .sorted { $0.activityAt > $1.activityAt }.prefix(commentCap)
                .compactMap { i in i.ref(in: snap.summary.ref).map { (id: i.id, at: i.activityAt, ref: $0) } }
            if targets.isEmpty { continue }
            let summary = snap.summary
            commentRuns += 1
            let id = commentRuns
            let task = CallPriority.task(.background) { [weak self] in
                guard let self = self else { return }
                let r = await ProjectStore.readComments(client, summary, targets)
                await MainActor.run {
                    guard self.commentRun?.id == id else { return }
                    self.commentRun = nil
                    self.mergeComments(key, r)
                    self.pumpComments()
                }
            }
            commentRun = (id, key, now(), task)
            DispatchQueue.main.asyncAfter(wallDeadline: .now() + maxRead + 1) { [weak self] in self?.releaseStuckReads() }
            return
        }
    }

    /// One comment call for each item. A failed call leaves its item due. A rate limit stops the read.
    private static func readComments(_ t: any Tracker, _ p: ProjectSummary,
                                     _ targets: [(id: String, at: Date, ref: ItemRef)]) async -> [String: (at: Date, comments: [Comment])] {
        let started = Date()
        var out: [String: (at: Date, comments: [Comment])] = [:]
        var limited = false
        for target in targets {
            guard !Task.isCancelled else { break }
            do { out[target.id] = (target.at, try await t.comments(target.ref)) } catch ProviderError.rateLimited {
                limited = true
                break
            } catch {}
        }
        var e = LogEntry(level: limited ? .warn : .ok, area: .sync, job: "\(ENV.trackerName(p.ref.account)) comments", subject: p.identifier, host: p.ref.workspace,
                         message: limited ? "\(ENV.trackerName(p.ref.account)) limits the rate. Read \(out.count) of \(targets.count) items."
                                          : "\(out.count) of \(targets.count) items",
                         ms: Int(Date().timeIntervalSince(started) * 1000))
        e.verbose = limited ? nil : true
        APP_LOG.write(e)
        return out
    }

    /// Applies a comment read to the current snapshot. The change goes through `absorb`: feed lines, notifications and event rows.
    private func mergeComments(_ key: String, _ read: [String: (at: Date, comments: [Comment])]) {
        guard tracked.contains(where: { $0.ref.storeKey == key }), let cur = snapshots[key],
              let merged = ProjectStore.merged(cur, read) else { return }
        let before = ProjectStore.digest(cur)
        absorb(merged)
        read.keys.forEach { commentActors[$0] = nil }
        save()
        if before != snapshots[key].map(ProjectStore.digest) { publish(DataChange(.projects, projects: [key], origin: .poll)) }
    }

    /// The forced refreshes that came during the refresh of `keys`: one more run for all of them.
    private func runAgain(_ keys: [String]) {
        let next = keys.filter { again[$0] != nil }
        guard !next.isEmpty else { return }
        let waiters = next.flatMap { again.removeValue(forKey: $0) ?? [] }
        let lane: CallPriority = next.contains { againUser.contains($0) } ? .user : .background
        againUser.subtract(next)
        refresh(next, force: true, priority: lane) { ok in waiters.forEach { $0(ok) } }
    }

    private func workspace(of key: String) -> String? { tracked.first { $0.ref.storeKey == key }?.ref.workspace }

    private func account(of key: String) -> AccountID? { tracked.first { $0.ref.storeKey == key }?.ref.account }

    /// Events reach the project: the cloud pushes its webhooks, or its account has a live feed. Then it does not poll.
    func isLive(_ key: String) -> Bool {
        (liveKeys.contains(key) && relayIsLive()) || account(of: key).map(feedIsLive) == true
    }

    /// For the header chip. It keeps the Plane chip as it is.
    func showsLive(_ key: String) -> Bool {
        liveKeys.contains(key) || account(of: key).map(feedIsLive) == true
    }

    /// A feed went up or down: the headers draw again.
    func feedLiveChanged() { publish(DataChange(.projects, origin: .event)) }

    /// Refreshes the key at `at`. Keys with the same time share one refresh.
    private func later(_ key: String, at: Date) {
        if waiting.values.contains(where: { $0.contains(key) }) { return }
        if waiting[at] != nil { waiting[at]?.insert(key); return }
        waiting[at] = [key]
        DispatchQueue.main.asyncAfter(wallDeadline: .now() + max(0, at.timeIntervalSince(now()))) { [weak self] in
            guard let self, let keys = self.waiting.removeValue(forKey: at) else { return }
            self.refresh(Array(keys), force: false) { _ in }
        }
    }

    // A nil project means all tracked projects of the workspace. No events means all.
    func refreshForEvents(_ events: [(workspace: String, project: String?)], comments: [CommentHint] = [],
                          done: @escaping (Bool) -> Void) {
        let keys = tracked.map(\.ref).filter { ref in
            events.isEmpty || events.contains { $0.workspace == ref.workspace && ($0.project == nil || $0.project == ref.id) }
        }.map(\.storeKey)
        if keys.isEmpty { done(true); return }
        for hint in comments {
            for ref in tracked.map(\.ref) where ref.workspace == hint.workspace && ref.id == hint.project {
                if let item = hint.item { commentWant[ref.storeKey, default: []].insert(item) } else if commentAny[ref.storeKey] == nil {
                    commentAny[ref.storeKey] = now()
                }
            }
        }
        // Both Macs get the same cloud events. The Mac that does not lead waits, so the two do not load at once.
        guard leads() else {
            let at = now().addingTimeInterval(otherMacDelay)
            for k in keys { later(k, at: at) }
            done(true)
            return
        }
        refresh(keys, force: true, done: done)
    }

    /// The comments of an item from its tracker, on the main thread.
    func comments(key: String, done: @escaping (Result<[Comment], ProviderError>) -> Void) {
        if remote != nil {
            remoteRead("comments", ["item": .string(key)], done: done)
            return
        }
        guard let found = item(key: key), let client = trackers.tracker(found.snap.summary.ref.workspace),
              let ref = found.item.ref(in: found.snap.summary.ref) else {
            done(.failure(.notFound))
            return
        }
        CallPriority.task(.user) {
            let r = await Result(awaiting: { try await client.comments(ref) })
            DispatchQueue.main.async { done(r) }
        }
    }

    func timeline(itemId: String, done: @escaping ([ActivityEntry]) -> Void) {
        timelineRead(itemId: itemId) { done((try? $0.get()) ?? []) }
    }

    /// The timeline of an item. A failure comes only from the source app of a client. A local failure gives no entries.
    func timelineRead(itemId: String, done: @escaping (Result<[ActivityEntry], ProviderError>) -> Void) {
        guard let found = item(itemId) else { done(.success([])); return }
        let client = trackers.tracker(found.snap.summary.ref.workspace)
        guard client != nil || remote != nil else { done(.success([])); return }
        let stamp = isoFmt.string(from: found.item.activityAt)
        let cacheKey = itemId + "|" + stamp
        if let hit = timelineCache[cacheKey] { done(.success(hit.entries)); return }
        guard let ref = found.item.ref(in: found.snap.summary.ref) else { done(.success([])); return }
        if timelineWaiters[cacheKey] != nil { timelineWaiters[cacheKey]?.append(done); return }
        timelineWaiters[cacheKey] = [done]
        let projectKey = found.key
        let states = found.snap.statusOptions
        let current = found.snap.option(found.item.statusOptionId)?.name
        let remote = self.remote
        CallPriority.task(.user) { [weak self] in
            let result: Result<[ActivityEntry], ProviderError>
            if remote != nil {
                result = await self?.remoteRows("timeline", ["item": .string(itemId)]) ?? .failure(.notFound)
            } else if let client {
                result = await Result(awaiting: { try await ProjectStore.timeline(client, ref, statuses: states, current: current) })
            } else {
                result = .success([])
            }
            guard let self else { return }
            DispatchQueue.main.async {
                let waiters = self.timelineWaiters.removeValue(forKey: cacheKey) ?? []
                let out: Result<[ActivityEntry], ProviderError>
                if case .success(let list) = result {
                    let entries: [ActivityEntry] = list.suffix(200).map { e in
                        var c = e
                        c.projectKey = projectKey
                        c.itemId = itemId
                        c.unread = self.isUnread(c)
                        return c
                    }
                    self.timelineCache[cacheKey] = (stamp, entries)
                    out = .success(entries)
                } else if remote != nil, case .failure(let e) = result {
                    out = .failure(e)
                } else {
                    out = .success([])
                }
                waiters.forEach { $0(out) }
                if case .success = out { self.publish(DataChange(.projects, projects: [projectKey])) }
            }
        }
    }

    /// Asks the source app for a read. The source gives `{"rows": …}`. `done` runs on the main thread.
    private func remoteRead<T: Codable & Sendable>(_ what: String, _ args: [String: JSONValue], done: @escaping (Result<T, ProviderError>) -> Void) {
        Task { [weak self] in
            let r: Result<T, ProviderError> = await self?.remoteRows(what, args) ?? .failure(.notFound)
            await MainActor.run { done(r) }
        }
    }

    private func remoteRows<T: Codable & Sendable>(_ what: String, _ args: [String: JSONValue]) async -> Result<T, ProviderError> {
        guard let remote else { return .failure(.notFound) }
        do {
            let data = try await remote(what, .object(args))
            return .success(try MirrorCodec.value(MirrorRows<T>.self, from: data).rows)
        } catch let e as ProviderError {
            return .failure(e)
        } catch {
            return .failure(.vendor(code: "remote", message: error.localizedDescription))
        }
    }

    func activity(limit: Int, project: String?) -> [ActivityEntry] {
        Array(activityCache.lazy.filter { project == nil || $0.projectKey == project }.prefix(limit).map { e in
            var c = e
            c.unread = self.isUnread(e)
            return c
        })
    }

    // The menu icon and each list row ask this, so it must be cheap.
    private func unreadRows() -> (count: Int, items: Set<String>) {
        if let unread { return unread }
        var n = 0, items = Set<String>()
        for e in activityCache.prefix(500) where isUnread(e) && !e.itemId.isEmpty {
            n += 1
            items.insert(e.itemId)
        }
        unread = (n, items)
        return (n, items)
    }

    private func isUnread(_ e: ActivityEntry) -> Bool {
        !readActivity.contains(e.id) && !readItems.contains(e.itemId)
    }

    func unreadCount() -> Int { unreadRows().count }

    func isUnread(itemId: String) -> Bool { unreadRows().items.contains(itemId) }

    func markRead(itemId: String) {
        guard !itemId.isEmpty, readItems.insert(itemId).inserted else { return }
        save()
        publish(DataChange(.projects, origin: .user))
    }

    func markActivityRead(_ id: String) {
        guard readActivity.insert(id).inserted else { return }
        save()
        publish(DataChange(.projects, origin: .user))
    }

    /// Refuses to close a parent with open sub-items, unless `force` (OVERSIRE-396).
    func setStatus(itemId: String, optionId: String, force: Bool = false, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        if !force, refusesClose(itemId, to: optionId) { done(false); return }
        let before = item(itemId)
        let done = { [events] (ok: Bool) in
            if ok, let b = before { events.stateSet(b.item, in: b.snap, to: optionId, actor: actor) }
            done(ok)
        }
        write(itemId, by: actor, failure: "Could not change the status", done: done) { c, ref in
            try await c.update(ref, ItemPatch(status: optionId))
        }
    }

    func tracker(of p: ProjectRef) -> (any Tracker)? { trackers.tracker(p.workspace) }

    func update(itemId: String, _ patch: ItemPatch, failure: String, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        if refusesClose(itemId, to: patch.status) { done(false); return }
        write(itemId, by: actor, failure: failure, done: done) { c, ref in
            try await c.update(ref, patch)
        }
    }

    // The labels of the project and the members of the workspace, for the item window menus.
    func options(projectKey: String, done: @escaping (ItemOptions) -> Void) {
        if let hit = optionCache[projectKey], -hit.at.timeIntervalSinceNow < 600 { done(hit.options); return }
        if remote != nil {
            remoteRead("options", ["project": .string(projectKey)]) { [weak self] (r: Result<ItemOptions, ProviderError>) in
                guard case .success(let o) = r else { done(ItemOptions(labels: [], members: [])); return }
                self?.optionCache[projectKey] = (o, Date())
                done(o)
            }
            return
        }
        guard let snap = snapshots[projectKey], let client = trackers.tracker(snap.summary.ref.workspace) else {
            done(ItemOptions(labels: [], members: []))
            return
        }
        let project = snap.summary.ref
        CallPriority.task(.user) { [weak self] in
            let labels = (try? await (client as? any LabelManaging)?.labels(project)) ?? []
            let names = await (client as? any MemberListing)?.memberNames() ?? [:]
            let members = names.map { StatusOption(id: $0.key, name: $0.value, color: "") }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            let options = ItemOptions(labels: labels, members: members)
            DispatchQueue.main.async {
                self?.optionCache[projectKey] = (options, Date())
                done(options)
            }
        }
    }

    func comment(itemId: String, body: String, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        // The comment row comes later, from the comment read. The mark waits for it.
        if actor.type != .human { commentActors[itemId] = (actor, now().addingTimeInterval(commentMarkTTL)) }
        let done = { [weak self] (ok: Bool) in
            if !ok { self?.commentActors[itemId] = nil }
            done(ok)
        }
        write(itemId, by: actor, failure: "Could not post the comment", done: done) { c, ref in
            try await c.comment(ref, markdown: body)
        }
    }

    func edit(itemId: String, title: String, body: String, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        write(itemId, by: actor, failure: nil, done: done) { c, ref in
            try await c.update(ref, ItemPatch(title: title, bodyMarkdown: body))
        }
    }

    func relate(itemId: String, _ patch: RelationPatch, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        write(itemId, by: actor, failure: nil, done: done) { c, ref in
            guard let r = c as? any RelationManaging else { throw ProviderError.unsupported(.relations) }
            try await r.apply(patch, to: ref)
        }
    }

    /// Adds a link to the item. A failure sets `lastError` to the message of the tracker.
    func addLink(itemId: String, url: URL, title: String, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        write(itemId, by: actor, failure: nil, done: done) { c, ref in
            guard let l = c as? any LinkManaging else { throw ProviderError.unsupported(.links) }
            try await l.addLink(ref, url: url, title: title)
        }
    }

    /// Uploads a file to the item and gives the attachment id. It does not refresh the project.
    func attach(itemId: String, _ file: AttachmentUpload, done: @escaping (Result<String, ProviderError>) -> Void) {
        guard let found = item(itemId), let client = trackers.tracker(found.snap.summary.ref.workspace),
              let ref = found.item.ref(in: found.snap.summary.ref) else { done(.failure(.notFound)); return }
        CallPriority.task(.user) {
            let r = await Result(awaiting: {
                guard let a = client as? any AttachmentUploading else { throw ProviderError.unsupported(.attachments) }
                return try await a.attach(file, to: ref)
            })
            DispatchQueue.main.async { done(r) }
        }
    }

    /// The labels of a project.
    func labels(projectKey: String, done: @escaping (Result<[StatusOption], ProviderError>) -> Void) {
        if remote != nil { remoteRead("labels", ["project": .string(projectKey)], done: done); return }
        guard let snap = snapshot(projectKey), let client = trackers.tracker(snap.summary.ref.workspace) else { done(.failure(.notFound)); return }
        let project = snap.summary.ref
        CallPriority.task(.user) {
            let r = await Result(awaiting: {
                guard let l = client as? any LabelManaging else { throw ProviderError.unsupported(.labels) }
                return try await l.labels(project)
            })
            DispatchQueue.main.async { done(r) }
        }
    }

    /// The links of an item. A tracker with no links, or a failed read, gives none.
    func links(itemId: String, done: @escaping ([URL]) -> Void) {
        if remote != nil {
            remoteRead("links", ["item": .string(itemId)]) { (r: Result<[URL], ProviderError>) in done((try? r.get()) ?? []) }
            return
        }
        guard let found = item(itemId), let client = trackers.tracker(found.snap.summary.ref.workspace) as? any LinkManaging,
              let ref = found.item.ref(in: found.snap.summary.ref) else { done([]); return }
        CallPriority.task(.user) {
            let urls = (try? await client.links(ref)) ?? []
            DispatchQueue.main.async { done(urls) }
        }
    }

    /// True when the tracker of the project has the capability.
    func has(_ c: Capability, in snap: ProjectSnapshot) -> Bool {
        if let catalog {
            return catalog.projects.first { $0.summary.ref.storeKey == snap.summary.ref.storeKey }?.capabilities.contains(c) ?? false
        }
        return tracker(of: snap.summary.ref)?.capabilities.contains(c) ?? false
    }

    /// A nil epic removes the item from its epic.
    func setEpic(_ epic: EpicID?, itemId: String, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        writeActors[itemId] = actor
        write(itemId, by: actor, failure: nil, done: { [weak self] ok in
            self?.writeActors[itemId] = nil
            done(ok)
        }) { c, ref in
            guard let t = c as? any EpicTracking else { throw ProviderError.unsupported(.epics) }
            try await t.setEpic(epic, for: ref)
        }
    }

    func createEpic(_ d: EpicDraft, projectKey: String, by actor: EventActor = .user, done: @escaping (Result<Epic, ProviderError>) -> Void) {
        epicCall(projectKey, actor: actor, done: done) { t, snap in try await t.createEpic(d, in: snap.summary.ref) }
    }

    func updateEpic(_ e: Epic, _ patch: EpicPatch, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        epicCall(e.project.storeKey, actor: actor, done: { done($0.isOk) }) { t, _ in try await t.updateEpic(e, patch) }
    }

    /// One epic write, then a user refresh of the project. A failure sets `lastError`. The refresh names `actor` in the epic rows.
    private func epicCall(_ key: String, actor: EventActor, done: @escaping (Result<Epic, ProviderError>) -> Void,
                          _ op: @escaping @Sendable (any EpicTracking, ProjectSnapshot) async throws -> Epic) {
        guard let snap = snapshots[key], let client = trackers.tracker(snap.summary.ref.workspace) else {
            lastError = "OverSire has no loaded project \(key)."
            done(.failure(.unauthorized))
            return
        }
        CallPriority.task(.user) { [weak self] in
            let result = await Result(awaiting: {
                guard let t = client as? any EpicTracking else { throw ProviderError.unsupported(.epics) }
                return try await op(t, snap)
            })
            DispatchQueue.main.async {
                guard let self else { return }
                let mark = (try? result.get())?.id.rawValue
                if let mark { self.writeActors[mark] = actor }
                if case .failure(let e) = result { self.lastError = e.message }
                self.refresh([key], force: true, priority: .user) { _ in
                    if let mark { self.writeActors[mark] = nil }
                    done(result)
                }
            }
        }
    }

    /// An epic of a project, by store key or identifier.
    func epic(_ projectKey: String, _ id: EpicID) -> (snap: ProjectSnapshot, epic: Epic)? {
        guard let snap = snapshot(projectKey), let epic = snap.epic(id) else { return nil }
        return (snap, epic)
    }

    /// All epics of all loaded projects.
    var allEpics: [(snap: ProjectSnapshot, epic: Epic)] {
        snapshots.values.sorted { $0.summary.identifier < $1.summary.identifier }.flatMap { s in (s.epics ?? []).map { (s, $0) } }
    }

    func assignMe(itemId: String, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        write(itemId, by: actor, failure: "Could not assign the item", done: done) { c, ref in try await ProjectStore.assignMe(c, ref) }
    }

    // The first "in progress" state, plus assign me. A project without such a state only assigns.
    func start(itemId: String, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        guard let found = item(itemId) else { done(false); return }
        let progress = found.snap.statusOptions.first { $0.category == .progress }
        let current = found.item.statusOptionId
        let done = { [events] (ok: Bool) in
            if ok, let progress, current != progress.id { events.stateSet(found.item, in: found.snap, to: progress.id, actor: actor) }
            done(ok)
        }
        write(itemId, by: actor, failure: nil, done: done) { c, ref in
            if let progress, current != progress.id { try await c.update(ref, ItemPatch(status: progress.id)) }
            try await ProjectStore.assignMe(c, ref)
        }
    }

    // Sets each sub-item to the first completed state, with a comment, then reloads once.
    // A sub-item that is not loaded uses the parent URL: the tracker writes by id.
    func closeSubItems(_ ids: [String], parentId: String, done: @escaping (Bool) -> Void) {
        guard let found = item(parentId), let client = trackers.tracker(found.snap.summary.ref.workspace),
              let parent = found.item.ref(in: found.snap.summary.ref),
              let state = found.snap.firstState(group: "completed", else: .done) else { done(false); return }
        let snap = found.snap
        let refs = ids.map { id in
            snap.items.first { $0.id == id }?.ref(in: snap.summary.ref)
                ?? ItemRef(project: snap.summary.ref, id: id, key: "", url: parent.url)
        }
        let body = "OverSire closed this sub-item with its parent \(found.item.key)."
        ids.forEach { suppressNotify.insert($0) }
        CallPriority.task(.user) { [weak self] in
            var failed = 0
            for ref in refs {
                do {
                    try await client.update(ref, ItemPatch(status: state.id))
                    try? await client.comment(ref, markdown: body)
                } catch { failed += 1 }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if failed > 0 { self.lastError = "Could not close \(failed) of \(refs.count) sub-items" }
                self.refresh([found.key], force: true, priority: .user) { done($0 && failed == 0) }
            }
        }
    }

    // Sets the item and its open sub-items at all levels to the status, then reloads once (OVERSIRE-372).
    // A sub-item that is not loaded uses the parent URL: the tracker writes by id.
    func setStatusWithSubItems(itemId: String, optionId: String, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        guard let found = item(itemId), let client = trackers.tracker(found.snap.summary.ref.workspace),
              let parent = found.item.ref(in: found.snap.summary.ref),
              let state = found.snap.option(optionId) else { done(false); return }
        let snap = found.snap
        let ids = [found.item.id] + snap.openDescendants(of: found.item.id)
        let refs = ids.map { id in
            snap.items.first { $0.id == id }?.ref(in: snap.summary.ref) ?? ItemRef(project: snap.summary.ref, id: id, key: "", url: parent.url)
        }
        ids.forEach { suppressNotify.insert($0) }
        CallPriority.task(.user) { [weak self] in
            var failed = 0
            for ref in refs {
                do { try await client.update(ref, ItemPatch(status: optionId)) } catch { failed += 1 }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if failed > 0 { self.lastError = "Could not set \(failed) of \(refs.count) items to \(state.name)" }
                else { self.events.stateSet(found.item, in: snap, to: optionId, actor: actor) }
                self.refresh([found.key], force: true, priority: .user) { done($0 && failed == 0) }
            }
        }
    }

    // Moves a Done parent back to the first started state.
    func reopen(itemId: String, by actor: EventActor = .user, done: @escaping (Bool) -> Void) {
        guard let found = item(itemId), let state = found.snap.firstState(group: "started", else: .progress) else { done(false); return }
        let done = { [events] (ok: Bool) in
            if ok { events.stateSet(found.item, in: found.snap, to: state.id, actor: actor) }
            done(ok)
        }
        update(itemId: itemId, ItemPatch(status: state.id), failure: "Could not reopen the item", by: actor, done: done)
    }

    /// For `--uishots`: a changed copy of a snapshot. The next refresh replaces it.
    func seed(_ snap: ProjectSnapshot) {
        snapshots[snap.summary.ref.storeKey] = snap
        publish(DataChange(.projects, projects: [snap.summary.ref.storeKey]))
    }

    /// For `--uishots`: Plane is down and no snapshot is left. The next refresh replaces this.
    func seedDown(_ why: String) {
        snapshots = [:]
        for p in tracked { errors[p.ref.storeKey] = why }
        lastError = why
        publish(DataChange([.projects, .intake], origin: .event))
    }

    // `done(created, message)`.
    func create(_ new: NewItem, by actor: EventActor = .user, done: @escaping (Bool, String?) -> Void) {
        guard let snap = snapshots[new.projectKey], let client = trackers.tracker(snap.summary.ref.workspace) else {
            done(false, "The project is not loaded yet"); return
        }
        let draft = ItemDraft(title: new.title, bodyMarkdown: new.body.trimmingCharacters(in: .whitespacesAndNewlines),
                              status: new.fieldOptions[ProjectSnapshot.statusFieldId],
                              priority: snap.hasPriority ? new.fieldOptions[ProjectSnapshot.priorityFieldId] : nil,
                              labels: new.labels, parent: new.parent)
        let project = snap.summary.ref
        CallPriority.task(.user) { [weak self] in
            let added = await Result(awaiting: { try await client.create(draft, in: project).id })
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch added {
                case .failure(let e):
                    self.lastError = e.message
                    done(false, e.message)
                case .success(let itemId):
                    self.lastCreated = itemId
                    self.suppressNotify.insert(itemId)
                    if actor.type != .human { self.writeActors[itemId] = actor }
                    self.refresh([new.projectKey], force: true, priority: .user) { _ in
                        if actor.type != .human { self.writeActors[itemId] = nil }
                        done(true, nil)
                    }
                }
            }
        }
    }

    // Runs one change off the main queue, then reloads the project. A change made here is not news.
    /// True, with `lastError` set, when the state closes an item that has open sub-items.
    private func refusesClose(_ itemId: String, to stateId: String?) -> Bool {
        guard let stateId, let found = item(itemId) else { return false }
        let n = found.snap.blockingSubItems(found.item, to: stateId)
        guard n > 0 else { return false }
        lastError = Self.openSubItemsReason(found.item.key, n)
        return true
    }

    static func openSubItemsReason(_ key: String, _ n: Int) -> String {
        "\(key) has \(n) open sub-item\(n == 1 ? "" : "s"). Close \(n == 1 ? "it" : "them") first."
    }

    /// `actor`: an agent or the system is named in the poll rows of the write. The mark ends after the refresh.
    private func write(_ itemId: String, by actor: EventActor = .user, failure: String?, done: @escaping (Bool) -> Void,
                       _ op: @escaping @Sendable (any Tracker, ItemRef) async throws -> Void) {
        guard let found = item(itemId), let client = trackers.tracker(found.snap.summary.ref.workspace),
              let ref = found.item.ref(in: found.snap.summary.ref) else { done(false); return }
        suppressNotify.insert(itemId)
        let marked = actor.type != .human
        if marked { writeActors[itemId] = actor }
        CallPriority.task(.user) { [weak self] in
            let result = await Result(awaiting: { try await op(client, ref) })
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .failure(let e) = result {
                    self.suppressNotify.remove(itemId)
                    self.lastError = failure ?? e.message
                }
                self.timelineCache = self.timelineCache.filter { !$0.key.hasPrefix(itemId) }
                self.refresh([found.key], force: true, priority: .user) {
                    if marked { self.writeActors[itemId] = nil }
                    done($0 && result.isOk)
                }
            }
        }
    }

    // MARK: Intake

    func intakeDetail(projectKey: String, item: IntakeItem, priority: CallPriority = .user, done: @escaping (Result<IntakeDetail, ProviderError>) -> Void) {
        if remote != nil {
            let intake = (try? MirrorCodec.body(item)) ?? .object([:])
            remoteRead("intakeDetail", ["project": .string(projectKey), "intake": intake], done: done)
            return
        }
        guard let snap = snapshots[projectKey], let client = trackers.tracker(snap.summary.ref.workspace) else {
            done(.failure(.unauthorized)); return
        }
        let project = snap.summary.ref
        CallPriority.task(priority) {
            let r = await Result(awaiting: {
                guard let t = client as? any IntakeTriaging else { throw ProviderError.unsupported(.intake) }
                return try await t.intakeDetail(item, in: project)
            })
            DispatchQueue.main.async { done(r) }
        }
    }

    // The refresh then moves an accepted item into the list.
    func triage(projectKey: String, item: IntakeItem, action: IntakeAction, done: @escaping (Bool) -> Void) {
        guard let snap = snapshots[projectKey], let client = trackers.tracker(snap.summary.ref.workspace) else { done(false); return }
        suppressNotify.insert(item.workItemId)
        let project = snap.summary.ref
        CallPriority.task(.user) { [weak self] in
            let r = await Result(awaiting: {
                guard let t = client as? any IntakeTriaging else { throw ProviderError.unsupported(.intake) }
                try await t.triage(item, in: project, action)
            })
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let e) = r {
                    self.suppressNotify.remove(item.workItemId)
                    self.lastError = action.failure + e.message
                } else if case .accept = action {
                    EVENTS.action(.intakeAccepted, item: nil, project: snap.summary.identifier, verb: "intake:\(item.id)", item.name,
                                  payload: ["intake": .string(item.id), "title": .string(item.name)])
                }
                self.refresh([projectKey], force: true, priority: .user) { done($0 && r.isOk) }
            }
        }
    }

    // The numbers do not change, so one load per new item is enough.
    func loadIntakeKeys(projectKey: String, done: @escaping () -> Void) {
        guard let snap = snapshots[projectKey], let intake = snap.intake,
              intake.contains(where: { intakeKeys[$0.workItemId] == nil && !askedKeys.contains($0.workItemId) }), !loadingKeys.contains(projectKey),
              let client = trackers.tracker(snap.summary.ref.workspace) as? any IntakeKeying else { return }
        loadingKeys.insert(projectKey)
        let project = snap.summary.ref
        let asked = intake.map(\.workItemId)
        CallPriority.task(.user) { [weak self] in
            let r = await Result(awaiting: { try await client.intakeSequences(project) })
            DispatchQueue.main.async {
                guard let self else { return }
                self.loadingKeys.remove(projectKey)
                guard case .success(let found) = r else { return }
                // An id with no number stays asked. Without this, each page build asks again and builds again.
                self.askedKeys.formUnion(asked)
                let before = self.intakeKeys.count
                self.intakeKeys.merge(found) { $1 }
                if self.intakeKeys.count != before { done() }
            }
        }
    }

    // Plane images have an asset id as src. This puts signed download links in their place.
    func resolveImages(_ markdown: String, projectKey: String, done: @escaping (String) -> Void) {
        let linker = snapshots[projectKey].flatMap { trackers.tracker($0.summary.ref.workspace) as? any AssetLinking }
        let ids = linker?.assetIds(in: markdown) ?? []
        let todo = ids.filter { id in assetCache[id].map { -$0.at.timeIntervalSinceNow > 3000 } ?? true }
        func apply() -> String {
            var out = markdown
            for id in ids { if let u = assetCache[id]?.url { out = out.replacingOccurrences(of: "](\(id))", with: "](\(u))") } }
            return out
        }
        guard !todo.isEmpty, let client = linker else {
            done(apply()); return
        }
        CallPriority.task(.user) { [weak self] in
            var found: [(String, String)] = []
            for id in todo { if let u = try? await client.assetURL(id) { found.append((id, u.absoluteString)) } }
            DispatchQueue.main.async {
                guard let self else { return }
                for (id, u) in found { self.assetCache[id] = (u, Date()) }
                done(apply())
            }
        }
    }

    // New, changed and closed intake items. A closed item is accepted when it is now in the list.
    private func notifyIntake(old: ProjectSnapshot?, new snap: ProjectSnapshot) {
        guard PROJECTS_CFG.notifications(for: snap.summary.identifier)?.intake == true, let before = old?.intake, let after = snap.intake else { return }
        let was = Dictionary(before.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let now = Dictionary(after.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var lines: [(IntakeItem, String)] = []
        for i in after where !suppressNotify.contains(i.workItemId) {
            if let prev = was[i.id] {
                if prev.name != i.name || prev.priority != i.priority { lines.append((i, "Intake item changed")) }
            } else {
                lines.append((i, "New intake item" + (i.author.map { " from \($0)" } ?? "")))
            }
        }
        for i in before where now[i.id] == nil {
            if suppressNotify.remove(i.workItemId) != nil { continue }
            let accepted = snap.items.contains { $0.id == i.workItemId }
            lines.append((i, accepted ? "Intake item accepted" : "Intake item declined or removed"))
        }
        notifier.intake(lines, in: snap)
    }

    func item(_ id: String) -> (key: String, snap: ProjectSnapshot, item: Item)? {
        for (key, snap) in snapshots {
            if let item = snap.items.first(where: { $0.id == id }) { return (key, snap, item) }
        }
        return nil
    }

    func item(key: String) -> (key: String, snap: ProjectSnapshot, item: Item)? {
        if keyIndex == nil {
            var index: [String: (project: String, at: Int)] = [:]
            for (pk, snap) in snapshots {
                for (i, item) in snap.items.enumerated() where index[item.key.uppercased()] == nil {
                    index[item.key.uppercased()] = (pk, i)
                }
            }
            keyIndex = index
        }
        guard let hit = keyIndex?[key.uppercased()], let snap = snapshots[hit.project] else { return nil }
        return (hit.project, snap, snap.items[hit.at])
    }

    /// Finished: closed, and all sub-items closed. A Done blocker with open sub-items still blocks.
    func isDone(key: String) -> Bool {
        guard let (_, snap, item) = item(key: key) else { return false }
        return snap.isFinished(item)
    }

    /// The keys whose relations the plan needs: open members of open epics of the project, in epic order.
    /// Only loaded items count: an item that is only in the index has no ref.
    func planKeys(_ project: String) -> [String] {
        guard let snap = snapshots[project] else { return [] }
        let open = snap.sorted(snap.items.filter { $0.epicId != nil && !snap.isClosed($0.statusOptionId) })
        return snap.epicGroups(open).filter { $0.epic.map { !$0.state.isClosed } ?? false }.flatMap { $0.items.map(\.key) }
    }

    /// Shows the disk relations of the plan keys, then loads the missing and stale keys.
    func loadPlan(_ project: String) {
        guard let snap = snapshots[project] else { return }
        let at = Dictionary(snap.items.map { ($0.key.uppercased(), $0.updatedAt) }, uniquingKeysWith: { a, _ in a })
        relations.loadPlan(planKeys(project), updatedAt: { at[$0.uppercased()] })
    }

    /// The open blocker keys of an item, from the relation cache.
    func blockers(of key: String) -> [String] { relations.blockers(of: key) { isDone(key: $0) } }

    /// The window of items by newest activity. Closed items outside it do not load. Open items always load.
    var snapshotLimit: Int { Self.snapshotLimit(itemsPerProject: PROJECTS_CFG.itemsPerProject) }

    static func snapshotLimit(itemsPerProject n: Int) -> Int { min(300, max(100, n == 0 ? 200 : n)) }

    // MARK: Diff

    static func diff(_ old: ProjectSnapshot?, _ new: ProjectSnapshot) -> [(itemId: String, ItemChange)] {
        guard let old = old else { return [] }
        var out: [(String, ItemChange)] = []
        let oldById = Dictionary(old.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let newIds = Set(new.items.map(\.id))
        for item in new.items {
            guard let prev = oldById[item.id] else {
                out.append((item.id, .added))
                if item.mentionsMe { out.append((item.id, .mention)) }
                continue
            }
            if prev.statusOptionId != item.statusOptionId {
                out.append((item.id, .status(from: old.statusName(prev.statusOptionId), to: new.statusName(item.statusOptionId))))
            }
            let wasDone = old.option(prev.statusOptionId)?.category == .done
            let isDone = new.option(item.statusOptionId)?.category == .done
            if isDone && !wasDone { out.append((item.id, .closed)) }
            if wasDone && !isDone { out.append((item.id, .reopened)) }
            let names = Set(prev.fields.keys).union(item.fields.keys).subtracting(["Status"])
            for name in names.sorted() where prev.fields[name] != item.fields[name] {
                out.append((item.id, .field(name: name, from: prev.fields[name], to: item.fields[name])))
            }
            let oldA = Set(prev.assignees), newA = Set(item.assignees)
            for a in newA.subtracting(oldA).sorted() { out.append((item.id, .assigned(a))) }
            for a in oldA.subtracting(newA).sorted() { out.append((item.id, .unassigned(a))) }
            // A comment that the stamp already covers is not news.
            if let last = item.lastComment, last.id != prev.lastComment?.id, last.createdAt > (prev.commentsAt ?? old.fetchedAt) {
                let n = prev.lastComment == nil ? 1 : max(1, item.commentCount - prev.commentCount)
                out.append((item.id, .comments(new: n, last: last)))
                if item.mentionsMe { out.append((item.id, .mention)) }
            }
        }
        for item in old.items where !newIds.contains(item.id) {
            out.append((item.id, .removed))
        }
        return out
    }

    // MARK: Private

    // Applies the status categories that the user set in the project settings.
    static func localized(_ snap: ProjectSnapshot, cfg: ProjectsConfig = PROJECTS_CFG) -> ProjectSnapshot {
        var s = snap
        s.statusOptions = s.statusOptions.map { o in
            var o = o
            o.localCategory = cfg.local(snap.summary.identifier).categories[o.id]
            return o
        }
        return s
    }

    // Applies changed status categories to the snapshots in memory.
    func applyLocalSettings() {
        snapshots = snapshots.mapValues { ProjectStore.localized($0) }
        publish(DataChange(.projects, origin: .user))
    }

    /// The items that left the snapshot and that the tracker does not find. Other items only fell out of the item limit.
    /// A tracker with an index: an item that is not in the index is gone, with no call. With no index, nothing is gone.
    /// Else only a "not found" reply counts as removed; at most 20 checks for each poll.
    static func gone(_ client: Tracker, _ old: ProjectSnapshot?, _ new: ProjectSnapshot) async -> Set<String> {
        guard let old else { return [] }
        let ids = Set(new.items.map(\.id))
        if client is any ItemIndexing {
            guard let index = new.index else { return [] }
            let all = Set(index.map(\.id))
            return Set(old.items.filter { !ids.contains($0.id) && !all.contains($0.id) }.map(\.id))
        }
        var out = Set<String>()
        for item in old.items.filter({ !ids.contains($0.id) }).prefix(20) {
            guard let ref = item.ref(in: new.summary.ref) else { continue }
            do { _ = try await client.detail(ref) } catch ProviderError.notFound { out.insert(item.id) } catch {}
        }
        return out
    }

    /// `away`: the ids of the items that changed during a long break. They get one feed line in place of one line each.
    func absorb(_ snap: ProjectSnapshot, gone: Set<String> = [], away: Set<String>? = nil) {
        let key = snap.summary.ref.storeKey
        let old = snapshots[key]
        let all = ProjectStore.diff(old, snap)
        // An item that was in the index only joined the snapshot. It is not new.
        let known = Set(old?.index?.map(\.id) ?? [])
        let back = Set(all.compactMap { c -> String? in
            if case .added = c.1, seenItems.contains(c.itemId) || known.contains(c.itemId) { return c.itemId }
            return nil
        })
        let changes = all.filter { c in
            if case .removed = c.1 { return gone.contains(c.itemId) }
            return !back.contains(c.itemId)
        }
        seenItems.formUnion(snap.items.map(\.id))
        let snap = ProjectStore.localized(snap)
        snapshots[key] = snap
        notifyIntake(old: old, new: snap)
        commentActors = commentActors.filter { $0.value.until > now() }
        events.tracker(changes, old: old, new: snap, skipState: suppressNotify, actors: writeActors.merging(commentActors.mapValues(\.actor)) { a, _ in a })
        events.epics(old: old, new: snap, actors: writeActors)
        for id in snap.items.map(\.id) where old?.epicId(of: id) != snap.epicId(of: id) { writeActors[id] = nil }
        if let away, old != nil {
            let n = away.subtracting(back).count
            if n > 0 {
                append([ActivityEntry.make(projectKey: key, itemId: "", change: .away(items: n), actor: nil, url: snap.summary.url,
                                           at: snap.fetchedAt, itemKey: nil, title: snap.summary.title)])
            }
            suppressNotify.subtract(changes.map(\.itemId))
            return
        }
        guard old != nil, !changes.isEmpty else { return }
        let at = snap.fetchedAt
        let me = snap.me?.lowercased()
        var own = Set<String>()
        let entries = changes.map { pair -> ActivityEntry in
            let item = snap.items.first { $0.id == pair.itemId } ?? old?.items.first { $0.id == pair.itemId }
            let actor: String?
            switch pair.1 {
            case .added: actor = item?.author
            case .comments(_, let last): actor = last.author
            case .mention: actor = item?.lastComment?.author ?? item?.author
            default: actor = item?.updatedBy
            }
            let e = ActivityEntry.make(projectKey: key, itemId: pair.itemId, change: pair.1, actor: actor,
                                       url: item?.url ?? snap.summary.url, at: at, itemKey: item?.key, title: item?.title)
            // Changes made in OverSire or by me are not news.
            if suppressNotify.contains(pair.itemId) || (me != nil && actor?.lowercased() == me) { own.insert(e.id) }
            return e
        }
        append(entries)
        readActivity.formUnion(own)
        let filtered = zip(changes, entries).filter { !own.contains($1.id) }.map(\.0)
        suppressNotify.subtract(changes.map(\.itemId))
        guard let n = PROJECTS_CFG.notifications(for: snap.summary.identifier) else { return }
        notifier.handle(filtered, in: snap, settings: n)
    }

    private func append(_ entries: [ActivityEntry]) {
        let known = Set(activityCache.map(\.id))
        let fresh = entries.filter { !known.contains($0.id) }
        guard !fresh.isEmpty else { return }
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        activityCache = (fresh + activityCache).filter { $0.at >= cutoff }.sorted { $0.at > $1.at }
        writeActivity()
    }

    // Oldest first in the file.
    private func writeActivity() {
        let enc = JSONEncoder()
        let text = activityCache.reversed().compactMap { e -> String? in
            guard let d = try? enc.encode(e) else { return nil }
            return String(data: d, encoding: .utf8)
        }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(atPath: (activityPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? text.write(toFile: activityPath, atomically: true, encoding: .utf8)
    }

    /// Drops the rows of items that only moved across the item limit: an "added" after an older row,
    /// and a "removed" before a newer row of the same item. Newest first, in and out.
    static func withoutChurn(_ rows: [ActivityEntry]) -> [ActivityEntry] {
        var oldest: [String: String] = [:]
        for e in rows { oldest[e.itemId] = e.id }
        var newer = Set<String>()
        return rows.filter { e in
            defer { newer.insert(e.itemId) }
            switch e.change {
            case .added: return oldest[e.itemId] == e.id
            case .removed: return !newer.contains(e.itemId)
            default: return true
            }
        }
    }

    private struct Disk: Codable {
        var snapshots: [String: ProjectSnapshot]
        var readActivity: [String]
        var readItems: [String]
        var seenItems: [String]?
    }

    private func load() {
        if let data = FileManager.default.contents(atPath: statePath),
           let disk = try? JSONDecoder().decode(Disk.self, from: data) {
            snapshots = disk.snapshots.mapValues { ProjectStore.localized($0) }
            readActivity = Set(disk.readActivity)
            readItems = Set(disk.readItems)
            seenItems = Set(disk.seenItems ?? [])
        }
        let raw = (try? String(contentsOfFile: activityPath, encoding: .utf8)) ?? ""
        let dec = JSONDecoder()
        let rows = raw.split(separator: "\n").compactMap { line -> ActivityEntry? in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? dec.decode(ActivityEntry.self, from: d)
        }.sorted { $0.at > $1.at }
        activityCache = ProjectStore.withoutChurn(rows)
        if activityCache.count < rows.count { writeActivity() }
        if seenItems.isEmpty {
            seenItems = Set(snapshots.values.flatMap { $0.items.map(\.id) } + activityCache.map(\.itemId))
        }
    }

    private func save() {
        let disk = Disk(snapshots: snapshots, readActivity: Array(readActivity), readItems: Array(readItems),
                        seenItems: Array(seenItems))
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    /// A nil change tells the store observers only. The pages get no update.
    private func publish(_ c: DataChange?) {
        if let c { onChange?(c) }
        NotificationCenter.default.post(name: ProjectStore.changed, object: self)
    }

    /// The bytes of a snapshot without its fetch time, to find a fetch that changed nothing.
    static func digest(_ s: ProjectSnapshot) -> Data {
        let e = JSONEncoder()
        e.outputFormatting = .sortedKeys
        let bare = ProjectSnapshot(summary: s.summary, statusOptions: s.statusOptions, items: s.items, fetchedAt: .distantPast,
                                   fields: s.fields, me: s.me, meId: s.meId, index: s.index, intake: s.intake, epics: s.epics)
        return (try? e.encode(bare)) ?? Data()
    }
}

extension ProjectStore {
    /// The list of a project. It makes no comment calls: the comment fields come from `previous`, and the stamp tells which items are due.
    static func snapshot(_ t: any Tracker, _ summary: ProjectSummary, limit: Int,
                         previous: ProjectSnapshot?) async throws -> ProjectSnapshot {
        var ref = summary.ref
        ref.key = summary.identifier
        let me = try await t.probe().person
        let states = try await t.statuses(ref)
        // Before the items: the tracker then knows the pending intake items and does not load them as parents.
        let intake = try? await (t as? any IntakeTriaging)?.intake(ref)
        // Before the items too: the adapter then has a fresh member cache. A failure hides the epics and keeps the snapshot.
        let epics = t.capabilities.contains(.epics) ? try? await (t as? any EpicTracking)?.epics(in: ref) : nil
        let prevById = Dictionary((previous?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // An item that only joins the snapshot has no news, as in a first snapshot.
        let indexed = Set(previous?.index?.map(\.id) ?? [])
        var items: [Item] = []
        for var item in try await t.items(ref, since: nil, limit: limit) {
            if let prev = prevById[item.id] {
                item.commentCount = prev.commentCount
                item.lastComment = prev.lastComment
                item.mentionsMe = prev.mentionsMe
                item.commentsAt = prev.commentsAt ?? prev.activityAt
            } else if let previous, !indexed.contains(item.id) {
                // A new item: its comments are news from the last read. The body is in the list.
                item.commentsAt = previous.fetchedAt
                item.mentionsMe = (item.body ?? "").localizedCaseInsensitiveContains("@" + me.name)
            } else {
                item.commentsAt = item.activityAt
            }
            items.append(item)
        }
        var fields = [ProjectField(id: ProjectSnapshot.statusFieldId, name: "Status", options: states)]
        if t.capabilities.contains(.priority) {
            fields.append(ProjectField(id: ProjectSnapshot.priorityFieldId, name: "Priority",
                                       options: StatusOption.priorities.filter { $0.id != "none" }))
        }
        return ProjectSnapshot(summary: summary, statusOptions: states, items: items, fetchedAt: Date(),
                               fields: fields, me: me.name, meId: me.id, index: try? await (t as? any ItemIndexing)?.index(ref),
                               intake: intake, epics: epics)
    }
}

extension ProjectStore {
    static func withItems(_ s: ProjectSnapshot, _ items: [Item]) -> ProjectSnapshot {
        ProjectSnapshot(summary: s.summary, statusOptions: s.statusOptions, items: items, fetchedAt: s.fetchedAt,
                        fields: s.fields, me: s.me, meId: s.meId, index: s.index, intake: s.intake, epics: s.epics)
    }

    /// Copies the comment fields of `cur` to the items that both snapshots have. A merge that landed during a list read stays.
    static func carried(_ snap: ProjectSnapshot, from cur: ProjectSnapshot?) -> ProjectSnapshot {
        guard let cur else { return snap }
        let byId = Dictionary(cur.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return withItems(snap, snap.items.map { i in
            guard let c = byId[i.id] else { return i }
            var i = i
            i.commentCount = c.commentCount
            i.lastComment = c.lastComment
            i.mentionsMe = c.mentionsMe
            i.commentsAt = c.commentsAt ?? c.activityAt
            return i
        })
    }

    /// Marks the due items as read, with no news. For a read after a long break.
    static func settled(_ snap: ProjectSnapshot) -> ProjectSnapshot {
        withItems(snap, snap.items.map { i in
            guard i.commentsDue else { return i }
            var i = i
            i.commentsAt = i.activityAt
            i.mentionsMe = false
            return i
        })
    }

    /// Applies a comment read to the items whose activity is still the one that was read. Nil when no item applies.
    static func merged(_ cur: ProjectSnapshot, _ read: [String: (at: Date, comments: [Comment])]) -> ProjectSnapshot? {
        var applied = false
        let name = cur.me ?? ""
        let items = cur.items.map { i -> Item in
            guard let r = read[i.id], r.at == i.activityAt else { return i }
            applied = true
            var i = i
            let since = i.commentsAt ?? cur.fetchedAt
            i.commentCount = r.comments.count
            i.lastComment = r.comments.last
            i.mentionsMe = !name.isEmpty && r.comments.contains {
                $0.createdAt > since && ($0.body ?? "").localizedCaseInsensitiveContains("@" + name)
            }
            i.commentsAt = i.activityAt
            return i
        }
        return applied ? withItems(cur, items) : nil
    }

    /// The items for the next comment read, newest activity first. `rest` holds the items beyond `cap`.
    /// Live: the items that comment events name, and all changed items when an event names none. Polling: my due items.
    static func commentTargets(old: ProjectSnapshot, new: ProjectSnapshot, live: Bool, named: Set<String>, anyComment: Bool,
                               cap: Int) -> (read: [String], rest: [String]) {
        let before = Dictionary(old.items.map { ($0.id, $0.activityAt) }, uniquingKeysWith: { a, _ in a })
        let picked = new.items.filter { i in
            if live { return named.contains(i.id) || (anyComment && before[i.id] != i.activityAt) }
            return i.commentsDue && i.isMine(new.me)
        }.sorted { $0.activityAt > $1.activityAt }.map(\.id)
        return (Array(picked.prefix(cap)), Array(picked.dropFirst(cap)))
    }
}

extension ProjectStore {
    static func timeline(_ t: any Tracker, _ i: ItemRef, statuses: [StatusOption], current: String?) async throws -> [ActivityEntry] {
        if let t = t as? any StatusTimeline { return try await t.timeline(i, statuses: statuses, current: current) }
        return try await (t as? any TimelineReading)?.timeline(i) ?? []
    }

    /// The fields of one item. A tracker with ItemReading loads no comments and no links.
    static func item(_ t: any Tracker, _ i: ItemRef) async throws -> Item {
        if let r = t as? any ItemReading { return try await r.item(i) }
        return try await t.detail(i).item
    }

    /// Adds me and keeps the other assignees.
    static func assignMe(_ t: any Tracker, _ i: ItemRef) async throws {
        if let t = t as? any SelfAssigning { return try await t.assignMe(i) }
        let me = try await t.probe().person.id
        let now = try await t.detail(i).item.assignees
        if !now.contains(me) { try await t.update(i, ItemPatch(assignees: now + [me])) }
    }
}

extension Result {
    var isOk: Bool { if case .success = self { return true }; return false }
}

extension Result where Failure == ProviderError {
    init(awaiting op: () async throws -> Success) async {
        do { self = .success(try await op()) }
        catch let e as ProviderError { self = .failure(e) }
        catch { self = .failure(.transport(error.localizedDescription)) }
    }
}

// MARK: Mirror

extension ProjectStore {
    /// Applies the delta of a pull of the mirror feed (OVERSIRE-527). It writes no event row and no feed line:
    /// the source writes them. It tells the user of new items and changes, as a poll does.
    func mirrored(_ d: MirrorDelta) {
        var touched = Set<String>()
        if d.reset {
            for key in snapshots.keys where d.projects[key] == nil { snapshots[key] = nil; touched.insert(key) }
            orphans = [:]
        }
        for key in d.removedProjects where snapshots.removeValue(forKey: key) != nil { touched.insert(key) }
        let keys = Set(d.projects.keys).union(d.items.keys).union(d.removedItems.keys).subtracting(d.removedProjects)
        for key in keys.sorted() {
            let prior = snapshots[key]
            let upserts = (orphans.removeValue(forKey: key) ?? []) + (d.items[key] ?? [])
            guard let base = d.projects[key] ?? prior else { orphans[key] = upserts; continue }
            var items = d.reset ? [] : (prior?.items ?? [])
            var at = Dictionary(items.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { a, _ in a })
            for i in upserts {
                if let n = at[i.id] { items[n] = i } else { at[i.id] = items.count; items.append(i) }
            }
            if let gone = d.removedItems[key].map(Set.init), !gone.isEmpty { items.removeAll { gone.contains($0.id) } }
            let snap = ProjectStore.localized(ProjectStore.withItems(base, items))
            snapshots[key] = snap
            touched.insert(key)
            if let prior, now().timeIntervalSince(prior.fetchedAt) <= awayAfter { notifyMirrored(old: prior, new: snap) }
            seenItems.formUnion(items.map(\.id))
        }
        if !d.activity.isEmpty {
            // The first read is quiet, as the first snapshot of a poll is.
            if d.reset, activityCache.isEmpty { readActivity.formUnion(d.activity.map(\.id)) }
            append(d.activity)
        }
        guard !touched.isEmpty || !d.activity.isEmpty || d.reset else { return }
        save()
        publish(DataChange([.projects, .intake], projects: touched, origin: .poll))
    }

    private func notifyMirrored(old: ProjectSnapshot, new snap: ProjectSnapshot) {
        let all = ProjectStore.diff(old, snap)
        let known = Set(old.index?.map(\.id) ?? [])
        let back = Set(all.compactMap { c -> String? in
            if case .added = c.1, seenItems.contains(c.itemId) || known.contains(c.itemId) { return c.itemId }
            return nil
        })
        let changes = all.filter { c in
            if case .removed = c.1 { return false }
            return !back.contains(c.itemId)
        }
        notifyIntake(old: old, new: snap)
        guard !changes.isEmpty, let n = PROJECTS_CFG.notifications(for: snap.summary.identifier) else { return }
        notifier.handle(changes, in: snap, settings: n)
    }
}
