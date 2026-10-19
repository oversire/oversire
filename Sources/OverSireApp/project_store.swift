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
}

/// Optional tracker features that the store uses when a tracker has them.
protocol MemberListing: Tracker { func memberNames() async -> [String: String] }
protocol SelfAssigning: Tracker { func assignMe(_ i: ItemRef) async throws }
protocol StatusTimeline: Tracker { func timeline(_ i: ItemRef, statuses: [StatusOption], current: String?) async throws -> [ActivityEntry] }
protocol IntakeKeying: Tracker { func intakeSequences(_ p: ProjectRef) async throws -> [String: Int] }
/// A tracker whose Markdown names uploaded files by id.
protocol AssetLinking: AssetResolving { func assetIds(in markdown: String) -> Set<String> }

// Last snapshots, the activity feed, and unread state. Fetches run off the main
// queue. The first snapshot of a project creates no activity, so launch is quiet.

final class ProjectStore {
    static let changed = Notification.Name("ProjectStoreChanged")

    private(set) var snapshots: [String: ProjectSnapshot] = [:]
    private(set) var refreshing: Set<String> = []
    private(set) var lastError: String?
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
    private var readActivity = Set<String>()
    private var readItems = Set<String>()
    private var activityCache: [ActivityEntry] = []
    private var timelineCache: [String: (stamp: String, entries: [ActivityEntry])] = [:]
    private var optionCache: [String: (options: ItemOptions, at: Date)] = [:]
    private var timelineWaiters: [String: [([ActivityEntry]) -> Void]] = [:]
    private var suppressNotify = Set<String>()
    private var assetCache: [String: (url: String, at: Date)] = [:]
    private(set) lazy var relations = RelationCache(
        tracker: { [weak self] in self?.trackers.tracker($0.project.workspace) as? any RelationManaging },
        ref: { [weak self] key in self?.item(key: key).flatMap { $0.item.ref(in: $0.snap.summary.ref) } })
    var relayIsLive: () -> Bool = { false }
    var onChange: (() -> Void)?
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
        tracked = projects
        liveKeys = live
        PROJECT_ICONS.track(projects)
        restartTimer()
        let keys = projects.map { $0.ref.storeKey }
        refresh(keys, force: false) { _ in }
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
            if liveKeys.contains(key) { return !liveRelay }
            return true
        }
        refresh(keys, force: false) { _ in }
    }

    func refresh(_ keys: [String], force: Bool, done: @escaping (Bool) -> Void) {
        let todo = keys.filter { force || !refreshing.contains($0) }
        guard !todo.isEmpty else { done(true); return }
        for k in todo { refreshing.insert(k) }
        publish()
        let jobs = tracked.filter { todo.contains($0.ref.storeKey) }.map { p in
            (p, trackers.tracker(p.ref.workspace), snapshots[p.ref.storeKey])
        }
        let limit = snapshotLimit
        let label = { (n: Int) in jobs.count == 1 ? "Loading \(jobs[0].0.identifier)" : "Loading projects: \(n) of \(jobs.count)" }
        let token = busy?.begin(label(0))
        if hold { return }
        Task { [weak self] in
            guard let self = self else { return }
            var fresh: [ProjectSnapshot] = []
            var error: String?
            for (n, (p, client, previous)) in jobs.enumerated() {
                if n > 0, let token { await MainActor.run { self.busy?.update(token, label(n)) } }
                guard let client else { error = "\(p.ref.workspace): " + ProjectStore.noToken; continue }
                switch await Result(awaiting: { try await ProjectStore.snapshot(client, p, limit: limit, previous: previous) }) {
                case .success(let s): fresh.append(s)
                case .failure(let e): error = "\(p.ref.workspace): " + e.message
                }
            }
            let failed = error != nil
            DispatchQueue.main.async {
                if let token { self.busy?.end(token) }
                for k in todo { self.refreshing.remove(k) }
                self.lastError = error
                var changed = Set<String>()
                for snap in fresh {
                    let old = Dictionary((self.snapshots[snap.summary.ref.storeKey]?.items ?? []).map { ($0.id, $0.activityAt) },
                                         uniquingKeysWith: { a, _ in a })
                    changed.formUnion(snap.items.filter { old[$0.id] != $0.activityAt }.map(\.key))
                    self.absorb(snap)
                }
                self.save()
                self.relations.refresh(changed: changed)
                self.publish()
                done(!failed)
            }
        }
    }

    // A nil project means all tracked projects of the workspace. No events means all.
    func refreshForEvents(_ events: [(workspace: String, project: String?)], done: @escaping (Bool) -> Void) {
        let keys = tracked.map(\.ref).filter { ref in
            events.isEmpty || events.contains { $0.workspace == ref.workspace && ($0.project == nil || $0.project == ref.id) }
        }.map(\.storeKey)
        if keys.isEmpty { done(true); return }
        refresh(keys, force: true, done: done)
    }

    func timeline(itemId: String, done: @escaping ([ActivityEntry]) -> Void) {
        guard let found = item(itemId), let client = trackers.tracker(found.snap.summary.ref.workspace) else { done([]); return }
        let stamp = isoFmt.string(from: found.item.activityAt)
        let cacheKey = itemId + "|" + stamp
        if let hit = timelineCache[cacheKey] { done(hit.entries); return }
        if timelineWaiters[cacheKey] != nil { timelineWaiters[cacheKey]?.append(done); return }
        timelineWaiters[cacheKey] = [done]
        let projectKey = found.key
        guard let ref = found.item.ref(in: found.snap.summary.ref) else { done([]); return }
        let states = found.snap.statusOptions
        let current = found.snap.option(found.item.statusOptionId)?.name
        Task { [weak self] in
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
                        c.unread = !self.readActivity.contains(c.id) && !self.readItems.contains(itemId)
                        return c
                    }
                    self.timelineCache[cacheKey] = (stamp, entries)
                } else {
                    entries = []
                }
                waiters.forEach { $0(entries) }
                self.publish()
            }
        }
    }

    func activity(limit: Int, project: String?) -> [ActivityEntry] {
        let rows = activityCache.filter { project == nil || $0.projectKey == project }
            .sorted { $0.at > $1.at }
        return Array(rows.prefix(limit)).map { e in
            var c = e
            c.unread = !readActivity.contains(e.id) && !readItems.contains(e.itemId)
            return c
        }
    }

    func unreadCount() -> Int {
        activity(limit: 500, project: nil).filter(\.unread).count
    }

    func isUnread(itemId: String) -> Bool {
        activity(limit: 500, project: nil).contains { $0.itemId == itemId && $0.unread }
    }

    func markRead(itemId: String) {
        readItems.insert(itemId)
        save()
        publish()
    }

    func markActivityRead(_ id: String) {
        readActivity.insert(id)
        save()
        publish()
    }

    func markActivityUnread(_ id: String) {
        readActivity.remove(id)
        save()
        publish()
    }

    func setStatus(itemId: String, optionId: String, done: @escaping (Bool) -> Void) {
        write(itemId, failure: "Could not change the status", done: done) { c, ref in
            try await c.update(ref, ItemPatch(status: optionId))
        }
    }

    func update(itemId: String, _ patch: ItemPatch, failure: String, done: @escaping (Bool) -> Void) {
        write(itemId, failure: failure, done: done) { c, ref in
            try await c.update(ref, patch)
        }
    }

    // The labels of the project and the members of the workspace, for the item window menus.
    func options(projectKey: String, done: @escaping (ItemOptions) -> Void) {
        if let hit = optionCache[projectKey], -hit.at.timeIntervalSinceNow < 600 { done(hit.options); return }
        guard let snap = snapshots[projectKey], let client = trackers.tracker(snap.summary.ref.workspace) else { return }
        let project = snap.summary.ref
        Task { [weak self] in
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

    // Title, facts, link, description and all comments as Markdown, on the pasteboard.
    func copyForAgent(_ id: String) {
        timeline(itemId: id) { [weak self] entries in
            guard let found = self?.item(id) else { return }
            let comments = entries.compactMap { e -> Comment? in
                if case .comments(_, let last) = e.change { return last }
                return nil
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(found.item.agentMarkdown(snap: found.snap, comments: comments), forType: .string)
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

    // `done(created, message)`.
    func create(_ new: NewItem, done: @escaping (Bool, String?) -> Void) {
        guard let snap = snapshots[new.projectKey], let client = trackers.tracker(snap.summary.ref.workspace) else {
            done(false, "The project is not loaded yet"); return
        }
        let draft = ItemDraft(title: new.title, bodyMarkdown: new.body.trimmingCharacters(in: .whitespacesAndNewlines),
                              status: new.fieldOptions[ProjectSnapshot.statusFieldId],
                              priority: new.fieldOptions[ProjectSnapshot.priorityFieldId])
        let project = snap.summary.ref
        Task { [weak self] in
            let added = await Result(awaiting: { try await client.create(draft, in: project).id })
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch added {
                case .failure(let e):
                    self.lastError = e.message
                    done(false, e.message)
                case .success(let itemId):
                    self.suppressNotify.insert(itemId)
                    self.refresh([new.projectKey], force: true) { _ in done(true, nil) }
                }
            }
        }
    }

    // Runs one change off the main queue, then reloads the project. A change made here is not news.
    private func write(_ itemId: String, failure: String?, done: @escaping (Bool) -> Void,
                       _ op: @escaping @Sendable (any Tracker, ItemRef) async throws -> Void) {
        guard let found = item(itemId), let client = trackers.tracker(found.snap.summary.ref.workspace),
              let ref = found.item.ref(in: found.snap.summary.ref) else { done(false); return }
        suppressNotify.insert(itemId)
        Task { [weak self] in
            let result = await Result(awaiting: { try await op(client, ref) })
            DispatchQueue.main.async {
                guard let self = self else { return }
                if case .failure(let e) = result {
                    self.suppressNotify.remove(itemId)
                    self.lastError = failure ?? e.message
                }
                self.timelineCache = self.timelineCache.filter { !$0.key.hasPrefix(itemId) }
                self.refresh([found.key], force: true) { done($0 && result.isOk) }
            }
        }
    }

    // MARK: Intake

    func intakeDetail(projectKey: String, item: IntakeItem, done: @escaping (Result<IntakeDetail, ProviderError>) -> Void) {
        guard let snap = snapshots[projectKey], let client = trackers.tracker(snap.summary.ref.workspace) else {
            done(.failure(.unauthorized)); return
        }
        let project = snap.summary.ref
        Task {
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
        Task { [weak self] in
            let r = await Result(awaiting: {
                guard let t = client as? any IntakeTriaging else { throw ProviderError.unsupported(.intake) }
                try await t.triage(item, in: project, action)
            })
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let e) = r {
                    self.suppressNotify.remove(item.workItemId)
                    self.lastError = action.failure + e.message
                }
                self.refresh([projectKey], force: true) { done($0 && r.isOk) }
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
        Task { [weak self] in
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
        Task { [weak self] in
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

    func isDone(key: String) -> Bool {
        guard let (_, snap, item) = item(key: key) else { return false }
        return snap.option(item.statusOptionId)?.category == .done
    }

    /// The open blocker keys of an item, from the relation cache.
    func blockers(of key: String) -> [String] { relations.blockers(of: key) { isDone(key: $0) } }

    var snapshotLimit: Int {
        let n = PROJECTS_CFG.itemsPerProject
        return min(300, max(100, n == 0 ? 200 : n))
    }

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
        publish()
    }

    private func absorb(_ snap: ProjectSnapshot) {
        let key = snap.summary.ref.storeKey
        let old = snapshots[key]
        let changes = ProjectStore.diff(old, snap)
        let snap = ProjectStore.localized(snap)
        snapshots[key] = snap
        notifyIntake(old: old, new: snap)
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
                                       url: item?.url ?? snap.summary.url, at: at)
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
        activityCache.append(contentsOf: fresh)
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        activityCache.removeAll { $0.at < cutoff }
        let text = activityCache.compactMap { e -> String? in
            guard let d = try? JSONEncoder().encode(e) else { return nil }
            return String(data: d, encoding: .utf8)
        }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
        try? text.write(toFile: activityPath, atomically: true, encoding: .utf8)
    }

    private struct Disk: Codable {
        var snapshots: [String: ProjectSnapshot]
        var readActivity: [String]
        var readItems: [String]
    }

    private func load() {
        if let data = FileManager.default.contents(atPath: statePath),
           let disk = try? JSONDecoder().decode(Disk.self, from: data) {
            snapshots = disk.snapshots.mapValues { ProjectStore.localized($0) }
            readActivity = Set(disk.readActivity)
            readItems = Set(disk.readItems)
        }
        let raw = (try? String(contentsOfFile: activityPath, encoding: .utf8)) ?? ""
        let dec = JSONDecoder()
        activityCache = raw.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return try? dec.decode(ActivityEntry.self, from: d)
        }
    }

    private func save() {
        let disk = Disk(snapshots: snapshots, readActivity: Array(readActivity), readItems: Array(readItems))
        guard let data = try? JSONEncoder().encode(disk) else { return }
        try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
    }

    private func publish() {
        onChange?()
        NotificationCenter.default.post(name: ProjectStore.changed, object: self)
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
        let prevById = Dictionary((previous?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var items: [Item] = []
        for var item in try await t.items(ref, since: nil, limit: limit) {
            let prev = prevById[item.id]
            if let prev, prev.activityAt == item.activityAt {
                item.commentCount = prev.commentCount
                item.lastComment = prev.lastComment
                item.mentionsMe = prev.mentionsMe
            } else if previous != nil, let iref = item.ref(in: ref), let list = try? await t.comments(iref) {
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
                               intake: try? await (t as? any IntakeTriaging)?.intake(ref))
    }
}

extension ProjectStore {
    static func timeline(_ t: any Tracker, _ i: ItemRef, statuses: [StatusOption], current: String?) async throws -> [ActivityEntry] {
        if let t = t as? any StatusTimeline { return try await t.timeline(i, statuses: statuses, current: current) }
        return try await (t as? any TimelineReading)?.timeline(i) ?? []
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
