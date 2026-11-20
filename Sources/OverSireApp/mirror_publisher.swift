import Foundation
import CryptoKit
import OverSireCore
import OverSireSync

// ─── Mirror publisher ────────────────────────────────────────────────────────
// The app that holds the automations lease sends its provider data to the mirror of the home daemon
// (OVERSIRE-526). It sends only the docs whose hash changed. A client reads the docs later (OVERSIRE-527).

/// The docs of the app. A doc has its hash set, or an empty hash: the publisher then computes it.
/// The publisher sets `at`.
@MainActor
protocol MirrorDocSource {
    /// The `project` doc and the `item` docs of each tracked project. nil: all projects.
    func projectDocs(_ keys: [String]?) -> [MirrorDoc]
    func runDocs(_ repos: [String]?) -> [MirrorDoc]
    func prDocs(_ repos: [String]?) -> [MirrorDoc]
    /// The entries that are not older than `since`.
    func activityDocs(since: Date?) -> [MirrorDoc]
    func catalogDoc() -> MirrorDoc
}

extension MirrorDoc {
    /// A live doc of the current body version. The hash is the SHA-256 of the bytes that the daemon hashes.
    static func make<T: Encodable>(_ kind: MirrorKind, id: String, _ value: T) -> MirrorDoc? {
        guard let body = try? MirrorCodec.body(value) else { return nil }
        return MirrorDoc(kind: kind, id: id, v: MirrorCodec.version, hash: MirrorHash.hex(MirrorCodec.bytes(body)), at: Date(), body: body)
    }
}

enum MirrorHash {
    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// Main thread only.
@MainActor
final class MirrorPublisher {
    static let maxDocs = 500
    static let maxBatchBytes = 8 << 20
    static let maxDocBytes = 1 << 20
    static let activityDays = 14

    struct NoHome: Error {}

    /// What changed since the last send. A key set with its `all` flag false holds the keys.
    private struct Pending {
        var projects = Set<String>(), allProjects = false
        var runs = Set<String>(), allRuns = false
        var prs = Set<String>(), allPRs = false
        var activity = false
        var catalog = false

        var isEmpty: Bool { !allProjects && projects.isEmpty && !allRuns && runs.isEmpty && !allPRs && prs.isEmpty && !activity && !catalog }

        mutating func merge(_ o: Pending) {
            projects.formUnion(o.projects); allProjects = allProjects || o.allProjects
            runs.formUnion(o.runs); allRuns = allRuns || o.allRuns
            prs.formUnion(o.prs); allPRs = allPRs || o.allPRs
            activity = activity || o.activity
            catalog = catalog || o.catalog
        }
    }

    private struct Entry {
        var kind: MirrorKind
        var id: String
        var hash: String
    }

    /// A doc to send and its hash and size. A tombstone has no hash.
    private struct Out {
        var doc: MirrorDoc
        var bytes: Int
    }

    private let home: () async -> DaemonClient?
    private let rehome: () async -> Void
    private let docs: MirrorDocSource
    private let bus: ChangeBus
    private let appVersion: String
    private let source: String
    private let sourceName: String
    private let clock: () -> Date
    private let debounce: TimeInterval

    private var observation: ChangeBus.Observation?
    private var running = false
    private var pending = Pending()
    // "kind/id" → the doc that the home has.
    private var known: [String: Entry] = [:]
    private var epoch: String?
    private var needsAll = true
    // The home of the last full diff.
    private var base: URL?
    private var timer: Task<Void, Never>?
    private var tail: Task<Void, Never>?
    private var failures = 0

    init(home: @escaping () async -> DaemonClient?, rehome: @escaping () async -> Void, docs: MirrorDocSource, bus: ChangeBus = .shared,
         appVersion: String, source: String, sourceName: String, clock: @escaping () -> Date = Date.init, debounce: TimeInterval = 2) {
        self.home = home
        self.rehome = rehome
        self.docs = docs
        self.bus = bus
        self.appVersion = appVersion
        self.source = source
        self.sourceName = sourceName
        self.clock = clock
        self.debounce = debounce
    }

    var isRunning: Bool { running }

    func start() {
        guard !running else { return }
        running = true
        needsAll = true
        observation = bus.observe { [weak self] c in MainActor.assumeIsolated { self?.changed(c) } }
        schedule(after: debounce)
    }

