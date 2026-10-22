import Foundation
import OverSireCore

/// The store of a Mac that syncs with the cloud hub or with the home daemon of its machine group. It wraps LocalStore and works offline.
/// A write goes to disk at once, and its op waits in the outbox until the server accepts it.
/// Remote ops apply when their hlc is newer (last write wins for each record). Other collections stay local.
/// The replica can change: a home move (409) or a group change. Each replica has its own cursor. The outbox keeps the ops
/// while there is no replica.
public actor SyncedStore: Store {
    public static let cursorKey = "store"
    public static let tombstoneDays = 30
    /// The collections that sync. Derived state and caches do not.
    public static let collections: [any StoreRecord.Type] = [
        QueueLane.self, QueueTrigger.self, IgnoredFailure.self, Pin.self, Snooze.self, Note.self, AgentLink.self,
        MemoryEntry.self, AIJob.self, Suggestion.self, ItemAreas.self, PlannerSettings.self, AreaCatalog.self, AreaCandidates.self,
        ChangedPaths.self,
    ]
    /// The collections that only the hub writes. They come down and never go up.
    public static let hubOnly: [any StoreRecord.Type] = [BillingState.self, WorkOrder.self, RunnerState.self, RunnerSession.self, AreaClaim.self]
    private static let byName = Dictionary(uniqueKeysWithValues: collections.map { ($0.collection, $0) })
    private static let pulled = Dictionary(uniqueKeysWithValues: (collections + hubOnly).map { ($0.collection, $0) })
    private static let names = pulled.keys.sorted()

    public nonisolated let local: LocalStore
    /// The device id in the hlc of each local write.
    public nonisolated let device: String
    private var replica: StoreReplica?
    private let rehome: @Sendable (StoreNotHome) async -> StoreReplica?
    private let clock: HybridClock
    private let outbox: Outbox
    private let cursors: CursorStore
    private let stateURL: URL?
    private let now: @Sendable () -> Date
    private let sleeper: any Clock<Duration>
    private let autoSync: Bool
    private var state: SyncState
    private var syncing = false
    private var syncAgain = false
    private var retry: Task<Void, Never>?
    private var backoff = Backoff()
    private var remote: [UUID: AsyncStream<StoreChange>.Continuation] = [:]
    public private(set) var lastSync: Date?
    public private(set) var lastError: String?

    /// The cloud hub as the replica, with the id "cloud".
    public init(local: LocalStore, replication: any StoreReplication, device: String, dir: URL?, cursors: CursorStore,
                now: @escaping @Sendable () -> Date = Date.init, sleeper: any Clock<Duration> = ContinuousClock(),
                autoSync: Bool = true) {
        self.init(local: local, replica: StoreReplica(id: Self.cloudReplica, replication: replication), device: device, dir: dir,
                  cursors: cursors, now: now, sleeper: sleeper, autoSync: autoSync)
    }

    /// dir holds the outbox and the record clocks. A nil dir keeps them in memory. autoSync off: only sync() sends.
    /// A nil replica keeps all ops in the outbox. rehome gives the replica after a 409 (nil: none now).
    public init(local: LocalStore, replica: StoreReplica?, device: String, dir: URL?, cursors: CursorStore,
                now: @escaping @Sendable () -> Date = Date.init, sleeper: any Clock<Duration> = ContinuousClock(),
                autoSync: Bool = true, rehome: @escaping @Sendable (StoreNotHome) async -> StoreReplica? = { _ in nil }) {
        self.local = local
        self.replica = replica
        self.rehome = rehome
        self.cursors = cursors
        self.now = now
        self.sleeper = sleeper
        self.autoSync = autoSync
        self.device = device
        clock = HybridClock(device: device, now: now)
        outbox = Outbox(url: dir?.appendingPathComponent("outbox.json"))
        stateURL = dir?.appendingPathComponent("clocks.json")
        state = stateURL.flatMap { try? JSONDecoder().decode(SyncState.self, from: Data(contentsOf: $0)) } ?? SyncState()
        // A clock that went back after a restart still makes larger stamps.
        for hlc in state.clocks.values.map(\.hlc) + outbox.pending.map(\.hlc) { clock.observe(hlc) }
        if let replica, state.home == nil { state.home = replica.id }
    }

    /// The id of the cloud replica. Its cursor keeps the old key.
    public static let cloudReplica = "cloud"

    /// The id of the replica now. nil: local only.
    public var replicaID: String? { replica?.id }

    /// Changes the replica. A new home gets the full local store once, with the hlc of each record: the newest write wins there.
    /// nil keeps the ops in the outbox until a replica comes back.
    public func use(_ next: StoreReplica?) {
        switchTo(next)
        if next != nil, autoSync { Task { await self.sync() } }
    }

    private func switchTo(_ next: StoreReplica?) {
        guard next?.id != replica?.id else { replica = next; return }
        replica = next
        guard let next else { return }
        if let home = state.home, home != next.id { pushAll() }
        state.home = next.id
        saveState()
    }

    /// Queues each record and tombstone with its own hlc.
    private func pushAll() {
        let waiting = Set(outbox.pending.map { Self.key($0.collection, $0.id) })
        for (key, c) in state.clocks where !waiting.contains(key) {
            guard let slash = key.firstIndex(of: "/") else { continue }
            let collection = String(key[..<slash]), id = String(key[key.index(after: slash)...])
            guard let type = Self.byName[collection] else { continue }
            if c.deleted {
                outbox.add(StoreOp(collection: collection, id: id, op: .delete, hlc: c.hlc, device: clock.device))
            } else if let value = Self.stored(type, id: id, in: local) {
                outbox.add(StoreOp(collection: collection, id: id, op: .put, record: value, hlc: c.hlc, device: clock.device))
            }
        }
    }

    private static func stored<R: StoreRecord>(_ type: R.Type, id: String, in local: LocalStore) -> JSONValue? {
        local.stored(type).first { $0.id == id }.flatMap { try? JSONValue($0) }
    }

    private var cursorKey: String {
        guard let id = replica?.id, id != Self.cloudReplica else { return Self.cursorKey }
        return "\(Self.cursorKey)@\(id)"
    }

    public var pending: Int { outbox.pending.count }

    // MARK: Store

    public func all<R: StoreRecord>(_ type: R.Type) async throws -> [R] { try await local.all(type) }

    public func get<R: StoreRecord>(_ type: R.Type, id: String) async throws -> R? { try await local.get(type, id: id) }

    public func put<R: StoreRecord>(_ record: R) async throws {
        guard Self.byName[R.collection] != nil else { return try await local.put(record) }
        if try await local.get(R.self, id: record.id) == record { return }
        let value = try JSONValue(record)
        let hlc = clock.next()
        state.clocks[Self.key(R.collection, record.id)] = RecordClock(hlc: hlc, deleted: false)
        try await local.put(record)
        queue(StoreOp(collection: R.collection, id: record.id, op: .put, record: value, hlc: hlc, device: clock.device))
    }

    public func delete<R: StoreRecord>(_ type: R.Type, id: String) async throws {
        guard Self.byName[R.collection] != nil else { return try await local.delete(type, id: id) }
        guard try await local.get(R.self, id: id) != nil else { return }
        let hlc = clock.next()
        state.clocks[Self.key(R.collection, id)] = RecordClock(hlc: hlc, deleted: true)
        try await local.delete(type, id: id)
        queue(StoreOp(collection: R.collection, id: id, op: .delete, hlc: hlc, device: clock.device))
    }

    /// Local and remote writes.
    public func changes() async -> AsyncStream<StoreChange> { await local.changes() }

    /// Only the writes that came from the server. A model that keeps records in memory reads them again.
    public func remoteChanges() -> AsyncStream<StoreChange> {
        let id = UUID()
        let (stream, cont) = AsyncStream.makeStream(of: StoreChange.self)
        remote[id] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.dropStream(id) } }
        return stream
    }

    private func dropStream(_ id: UUID) { remote[id] = nil }

    private func emitRemote(_ c: StoreChange) {
        for s in remote.values { s.yield(c) }
    }

    private func queue(_ op: StoreOp) {
        outbox.add(op)
        saveState()
        if autoSync { Task { await self.sync() } }
    }

    // MARK: Sync

    /// Sends the outbox, then reads the remote ops. Calls during a sync run once more after it.
    /// A failure tries again later with a backoff.
    public func sync() async {
        guard replica != nil else { return }
        guard !syncing else { syncAgain = true; return }
        syncing = true
        defer { syncing = false }
        repeat {
            syncAgain = false
            do {
                // A new app version can sync more collections. It reads all ops again and sends the local records once.
                let grew = state.known != Self.names
                try await push()
                try await pull(all: grew)
                if !state.seeded || grew { try await seed() }
                lastSync = now()
                lastError = nil
                backoff.reset()
                retry?.cancel()
                retry = nil
            } catch let e as StoreNotHome {
                lastError = e.message
                let next = await rehome(e)
                // The store of another replica is not here yet: the next sync reads it.
                guard next != nil, next?.id != replica?.id else { switchTo(nil); return }
                switchTo(next)
                syncAgain = true
                continue
            } catch {
                lastError = (error as? ProviderError)?.message ?? error.localizedDescription
                if error as? ProviderError != .unauthorized { scheduleRetry() }
                return
            }
        } while syncAgain
    }

    public func stop() {
        retry?.cancel()
        retry = nil
    }

    private func scheduleRetry() {
        guard retry == nil, autoSync else { return }
        let wait = backoff.next()
        retry = Task { [sleeper] in
            try? await sleeper.sleep(for: wait)
            guard !Task.isCancelled else { return }
            await self.retried()
        }
    }

    private func retried() async {
        retry = nil
        await sync()
    }

    private func push() async throws {
        guard let replication = replica?.replication else { throw ProviderError.transport("The store has no home now") }
        while true {
            let batch = Array(outbox.pending.prefix(100))
            if batch.isEmpty { return }
            _ = try await replication.push(batch)
            // A rejected op lost to a newer write. The pull brings that write.
            outbox.remove(batch)
        }
    }

    private func pull(all: Bool) async throws {
        guard let replication = replica?.replication else { return }
        let key = cursorKey
        var cursor = all ? nil : cursors[key]
        var reset = false
        var seen = Set<String>()
        while true {
            let page = try await replication.pull(after: cursor)
            reset = reset || page.reset
            for op in page.ops {
                seen.insert(Self.key(op.collection, op.id))
                try await apply(op)
            }
            cursor = page.cursor
            if !page.more { break }
        }
        // Before the seed, the local records did not go to the server yet: keep them.
        if reset && state.seeded && !all { try await drop(keeping: seen) }
        pruneTombstones()
        saveState()
        cursors[key] = cursor
    }

    private func apply(_ op: StoreOp) async throws {
        clock.observe(op.hlc)
        let key = Self.key(op.collection, op.id)
        if let c = state.clocks[key], c.hlc >= op.hlc { return }
        // A collection of a newer app version stays on the server.
        guard let type = Self.pulled[op.collection] else { return }
        try await write(type, op, key: key)
    }

    private func write<R: StoreRecord>(_ type: R.Type, _ op: StoreOp, key: String) async throws {
        switch op.op {
        case .put:
            guard let value = op.record,
                  let record = try? LocalStore.decoder.decode(R.self, from: JSONEncoder().encode(value)) else { return }
            state.clocks[key] = RecordClock(hlc: op.hlc, deleted: false)
            try await local.put(record)
        case .delete:
            state.clocks[key] = RecordClock(hlc: op.hlc, deleted: true)
            try await local.delete(type, id: op.id)
        }
        emitRemote(StoreChange(collection: R.collection, id: op.id, deleted: op.op == .delete))
    }

    // After a reset, a record that the server does not have is gone, unless its op still waits.
    private func drop(keeping seen: Set<String>) async throws {
        let waiting = Set(outbox.pending.map { Self.key($0.collection, $0.id) })
        for type in Self.collections + Self.hubOnly { try await drop(type, keeping: seen.union(waiting)) }
    }

    private func drop<R: StoreRecord>(_ type: R.Type, keeping: Set<String>) async throws {
        for r in try await local.all(type) where !keeping.contains(Self.key(R.collection, r.id)) {
            state.clocks[Self.key(R.collection, r.id)] = nil
            try await local.delete(type, id: r.id)
            emitRemote(StoreChange(collection: R.collection, id: r.id, deleted: true))
        }
    }

    // The records from before the pairing go to the server once, after the first pull.
    // A record that the server has already keeps the server copy.
    private func seed() async throws {
        for type in Self.collections { try await seed(type) }
        state.seeded = true
        state.known = Self.names
        saveState()
        if !outbox.pending.isEmpty { syncAgain = true }
    }

    private func seed<R: StoreRecord>(_ type: R.Type) async throws {
        for r in try await local.all(type) where state.clocks[Self.key(R.collection, r.id)] == nil {
            let hlc = clock.next()
            state.clocks[Self.key(R.collection, r.id)] = RecordClock(hlc: hlc, deleted: false)
            outbox.add(StoreOp(collection: R.collection, id: r.id, op: .put, record: try JSONValue(r), hlc: hlc, device: clock.device))
        }
    }

    private func pruneTombstones() {
        let cutoff = HybridClock.millis(now()) - Int64(Self.tombstoneDays) * 86_400_000
        state.clocks = state.clocks.filter { _, c in !c.deleted || (HybridClock.parse(c.hlc)?.ms ?? 0) >= cutoff }
    }

    private func saveState() {
        guard let stateURL, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: stateURL, options: .atomic)
    }

    static func key(_ collection: String, _ id: String) -> String { "\(collection)/\(id)" }
}

/// The hlc of the last write of one record. A delete keeps its hlc as a tombstone.
struct RecordClock: Codable, Hashable, Sendable {
    var hlc: String
    var deleted: Bool
}

struct SyncState: Codable, Sendable {
    var seeded = false
    var clocks: [String: RecordClock] = [:]
    /// The pulled collections at the last seed. Nil before this field.
    var known: [String]?
    /// The id of the last replica. Nil before this field.
    var home: String?
}

extension JSONValue {
    /// The JSON form of a record, as LocalStore writes it.
    public init<T: Encodable>(_ value: T) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: LocalStore.encoder.encode(value))
    }
}
