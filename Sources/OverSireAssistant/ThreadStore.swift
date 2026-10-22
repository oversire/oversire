import CryptoKit
import Foundation
import OverSireCore
import OverSireAI

/// How long the app keeps chats. Pinned chats stay.
public enum ChatRetention: String, Sendable, Codable, CaseIterable {
    case days7 = "7d", days30 = "30d", always

    public var seconds: TimeInterval? {
        switch self {
        case .days7: return 7 * 86_400
        case .days30: return 30 * 86_400
        case .always: return nil
        }
    }
}

/// The chats of the assistant: threads and messages in the store, blobs as files named by their sha256.
public actor ThreadStore: BlobReading {
    public static let newTitle = "New chat"

    let store: any Store
    public nonisolated let blobDir: URL

    /// `blobDir`: ~/.config/oversire/assistant/blobs in the app.
    public init(store: any Store, blobDir: URL) {
        self.store = store
        self.blobDir = blobDir
    }

    /// Newest first.
    public func threads() async throws -> [AssistantThread] {
        try await store.all(AssistantThread.self).sorted { $0.updatedAt > $1.updatedAt }
    }

    public func thread(_ id: String) async throws -> AssistantThread? { try await store.get(AssistantThread.self, id: id) }

    public func save(_ t: AssistantThread) async throws { try await store.put(t) }

    /// Oldest first.
    public func messages(_ thread: String) async throws -> [AssistantMessage] {
        try await store.all(AssistantMessage.self).filter { $0.thread == thread }
            .sorted { ($0.at, $0.role == .user ? 0 : 1) < ($1.at, $1.role == .user ? 0 : 1) }
    }

    public func save(_ m: AssistantMessage) async throws { try await store.put(m) }

    /// Deletes the thread and its messages. Blobs go at the next prune.
    public func delete(thread id: String) async throws {
        for m in try await store.all(AssistantMessage.self) where m.thread == id {
            try await store.delete(AssistantMessage.self, id: m.id)
        }
        try await store.delete(AssistantThread.self, id: id)
    }

    /// Writes the bytes once. Gives the sha256 in hex.
    public func put(blob data: Data) throws -> String {
        let id = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let url = blobDir.appendingPathComponent(id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: blobDir, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
        return id
    }

    public func blob(_ id: String) -> Data? {
        guard id.allSatisfy(\.isHexDigit) else { return nil }
        return try? Data(contentsOf: blobDir.appendingPathComponent(id))
    }

    /// Deletes the threads that did not change in the retention time, then the blobs that no message uses.
    /// The app runs it at launch.
    public func prune(_ retention: ChatRetention, now: Date = Date()) async throws {
        if let keep = retention.seconds {
            for t in try await store.all(AssistantThread.self) where !t.pinned && now.timeIntervalSince(t.updatedAt) > keep {
                try await delete(thread: t.id)
            }
        }
        var used = Set<String>()
        for m in try await store.all(AssistantMessage.self) {
            for p in m.parts {
                switch p {
                case .image(let b, _, _, _), .file(let b, _, _, _): used.insert(b)
                default: break
                }
            }
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: blobDir.path)) ?? []
        for name in names where !name.hasPrefix(".") && !used.contains(name) {
            try? FileManager.default.removeItem(at: blobDir.appendingPathComponent(name))
        }
    }
}
