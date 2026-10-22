import Foundation
import OverSireCore

/// The op log of a Hub in memory, with the same rules: last write wins by hlc, and a pull reads after a seq.
public actor FakeStoreHub {
    private var records: [String: (seq: Int, op: StoreOp)] = [:]
    private var seq = 0
    private var prunedThrough = 0
    public var online = true
    public var pageSize = 500
    public private(set) var pushes = 0
    public private(set) var pulls = 0
    /// A daemon that is not home any more answers 409 to each call.
    public private(set) var notHome: StoreNotHome?

    public init() {}

    public nonisolated func replication() -> FakeReplication { FakeReplication(hub: self) }

    public func setOnline(_ on: Bool) { online = on }

    public func setNotHome(_ e: StoreNotHome?) { notHome = e }

    public func setPageSize(_ n: Int) { pageSize = n }

    /// The newest op of each record.
    public func ops() -> [StoreOp] { records.values.sorted { $0.seq < $1.seq }.map(\.op) }

    /// Forgets the tombstones. A client with an older cursor then gets a reset.
    public func pruneTombstones() {
        prunedThrough = seq
        records = records.filter { $0.value.op.op == .put }
    }

    func push(_ ops: [StoreOp]) throws -> [StoreOp] {
        guard online else { throw ProviderError.transport("offline") }
        if let notHome { throw notHome }
        pushes += 1
        var accepted: [StoreOp] = []
        for op in ops {
            let key = "\(op.collection)/\(op.id)"
            if let r = records[key], r.op.hlc >= op.hlc { continue }
            seq += 1
            records[key] = (seq, op)
            accepted.append(op)
        }
        return accepted
    }

    func pull(after: Cursor?) throws -> StorePull {
        guard online else { throw ProviderError.transport("offline") }
        if let notHome { throw notHome }
        pulls += 1
        var from = after.flatMap { Int($0.rawValue) } ?? 0
        let reset = from > 0 && from < prunedThrough
        if reset { from = 0 }
        let rows = records.values.filter { $0.seq > from }.sorted { $0.seq < $1.seq }
        // A reset sends all records in one page.
        let page = reset ? rows[...] : rows.prefix(pageSize)
        let more = page.count < rows.count
        return StorePull(ops: page.map(\.op), cursor: Cursor(rawValue: String(more ? page.last!.seq : seq)), more: more, reset: reset)
    }
}

public struct FakeReplication: StoreReplication {
    let hub: FakeStoreHub

    public func push(_ ops: [StoreOp]) async throws -> [StoreOp] { try await hub.push(ops) }

    public func pull(after: Cursor?) async throws -> StorePull { try await hub.pull(after: after) }
}
