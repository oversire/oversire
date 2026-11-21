import Foundation
import OverSireCore

/// The Big Timer adapter. One instance for each server and token.
public final class BigTimerTracker: Tracker, ItemSearching, LiveFeeding, EpicUpdating, TimelineReading, @unchecked Sendable {
    public let id: ProviderID = .bigtimer
    public let account: AccountID
    public let capabilities: Set<Capability> = [.itemSearch, .subItems, .liveFeed, .epics, .epicHealth, .timeline, .dates, .estimate]
    // The server has no general rate limit. The real load is the ProjectStore refresh.
    public let pollPolicy = PollPolicy(minInterval: .seconds(60), requestsPerHour: 600)
    public let keyFormat = KeyFormat.projectDash

    let api: BigTimerAPI
    private let lock = NSLock()
    private var meCache: (me: BTMe, at: Duration)?
    private var memberCache: (members: [BTMember], at: Duration)?
    private var prefixes: [String: String] = [:]                    // project uuid → prefix
    private var issueKeys: [String: (key: String, project: String)] = [:]   // issue uuid → key, project uuid
    private var commentIssues: [String: String] = [:]               // comment uuid → issue uuid
    private var epicKeys: [String: String] = [:]                    // epic key → epic uuid
    private var epicIds: Set<String> = []                           // uuids of the known epics
    let indexCache = BigTimerIndexCache()
    static let cacheAge: Duration = .seconds(3600)
    static let pageMax = 500

    public init(server: URL, account: AccountID, token: String, http: any HTTPTransport,
                streaming: (any HTTPStreaming)? = nil, clock: any Clock<Duration> = ContinuousClock()) {
        api = BigTimerAPI(base: server, token: token, http: http, streaming: streaming ?? (http as? any HTTPStreaming), clock: clock)
        self.account = account
        api.onWrite = { [indexCache] in indexCache.drop() }
    }

    // MARK: Provider

    public func probe() async throws -> Identity {
        let me = try await me()
        guard me.token.scopes.contains(where: { $0 == "write" || $0 == "admin" }) else { throw ProviderError.forbidden }
        return Identity(person: PersonRef(id: me.member.uuid, name: me.member.name), scopes: me.token.scopes)
    }

    private func me() async throws -> BTMe {
        if let c = lock.withLock({ meCache }), api.now - c.at < Self.cacheAge { return c.me }
        let me: BTMe = try await api.get("/v1/me")
        lock.withLock { meCache = (me, api.now) }
        return me
    }

    // MARK: Members

    private func members() async -> [BTMember] {
        if let c = lock.withLock({ memberCache }), api.now - c.at < Self.cacheAge { return c.members }
        guard let list: BTMemberList = try? await api.get("/v1/members") else { return lock.withLock { memberCache?.members ?? [] } }
        lock.withLock { memberCache = (list.items, api.now) }
        return list.items
    }

