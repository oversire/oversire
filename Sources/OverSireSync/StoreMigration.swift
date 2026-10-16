import Foundation
import OverSireCore

/// Copies the state of older app versions into the store: the "ignoredFailures" user default
/// and the queue.json file. The caller removes the old copy after a success.
public struct StoreMigration: Sendable {
    public static let ignoredKey = "ignoredFailures"

    /// The old queue.json: lanes, and the item keys of tracker triggers. Dates are seconds since 2001.
    struct OldQueue: Decodable {
        var lanes: [QueueLane]
        var seen: [String]
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

    /// Records that are in the store already stay.
    public func run(into store: any Store) async throws {
        for r in ignored where try await store.get(IgnoredFailure.self, id: r.id) == nil { try await store.put(r) }
        guard let q = try queue() else { return }
        for lane in q.lanes where try await store.get(QueueLane.self, id: lane.id) == nil { try await store.put(lane) }
        for key in q.seen where try await store.get(QueueTrigger.self, id: key) == nil {
            try await store.put(QueueTrigger(key: key, at: now))
        }
    }
}
