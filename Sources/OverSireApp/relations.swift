import Foundation
import OverSireCore

// The relations of the items that the app looks at: the open item page and the queue entries.
// A relation call costs one request for each item, so the cache loads only these keys.
final class RelationCache {
    static let changed = Notification.Name("RelationCacheChanged")

    private let tracker: (ItemRef) -> (any RelationManaging)?
    private let ref: (String) -> ItemRef?
    private(set) var byKey: [String: [ItemRelation]] = [:]      // upper-case key → relations
    private(set) var loading: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private var seeded: Set<String> = []

    /// `ref`: the ItemRef of a key, from the snapshots.
    init(tracker: @escaping (ItemRef) -> (any RelationManaging)?, ref: @escaping (String) -> ItemRef?) {
        self.tracker = tracker
        self.ref = ref
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

    /// Loads the keys that are not loaded. `force` loads them again.
    func load(_ keys: [String], force: Bool = false) {
        for k in Set(keys.map { $0.uppercased() }) where !loading.contains(k) && !seeded.contains(k) && (force || byKey[k] == nil) {
            guard let r = ref(k), let t = tracker(r), t.capabilities.contains(.relations) else { continue }
            loading.insert(k)
            Task { [weak self] in
                let result = await Result(awaiting: { try await t.relations(of: r) })
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loading.remove(k)
                    switch result {
                    case .success(let rels): self.byKey[k] = rels; self.errors[k] = nil
                    case .failure(let e): self.errors[k] = e.message
                    }
                    NotificationCenter.default.post(name: Self.changed, object: self)
                }
            }
        }
    }

    /// After a project refresh: loads again each cached key that changed or that relates to a changed item.
    func refresh(changed: Set<String>) {
        let up = Set(changed.map { $0.uppercased() })
        let stale = byKey.filter { k, rels in up.contains(k) || rels.contains { up.contains($0.item.key.uppercased()) } }.map(\.key)
        load(stale, force: true)
    }

    /// Writes the patch, then loads the item and the other items again.
    func apply(_ patch: RelationPatch, to key: String, done: @escaping (String?) -> Void) {
        guard let r = ref(key), let t = tracker(r) else { done("OverSire does not know \(key)."); return }
        Task { [weak self] in
            let result = await Result(awaiting: { try await t.apply(patch, to: r) })
            DispatchQueue.main.async {
                guard let self else { return }
                if case .failure(let e) = result { done(e.message); return }
                let others = (patch.add + patch.remove).map(\.item.key).filter { self.byKey[$0.uppercased()] != nil }
                self.load([key] + others, force: true)
                done(nil)
            }
        }
    }

    /// For `--uishots` and tests: relations without a tracker. A load does not replace them.
    func seed(_ key: String, _ rels: [ItemRelation]) {
        byKey[key.uppercased()] = rels
        seeded.insert(key.uppercased())
    }
}
