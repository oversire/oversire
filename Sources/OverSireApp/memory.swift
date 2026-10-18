import Foundation
import OverSireCore

// The vision and the memory entries of each project. It keeps the writes in memory,
// because StoreWrites.load does not see writes that did not end.
final class ProjectMemory {
    static let changed = Notification.Name("ProjectMemoryChanged")

    enum SaveError: Error, Equatable {
        case tooLong(Int)
        case empty
    }

    private let writes: StoreWrites
    private(set) var entries: [MemoryEntry]
    private var observer: NSObjectProtocol?

    init(writes: StoreWrites) {
        self.writes = writes
        entries = writes.load(MemoryEntry.self)
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard let self, n.userInfo?["collection"] as? String == MemoryEntry.collection else { return }
            self.entries = self.writes.load(MemoryEntry.self)
            NotificationCenter.default.post(name: Self.changed, object: self)
        }
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func vision(of p: ProjectRef) -> MemoryEntry? { MemoryEntry.vision(for: p, in: entries) }

    /// The facts with scope project, oldest first.
    func facts(of p: ProjectRef) -> [MemoryEntry] {
        entries.filter {
            guard $0.kind == .fact, $0.scope == .project, case .project(let r)? = $0.scopeRef else { return false }
            return r.storeKey == p.storeKey
        }.sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Checks the text against the save rules and gives the text to save.
    static func clean(_ text: String) throws -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count <= MemoryDraft.maxText else { throw SaveError.tooLong(t.count) }
        return t
    }

    /// Saves the one vision of the project. An empty text removes it.
    func saveVision(_ text: String, of p: ProjectRef, now: Date = Date()) throws {
        let t = try Self.clean(text)
        let id = MemoryEntry.visionID(of: p)
        if t.isEmpty {
            remove(id: id)
            return
        }
        put(.vision(t, of: p, updatedAt: now))
    }

    /// Adds a fact (id nil) or changes one. The source of a changed fact becomes the user.
    @discardableResult
    func saveFact(_ text: String, id: String? = nil, of p: ProjectRef, now: Date = Date()) throws -> MemoryEntry {
        let t = try Self.clean(text)
        guard !t.isEmpty else { throw SaveError.empty }
        let e = MemoryEntry(id: id ?? "fact-\(UUID().uuidString.lowercased())", scope: .project, scopeRef: .project(p), text: t, updatedAt: now)
        put(e)
        return e
    }

    func remove(id: String) {
        guard entries.contains(where: { $0.id == id }) else { return }
        entries.removeAll { $0.id == id }
        writes.delete(MemoryEntry.self, id: id)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    private func put(_ e: MemoryEntry) {
        entries.removeAll { $0.id == e.id }
        entries.append(e)
        writes.put(e)
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}