    func stop() {
        running = false
        observation = nil
        timer?.cancel()
        timer = nil
        pending = Pending()
        failures = 0
    }

    /// nil ids: all ids of the kind. A `project` or `item` id is a store key. A `runs` or `prs` id is a repo.
    func touched(_ kind: MirrorKind, ids: [String]?) {
        guard running else { return }
        switch kind {
        case .project, .item:
            if let ids { pending.projects.formUnion(ids) } else { pending.allProjects = true }
        case .runs:
            if let ids { pending.runs.formUnion(ids) } else { pending.allRuns = true }
        case .prs:
            if let ids { pending.prs.formUnion(ids) } else { pending.allPRs = true }
        case .activity: pending.activity = true
        case .catalog: pending.catalog = true
        case .settings: return
        }
        schedule(after: debounce)
    }

    private func changed(_ c: DataChange) {
        if c.domains.contains(.projects) {
            touched(.project, ids: c.projects.isEmpty ? nil : Array(c.projects))
            touched(.activity, ids: nil)
        }
        if c.domains.contains(.runs) { touched(.runs, ids: c.repos.isEmpty ? nil : Array(c.repos)) }
        if c.domains.contains(.prs) { touched(.prs, ids: c.repos.isEmpty ? nil : Array(c.repos)) }
    }

    private func schedule(after delay: TimeInterval) {
        guard running, timer == nil else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.timer = nil
            await self.tick()
        }
    }

    private func tick() async {
        do {
            try await flush()
            failures = 0
        } catch {
            failures += 1
            let wait = min(5 * pow(2, Double(failures - 1)), 300)
            log.error("mirror put failed: \(String(describing: error), privacy: .public). Retry in \(Int(wait)) s.")
            schedule(after: wait)
        }
    }

    /// Sends the pending docs at once. Calls run one after the other.
    func flush() async throws {
        timer?.cancel()
        timer = nil
        let before = tail
        let run = Task { @MainActor in
            await before?.value
            try await self.drain()
        }
        tail = Task { _ = try? await run.value }
        try await run.value
    }

    private func drain() async throws {
        var retries = 0
        while running {
            guard let client = await home() else { throw NoHome() }
            guard running else { return }
            do {
                if needsAll || client.base != base { try await sendAll(client) } else { try await sendPending(client) }
                return
            } catch let e as StoreNotHome {
                log.info("Mirror: \(e.message, privacy: .public)")
                needsAll = true
                retries += 1
                if retries > 2 { throw e }
                await rehome()
            } catch ProviderError.vendor(let code, _) where code == "409" {
                // The mirror has a new epoch: read the index again and send what differs.
                needsAll = true
                retries += 1
                if retries > 2 { throw ProviderError.vendor(code: code, message: "The mirror keeps changing.") }
            }
        }
    }

    // MARK: Sending

    private func cutoff() -> Date { clock().addingTimeInterval(-Double(Self.activityDays) * 86400) }

    /// The first send to a home, a new epoch or a new home. Diffs all docs with the index, then sets `ready`.
    private func sendAll(_ client: DaemonClient) async throws {
        let index = try await client.mirrorIndex()
        epoch = index.epoch
        known = Dictionary(index.docs.map { (Self.key($0.kind, $0.id), Entry(kind: $0.kind, id: $0.id, hash: $0.hash)) },
                           uniquingKeysWith: { a, _ in a })
        base = client.base
        pending = Pending()
        let wanted = docs.projectDocs(nil) + docs.runDocs(nil) + docs.prDocs(nil) + docs.activityDocs(since: cutoff()) + [docs.catalogDoc()]
        needsAll = true
        try await send(client, wanted: wanted, inScope: { _ in true }, ready: true)
        needsAll = false
    }

