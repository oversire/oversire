import Foundation
import OverSireCore
import OverSireSync

// ─── Planner (cloud) ─────────────────────────────────────────────────────────
// Code areas of the items, the plan changes of the hub, the Planner settings and the hold of work orders.
// The books keep the writes in memory, because StoreWrites.load does not see writes that did not end.

final class ItemAreaBook {
    static let changed = Notification.Name("ItemAreaBookChanged")

    private let writes: StoreWrites
    private(set) var records: [String: ItemAreas] = [:]   // by ItemAreas.id
    private var observer: NSObjectProtocol?

    init(writes: StoreWrites) {
        self.writes = writes
        load()
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard let self, n.userInfo?["collection"] as? String == ItemAreas.collection else { return }
            self.load()
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func areas(of ref: ItemRef) -> [String] { records[ItemAreas.id(of: ref)]?.areas ?? [] }

    func areas(key: String) -> [String] {
        let k = key.uppercased()
        return records.values.first { $0.item.key.uppercased() == k }?.areas ?? []
    }

    /// Saves the clean tags with source user and gives them back. No tags keeps a record: the user chose none.
    @discardableResult
    func save(_ tags: [String], for ref: ItemRef, now: Date = Date()) -> [String] {
        let r = ItemAreas(item: ref, areas: ItemAreas.clean(tags), source: .user, updatedAt: now)
        records[r.id] = r
        writes.put(r)
        NotificationCenter.default.post(name: Self.changed, object: self)
        return r.areas
    }

    /// Area → the first running key that has it.
    func busy(running keys: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for k in keys.sorted() { for a in areas(key: k) where out[a] == nil { out[a] = k } }
        return out
    }

    /// For `--uishots`: areas without a write.
    func seed(_ r: ItemAreas) { records[r.id] = r }

    private func load() { records = Dictionary(writes.load(ItemAreas.self).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b }) }
}

final class SuggestionBook {
    static let changed = Notification.Name("SuggestionBookChanged")

    private let writes: StoreWrites
    private(set) var all: [Suggestion] = []
    private var observer: NSObjectProtocol?
    /// The runner path of a workOrder proposal. nil: the hub makes each order.
    var desk: RunnerDesk?

