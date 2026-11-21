import Foundation
import OverSireCore

/// The kept index of each project. A write or a feed change drops it.
final class BigTimerIndexCache: @unchecked Sendable {
    struct Entry {
        var stubs: [ItemStub]
        var truncated: Bool
        var at: Duration
    }

    /// The most issues that the index reads for a project.
    var limit = 5000
    var maxAge: Duration = .seconds(300)

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var drops = 0
    private var warned: Set<String> = []

    func entry(_ project: String, now: Duration) -> Entry? {
        lock.withLock { entries[project].flatMap { now - $0.at < maxAge ? $0 : nil } }
    }

    /// The number of drops so far. A read that began before a drop does not store its rows.
    var epoch: Int { lock.withLock { drops } }

    func store(_ entry: Entry, project: String, epoch: Int) {
        lock.withLock { if drops == epoch { entries[project] = entry } }
    }

    /// Nil drops all projects.
    func drop(_ project: String? = nil) {
        lock.withLock {
            drops += 1
            if let project { entries[project] = nil } else { entries = [:] }
        }
    }

    /// An issue change drops its project. A delete or a comment change names no project, so it drops all.
    func drop(for changes: [BTChange]) {
        for c in changes {
            if case .issue(let r)? = c.record { drop(r.project_uuid) } else { drop() }
        }
    }

    /// True once for each project.
    func firstWarning(_ project: String) -> Bool { lock.withLock { warned.insert(project).inserted } }
}

extension BigTimerTracker: ItemIndexing {
    /// All issues of the project, with no epics. The list route has no field filter, so each row is a full issue.
    public func index(_ p: ProjectRef) async throws -> [ItemStub] {
        if let e = indexCache.entry(p.id, now: api.now) { return try Self.stubs(of: e, p) }
        let epoch = indexCache.epoch
        var rows: [BTIssue] = []
        var cursor: String?
        var truncated = false
        while true {
            let page: BTIssuePage = try await api.get("/v1/issues", query: [
                URLQueryItem(name: "project", value: p.id), URLQueryItem(name: "kind", value: "issue"),
                URLQueryItem(name: "limit", value: String(Self.pageMax)),
            ] + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []))
            rows += page.items
            guard let next = page.next_cursor, !next.isEmpty else { break }
            if rows.count >= indexCache.limit { truncated = true; break }
            cursor = next
        }
        if truncated && indexCache.firstWarning(p.id) {
            FileHandle.standardError.write(Data("bigtimer: project \(p.key ?? p.id) has more than \(indexCache.limit) issues; the index stops there\n".utf8))
        }
        let e = BigTimerIndexCache.Entry(stubs: Self.stubs(rows), truncated: truncated, at: api.now)
        indexCache.store(e, project: p.id, epoch: epoch)
        return try Self.stubs(of: e, p)
    }

    /// An index with a cut would show the issues past the cut as removed. Thus the caller gets an error.
    private static func stubs(of e: BigTimerIndexCache.Entry, _ p: ProjectRef) throws -> [ItemStub] {
        if e.truncated { throw ProviderError.vendor(code: "index_truncated", message: "The project has more issues than the index holds.") }
        return e.stubs
    }

    /// A sub-item has no epic_uuid. It uses the epic of its parent row.
    private static func stubs(_ rows: [BTIssue]) -> [ItemStub] {
        let epics = Dictionary(rows.compactMap { r in r.epic_uuid.map { (r.uuid, $0) } }, uniquingKeysWith: { a, _ in a })
        return rows.map {
            ItemStub(id: $0.uuid, parentId: $0.parent_uuid, stateId: $0.status, activityAt: $0.activity_at ?? $0.updated_at,
                     epicId: ($0.epic_uuid ?? $0.parent_uuid.flatMap { epics[$0] }).map { EpicID(rawValue: $0) }, key: $0.key)
        }
    }
}
