import Foundation
import OverSireCore

// ─── Sequencing (cloud) ──────────────────────────────────────────────────────
// Code areas of the items, the sequence suggestions of the hub and the hold of work orders.
// Both books keep the writes in memory, because StoreWrites.load does not see writes that did not end.

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

    init(writes: StoreWrites) {
        self.writes = writes
        all = writes.load(Suggestion.self)
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard let self, n.userInfo?["collection"] as? String == Suggestion.collection else { return }
            self.all = self.writes.load(Suggestion.self)
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// Open sequence suggestions that did not expire, newest first.
    func openSequences(now: Date = Date()) -> [Suggestion] {
        all.filter { $0.state == .open && $0.sequence != nil && $0.expiresAt > now }.sorted { $0.createdAt > $1.createdAt }
    }

    func openSequence(for key: String, now: Date = Date()) -> Suggestion? {
        openSequences(now: now).first { $0.subjectKey == key.uppercased() }
    }

    /// `drop`: the indexes of SequenceDraft.lines that the user cleared. The hub applies the rest.
    func accept(_ id: String, drop: Set<Int>, by device: String?, now: Date = Date()) {
        decide(id, .accepted, by: device, now: now) { $0.edit = drop.isEmpty ? nil : SuggestionEdit(drop: drop.sorted()) }
    }

    func dismiss(_ id: String, by device: String?, now: Date = Date()) {
        decide(id, .dismissed, by: device, now: now) { _ in }
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

extension Suggestion {
    var sequence: SequenceDraft? { if case .sequence(let d)? = proposal { return d }; return nil }

    /// The upper-case item key of an item subject.
    var subjectKey: String? { if case .item(let r) = subject { return r.key.uppercased() }; return nil }

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
