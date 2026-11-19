import Foundation
import OverSireCore

// The relations of the items that the app looks at: the open item page, the queue entries and the plan of a project.
// A relation call costs one request for each item, so the cache loads only these keys and keeps them on disk.
final class RelationCache {
    static let changed = Notification.Name("RelationCacheChanged")

    private let tracker: (ItemRef) -> (any RelationManaging)?
    private let ref: (String) -> ItemRef?
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let disk: RelationDisk?
    private let project: (String) -> String?
    private let updatedAt: (String) -> Date?
    /// Upper-case key → the read of the relations of the item. A failed read keeps the old relations.
    private var reads: [String: PartReader<[ItemRelation]>] = [:]
    private var seeded: Set<String> = []
    /// Keys that show disk relations. Their first `load` reads them again.
    private var primed: Set<String> = []
    /// Project store key → upper-case key → the entry on disk.
    private var files: [String: [String: RelationDisk.Entry]] = [:]
    private var dirty: Set<String> = []
    private var flushDue = false
    /// The `updatedAt` of the item at the start of its read.
    private var readFrom: [String: Date] = [:]
    /// Plan keys that load one at a time at background priority, so that the project reads do not wait long.
    private var planQueue: [(key: String, force: Bool)] = []
    private var planBusy = false

    var byKey: [String: [ItemRelation]] { reads.compactMapValues(\.value) }
    var loading: Set<String> { Set(reads.filter { if case .busy = $0.value.state { return true }; return false }.keys) }
    /// The text of the last failed read of each key.
    var errors: [String: String] {
        reads.compactMapValues {
            switch $0.state {
            case .failed(let e), .stale(_, let e): return e
            default: return nil
            }
        }
    }

    /// `ref`: the ItemRef of a key, from the snapshots. `project`: the project store key of a key, for the disk file.
    /// `updatedAt`: the `updatedAt` of the item, kept with each disk entry.
    init(tracker: @escaping (ItemRef) -> (any RelationManaging)?, ref: @escaping (String) -> ItemRef?,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = ChangeBus.mainAfter,
         disk: RelationDisk? = nil, project: @escaping (String) -> String? = { _ in nil },
         updatedAt: @escaping (String) -> Date? = { _ in nil }) {
        self.tracker = tracker
        self.ref = ref
        self.now = now
        self.schedule = schedule
        self.disk = disk
        self.project = project
        self.updatedAt = updatedAt
    }

    /// The read of a key. Nil when no load or seed made one.
    func read(_ key: String) -> PartReader<[ItemRelation]>? { reads[key.uppercased()] }

    /// The part for the toolbar menu and the Planner card.
    func part(_ key: String) -> PagePart? {
        read(key)?.part(id: "planner", title: "Planner")
    }

    private func reader(_ k: String) -> PartReader<[ItemRelation]> {
        if let r = reads[k] { return r }
        let r = PartReader<[ItemRelation]>(
            fetch: { [weak self] in
                guard let self else { throw ProviderError.transport("The relation cache is gone.") }
                let found = await MainActor.run { () -> (ItemRef, any RelationManaging)? in
                    guard let r = self.ref(k), let t = self.tracker(r) else { return nil }
                    self.readFrom[k] = self.updatedAt(k)
                    return (r, t)
                }
                guard let (r, t) = found else { throw ProviderError.transport("OverSire does not know \(k).") }
                return try await t.relations(of: r)
            },
            onRead: { [weak self] in self?.remember(k, $0) },
            now: now, schedule: schedule,
            changed: { [weak self] in self?.notify() })
        reads[k] = r
        return r
    }

    /// Later, so a load inside a handler of the notice does not nest.
    private func notify() {
        DispatchQueue.main.async { [weak self] in NotificationCenter.default.post(name: Self.changed, object: self) }
    }

    /// Nil until the first load ends.
    func relations(_ key: String) -> [ItemRelation]? { byKey[key.uppercased()] }

    func supports(_ key: String) -> Bool {
        guard let r = ref(key), let t = tracker(r) else { return false }
        return t.capabilities.contains(.relations)
    }

    /// The keys of the open blockers, in relation order. A blocker that `done` does not know stays open.
    func blockers(of key: String, done: (String) -> Bool) -> [String] {
        (relations(key) ?? []).filter { $0.kind == .blockedBy && !done($0.item.key) }.map(\.item.key)
    }

    /// Loads the keys that are not loaded. `force` loads them again and starts the retry plan again.
    /// A key with a failed read waits for its retry plan.
    func load(_ keys: [String], force: Bool = false, priority: CallPriority = .user) {
        for k in Set(keys.map { $0.uppercased() }) where !seeded.contains(k) {
            guard let r = ref(k), let t = tracker(r), t.capabilities.contains(.relations) else { continue }
            let f = primed.remove(k) != nil || force
            CallPriority.$current.withValue(priority) { reader(k).start(force: f) }
        }
    }

    /// Shows the cached relations at once. A later load replaces them. Not `seeded`.
    func prime(_ key: String, _ rels: [ItemRelation], at: Date) {
        let k = key.uppercased()
        reader(k).seed(Read(value: rels, at: at))
        primed.insert(k)
        notify()
    }

