import Foundation
import OverSireCore

// ─── Parent guard ────────────────────────────────────────────────────────────
// A Done parent with open sub-items goes back to its last open state, with one comment (OVERSIRE-397).
// Only the automations owner runs it. It fixes each item one time until the item is finished, so a tool
// that closes the item again does not make a loop. The Needs you row shows such an item.

final class ParentGuard {
    struct Memory: Codable, Equatable {
        /// Item id → the last open state that OverSire saw.
        var lastOpen: [String: String] = [:]
        /// Item id → the time of the reopen.
        var reopened: [String: Date] = [:]
    }

    /// Only a close in this time counts. The Needs you row uses the same window.
    static let window: TimeInterval = 7 * 86400
    /// A reopen mark ends after this time, or when the item is finished.
    static let markLife: TimeInterval = 30 * 86400

    private(set) var memory = Memory()
    private var inFlight: Set<String> = []
    private let path: String?
    private let store: ProjectStore
    /// False when another app owns the automations (AutomationOwner).
    var mayAct: () -> Bool = { true }
    var enabled: () -> Bool = { PROJECTS_CFG.reopenOpenParents }
    var now: () -> Date = { Date() }
    var onError: ((String) -> Void)?

    init(path: String?, store: ProjectStore) {
        self.path = path
        self.store = store
        if let path, let d = FileManager.default.contents(atPath: path), let m = try? JSONDecoder().decode(Memory.self, from: d) { memory = m }
    }

    /// Runs after each tracker refresh. Main thread.
    func check(_ snaps: [ProjectSnapshot]) {
        var m = memory
        let t = now()
        for snap in snaps {
            for i in snap.items {
                if snap.isFinished(i) {
                    m.lastOpen[i.id] = nil
                    m.reopened[i.id] = nil
                } else if !snap.isClosed(i.statusOptionId), let s = i.statusOptionId {
                    m.lastOpen[i.id] = s
                }
            }
        }
        m.reopened = m.reopened.filter { t.timeIntervalSince($0.value) < Self.markLife }
        if enabled(), mayAct() {
            for snap in snaps {
                for i in snap.items where snap.isDoneWithOpenSubItems(i) && m.reopened[i.id] == nil && !inFlight.contains(i.id)
                    && t.timeIntervalSince(i.activityAt) < Self.window {
                    guard let to = Self.target(i, in: snap, lastOpen: m.lastOpen[i.id]) else { continue }
                    m.reopened[i.id] = t
                    reopen(i, in: snap, to: to)
                }
            }
        }
        if m != memory {
            memory = m
            save()
        }
    }

    /// The last open state when the project still has it, else the first started state.
    static func target(_ i: Item, in snap: ProjectSnapshot, lastOpen: String?) -> StatusOption? {
        if let o = snap.option(lastOpen), !snap.isClosed(o.id) { return o }
        return snap.firstState(group: "started", else: .progress)
    }

    static func comment(_ i: Item, in snap: ProjectSnapshot, to state: String) -> String {
        let n = snap.openSubItems(of: i.id)
        let keys = snap.openDescendants(of: i.id).compactMap { id in snap.items.first { $0.id == id }?.key }
        let list = keys.isEmpty ? "" : ": " + keys.prefix(5).joined(separator: ", ") + (keys.count > 5 ? ", …" : "")
        return "OverSire moved this item back to \(state). \(n) sub-item\(n == 1 ? " is" : "s are") open\(list). "
            + "Close \(n == 1 ? "it" : "them") first, or close this item again to keep it Done."
    }

    private func reopen(_ i: Item, in snap: ProjectSnapshot, to: StatusOption) {
        inFlight.insert(i.id)
        let n = snap.openSubItems(of: i.id)
        let body = Self.comment(i, in: snap, to: to.name)
        store.update(itemId: i.id, ItemPatch(status: to.id), failure: "Could not reopen \(i.key)") { [weak self] ok in
            guard let self else { return }
            self.inFlight.remove(i.id)
            guard ok else {
                self.memory.reopened[i.id] = nil
                self.save()
                self.onError?("Parent guard: could not reopen \(i.key)")
                return
            }
            EVENTS.reopened(i, in: snap, to: to.id, open: n)
            self.store.comment(itemId: i.id, body: body) { _ in }
        }
    }

    private func save() {
        guard let path, let d = try? JSONEncoder().encode(memory) else { return }
        try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
