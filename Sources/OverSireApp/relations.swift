import Foundation
import OverSireCore

// The relations of the items that the app looks at: the open item page and the queue entries.
// A relation call costs one request for each item, so the cache loads only these keys.
final class RelationCache {
    static let changed = Notification.Name("RelationCacheChanged")

    private let tracker: (ItemRef) -> (any RelationManaging)?
    private let ref: (String) -> ItemRef?
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    /// Upper-case key → the read of the relations of the item. A failed read keeps the old relations.
    private var reads: [String: PartReader<[ItemRelation]>] = [:]
    private var seeded: Set<String> = []

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

    /// `ref`: the ItemRef of a key, from the snapshots.
    init(tracker: @escaping (ItemRef) -> (any RelationManaging)?, ref: @escaping (String) -> ItemRef?,
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = ChangeBus.mainAfter) {
        self.tracker = tracker
        self.ref = ref
        self.now = now
        self.schedule = schedule
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
                    return (r, t)
                }
                guard let (r, t) = found else { throw ProviderError.transport("OverSire does not know \(k).") }
                return try await t.relations(of: r)
            },
            now: now, schedule: schedule,
            changed: { [weak self] in
                // Later, so a load inside a handler of the notice does not nest.
                DispatchQueue.main.async { [weak self] in NotificationCenter.default.post(name: Self.changed, object: self) }
            })
        reads[k] = r
        return r
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
            CallPriority.$current.withValue(priority) { reader(k).start(force: force) }
        }
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
