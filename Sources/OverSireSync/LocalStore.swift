import Foundation
import OverSireCore

/// The store on this Mac: one JSON file for each collection, `{id: record}`. Writes are atomic.
/// A record that does not decode is skipped, not lost: it stays in the file.
public actor LocalStore: Store {
    public nonisolated let dir: URL
    private var cache: [String: [String: Data]] = [:]
    private var streams: [UUID: AsyncStream<StoreChange>.Continuation] = [:]

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }()

    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    public init(dir: URL) {
        self.dir = dir
    }

    public func all<R: StoreRecord>(_ type: R.Type) throws -> [R] {
        try rows(R.collection).values.compactMap { try? Self.decoder.decode(R.self, from: $0) }
    }

    /// The records on disk, read outside the actor. Use it only at start, before the first write.
    public nonisolated func stored<R: StoreRecord>(_ type: R.Type) -> [R] {
        guard let data = try? Data(contentsOf: file(R.collection)),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return obj.values.compactMap { v in
            (try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed])).flatMap { try? Self.decoder.decode(R.self, from: $0) }
        }
    }

    public func get<R: StoreRecord>(_ type: R.Type, id: String) throws -> R? {
        try rows(R.collection)[id].flatMap { try? Self.decoder.decode(R.self, from: $0) }
    }

    public func put<R: StoreRecord>(_ record: R) throws {
        var rows = try rows(R.collection)
        let data = try Self.encoder.encode(record)
        guard rows[record.id] != data else { return }
        rows[record.id] = data
        try save(R.collection, rows)
        emit(StoreChange(collection: R.collection, id: record.id, deleted: false))
    }

    public func delete<R: StoreRecord>(_ type: R.Type, id: String) throws {
        var rows = try rows(R.collection)
        guard rows.removeValue(forKey: id) != nil else { return }
        try save(R.collection, rows)
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

    // MARK: Files

    nonisolated func file(_ collection: String) -> URL { dir.appendingPathComponent(collection + ".json") }

    private func rows(_ collection: String) throws -> [String: Data] {
        if let c = cache[collection] { return c }
        var out: [String: Data] = [:]
        if let data = try? Data(contentsOf: file(collection)) {
            guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ProviderError.decoding("\(collection).json is not an object")
            }
            for (id, v) in obj { out[id] = try JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed]) }
        }
        cache[collection] = out
        return out
    }

    private func save(_ collection: String, _ rows: [String: Data]) throws {
        var obj: [String: Any] = [:]
        for (id, d) in rows { obj[id] = try JSONSerialization.jsonObject(with: d, options: .fragmentsAllowed) }
        let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file(collection), options: .atomic)
        } catch {
            throw ProviderError.transport("Could not write \(collection).json: \(error.localizedDescription)")
        }
        cache[collection] = rows
    }
}