    /// Loads the plan keys: missing or stale keys only. The first `first` keys run at .user priority, the others
    /// at .background, one at a time. A key with no read shows its disk entry first.
    /// A key is stale when the item changed after the entry, or when the entry is older than `maxAge`.
    func loadPlan(_ keys: [String], updatedAt: (String) -> Date?, first: Int = 20, maxAge: TimeInterval = 86_400) {
        var seen = Set<String>()
        for (i, key) in keys.enumerated() {
            let k = key.uppercased()
            guard seen.insert(k).inserted, !seeded.contains(k) else { continue }
            guard let r = ref(k), let t = tracker(r), t.capabilities.contains(.relations) else { continue }
            let e = entry(k)
            if let e, reads[k] == nil { prime(k, e.relations, at: e.at) }
            let force: Bool
            if let e {
                let changed = updatedAt(k).map { $0 > (e.itemUpdatedAt ?? e.at) } ?? false
                guard changed || now().timeIntervalSince(e.at) > maxAge else { continue }
                // A failed read that waits for its retry plan does not start again.
                if let last = reads[k]?.last, last.retry(now: now()) != nil { continue }
                force = true
            } else {
                force = false
            }
            primed.remove(k)
            if i < first {
                CallPriority.$current.withValue(.user) { reader(k).start(force: force) }
            } else if !planQueue.contains(where: { $0.key == k }) {
                planQueue.append((k, force))
            }
        }
        pumpPlan()
    }

    private func pumpPlan() {
        guard !planBusy else { return }
        while !planQueue.isEmpty {
            let (k, force) = planQueue.removeFirst()
            let r = reader(k)
            CallPriority.$current.withValue(.background) { r.start(force: force) }
            guard case .busy = r.state else { continue }
            planBusy = true
            Task { @MainActor [weak self] in
                await r.settled()
                self?.planBusy = false
                self?.pumpPlan()
            }
            return
        }
    }

    /// Loaded keys of `keys` and their count, for the "Relations k of n" part. A key with no ref counts as not loaded.
    func progress(_ keys: [String]) -> (loaded: Int, total: Int, failed: Int) {
        let ks = Set(keys.map { $0.uppercased() })
        let loaded = ks.filter { reads[$0]?.value != nil }.count
        let failed = ks.filter { reads[$0].map { $0.value == nil && $0.state.didFail } ?? false }.count
        return (loaded, ks.count, failed)
    }

    // MARK: Disk

    private func entry(_ k: String) -> RelationDisk.Entry? {
        project(k).flatMap { stored($0)[k] }
    }

    private func stored(_ p: String) -> [String: RelationDisk.Entry] {
        if let f = files[p] { return f }
        let f = disk?.load(project: p) ?? [:]
        files[p] = f
        return f
    }

    private func remember(_ k: String, _ rels: [ItemRelation]) {
        primed.remove(k)
        let from = readFrom.removeValue(forKey: k)
        guard disk != nil, let p = project(k) else { return }
        var f = stored(p)
        f[k] = RelationDisk.Entry(relations: rels, at: now(), itemUpdatedAt: from)
        files[p] = f
        dirty.insert(p)
        guard !flushDue else { return }
        flushDue = true
        schedule(1) { [weak self] in self?.flush() }
    }

    /// Writes the changed project files. A failed write stays in memory and goes in the log.
    func flush() {
        flushDue = false
        guard let disk else { return }
        for p in dirty {
            do { try disk.save(project: p, files[p] ?? [:]) } catch {
                APP_LOG.write(LogEntry(level: .warn, area: .sync, job: "Relation cache write", subject: p, message: error.localizedDescription))
            }
        }
        dirty = []
    }

    /// After a project refresh: loads again each cached key that changed or that relates to a changed item.
    /// A failed key that changed loads again too.
    func refresh(changed: Set<String>) {
        let up = Set(changed.map { $0.uppercased() })
        let stale = reads.filter { k, r in up.contains(k) || (r.value ?? []).contains { up.contains($0.item.key.uppercased()) } }.map(\.key)
        load(stale, force: true, priority: .background)
    }

    /// Writes the patch, then loads the item and the other items again.
    func apply(_ patch: RelationPatch, to key: String, done: @escaping (String?) -> Void) {
        guard let r = ref(key), let t = tracker(r) else { done("OverSire does not know \(key)."); return }
        CallPriority.task(.user) { [weak self] in
            let result = await Result(awaiting: { try await t.apply(patch, to: r) })
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let e) = result { done(e.message); return }
                let others = (patch.add + patch.remove).map(\.item.key).filter { self.reads[$0.uppercased()]?.value != nil }
                self.load([key] + others, force: true)
                done(nil)
            }
        }
    }

    /// For `--uishots` and tests: relations without a tracker. A load does not replace them.
    func seed(_ key: String, _ rels: [ItemRelation]) {
        reader(key.uppercased()).seed(Read(value: rels))
        seeded.insert(key.uppercased())
    }

    /// For `--uishots`: a read in any state. A load does not replace it.
    func seed(_ key: String, read r: Read<[ItemRelation]>) {
        self.read(key)?.seed(r) ?? reader(key.uppercased()).seed(r)
        seeded.insert(key.uppercased())
    }
}