    /// Member id → name, for the active members. Kept for one hour.
    public func memberNames() async -> [String: String] {
        Dictionary(await members().filter { $0.status == "active" }.map { ($0.uuid, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// The names of all members that joined, also the deactivated ones, for authors and assignees.
    private func names() async -> [String: String] {
        Dictionary(await members().filter { $0.status != "invited" }.map { ($0.uuid, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    public func ownerEmail() async -> String? { try? await me().member.email }

    // MARK: Projects and items

    public func projects() async throws -> [ProjectSummary] {
        let rows = try await pages(BTProjectPage.self, "/v1/projects")
        lock.withLock { for r in rows { prefixes[r.uuid] = r.issue_prefix } }
        return rows.map {
            ProjectSummary(ref: ProjectRef(account: account, id: $0.uuid, key: $0.issue_prefix), identifier: $0.issue_prefix, title: $0.name,
                           url: "bigtimer://issues?project=\($0.issue_prefix)", closed: false, logo: nil)
        }
    }

    public func statuses(_ p: ProjectRef) async throws -> [StatusOption] { BigTimerStatus.options }

    /// Each open item, then the newest `limit` items of any status. Newest activity first.
    public func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item] {
        var base = [URLQueryItem(name: "project", value: p.id), URLQueryItem(name: "kind", value: "issue"), URLQueryItem(name: "order", value: "activity")]
        if let since { base.append(URLQueryItem(name: "updated_since", value: Self.time(since))) }
        let open = try await pages(BTIssuePage.self, "/v1/issues", query: base + [
            URLQueryItem(name: "status", value: BigTimerStatus.options.map(\.id).filter(BigTimerStatus.openIDs.contains).joined(separator: ",")),
            URLQueryItem(name: "limit", value: String(Self.pageMax)),
        ])
        let latest: BTIssuePage = try await api.get("/v1/issues", query: base + [
            URLQueryItem(name: "limit", value: String(min(max(limit, 1), Self.pageMax))),
        ])
        var seen = Set<String>()
        let rows = (open + latest.items).filter { seen.insert($0.uuid).inserted }
        let names = await names()
        return rows.map { item(from: $0, names: names) }.sorted { $0.activityAt > $1.activityAt }
    }

    /// One item with no comments.
    public func item(_ i: ItemRef) async throws -> Item {
        let row: BTIssue = try await api.get("/v1/issues/\(i.id)")
        return item(from: row, names: await names())
    }

    public func detail(_ i: ItemRef) async throws -> ItemDetail {
        async let item = item(i)
        async let comments = comments(i)
        return ItemDetail(item: try await item, comments: try await comments, links: [])
    }

    /// Oldest first.
    public func comments(_ i: ItemRef) async throws -> [Comment] {
        let list: BTCommentList = try await api.get("/v1/issues/\(i.id)/comments")
        let names = await names()
        lock.withLock { for c in list.items { commentIssues[c.uuid] = c.issue_uuid } }
        return list.items.map {
            Comment(id: $0.uuid, author: $0.author_uuid.flatMap { names[$0] } ?? "Unknown", createdAt: $0.created_at,
                    url: i.url.absoluteString, body: $0.body)
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef {
        if d.priority != nil { throw ProviderError.unsupported(.priority) }
        if !d.labels.isEmpty { throw ProviderError.unsupported(.labels) }
        var body = BTIssueCreate(project_uuid: p.id, title: d.title, details: d.bodyMarkdown, status: d.status, parent_uuid: d.parent)
        body.start_date = d.startDate.flatMap { $0.isEmpty ? nil : $0 }
        body.due_date = d.dueDate.flatMap { $0.isEmpty ? nil : $0 }
        body.size = try d.estimate.flatMap { $0.isEmpty ? nil : try Self.size($0) }
        let data = try await api.send("POST", "/v1/issues", json: body)
        let row = try BigTimerAPI.decode(BTIssue.self, from: data)
        remember(row)
        return ref(of: row, project: p)
    }

    /// The PATCH goes first, then the assignee. The two writes are not atomic.
    public func update(_ i: ItemRef, _ patch: ItemPatch) async throws {
        if patch.priority != nil { throw ProviderError.unsupported(.priority) }
        if patch.labels != nil { throw ProviderError.unsupported(.labels) }
        var body = BTIssuePatch(title: patch.title, details: patch.bodyMarkdown, status: patch.status, parent_uuid: patch.parent)
        if let v = patch.startDate { if v.isEmpty { body.clear.insert("start_date") } else { body.start_date = v } }
        if let v = patch.dueDate { if v.isEmpty { body.clear.insert("due_date") } else { body.due_date = v } }
        if let e = patch.estimate {
            if e.isEmpty { body.clear.insert("size") } else { body.size = try Self.size(e) }
        }
        if !body.isEmpty { _ = try await api.send("PATCH", "/v1/issues/\(i.id)", json: body) }
        if let who = patch.assignees { _ = try await api.send("POST", "/v1/issues/\(i.id)/assign", json: BTAssign(member: who.first)) }
    }

    public func comment(_ i: ItemRef, markdown: String) async throws {
        _ = try await api.send("POST", "/v1/issues/\(i.id)/comments", json: BTCommentCreate(body: markdown))
    }

    /// The server takes "me" as a member.
    public func assignMe(_ i: ItemRef) async throws {
        _ = try await api.send("POST", "/v1/issues/\(i.id)/assign", json: BTAssign(member: "me"))
    }

    // MARK: Timeline

    static let sizes = ["S", "M", "L", "XL"]

    /// The size code of an estimate label.
    static func size(_ estimate: String) throws -> String {
        let s = estimate.trimmingCharacters(in: .whitespaces).uppercased()
        guard sizes.contains(s) else { throw ProviderError.vendor(code: "validation", message: "Big Timer sizes: S, M, L, XL.") }
        return s
    }

    /// The status changes, the field changes and the comments of one item, oldest first. Version 1 is the creation: it gives no field row.
    public func timeline(_ i: ItemRef) async throws -> [ActivityEntry] {
        let history: BTIssueHistory = try await api.get("/v1/issues/\(i.id)/history")
        let names = await names()
        let url = i.url.absoluteString
        func entry(_ change: ItemChange, _ actor: String?, _ at: Date) -> ActivityEntry {
            ActivityEntry.make(projectKey: "", itemId: i.id, change: change, actor: actor, url: url, at: at)
        }
        func status(_ id: String?) -> String? { id.map { id in BigTimerStatus.options.first { $0.id == id }?.name ?? id } }
        var out = history.transitions.map {
            entry(.status(from: status($0.from_status), to: status($0.to_status)), $0.created_by.flatMap { names[$0] }, $0.transitioned_at)
        }
        for r in history.changes where r.version > 1 {
            let actor = r.actor_uuid.flatMap { names[$0] } ?? r.channel
            let (old, new) = (Self.jsonText(r.old), Self.jsonText(r.new))
            let change: ItemChange
            switch r.field {
            case "status": continue
            case "assignee_uuid":
                if let new { change = .assigned(names[new] ?? new) }
                else if let old { change = .unassigned(names[old] ?? old) }
                else { continue }
            case "parent_uuid", "epic_uuid":
                let name = r.field == "parent_uuid" ? "Parent" : "Epic"
                change = .field(name: name, from: old.map(key(ofIssue:)), to: new.map(key(ofIssue:)))
            default:
                let name = ["title": "Title", "due_date": "Due", "start_date": "Start", "size": "Estimate"][r.field] ?? r.field
                change = .field(name: name, from: old, to: new)
            }
            out.append(entry(change, actor, r.at))
        }
        if let list = try? await comments(i) {
            out += list.map { entry(.comments(new: 1, last: $0), $0.author, $0.createdAt) }
        }
        return out.sorted { $0.at < $1.at }
    }

    /// An audit value is JSON text. A string loses its quotes, and null gives nil.
    static func jsonText(_ raw: String?) -> String? {
        guard let raw, let data = raw.data(using: .utf8),
              let v = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) else { return raw }
        switch v {
        case is NSNull: return nil
        case let s as String: return s
        default: return raw
        }
    }

    private func key(ofIssue uuid: String) -> String {
        lock.withLock { issueKeys[uuid]?.key ?? epicKeys.first { $0.value == uuid }?.key } ?? uuid
    }

    // MARK: Epics

    public func epics(in p: ProjectRef) async throws -> [Epic] {
        let rows = try await pages(BTIssuePage.self, "/v1/issues", query: [
            URLQueryItem(name: "project", value: p.id), URLQueryItem(name: "kind", value: "epic"),
            URLQueryItem(name: "limit", value: String(Self.pageMax)),
        ])
        return rows.map { epic(from: $0, project: p) }
    }

    public func createEpic(_ d: EpicDraft, in p: ProjectRef) async throws -> Epic {
        var body = BTIssueCreate(project_uuid: p.id, title: d.title, details: d.goal, status: Self.status(d.state), parent_uuid: nil)
        body.kind = "epic"
        body.start_date = d.startDate.map(Self.day)
        body.due_date = d.targetDate.map(Self.day)
        var data = try await api.send("POST", "/v1/issues", json: body)
        var row = try BigTimerAPI.decode(BTIssue.self, from: data)
        if let lead = d.lead {
            data = try await api.send("POST", "/v1/issues/\(row.uuid)/assign", json: BTAssign(member: lead))
            row = try BigTimerAPI.decode(BTIssue.self, from: data)
        }
        return epic(from: row, project: p)
    }

    /// The PATCH goes first, then the lead. The two writes are not atomic.
    public func updateEpic(_ e: Epic, _ patch: EpicPatch) async throws -> Epic {
        var body = BTIssuePatch(title: patch.title, details: patch.goal, status: patch.state.map { Self.status($0) }, parent_uuid: nil,
                                start_date: patch.startDate.map(Self.day), due_date: patch.targetDate.map(Self.day))
        for f in patch.clear {
            switch f {
            case .goal: body.clear.insert("details")
            case .startDate: body.clear.insert("start_date")
            case .targetDate: body.clear.insert("due_date")
            default: break
            }
        }
        if !body.isEmpty { _ = try await api.send("PATCH", "/v1/issues/\(e.id.rawValue)", json: body) }
        if patch.lead != nil || patch.clear.contains(.lead) {
            _ = try await api.send("POST", "/v1/issues/\(e.id.rawValue)/assign", json: BTAssign(member: patch.clear.contains(.lead) ? nil : patch.lead))
        }
        let row: BTIssue = try await api.get("/v1/issues/\(e.id.rawValue)")
        return epic(from: row, project: e.project)
    }

    /// A sub-item has the epic of its parent, so the server refuses it with a message.
    public func setEpic(_ epic: EpicID?, for item: ItemRef) async throws {
        var body = BTIssuePatch(title: nil, details: nil, status: nil, parent_uuid: nil, epic_uuid: epic?.rawValue)
        if epic == nil { body.clear = ["epic_uuid"] }
        _ = try await api.send("PATCH", "/v1/issues/\(item.id)", json: body)
    }

    public func postUpdate(_ e: Epic, health: EpicHealth?, markdown: String) async throws {
        _ = try await api.send("POST", "/v1/issues/\(e.id.rawValue)/comments", json: BTCommentCreate(body: markdown, health: health?.rawValue))
    }

    func epic(from row: BTIssue, project: ProjectRef) -> Epic {
        lock.withLock {
            epicIds.insert(row.uuid)
            epicKeys[row.key] = row.uuid
        }
        return Epic(id: EpicID(rawValue: row.uuid), key: row.key, title: row.title, goal: row.details, state: Self.epicState(row.status),
                    nativeState: row.status, lead: row.assignee_uuid, startDate: row.start_date.flatMap(Self.date),
                    targetDate: row.due_date.flatMap(Self.date), url: Self.url(row.key).absoluteString, project: project,
                    createdAt: row.created_at, updatedAt: row.updated_at, health: row.health.flatMap(EpicHealth.init(rawValue:)),
                    counts: EpicCounts(total: row.item_count ?? 0, done: row.items_done ?? 0, inProgress: row.items_in_progress ?? 0,
                                       blocked: row.items_blocked ?? 0, estimateMinutes: row.estimate_minutes))
    }

    static func epicState(_ status: String) -> EpicState {
        switch status {
        case "in_progress", "client_reviewing": return .active
        case "blocked": return .paused
        case "done": return .done
        case "cancelled": return .canceled
        default: return .planned
        }
    }

    static func status(_ s: EpicState) -> String {
        switch s {
        case .planned: return "open"
        case .active: return "in_progress"
        case .paused: return "blocked"
        case .done: return "done"
        case .canceled: return "cancelled"
        }
    }

    /// A date with no time ("2026-11-30"), in the time zone of the user.
    static func date(_ s: String) -> Date? {
        let n = s.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard n.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: n[0], month: n[1], day: n[2]))
    }

    static func day(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: d)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    // MARK: Search

    public func search(_ query: String, in projects: [ProjectRef]?, limit: Int) async throws -> [Item] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, limit > 0, projects?.isEmpty != true else { return [] }
        let wanted = projects.map { Set($0.map(\.id)) }
        var rows: [BTIssue] = []
        if keyFormat.keys(in: q) == [q.uppercased()] {
            do {
                let row: BTIssue = try await api.get("/v1/issues/\(q.uppercased())")
                if row.kind != "epic" { rows.append(row) }
            } catch ProviderError.notFound {}
        }
        var query = [URLQueryItem(name: "q", value: q), URLQueryItem(name: "kind", value: "issue"), URLQueryItem(name: "order", value: "activity"),
                     URLQueryItem(name: "limit", value: String(min(limit, Self.pageMax)))]
        if let only = wanted, only.count == 1, let id = only.first { query.append(URLQueryItem(name: "project", value: id)) }
        let found: BTIssuePage = try await api.get("/v1/issues", query: query)
        var seen = Set<String>()
        rows = (rows + found.items).filter { seen.insert($0.uuid).inserted && (wanted?.contains($0.project_uuid) ?? true) }
        let names = await names()
        return rows.prefix(limit).map { item(from: $0, names: names) }
    }

    // MARK: Poll

    /// The cursor is the seq of the change feed. A new or expired cursor sets a baseline and gives no events.
    public func poll(since: Cursor?) async throws -> EventPage {
        guard let seq = since.flatMap({ Int($0.rawValue) }) else { return try await baseline() }
        let page: BTChangesPage
        do { page = try await api.get("/v1/changes", query: Self.feed(since: seq, limit: Self.pageMax)) }
        catch ProviderError.vendor(let code, _) where code == "cursor_expired" { return try await baseline() }
        indexCache.drop(for: page.changes)
        var refreshed = false
        var events: [ProviderEvent] = []
        for c in page.changes {
            if let e = try await event(for: c, at: page.server_time, refreshed: &refreshed) { events.append(e) }
        }
        return EventPage(events: events, cursor: Cursor(rawValue: String(page.next)))
    }

    private func baseline() async throws -> EventPage {
        let page: BTChangesPage = try await api.get("/v1/changes", query: Self.feed(since: 0, limit: 1))
        return EventPage(events: [], cursor: Cursor(rawValue: String(page.head)), baseline: true)
    }

    private static func feed(since: Int, limit: Int) -> [URLQueryItem] {
        [URLQueryItem(name: "since", value: String(since)), URLQueryItem(name: "limit", value: String(limit)),
         URLQueryItem(name: "entity", value: "issue,issue_comment")]
    }

    /// The ids are the same on a repeated page. `refreshed` allows one read of the projects for each poll.
    private func event(for change: BTChange, at serverTime: Date?, refreshed: inout Bool) async throws -> ProviderEvent? {
        guard let version = change.version, let uuid = change.uuid else { return nil }
        let action = change.op == "delete" ? "deleted" : version == 1 ? "created" : "updated"
        let eid = "bigtimer-\(change.entity)-\(uuid)-v\(version)"
        switch change.record {
        case .issue(let r):
            if r.kind == "epic" {
                lock.withLock { epicIds.insert(r.uuid) }
                return nil
            }
            guard let prefix = try await prefix(of: r.project_uuid, refreshed: &refreshed) else { return nil }
            let key = "\(prefix)-\(r.number)"
            lock.withLock { issueKeys[r.uuid] = (key, r.project_uuid); prefixes[r.project_uuid] = prefix }
            return ProviderEvent(id: eid, provider: .bigtimer, account: account, kind: .item, action: action,
                                 subject: .item(ref(project: r.project_uuid, prefix: prefix, issue: r.uuid, key: key)), at: r.updated_at,
                                 summary: EventSummary(title: r.title))
        case .comment(let r):
            lock.withLock { commentIssues[r.uuid] = r.issue_uuid }
            // An update on an epic from OverSire writes epic.updated. An outside update is not tracked yet.
            if lock.withLock({ epicIds.contains(r.issue_uuid) }) { return nil }
            guard let (key, project) = try await issueKey(r.issue_uuid), !lock.withLock({ epicIds.contains(r.issue_uuid) }) else { return nil }
            return ProviderEvent(id: eid, provider: .bigtimer, account: account, kind: .comment, action: action,
                                 subject: .item(ref(project: project, prefix: lock.withLock { prefixes[project] }, issue: r.issue_uuid, key: key)),
                                 at: r.updated_at)
        case nil:
            // A delete has only a uuid and a version. The caches name the issue.
            let issue: String? = change.entity == "issue_comment" ? lock.withLock({ commentIssues[uuid] }) : uuid
            guard let issue, !lock.withLock({ epicIds.contains(issue) }),
                  let (key, project) = lock.withLock({ issueKeys[issue] }) else { return nil }
            return ProviderEvent(id: eid, provider: .bigtimer, account: account,
                                 kind: change.entity == "issue" ? .item : .comment, action: action,
                                 subject: .item(ref(project: project, prefix: lock.withLock { prefixes[project] }, issue: issue, key: key)),
                                 at: serverTime ?? Date())
        }
    }

    // MARK: Helpers

    private func pages<P: BTPage>(_ type: P.Type, _ path: String, query: [URLQueryItem] = []) async throws -> [P.Row] {
        var out: [P.Row] = []
        var cursor: String?
        for _ in 0..<20 {
            let page: P = try await api.get(path, query: query + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? []))
            out += page.items
            guard let next = page.next_cursor, !next.isEmpty else { break }
            cursor = next
        }
        return out
    }

    /// The prefix of a project. A miss reads the projects once for each poll.
    private func prefix(of project: String, refreshed: inout Bool) async throws -> String? {
        if let p = lock.withLock({ prefixes[project] }) { return p }
        guard !refreshed else { return nil }
        refreshed = true
        _ = try await projects()
        return lock.withLock { prefixes[project] }
    }

    /// The key and project of an issue. A miss reads the issue. A 404 gives nil.
    private func issueKey(_ issue: String) async throws -> (String, String)? {
        if let k = lock.withLock({ issueKeys[issue] }) { return k }
        do {
            let row: BTIssue = try await api.get("/v1/issues/\(issue)")
            remember(row)
            return (row.key, row.project_uuid)
        } catch ProviderError.notFound { return nil }
    }

    private func remember(_ row: BTIssue) {
        lock.withLock {
            issueKeys[row.uuid] = (row.key, row.project_uuid)
            if row.kind == "epic" { epicIds.insert(row.uuid) }
            if prefixes[row.project_uuid] == nil { prefixes[row.project_uuid] = String(row.key.dropLast("-\(row.number)".count)) }
        }
    }

    private static func url(_ key: String) -> URL { URL(string: "bigtimer://issue/\(key)")! }

    private func ref(project: String, prefix: String?, issue: String, key: String) -> ItemRef {
        ItemRef(project: ProjectRef(account: account, id: project, key: prefix), id: issue, key: key, url: Self.url(key))
    }

    private func ref(of row: BTIssue, project p: ProjectRef) -> ItemRef { ItemRef(project: p, id: row.uuid, key: row.key, url: Self.url(row.key)) }

    private static func time(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// A sub-item has no epic_uuid. It uses the epic of its parent, named by key.
    private func epicId(of row: BTIssue) -> EpicID? {
        if let id = row.epic_uuid { return EpicID(rawValue: id) }
        return row.epic_key.flatMap { key in lock.withLock { epicKeys[key] } }.map { EpicID(rawValue: $0) }
    }

    private func item(from row: BTIssue, names: [String: String]) -> Item {
        remember(row)
        var fields: [String: String] = [:]
        if let size = row.size { fields[Item.estimateField] = size }
        if let start = row.start_date { fields[Item.startField] = start }
        if let due = row.due_date { fields[Item.dueField] = due }
        return Item(id: row.uuid, key: row.key, title: row.title, url: Self.url(row.key).absoluteString, statusOptionId: row.status,
                    fields: fields, assignees: row.assignee_uuid.map { [names[$0] ?? "Unknown"] } ?? [], labels: [],
                    author: row.created_by.flatMap { names[$0] }, updatedBy: row.updated_by.flatMap { names[$0] },
                    updatedAt: row.updated_at, activityAt: row.activity_at ?? row.updated_at, commentCount: row.comment_count ?? 0,
                    lastComment: nil, mentionsMe: false, body: row.details, parentId: row.parent_uuid, epicId: epicId(of: row),
                    createdAt: row.created_at)
    }
}
