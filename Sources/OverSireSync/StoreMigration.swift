import Foundation
import OverSireCore

/// Copies the state of older app versions into the store: the "ignoredFailures" user default,
/// the queue.json file, and the lane state of store version 1. The caller removes the old copy after a success.
public struct StoreMigration: Sendable {
    public static let ignoredKey = "ignoredFailures"

    /// The old queue.json: lanes, and the item keys of tracker triggers. Dates are seconds since 2001.
    struct OldQueue: Decodable {
        var lanes: [OldLane]
        var seen: [String]
    }

    /// A queue lane of store version 1: it held its state. Version 2 keeps the state in QueueLaneState.
    struct OldLane: StoreRecord {
        static let collection = QueueLane.collection

        let project: String
        var identifier: String
        var entries: [QueueEntry]
        var lastStarted: String?
        var error: String?

        var id: String { project }
        var lane: QueueLane { QueueLane(project: project, identifier: identifier, entries: entries) }
        func state(at now: Date) -> QueueLaneState? {
            lastStarted == nil && error == nil ? nil : QueueLaneState(project: project, lastStarted: lastStarted, error: error, updatedAt: now)
        }
    }

    let ignoredKeys: [String]?
    public let queueFile: Data?
    public let now: Date

    /// `defaults`: the user defaults of the app.
    public init(defaults: [String: Any], queueFile: Data?, now: Date = Date()) {
        ignoredKeys = defaults[Self.ignoredKey] as? [String]
        self.queueFile = queueFile
        self.now = now
    }

    public var hasWork: Bool { ignoredKeys != nil || queueFile != nil }

    public var ignored: [IgnoredFailure] { (ignoredKeys ?? []).map { IgnoredFailure(id: $0, at: now) } }

    func queue() throws -> OldQueue? {
        guard let queueFile else { return nil }
        do { return try JSONDecoder().decode(OldQueue.self, from: queueFile) } catch {
            throw ProviderError.decoding("queue.json: \(error.localizedDescription)")
        }
    }

    /// Records that are in the store already stay. Safe to run at each start.
    public func run(into store: any Store) async throws {
        try await splitLanes(store)
        for r in ignored where try await store.get(IgnoredFailure.self, id: r.id) == nil { try await store.put(r) }
        guard let q = try queue() else { return }
        for old in q.lanes where try await store.get(QueueLane.self, id: old.id) == nil {
            try await store.put(old.lane)
            if let st = old.state(at: now), try await store.get(QueueLaneState.self, id: st.id) == nil { try await store.put(st) }
        }
        for key in q.seen where try await store.get(QueueTrigger.self, id: key) == nil {
            try await store.put(QueueTrigger(key: key, at: now))
        }
    }

    /// Moves lastStarted and error of each lane into its QueueLaneState, then writes the lane without them.
    func splitLanes(_ store: any Store) async throws {
        for old in try await store.all(OldLane.self) where old.lastStarted != nil || old.error != nil {
            if let st = old.state(at: now), try await store.get(QueueLaneState.self, id: st.id) == nil { try await store.put(st) }
            try await store.put(old.lane)
        }
    }
}
