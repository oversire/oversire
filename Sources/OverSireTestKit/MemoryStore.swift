import Foundation
import OverSireCore

/// A store in memory. Records go through JSON, as in LocalStore.
public actor MemoryStore: Store {
    private var rows: [String: [String: Data]] = [:]
    private var streams: [UUID: AsyncStream<StoreChange>.Continuation] = [:]

    public init() {}

    public func all<R: StoreRecord>(_ type: R.Type) throws -> [R] {
        try (rows[R.collection] ?? [:]).values.map { try JSONDecoder().decode(R.self, from: $0) }
    }

    public func get<R: StoreRecord>(_ type: R.Type, id: String) throws -> R? {
        try rows[R.collection]?[id].map { try JSONDecoder().decode(R.self, from: $0) }
    }

    public func put<R: StoreRecord>(_ record: R) throws {
        let data = try JSONEncoder().encode(record)
        guard rows[R.collection]?[record.id] != data else { return }
        rows[R.collection, default: [:]][record.id] = data
        emit(StoreChange(collection: R.collection, id: record.id, deleted: false))
    }

    public func delete<R: StoreRecord>(_ type: R.Type, id: String) throws {
        guard rows[R.collection]?.removeValue(forKey: id) != nil else { return }
        emit(StoreChange(collection: R.collection, id: id, deleted: true))
    }

    public func changes() -> AsyncStream<StoreChange> {
        let id = UUID()
        let (stream, cont) = AsyncStream.makeStream(of: StoreChange.self)
        streams[id] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.drop(id) } }
        return stream
    }

    private func drop(_ id: UUID) { streams[id] = nil }

    private func emit(_ c: StoreChange) {
        for s in streams.values { s.yield(c) }
    }
}
