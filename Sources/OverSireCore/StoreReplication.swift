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

/// One copy of the synced collections: the cloud hub, or the home daemon of the machine group.
/// `id` names the copy, for example "cloud:<device>" or "member:<group>/<machine>". Each copy has its own cursor.
public struct StoreReplica: Sendable {
    public var id: String
    public var replication: any StoreReplication

    public init(id: String, replication: any StoreReplication) {
        self.id = id
        self.replication = replication
    }
}

/// A daemon does not keep the store (409). `home` is the member that keeps it now. `cloud`: the cloud hub keeps it.
public struct StoreNotHome: Error, Hashable, Sendable {
    public var home: String?
    public var cloud: Bool
    public var message: String

    public init(home: String? = nil, cloud: Bool = false, message: String) {
        self.home = home
        self.cloud = cloud
        self.message = message
    }
}
