import Foundation
import OverSireCore

// ─── Mirror reader ───────────────────────────────────────────────────────────
// A client reads the provider data of the home daemon from its mirror feed (OVERSIRE-527).
// The reader pages after its cursor and gives one delta for each pull. It keeps the CI data and the
// catalog in a cache. The projects, items and activity live in ProjectStore, which has its own files.

/// The two reads of the feed. DaemonClient implements it. The app wraps it, because the home can move.
public protocol MirrorFetch: Sendable {
    func head() async throws -> MirrorHead
    func page(after: Int64, limit: Int, epoch: String?) async throws -> MirrorPage
}

extension DaemonClient: MirrorFetch {
    public func head() async throws -> MirrorHead { try await mirrorHead() }

    public func page(after: Int64, limit: Int, epoch: String?) async throws -> MirrorPage {
        try await mirrorPage(after: after, limit: limit, epoch: epoch)
    }
}

/// What one pull changed.
public struct MirrorDelta: Sendable {
    /// The project docs that changed, with `items` empty. An item has its own doc.
    public var projects: [String: ProjectSnapshot] = [:]
    /// Store key → the items that were added or changed.
    public var items: [String: [Item]] = [:]
    /// Store key → the ids of the items that left.
    public var removedItems: [String: [String]] = [:]
    public var removedProjects: [String] = []
    /// All repos, when a `runs` doc changed. nil: no change.
    public var runs: [String: [Run]]?
    /// All repos, when a `prs` doc changed. nil: no change.
    public var prs: [String: [ChangeRequest]]?
    public var activity: [ActivityEntry] = []
    public var settings: JSONValue?
    public var catalog: ClientCatalog?
    /// The delta is the whole feed: the reader drops all data that this delta does not hold.
    public var reset = false
    /// The app version of the source, while a doc has a body version that this app cannot read.
    public var needsUpdate: String?

    public init() {}

    public var isEmpty: Bool {
        projects.isEmpty && items.isEmpty && removedItems.isEmpty && removedProjects.isEmpty && runs == nil && prs == nil
            && activity.isEmpty && settings == nil && catalog == nil && !reset
    }
}

/// The files of a client in `<dir>`. A write waits `debounce` seconds, so a burst of pulls makes one write.
public final class MirrorCache: @unchecked Sendable {
    public struct Head: Codable, Equatable, Sendable {
        public var epoch: String?
        public var cursor: Int64
        public var head: Int64
        /// The time of the last good pull.
        public var updatedAt: Date?
        public var needsUpdate: String?
        public var skipped: [String]?
    }

    struct CI: Codable {
        var runs: [String: [Run]] = [:]
        var prs: [String: [ChangeRequest]] = [:]
    }

    private let dir: String
    private let debounce: TimeInterval
    private let lock = NSLock()
    private var pending: [String: @Sendable () -> Data?] = [:]
    private var scheduled = false
    private let queue = DispatchQueue(label: "oversire.mirror-cache")

    public init(dir: String, debounce: TimeInterval = 2) {
        self.dir = dir
        self.debounce = debounce
    }

    public func head() -> Head? { read("head.json") }
    func ci() -> CI { read("ci.json") ?? CI() }
    public func catalog() -> ClientCatalog? { read("catalog.json") }
    public func settings() -> JSONValue? { read("settings.json") }

    public func save(head: Head) { put("head.json", head) }
    func save(ci: CI) { put("ci.json", ci) }
    public func save(catalog: ClientCatalog) { put("catalog.json", catalog) }
    public func save(settings: JSONValue) { put("settings.json", settings) }

    /// Writes the waiting files at once.
    public func flush() {
        let jobs: [String: @Sendable () -> Data?] = lock.withLock {
            defer { pending = [:] }
            return pending
        }
        write(jobs)
    }

    private func read<T: Decodable>(_ name: String) -> T? {
        guard let data = FileManager.default.contents(atPath: dir + "/" + name) else { return nil }
        return try? MirrorCodec.decoder().decode(T.self, from: data)
    }

    private func put<T: Encodable & Sendable>(_ name: String, _ value: T) {
        let first: Bool = lock.withLock {
            pending[name] = { try? MirrorCodec.encoder().encode(value) }
            if debounce <= 0 { return false }
            defer { scheduled = true }
            return !scheduled
        }
        if debounce <= 0 { flush(); return }
        guard first else { return }
        queue.asyncAfter(deadline: .now() + debounce) { [weak self] in
            self?.lock.withLock { self?.scheduled = false }
            self?.flush()
        }
    }

    private func write(_ jobs: [String: @Sendable () -> Data?]) {
        guard !jobs.isEmpty else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for (name, make) in jobs {
            guard let data = make() else { continue }
            try? data.write(to: URL(fileURLWithPath: dir + "/" + name), options: .atomic)
        }
    }
}