    private func sendPending(_ client: DaemonClient) async throws {
        let p = pending
        pending = Pending()
        guard !p.isEmpty else { return }
        do {
            var wanted: [MirrorDoc] = []
            var scopes: [(Entry) -> Bool] = []
            if p.allProjects || !p.projects.isEmpty {
                let keys = p.allProjects ? nil : Array(p.projects)
                wanted += docs.projectDocs(keys)
                scopes.append { e in
                    switch e.kind {
                    case .project: return keys == nil || p.projects.contains(e.id)
                    case .item: return keys == nil || MirrorCodec.projectKey(ofItemDoc: e.id).map(p.projects.contains) ?? false
                    default: return false
                    }
                }
            }
            if p.allRuns || !p.runs.isEmpty {
                wanted += docs.runDocs(p.allRuns ? nil : Array(p.runs))
                scopes.append { $0.kind == .runs && (p.allRuns || p.runs.contains($0.id)) }
            }
            if p.allPRs || !p.prs.isEmpty {
                wanted += docs.prDocs(p.allPRs ? nil : Array(p.prs))
                scopes.append { $0.kind == .prs && (p.allPRs || p.prs.contains($0.id)) }
            }
            if p.activity {
                wanted += docs.activityDocs(since: cutoff())
                scopes.append { $0.kind == .activity }
            }
            if p.catalog {
                wanted.append(docs.catalogDoc())
                scopes.append { $0.kind == .catalog }
            }
            try await send(client, wanted: wanted, inScope: { e in scopes.contains { $0(e) } }, ready: false)
        } catch {
            pending.merge(p)
            throw error
        }
    }

    private static func key(_ kind: MirrorKind, _ id: String) -> String { "\(kind.rawValue)/\(id)" }

    /// Sends the docs of `wanted` that differ from `known`, and a tombstone for each known doc in scope that is not in `wanted`.
    /// `ready` sets the flag on the last batch, also when nothing differs.
    private func send(_ client: DaemonClient, wanted: [MirrorDoc], inScope: (Entry) -> Bool, ready: Bool) async throws {
        let now = clock()
        var seen = Set<String>()
        var out: [Out] = []
        for d in wanted {
            let k = Self.key(d.kind, d.id)
            seen.insert(k)
            guard let body = d.body else { continue }
            var hash = d.hash
            var size = 0
            if hash.isEmpty {
                let bytes = MirrorCodec.bytes(body)
                hash = MirrorHash.hex(bytes)
                size = bytes.count
            }
            if known[k]?.hash == hash { continue }
            if size == 0 { size = MirrorCodec.bytes(body).count }
            if size > Self.maxDocBytes {
                log.error("mirror skips \(k, privacy: .public): \(size) bytes is over the limit")
                continue
            }
            var doc = d
            doc.hash = ""
            doc.at = now
            out.append(Out(doc: doc, bytes: size))
        }
        let gone = known.filter { !seen.contains($0.key) && inScope($0.value) }.sorted { $0.key < $1.key }
        for (_, e) in gone {
            out.append(Out(doc: MirrorDoc(kind: e.kind, id: e.id, v: MirrorCodec.version, at: now, deleted: true), bytes: 0))
        }
        let hashes = Dictionary(wanted.compactMap { d in d.body == nil ? nil : (Self.key(d.kind, d.id), d.hash) }, uniquingKeysWith: { a, _ in a })

        var batches: [[Out]] = []
        var batch: [Out] = []
        var bytes = 0
        for o in out {
            if !batch.isEmpty && (batch.count >= Self.maxDocs || bytes + o.bytes > Self.maxBatchBytes) {
                batches.append(batch)
                batch = []
                bytes = 0
            }
            batch.append(o)
            bytes += o.bytes
        }
        if !batch.isEmpty || ready { batches.append(batch) }

        for (i, b) in batches.enumerated() {
            guard running, let epoch else { return }
            let last = i == batches.count - 1
            let put = MirrorPut(epoch: epoch, source: source, sourceName: sourceName, appVersion: appVersion,
                                ready: ready && last ? true : nil, docs: b.map(\.doc))
            let res = try await client.mirrorPut(put)
            log.info("mirror put docs=\(b.count) same=\(res.same) head=\(res.head.head)")
            for o in b {
                let k = Self.key(o.doc.kind, o.doc.id)
                if o.doc.deleted == true { known[k] = nil } else {
                    known[k] = Entry(kind: o.doc.kind, id: o.doc.id, hash: hashes[k].flatMap { $0.isEmpty ? nil : $0 } ?? Self.hash(of: o.doc))
                }
            }
        }
    }

    private static func hash(of doc: MirrorDoc) -> String { doc.body.map { MirrorHash.hex(MirrorCodec.bytes($0)) } ?? "" }
}
