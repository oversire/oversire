import Foundation

/// The copy of the synced collections on the server. SyncedStore uses it. The cloud adapter implements it.
public protocol StoreReplication: Sendable {
    /// Sends local ops. The answer holds the ops that the server accepted: the others lost to a newer write.
    func push(_ ops: [StoreOp]) async throws -> [StoreOp]
    /// The ops after a cursor. nil reads from the start.
    func pull(after: Cursor?) async throws -> StorePull
}

public struct StorePull: Hashable, Sendable {
    public var ops: [StoreOp]
    public var cursor: Cursor
    /// More ops wait after the cursor.
    public var more: Bool
    /// The server pruned tombstones after the old cursor (not for a read from the start). `ops` then holds all records, and a record that is not in it is gone.
    public var reset: Bool

    public init(ops: [StoreOp], cursor: Cursor, more: Bool = false, reset: Bool = false) {
        self.ops = ops
        self.cursor = cursor
        self.more = more
        self.reset = reset
    }
}