/// Main thread or any thread: the reader is an actor.
public actor MirrorReader {
    public static let pageLimit = 500

    /// The docs of one read, in the order of the feed. A reset read keeps them here until the new feed is ready.
    private struct Batch {
        var reset: Bool
        var projects: [String: ProjectSnapshot] = [:]
        var removedProjects: Set<String> = []
        var items: [String: [String: (n: Int, item: Item)]] = [:]
        var removedItems: [String: Set<String>] = [:]
        var runs: [String: [Run]] = [:]
        var goneRuns: Set<String> = []
        var prs: [String: [ChangeRequest]] = [:]
        var gonePRs: Set<String> = []
        var activity: [String: ActivityEntry] = [:]
        var settings: JSONValue?
        var catalog: ClientCatalog?
        var skipped: Set<String> = []
        var unskipped: Set<String> = []
        var count = 0

        mutating func add(_ d: MirrorDoc) {
            count += 1
            let k = "\(d.kind.rawValue)/\(d.id)"
            let gone = d.deleted == true
            if d.v > MirrorCodec.version {
                skipped.insert(k)
                return
            }
            if gone || d.body != nil { unskipped.insert(k); skipped.remove(k) }
            do {
                try decode(d, gone: gone)
            } catch {
                // A body that does not decode is as unreadable as a newer one.
                unskipped.remove(k)
                skipped.insert(k)
            }
        }

        private mutating func decode(_ d: MirrorDoc, gone: Bool) throws {
            switch d.kind {
            case .project:
                if gone { projects[d.id] = nil; removedProjects.insert(d.id); return }
                guard let body = d.body else { return }
                projects[d.id] = try MirrorCodec.value(ProjectSnapshot.self, from: body)
                removedProjects.remove(d.id)
            case .item:
                guard let slash = d.id.lastIndex(of: "/"), let key = MirrorCodec.projectKey(ofItemDoc: d.id) else { return }
                let id = String(d.id[d.id.index(after: slash)...])
                if gone {
                    items[key]?[id] = nil
                    removedItems[key, default: []].insert(id)
                    return
                }
                guard let body = d.body else { return }
                items[key, default: [:]][id] = (count, try MirrorCodec.value(Item.self, from: body))
                removedItems[key]?.remove(id)
            case .runs:
                if gone { runs[d.id] = nil; goneRuns.insert(d.id); return }
                guard let body = d.body else { return }
                runs[d.id] = try MirrorCodec.value(MirrorRuns.self, from: body).runs
                goneRuns.remove(d.id)
            case .prs:
                if gone { prs[d.id] = nil; gonePRs.insert(d.id); return }
                guard let body = d.body else { return }
                prs[d.id] = try MirrorCodec.value(MirrorPRs.self, from: body).prs
                gonePRs.remove(d.id)
            case .activity:
                guard !gone, let body = d.body else { return }
                activity[d.id] = try MirrorCodec.value(ActivityEntry.self, from: body)
            case .catalog:
                guard !gone, let body = d.body else { return }
                catalog = try MirrorCodec.value(ClientCatalog.self, from: body)
            case .settings:
                guard !gone, let body = d.body else { return }
                settings = body
            }
        }
    }

    private struct Staging {
        var epoch: String
        var cursor: Int64
        var batch: Batch
    }

    private let fetch: MirrorFetch
    private let cache: MirrorCache
    private let clock: @Sendable () -> Date
    private var epoch: String?
    private var cursor: Int64 = 0
    private var staging: Staging?
    private var runs: [String: [Run]]
    private var prs: [String: [ChangeRequest]]
    private var catalog: ClientCatalog?
    private var settings: JSONValue?
    private var skipped: Set<String>
    private var needs: String?
    private var lastPull: Date?
    private(set) public var head: MirrorHead?

    public init(fetch: MirrorFetch, cache: MirrorCache, clock: @escaping @Sendable () -> Date = Date.init) {
        self.fetch = fetch
        self.cache = cache
        self.clock = clock
        let saved = cache.head()
        epoch = saved?.epoch
        cursor = saved?.cursor ?? 0
        lastPull = saved?.updatedAt
        needs = saved?.needsUpdate
        skipped = Set(saved?.skipped ?? [])
        let ci = cache.ci()
        runs = ci.runs
        prs = ci.prs
        catalog = cache.catalog()
        settings = cache.settings()
    }

    /// True when the reader read a whole feed: the cache or a pull has data.
    public var hasData: Bool { epoch != nil }

    /// The time of the last good pull, also from before a restart.
    public var updatedAt: Date? { lastPull }

    /// The cursor of the data. Tests read it.
    public var position: (epoch: String?, cursor: Int64) { (epoch, cursor) }

    /// The data of the cache: the CI data, the catalog and the settings. Projects come from ProjectStore.
    public func cached() -> MirrorDelta {
        var d = MirrorDelta()
        guard epoch != nil else { return d }
        if !runs.isEmpty { d.runs = runs }
        if !prs.isEmpty { d.prs = prs }
        d.catalog = catalog
        d.settings = settings
        d.needsUpdate = needs
        return d
    }

    /// Reads the docs after the cursor until there are no more. A new epoch keeps the old data until it is ready.
    /// Throws StoreNotHome and the errors of the network.
    public func pull() async throws -> MirrorDelta {
        let h = try await fetch.head()
        head = h
        if staging == nil, epoch == h.epoch, cursor == h.head {
            lastPull = clock()
            save()
            return MirrorDelta().with(needsUpdate: needs)
        }
        var batch = staging?.batch ?? Batch(reset: false)
        var after = staging?.cursor ?? cursor
        var sent = staging?.epoch ?? epoch
        var resets = 0
        var next = after
        while true {
            let p = try await fetch.page(after: after, limit: Self.pageLimit, epoch: sent)
            if p.reset {
                resets += 1
                if resets > 3 { throw ProviderError.vendor(code: "mirror", message: "The mirror feed keeps changing.") }
                batch = Batch(reset: true)
                after = 0
                sent = p.epoch
                staging = Staging(epoch: p.epoch, cursor: 0, batch: batch)
                continue
            }
            // The first read of a feed is a reset too: nothing of the cache stands for it.
            if staging == nil, epoch == nil {
                batch = Batch(reset: true)
                staging = Staging(epoch: p.epoch, cursor: 0, batch: batch)
            }
            for d in p.docs { batch.add(d) }
            after = p.next
            next = p.next
            if staging != nil { staging?.batch = batch; staging?.cursor = after }
            if !p.more { break }
        }
        guard let s = staging else { return commit(batch, epoch: sent ?? h.epoch, cursor: next, head: h) }
        // The new feed is not complete until its source sends `ready`.
        let ready = h.ready ? true : try await fetch.head().ready
        guard ready else { return MirrorDelta().with(needsUpdate: needs) }
        return commit(s.batch, epoch: s.epoch, cursor: s.cursor, head: h)
    }

    private func commit(_ b: Batch, epoch newEpoch: String, cursor newCursor: Int64, head h: MirrorHead) -> MirrorDelta {
        staging = nil
        epoch = newEpoch
        cursor = newCursor
        lastPull = clock()
        var d = MirrorDelta()
        d.reset = b.reset
        d.projects = b.projects
        d.removedProjects = Array(b.removedProjects).sorted()
        d.items = b.items.mapValues { $0.values.sorted { $0.n < $1.n }.map(\.item) }
        d.removedItems = b.removedItems.mapValues { Array($0).sorted() }.filter { !$0.value.isEmpty }
        d.activity = b.activity.values.sorted { $0.at > $1.at }
        if b.reset {
            runs = [:]; prs = [:]; skipped = []
            catalog = nil; settings = nil
        }
        var touchedCI = b.reset
        if !b.runs.isEmpty || !b.goneRuns.isEmpty || b.reset {
            for r in b.goneRuns { runs[r] = nil }
            runs.merge(b.runs) { _, new in new }
            d.runs = runs
            touchedCI = true
        }
        if !b.prs.isEmpty || !b.gonePRs.isEmpty || b.reset {
            for r in b.gonePRs { prs[r] = nil }
            prs.merge(b.prs) { _, new in new }
            d.prs = prs
            touchedCI = true
        }
        if let c = b.catalog { catalog = c; d.catalog = c }
        if let s = b.settings { settings = s; d.settings = s }
        skipped.subtract(b.unskipped)
        skipped.formUnion(b.skipped)
        needs = skipped.isEmpty ? nil : (h.appVersion ?? "")
        d.needsUpdate = needs
        if touchedCI { cache.save(ci: .init(runs: runs, prs: prs)) }
        if let c = catalog, b.catalog != nil { cache.save(catalog: c) }
        if let s = settings, b.settings != nil { cache.save(settings: s) }
        save()
        return d
    }

    private func save() {
        cache.save(head: .init(epoch: epoch, cursor: cursor, head: head?.head ?? cursor, updatedAt: lastPull, needsUpdate: needs,
                               skipped: skipped.isEmpty ? nil : skipped.sorted()))
    }
}

private extension MirrorDelta {
    func with(needsUpdate v: String?) -> MirrorDelta {
        var d = self
        d.needsUpdate = v
        return d
    }
}
