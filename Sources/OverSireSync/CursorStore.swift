import Foundation
import OverSireCore

/// The poll position of each account, kept in one JSON file.
public final class CursorStore: @unchecked Sendable {
    private let url: URL?
    private let lock = NSLock()
    private var cursors: [String: Cursor]

    /// A nil url keeps the cursors in memory only.
    public init(url: URL?) {
        self.url = url
        cursors = url.flatMap { try? JSONDecoder().decode([String: Cursor].self, from: Data(contentsOf: $0)) } ?? [:]
    }

    public static func key(_ account: AccountID) -> String { "\(account.provider.rawValue)/\(account.id)" }

    public subscript(account: AccountID) -> Cursor? {
        get { self[Self.key(account)] }
        set { self[Self.key(account)] = newValue }
    }

    public subscript(key: String) -> Cursor? {
        get { lock.withLock { cursors[key] } }
        set {
            lock.withLock {
                guard cursors[key] != newValue else { return }
                cursors[key] = newValue
                if let url, let data = try? JSONEncoder().encode(cursors) { try? data.write(to: url, options: .atomic) }
            }
        }
    }
}
