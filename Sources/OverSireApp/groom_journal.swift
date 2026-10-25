import Foundation
import OverSireCore

// ─── Groom journal ───────────────────────────────────────────────────────────
// The last Groom of each project, on this Mac only. Each entry holds the old values of one item before the first write.
// Undo puts them back on the items that did not change after Groom. The Groom comments stay.

actor GroomJournal {
    /// The time between the write and the updated date of the tracker. A later change is a change of the user.
    static let grace: TimeInterval = 120

    struct Entry: Codable, Hashable, Sendable {
        /// The parent before Groom. nil id: no parent.
        struct Parent: Codable, Hashable, Sendable { var id: String? }

        var key: String
        var ref: ItemRef
        var status: String?          // the state before, when Groom changed it
        var body: String?            // the description before, when Groom changed it
        var parent: Parent?          // when Groom changed it
        var intake: IntakeItem?      // the item is in the intake
        var triaged = false          // Groom accepted, declined or closed the intake item
        var added: [ItemRelation] = []
        var writtenAt: Date?
    }

    struct Record: StoreRecord {
        static let collection = "groom-journal"
        var id: String               // the project key
        var project: ProjectRef
        var at: Date
        var entries: [Entry]
    }

    struct UndoOutcome: Equatable, Sendable {
        var undone: [String] = []
        var left: [String] = []           // changed after Groom
        var failed: [String: String] = [:]
    }

    private let store: any Store
    private var records: [String: Record] = [:]
    private var loaded = false

    init(store: any Store) { self.store = store }

    private func load() async {
        guard !loaded else { return }
        loaded = true
        for r in (try? await store.all(Record.self)) ?? [] { records[r.id] = r }
    }

    /// A new Groom replaces the journal of the last one.
    func begin(_ projectKey: String, project: ProjectRef, at: Date) async {
        await load()
        save(Record(id: projectKey, project: project, at: at, entries: []))
        try? await store.put(records[projectKey]!)
    }

    /// The old values of an item. Only the first record of an item counts.
    func record(before e: Entry, in projectKey: String) async {
        await load()
        guard var r = records[projectKey] else { return }
        if let i = r.entries.firstIndex(where: { $0.key == e.key }) {
            r.entries[i].added += e.added.filter { !r.entries[i].added.contains($0) }
            if r.entries[i].status == nil { r.entries[i].status = e.status }
            if r.entries[i].body == nil { r.entries[i].body = e.body }
            if r.entries[i].parent == nil { r.entries[i].parent = e.parent }
            if r.entries[i].intake == nil { r.entries[i].intake = e.intake }
            r.entries[i].triaged = r.entries[i].triaged || e.triaged
        } else {
            r.entries.append(e)
        }
        save(r)
        try? await store.put(r)
    }

    func written(_ key: String, at: Date, in projectKey: String) async {
        await load()
        guard var r = records[projectKey], let i = r.entries.firstIndex(where: { $0.key == key }) else { return }
        r.entries[i].writtenAt = at
        save(r)
        try? await store.put(r)
    }

    func last(_ projectKey: String) async -> Record? {
        await load()
        return records[projectKey].flatMap { $0.entries.contains { $0.writtenAt != nil } ? $0 : nil }
    }

    /// The written items that changed after Groom. An item that the tracker does not give stays undoable.
    func changed(_ projectKey: String, tracker: any Tracker) async -> [String] {
        guard let r = await last(projectKey) else { return [] }
        var out: [String] = []
        for e in r.entries {
            guard let at = e.writtenAt, let d = try? await tracker.detail(e.ref) else { continue }
            if d.item.updatedAt.timeIntervalSince(at) > Self.grace { out.append(e.key) }
        }
        return out
    }

    /// Puts back the old values of each written item that did not change after Groom, then deletes the journal.
    func undo(_ projectKey: String, tracker: any Tracker) async -> UndoOutcome {
        guard let r = await last(projectKey) else { return UndoOutcome() }
        let left = Set(await changed(projectKey, tracker: tracker))
        var out = UndoOutcome()
        for e in r.entries where e.writtenAt != nil {
            guard !left.contains(e.key) else { out.left.append(e.key); continue }
            do {
                let patch = ItemPatch(status: e.status, parent: e.parent.map { $0.id ?? "" }, bodyMarkdown: e.body)
                if let i = e.intake {
                    guard let t = tracker as? any IntakeTriaging else { throw ProviderError.unsupported(.intake) }
                    if e.triaged { try await t.triage(i, in: r.project, .pending) }
                    if !patch.isEmpty { try await t.triage(i, in: r.project, .update(IntakeEdit(patch: patch))) }
                } else if !patch.isEmpty {
                    try await tracker.update(e.ref, patch)
                }
                if !e.added.isEmpty, let rel = tracker as? any RelationManaging { try await rel.apply(RelationPatch(remove: e.added), to: e.ref) }
                try await tracker.comment(e.ref, markdown: "Groom undone.")
                out.undone.append(e.key)
            } catch {
                out.failed[e.key] = (error as? ProviderError)?.message ?? error.localizedDescription
            }
        }
        records[projectKey] = nil
        try? await store.delete(Record.self, id: projectKey)
        return out
    }

    private func save(_ r: Record) { records[r.id] = r }
}
