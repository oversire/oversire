import Foundation
import OverSireCore

/// The local ops that the server did not accept yet, in one JSON file. They survive a crash.
/// A new op for a record replaces the waiting op for the same record.
public final class Outbox: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var ops: [StoreOp]

    /// A nil url keeps the ops in memory only.
    public init(url: URL?) {
        self.url = url
        ops = url.flatMap { try? JSONDecoder().decode([StoreOp].self, from: Data(contentsOf: $0)) } ?? []
    }

    public var pending: [StoreOp] { lock.withLock { ops } }

    public func add(_ op: StoreOp) { add(contentsOf: [op]) }

    /// Adds the ops with one file write. A later op for a record replaces an earlier one.
    public func add(contentsOf new: [StoreOp]) {
        guard !new.isEmpty else { return }
        lock.withLock {
            let records = Set(new.map { Key(collection: $0.collection, id: $0.id) })
            ops.removeAll { records.contains(Key(collection: $0.collection, id: $0.id)) }
            var last: [Key: Int] = [:]
            for (i, op) in new.enumerated() { last[Key(collection: op.collection, id: op.id)] = i }
            ops += new.enumerated().filter { last[Key(collection: $0.element.collection, id: $0.element.id)] == $0.offset }.map(\.element)
            save()
        }
    }

    private struct Key: Hashable {
        let collection: String
        let id: String
    }

    /// Removes the sent ops. A newer op for the same record stays.
    public func remove(_ sent: [StoreOp]) {
        let done = Set(sent.map(\.hlc))
        lock.withLock {
            ops.removeAll { done.contains($0.hlc) }
            save()
        }
    }

    // Call with the lock held.
    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(ops) { try? data.write(to: url, options: .atomic) }
    }
}
