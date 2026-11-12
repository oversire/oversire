import Cocoa
import OverSireCore

struct NewItem {
    var projectKey: String
    var title: String
    var body: String                        // Markdown
    var fieldOptions: [String: String]      // field id ("state", "priority") → option id
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

    private(set) var snapshots: [String: ProjectSnapshot] = [:]
    private(set) var refreshing: Set<String> = []
    private(set) var lastError: String?
    /// The id of the item that `create` made last.
    private(set) var lastCreated: String?
    /// The last fetch error of each project, by store key. A good fetch clears it.
    private(set) var errors: [String: String] = [:]
    private(set) var tracked: [ProjectSummary] = []
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
    private var unread: (count: Int, items: Set<String>)?
    // Each item that was in a snapshot. An item that comes back over the item limit is not new.
    private var seenItems = Set<String>()
    private var timelineCache: [String: (stamp: String, entries: [ActivityEntry])] = [:]
    private var optionCache: [String: (options: ItemOptions, at: Date)] = [:]
    private var timelineWaiters: [String: [([ActivityEntry]) -> Void]] = [:]
    private var suppressNotify = Set<String>()
    private var assetCache: [String: (url: String, at: Date)] = [:]
    private(set) lazy var relations = RelationCache(
        tracker: { [weak self] in self?.trackers.tracker($0.project.workspace) as? any RelationManaging },
        ref: { [weak self] key in self?.item(key: key).flatMap { $0.item.ref(in: $0.snap.summary.ref) } })
    var relayIsLive: () -> Bool = { false }
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
    /// The snapshot limit of the last refresh. A new limit forces a refresh.
    private var limitUsed: Int?
    var otherMacDelay: TimeInterval = 60
    var onChange: ((DataChange) -> Void)?
    var busy: BusyTracker?
    var hold = false   // `--uishots` loading mode: fetches never end

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
        restartTimer()
        let keys = projects.map { $0.ref.storeKey }
        refresh(keys, force: limitUsed != nil && limitUsed != snapshotLimit) { _ in }
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
        let liveRelay = relayIsLive()
        let keys = tracked.map(\.ref.storeKey).filter { key in
            // A live project waits for its events, unless its last refresh failed or is old.
            if liveKeys.contains(key), liveRelay {
                guard errors[key] == nil, let at = snapshots[key]?.fetchedAt else { return true }
                return now().timeIntervalSince(at) > liveMaxAge
            }
            return true
        }
        refresh(keys, force: false) { _ in }
    }

    /// The Plane read of the keys, for the toolbar menu and the page notes. Plane polls on its own timer: no retry plan.
    func part(_ keys: [String]) -> PagePart {
        let named = keys.count == 1 ? tracked.first { $0.ref.storeKey == keys[0] }?.identifier ?? keys[0] : nil
        let title = named.map { "Plane project \($0)" } ?? "Plane projects"
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
    /// A workspace in its rate limit pause refreshes after the pause.
    /// A refresh that joins a running refresh keeps the lane of the running one. Its rerun uses the lane of the last caller.
    func refresh(_ keys: [String], force: Bool, priority: CallPriority = .background, done: @escaping (Bool) -> Void) {
        let running = keys.filter { refreshing.contains($0) }
        var todo = keys.filter { !refreshing.contains($0) }
        var done = done
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
        for k in todo { refreshing.insert(k) }
        for at in waiting.keys { waiting[at]?.subtract(todo) }
        publish(force ? DataChange(.projects, projects: Set(todo), origin: .user) : nil)
        let jobs = tracked.filter { todo.contains($0.ref.storeKey) }.map { p in
            (p, trackers.tracker(p.ref.workspace), snapshots[p.ref.storeKey])
        }
        let limit = snapshotLimit, minPause = cooldownMin
        limitUsed = limit
        let label = { (n: Int) in jobs.count == 1 ? "Loading \(jobs[0].0.identifier)" : "Loading projects: \(n) of \(jobs.count)" }
        let token = busy?.begin(label(0))
        if hold { return }
        CallPriority.task(priority) { [weak self] in
            guard let self = self else { return }
            var fresh: [ProjectSnapshot] = []
            var gone: [String: Set<String>] = [:]
            var error: String?
            var errors: [String: String] = [:]
            var limited: [String: TimeInterval] = [:]   // workspace → the pause
            var skipped: [String] = []
            for (n, (p, client, previous)) in jobs.enumerated() {
                if limited[p.ref.workspace] != nil { skipped.append(p.ref.storeKey); continue }
                if n > 0, let token { await MainActor.run { self.busy?.update(token, label(n)) } }
                let started = Date()
                let line = { (level: LogLevel, msg: String) in
                    var e = LogEntry(level: level, area: .sync, job: "Plane poll", subject: p.identifier, host: p.ref.workspace,
                                     message: msg, ms: Int(Date().timeIntervalSince(started) * 1000))
                    e.verbose = level == .ok ? true : nil
                    APP_LOG.write(e)
                }
                guard let client else {
                    let why = self.trackers.trackerError(p.ref.workspace).map { "\(ProjectStore.noToken) (\($0))" } ?? ProjectStore.noToken
                    error = "\(p.ref.workspace): " + why
                    errors[p.ref.storeKey] = why
                    line(.error, why)
                    continue
                }
                switch await Result(awaiting: { try await ProjectStore.snapshot(client, p, limit: limit, previous: previous) }) {
                case .success(let s):
                    fresh.append(s)
                    gone[p.ref.storeKey] = await ProjectStore.gone(client, previous, s)
                    line(.ok, "\(s.items.count) items")
                case .failure(let e):
                    error = "\(p.ref.workspace): " + e.message
                    errors[p.ref.storeKey] = e.message
                    line(.error, e.message)
                    if case .rateLimited(let after) = e {
                        limited[p.ref.workspace] = max(minPause, after.map { Double($0.components.seconds) } ?? 0)
                        skipped.append(p.ref.storeKey)
                    }
                }
            }
            let failed = error != nil
            DispatchQueue.main.async {
                if let token { self.busy?.end(token) }
                for k in todo { self.refreshing.remove(k); self.errors[k] = errors[k] ?? (skipped.contains(k) ? self.errors[k] : nil) }
                self.lastError = error
                for (ws, pause) in limited { self.cooldown[ws] = self.now().addingTimeInterval(pause) }
                for k in skipped { if let ws = self.workspace(of: k), let end = self.cooldown[ws] { self.later(k, at: end) } }
                var changed = Set<String>()
                var projects = force ? Set(todo) : []
                for snap in fresh {
                    let key = snap.summary.ref.storeKey
                    let old = Dictionary((self.snapshots[key]?.items ?? []).map { ($0.id, $0.activityAt) },
                                         uniquingKeysWith: { a, _ in a })
                    changed.formUnion(snap.items.filter { old[$0.id] != $0.activityAt }.map(\.key))
                    let before = self.snapshots[key].map(ProjectStore.digest)
                    self.absorb(snap, gone: gone[key] ?? [])
                    if before != self.snapshots[key].map(ProjectStore.digest) { projects.insert(key) }
                }
                self.save()
                self.relations.refresh(changed: changed)
                self.publish(projects.isEmpty ? nil : DataChange([.projects, .intake], projects: projects, origin: force ? .user : .poll))
                done(!failed)
                self.runAgain(todo)
            }
        }
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

    /// Refreshes the key at `at`. Keys with the same time share one refresh.
    private func later(_ key: String, at: Date) {
        if waiting.values.contains(where: { $0.contains(key) }) { return }
        if waiting[at] != nil { waiting[at]?.insert(key); return }
        waiting[at] = [key]
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, at.timeIntervalSince(now()))) { [weak self] in
            guard let self, let keys = self.waiting.removeValue(forKey: at) else { return }
            self.refresh(Array(keys), force: false) { _ in }
        }
    }

    // A nil project means all tracked projects of the workspace. No events means all.
    func refreshForEvents(_ events: [(workspace: String, project: String?)], done: @escaping (Bool) -> Void) {
        let keys = tracked.map(\.ref).filter { ref in
            events.isEmpty || events.contains { $0.workspace == ref.workspace && ($0.project == nil || $0.project == ref.id) }
        }.map(\.storeKey)
        if keys.isEmpty { done(true); return }
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
        guard let found = item(itemId), let client = trackers.tracker(found.snap.summary.ref.workspace) else { done([]); return }
        let stamp = isoFmt.string(from: found.item.activityAt)
        let cacheKey = itemId + "|" + stamp
        if let hit = timelineCache[cacheKey] { done(hit.entries); return }
        guard let ref = found.item.ref(in: found.snap.summary.ref) else { done([]); return }
        if timelineWaiters[cacheKey] != nil { timelineWaiters[cacheKey]?.append(done); return }
        timelineWaiters[cacheKey] = [done]
        let projectKey = found.key
        let states = found.snap.statusOptions
        let current = found.snap.option(found.item.statusOptionId)?.name
        CallPriority.task(.user) { [weak self] in
            let result = await Result(awaiting: { try await ProjectStore.timeline(client, ref, statuses: states, current: current) })
            guard let self else { return }
            DispatchQueue.main.async {
                let waiters = self.timelineWaiters.removeValue(forKey: cacheKey) ?? []
                let entries: [ActivityEntry]
                if case .success(let list) = result {
                    entries = list.suffix(200).map { e in
                        var c = e
                        c.projectKey = projectKey
                        c.itemId = itemId
                        c.unread = self.isUnread(c)
                        return c
                    }
                    self.timelineCache[cacheKey] = (stamp, entries)
                } else {
                    entries = []
                }
                waiters.forEach { $0(entries) }
                self.publish(DataChange(.projects, projects: [projectKey]))
            }
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
        for e in activityCache.prefix(500) where isUnread(e) {
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
        guard readItems.insert(itemId).inserted else { return }
        save()
        publish(DataChange(.projects, origin: .user))
    }

    func markActivityRead(_ id: String) {
        guard readActivity.insert(id).inserted else { return }
        save()
        publish(DataChange(.projects, origin: .user))
    }

    func markActivityUnread(_ id: String) {
        guard readActivity.remove(id) != nil else { return }
        save()
        publish(DataChange(.projects, origin: .user))
    }

    /// Refuses to close a parent with open sub-items, unless `force` (OVERSIRE-396).
    func setStatus(itemId: String, optionId: String, force: Bool = false, done: @escaping (Bool) -> Void) {
        if !force, refusesClose(itemId, to: optionId) { done(false); return }
        let before = item(itemId)
        let done = { (ok: Bool) in
            if ok, let b = before { EVENTS.stateSet(b.item, in: b.snap, to: optionId) }
            done(ok)
        }
        write(itemId, failure: "Could not change the status", done: done) { c, ref in
            try await c.update(ref, ItemPatch(status: optionId))
        }
    }

    func tracker(of p: ProjectRef) -> (any Tracker)? { trackers.tracker(p.workspace) }

    func update(itemId: String, _ patch: ItemPatch, failure: String, done: @escaping (Bool) -> Void) {
        if refusesClose(itemId, to: patch.status) { done(false); return }
        write(itemId, failure: failure, done: done) { c, ref in
            try await c.update(ref, patch)
        }
    }

    // The labels of the project and the members of the workspace, for the item window menus.
    func options(projectKey: String, done: @escaping (ItemOptions) -> Void) {
        if let hit = optionCache[projectKey], -hit.at.timeIntervalSinceNow < 600 { done(hit.options); return }
        guard let snap = snapshots[projectKey], let client = trackers.tracker(snap.summary.ref.workspace) else { return }
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

    func comment(itemId: String, body: String, done: @escaping (Bool) -> Void) {
        write(itemId, failure: "Could not post the comment", done: done) { c, ref in
            try await c.comment(ref, markdown: body)
        }
    }

    func edit(itemId: String, title: String, body: String, done: @escaping (Bool) -> Void) {
        write(itemId, failure: nil, done: done) { c, ref in
            try await c.update(ref, ItemPatch(title: title, bodyMarkdown: body))
        }
    }

    func relate(itemId: String, _ patch: RelationPatch, done: @escaping (Bool) -> Void) {
        write(itemId, failure: "Could not change the relations", done: done) { c, ref in
            guard let r = c as? any RelationManaging else { throw ProviderError.unsupported(.relations) }
            try await r.apply(patch, to: ref)
        }
    }

    func assignMe(itemId: String, done: @escaping (Bool) -> Void) {
        write(itemId, failure: "Could not assign the item", done: done) { c, ref in try await ProjectStore.assignMe(c, ref) }
    }

    // The first "in progress" state, plus assign me. A project without such a state only assigns.
    func start(itemId: String, done: @escaping (Bool) -> Void) {
        guard let found = item(itemId) else { done(false); return }
        let progress = found.snap.statusOptions.first { $0.category == .progress }
        let current = found.item.statusOptionId
        write(itemId, failure: nil, done: done) { c, ref in
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

    // Sets the item and its open sub-items at all levels to the first state of the group, then reloads once (OVERSIRE-372).
    // A sub-item that is not loaded uses the parent URL: the tracker writes by id.
    func move(key: String, group: String, else category: StatusCategory, done: @escaping (Bool) -> Void) {
        guard let found = item(key: key), let client = trackers.tracker(found.snap.summary.ref.workspace),
              let parent = found.item.ref(in: found.snap.summary.ref),
              let state = found.snap.firstState(group: group, else: category) else { done(false); return }
        let snap = found.snap
        let ids = [found.item.id] + snap.openDescendants(of: found.item.id)
        let refs = ids.map { id in
            snap.items.first { $0.id == id }?.ref(in: snap.summary.ref) ?? ItemRef(project: snap.summary.ref, id: id, key: "", url: parent.url)
        }
        ids.forEach { suppressNotify.insert($0) }
        CallPriority.task(.user) { [weak self] in
            var failed = 0
            for ref in refs {
                do { try await client.update(ref, ItemPatch(status: state.id)) } catch { failed += 1 }
            }
            DispatchQueue.main.async {
                guard let self = self else { return }
                if failed > 0 { self.lastError = "Could not set \(failed) of \(refs.count) items to \(state.name)" }
                self.refresh([found.key], force: true, priority: .user) { done($0 && failed == 0) }
            }
        }
    }

    // Moves a Done parent back to the first started state.
    func reopen(itemId: String, done: @escaping (Bool) -> Void) {
        guard let found = item(itemId), let state = found.snap.firstState(group: "started", else: .progress) else { done(false); return }
        update(itemId: itemId, ItemPatch(status: state.id), failure: "Could not reopen the item", done: done)
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
    func create(_ new: NewItem, done: @escaping (Bool, String?) -> Void) {
        guard let snap = snapshots[new.projectKey], let client = trackers.tracker(snap.summary.ref.workspace) else {
            done(false, "The project is not loaded yet"); return
        }
        let draft = ItemDraft(title: new.title, bodyMarkdown: new.body.trimmingCharacters(in: .whitespacesAndNewlines),
                              status: new.fieldOptions[ProjectSnapshot.statusFieldId],
                              priority: new.fieldOptions[ProjectSnapshot.priorityFieldId])
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
                    self.refresh([new.projectKey], force: true, priority: .user) { _ in done(true, nil) }
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

    private func write(_ itemId: String, failure: String?, done: @escaping (Bool) -> Void,
                       _ op: @escaping @Sendable (any Tracker, ItemRef) async throws -> Void) {
        guard let found = item(itemId), let client = trackers.tracker(found.snap.summary.ref.workspace),
              let ref = found.item.ref(in: found.snap.summary.ref) else { done(false); return }
        suppressNotify.insert(itemId)
        CallPriority.task(.user) { [weak self] in
            let result = await Result(awaiting: { try await op(client, ref) })
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .failure(let e) = result {
                    self.suppressNotify.remove(itemId)
                    self.lastError = failure ?? e.message
                }
                self.timelineCache = self.timelineCache.filter { !$0.key.hasPrefix(itemId) }
                self.refresh([found.key], force: true, priority: .user) { done($0 && result.isOk) }
            }
        }
    }

    // MARK: Intake

    func intakeDetail(projectKey: String, item: IntakeItem, priority: CallPriority = .user, done: @escaping (Result<IntakeDetail, ProviderError>) -> Void) {
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
        let k = key.uppercased()
        for (pk, snap) in snapshots {
            if let item = snap.items.first(where: { $0.key.uppercased() == k }) { return (pk, snap, item) }
        }
        return nil
    }

    /// Finished: closed, and all sub-items closed. A Done blocker with open sub-items still blocks.
    func isDone(key: String) -> Bool {
        guard let (_, snap, item) = item(key: key) else { return false }
        return snap.isFinished(item)
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
            // Comments load only on new activity, so an old comment can appear here first. Skip it.
            if let last = item.lastComment, last.id != prev.lastComment?.id, last.createdAt > old.fetchedAt {
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

    func absorb(_ snap: ProjectSnapshot, gone: Set<String> = []) {
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
        EVENTS.tracker(changes, old: old, new: snap, skipState: suppressNotify)
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
        try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
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
        try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
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
                                   fields: s.fields, me: s.me, meId: s.meId, index: s.index, intake: s.intake)
        return (try? e.encode(bare)) ?? Data()
    }
}

extension ProjectStore {
    // Items with new activity get their comments again. Other items keep the comment data of `previous`.
    static func snapshot(_ t: any Tracker, _ summary: ProjectSummary, limit: Int,
                         previous: ProjectSnapshot?) async throws -> ProjectSnapshot {
        var ref = summary.ref
        ref.key = summary.identifier
        let me = try await t.probe().person
        let states = try await t.statuses(ref)
        // Before the items: the tracker then knows the pending intake items and does not load them as parents.
        let intake = try? await (t as? any IntakeTriaging)?.intake(ref)
        let prevById = Dictionary((previous?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // An item that only joins the snapshot loads no comments, as in a first snapshot.
        let indexed = Set(previous?.index?.map(\.id) ?? [])
        var items: [Item] = []
        for var item in try await t.items(ref, since: nil, limit: limit) {
            let prev = prevById[item.id]
            if let prev, prev.activityAt == item.activityAt {
                item.commentCount = prev.commentCount
                item.lastComment = prev.lastComment
                item.mentionsMe = prev.mentionsMe
            } else if previous != nil, prev != nil || !indexed.contains(item.id), let iref = item.ref(in: ref) {
                let list: [Comment]
                do { list = try await t.comments(iref) } catch ProviderError.rateLimited(let after) {
                    throw ProviderError.rateLimited(retryAfter: after)
                } catch {
                    // Keep the old item, so its comments load again at the next refresh.
                    items.append(prev ?? item)
                    continue
                }
                item.commentCount = list.count
                item.lastComment = list.last
                let since = previous?.fetchedAt ?? .distantPast
                let fresh = list.filter { $0.createdAt > since }.compactMap(\.body)
                let text = prev == nil ? fresh + [item.body ?? ""] : fresh
                item.mentionsMe = text.contains { $0.localizedCaseInsensitiveContains("@" + me.name) }
            }
            items.append(item)
        }
        let fields = [ProjectField(id: ProjectSnapshot.statusFieldId, name: "Status", options: states),
                      ProjectField(id: ProjectSnapshot.priorityFieldId, name: "Priority",
                                   options: StatusOption.priorities.filter { $0.id != "none" })]
        return ProjectSnapshot(summary: summary, statusOptions: states, items: items, fetchedAt: Date(),
                               fields: fields, me: me.name, meId: me.id, index: try? await (t as? any ItemIndexing)?.index(ref),
                               intake: intake)
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
