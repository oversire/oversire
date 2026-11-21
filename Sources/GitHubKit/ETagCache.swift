import Foundation

/// The last GET bodies by path, with their ETag. A 304 answer costs no quota and gives back the kept body.
/// The oldest entries go first when the count or the bytes pass the limits.
public final class ETagCache: @unchecked Sendable {
    public let maxEntries: Int
    public let maxBytes: Int
    private let lock = NSLock()
    private var entries: [String: (etag: String, body: Data)] = [:]
    private var order: [String] = []
    private var bytes = 0

    public init(maxEntries: Int = 300, maxBytes: Int = 8 << 20) {
        self.maxEntries = maxEntries
        self.maxBytes = maxBytes
    }

    public func get(_ path: String) -> (etag: String, body: Data)? {
        lock.withLock {
            guard let e = entries[path] else { return nil }
            touch(path)
            return e
        }
    }

    public func put(_ path: String, etag: String, body: Data) {
        guard body.count <= maxBytes else { return }
        lock.withLock {
            bytes += body.count - (entries[path]?.body.count ?? 0)
            entries[path] = (etag, body)
            touch(path)
            while order.count > maxEntries || bytes > maxBytes, let old = order.first {
                order.removeFirst()
                bytes -= entries.removeValue(forKey: old)?.body.count ?? 0
            }
        }
    }

    private func touch(_ path: String) {
        order.removeAll { $0 == path }
        order.append(path)
    }
}

/// The poll mark of one repo. A nil `busy` is not in the JSON.
public struct ETagMark: Codable, Sendable {
    public var etag: String?
    public var at: Date
    public var busy: Bool?

    public init(etag: String?, at: Date, busy: Bool? = nil) {
        self.etag = etag
        self.at = at
        self.busy = busy
    }
}