    /// The book of the app store uses the runner desk of the app.
    init(writes: StoreWrites, desk: RunnerDesk? = nil) {
        self.writes = writes
        self.desk = desk ?? (writes === STORE_WRITES ? RUNNER_DESK : nil)
        all = writes.load(Suggestion.self)
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard let self, n.userInfo?["collection"] as? String == Suggestion.collection else { return }
            self.all = self.writes.load(Suggestion.self)
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// Open plan changes that did not expire, newest first.
    func openPlans(now: Date = Date()) -> [Suggestion] {
        all.filter { $0.state == .open && $0.plan != nil && $0.expiresAt > now }.sorted { $0.createdAt > $1.createdAt }
    }

    /// The open plan change of a lane. `lane` is QueueLane.project.
    func openPlan(lane: String, now: Date = Date()) -> Suggestion? {
        openPlans(now: now).first { $0.lane == lane }
    }

    /// The open plan change that has a line for the item.
    func openPlan(naming key: String, now: Date = Date()) -> Suggestion? {
        let k = key.uppercased()
        return openPlans(now: now).first { s in
            s.plan.map { d in d.order.contains { $0.item.key.uppercased() == k } || d.relations.contains { $0.item.key.uppercased() == k }
                || d.areas.contains { $0.item.key.uppercased() == k } } ?? false
        }
    }

    /// `drop`: the indexes of PlanDraft.lines that the user cleared. The hub applies the rest.
    func accept(_ id: String, drop: Set<Int>, by device: String?, now: Date = Date()) {
        if let desk, let s = all.first(where: { $0.id == id }), s.state == .open, case .workOrder(let draft)? = s.proposal,
           acceptOrder(s, draft: draft, by: device, now: now, desk: desk) { return }
        decide(id, .accepted, by: device, now: now) { $0.edit = drop.isEmpty ? nil : SuggestionEdit(drop: drop.sorted()) }
    }

    func dismiss(_ id: String, by device: String?, now: Date = Date()) {
        decide(id, .dismissed, by: device, now: now) { _ in }
    }

    /// Keeps the suggestion in memory, and writes it when `write` is true.
    func replace(_ s: Suggestion, write: Bool) {
        if let i = all.firstIndex(where: { $0.id == s.id }) { all[i] = s } else { all.append(s) }
        if write { writes.put(s) }
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// For `--uishots`: a suggestion without a write.
    func seed(_ s: Suggestion) { all.removeAll { $0.id == s.id }; all.append(s) }

    private func decide(_ id: String, _ state: Suggestion.State, by device: String?, now: Date, _ edit: (inout Suggestion) -> Void) {
        guard let i = all.firstIndex(where: { $0.id == id }), all[i].state == .open else { return }
        all[i].state = state
        all[i].decidedAt = now
        all[i].decidedBy = device
        edit(&all[i])
        writes.put(all[i])
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

/// The Planner records of the projects: settings, area catalogs, claims and area candidates.
final class PlannerBook {
    static let changed = Notification.Name("PlannerBookChanged")
    static let collections: Set<String> = [PlannerSettings.collection, AreaCatalog.collection, AreaClaim.collection, AreaCandidates.collection]

    private let writes: StoreWrites
    private(set) var settings: [String: PlannerSettings] = [:]   // by project
    private(set) var catalogs: [String: AreaCatalog] = [:]       // by project
    private(set) var claims: [String: AreaClaim] = [:]           // by ItemAreas id
    private var observer: NSObjectProtocol?

    init(writes: StoreWrites) {
        self.writes = writes
        load()
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard let self, let c = n.userInfo?["collection"] as? String, Self.collections.contains(c) else { return }
            self.load()
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func settings(_ project: String) -> PlannerSettings {
        settings[project] ?? PlannerSettings(project: project, slots: AGENTS.slots(project), updatedAt: .distantPast)
    }

    func catalog(_ project: String) -> AreaCatalog { catalogs[project] ?? AreaCatalog(project: project, updatedAt: .distantPast) }

    func kind(_ area: String, project: String) -> AreaKind { catalog(project).kind(of: area) }

    /// True when two items can hold the area at the same time.
    func sharable(_ area: String, project: String) -> Bool {
        !kind(area, project: project).isCore && settings(project).sharedFeature == .parallel
    }

    func claim(_ ref: ItemRef) -> AreaClaim? { claims[ItemAreas.id(of: ref)] }

    func claim(key: String) -> AreaClaim? {
        let k = key.uppercased()
        return claims.values.first { $0.item.key.uppercased() == k }
    }

    func update(_ project: String, now: Date = Date(), _ edit: (inout PlannerSettings) -> Void) {
        var s = settings(project)
        edit(&s)
        s.updatedAt = now
        settings[project] = s
        writes.put(s)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    func update(catalog project: String, now: Date = Date(), _ edit: (inout AreaCatalog) -> Void) {
        var c = catalog(project)
        edit(&c)
        c.updatedAt = now
        catalogs[project] = c
        writes.put(c)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    /// For `--uishots`: records without a write.
    func seed(_ s: PlannerSettings) { settings[s.project] = s }
    func seed(_ c: AreaCatalog) { catalogs[c.project] = c }
    func seed(_ c: AreaClaim) { claims[c.id] = c }

    private func load() {
        settings = Dictionary(writes.load(PlannerSettings.self).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        catalogs = Dictionary(writes.load(AreaCatalog.self).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
        claims = Dictionary(writes.load(AreaClaim.self).map { ($0.id, $0) }, uniquingKeysWith: { _, b in b })
    }
}

extension Suggestion {
    var plan: PlanDraft? { if case .plan(let d)? = proposal { return d }; return nil }

    /// The upper-case item key of an item subject.
    var subjectKey: String? { if case .item(let r) = subject { return r.key.uppercased() }; return nil }

    /// The queue lane of a project subject: ProjectRef.storeKey.
    var lane: String? { if case .project(let p) = subject { return p.storeKey }; return nil }

    func expiresText(now: Date = Date()) -> String {
        let h = Int(expiresAt.timeIntervalSince(now) / 3600)
        if h < 1 { return "Expires soon" }
        if h < 24 { return "Expires in \(h) hour\(h == 1 ? "" : "s")" }
        let d = h / 24
        return "Expires in \(d) day\(d == 1 ? "" : "s")"
    }
}

extension WorkOrderHold {
    /// "Held: waits on KEY" or "Held: area AREA busy". Blockers come first.
    var text: String {
        if !blockers.isEmpty { return "Held: waits on " + blockers.map(\.key).joined(separator: ", ") }
        if !areas.isEmpty { return "Held: area\(areas.count == 1 ? "" : "s") \(areas.joined(separator: ", ")) busy" }
        return "Held"
    }
}
