import Foundation
import OverSireCore

/// An in-memory Big Timer server. It routes the calls of the adapter, keeps the activity and the change feed,
/// refuses a bad token with a 401 Problem and refuses unknown body keys, as the real server does.
final class BigTimerFakeServer: HTTPTransport, @unchecked Sendable {
    struct Issue {
        var uuid: String
        var project: String
        var number: Int
        var title: String
        var details: String?
        var status: String
        var size: String?
        var due: String?
        var assignee: String?
        var parent: String?
        var kind = "issue"
        var epic: String?
        var start: String?
        var createdBy: String
        var createdAt: Date
        var updatedAt: Date
        var version = 1
    }

    struct Comment {
        var uuid: String
        var issue: String
        var author: String
        var body: String
        var health: String?
        var createdAt: Date
        var updatedAt: Date
        var version = 1
        var deleted = false
    }

    private struct Change {
        var seq: Int
        var entity: String
        var op: String
        var record: [String: Any]?
        var uuid: String
        var version: Int
    }

    struct Audit {
        var issue: String
        var version: Int
        var field: String
        var old: String?
        var new: String?
        var actor: String?
        var channel: String
        var at: Date
    }

    private let lock = NSLock()
    private var audit: [Audit] = []
    private var transitions: [(issue: String, from: String?, to: String, by: String, at: Date)] = []
    private var sent: [URLRequest] = []
    private var memberRows: [(uuid: String, name: String, email: String, status: String)] = []
    private var projectRows: [(uuid: String, name: String, prefix: String)] = []
    private var issues: [Issue] = []
    private var comments: [Comment] = []
    private var changes: [Change] = []
    private var counter = 0
    private var streams: [UUID: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var ended = 0
    private var ids = 0

    let token: String
    var scopes = ["read", "write"]
    var pageSize = 100
    /// Answers a request with a fixed reply before the routes run. Return nil to route it.
    var override: (@Sendable (URLRequest) -> (Int, [String: String], String)?)?

    init(token: String = "good") {
        self.token = token
        _ = addMember(name: "Ada Lovelace", email: "ada@example.com")
    }

    var requests: [URLRequest] { lock.withLock { sent } }
    var head: Int { lock.withLock { changes.last?.seq ?? 0 } }

    func paths(_ method: String? = nil) -> [String] {
        requests.filter { method == nil || $0.httpMethod == method }.map { $0.url!.path }
    }

    func body(_ r: URLRequest) -> [String: Any] {
        r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    // MARK: Seeds

    func addMember(name: String, email: String? = nil, status: String = "active") -> String {
        lock.withLock {
            let id = nextID()
            memberRows.append((id, name, email ?? "\(name.lowercased().replacingOccurrences(of: " ", with: "."))@example.com", status))
            return id
        }
    }

    var meUUID: String { lock.withLock { memberRows[0].uuid } }

    func addProject(prefix: String, name: String? = nil) -> String {
        lock.withLock {
            let id = nextID()
            projectRows.append((id, name ?? prefix.capitalized, prefix))
            return id
        }
    }

    @discardableResult
    func addIssue(project: String, title: String, status: String = "open", assignee: String? = nil, size: String? = nil, due: String? = nil, parent: String? = nil,
                  kind: String = "issue", epic: String? = nil, start: String? = nil) -> String {
        lock.withLock {
            let id = nextID()
            let n = (issues.filter { $0.project == project }.map(\.number).max() ?? 0) + 1
            let t = tick()
            let i = Issue(uuid: id, project: project, number: n, title: title, details: nil, status: status, size: size, due: due,
                          assignee: assignee, parent: parent, kind: kind, epic: epic, start: start, createdBy: memberRows[0].uuid, createdAt: t, updatedAt: t)
            issues.append(i)
            log(issue: i, op: "upsert")
            recordCreation(i)
            return id
        }
    }

    @discardableResult
    func addEpic(project: String, title: String, status: String = "open", due: String? = nil, start: String? = nil) -> String {
        addIssue(project: project, title: title, status: status, due: due, kind: "epic", start: start)
    }

    @discardableResult
    func addComment(issue: String, body: String, health: String? = nil) -> String {
        lock.withLock { insertComment(issue: issue, body: body, health: health) }
    }

    func deleteIssue(_ uuid: String) {
        lock.withLock {
            guard let n = issues.firstIndex(where: { $0.uuid == uuid }) else { return }
            for k in issues.indices where issues[k].epic == uuid { issues[k].epic = nil; touch(k) }
            let gone = issues.remove(at: n)
            changes.append(Change(seq: changes.count + 1, entity: "issue", op: "delete", record: nil, uuid: gone.uuid, version: gone.version + 1))
        }
    }

    func deleteComment(_ uuid: String) {
        lock.withLock {
            guard let n = comments.firstIndex(where: { $0.uuid == uuid }) else { return }
            comments[n].deleted = true
            comments[n].version += 1
            comments[n].updatedAt = tick()
            changes.append(Change(seq: changes.count + 1, entity: "issue_comment", op: "delete", record: nil, uuid: uuid, version: comments[n].version))
        }
    }

    func issue(_ uuid: String) -> Issue? { lock.withLock { issues.first { $0.uuid == uuid } } }

    // MARK: Transport

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { sent.append(request) }
        let (status, headers, text) = lock.withLock { route(request) }
        let url = request.url!
        return (Data(text.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    /// The streams that the client closed or cancelled.
    var closedStreams: Int { lock.withLock { ended } }
    var openStreams: Int { lock.withLock { streams.count } }

    /// Writes raw text to all open streams.
    func push(_ raw: String) {
        let open = lock.withLock { Array(streams.values) }
        open.forEach { $0.yield(Data(raw.utf8)) }
    }

    func endStreams() {
        let open = lock.withLock { () -> [AsyncThrowingStream<Data, Error>.Continuation] in
            defer { streams = [:] }
            return Array(streams.values)
        }
        open.forEach { $0.finish() }
    }

    // MARK: Routes (the lock is held)

    private func route(_ r: URLRequest) -> (Int, [String: String], String) {
        if let o = override?(r) { return o }
        guard r.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)" else { return problem(401, "unauthorized", "Bad token.") }
        let method = r.httpMethod ?? "GET"
        let url = r.url!
        let q = Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                           uniquingKeysWith: { a, _ in a })
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.first == "v1", parts.count >= 2 else { return problem(404, "not_found", "No route.") }
        switch (method, parts[1], parts.count) {
        case ("GET", "stream", 2): return (200, ["Content-Type": "text/event-stream"], "")
        case ("GET", "me", 2): return ok(me())
        case ("GET", "members", 2): return ok(["items": memberRows.map(member)])
        case ("GET", "projects", 2): return ok(page(projectRows.map(project), q))
        case ("GET", "changes", 2): return feed(q)
        case ("GET", "issues", 2): return listIssues(q)
        case ("POST", "issues", 2): return createIssue(r)
        case (_, "issues", 3):
            guard let i = resolve(parts[2]) else { return problem(404, "not_found", "No issue.") }
            if method == "GET" { return ok(view(i)) }
            if method == "PATCH" { return patchIssue(i, r) }
        case (_, "issues", 4):
            guard let i = resolve(parts[2]) else { return problem(404, "not_found", "No issue.") }
            switch (method, parts[3]) {
            case ("POST", "assign"): return assign(i, r)
            case ("GET", "history"): return history(i)
            case ("GET", "comments"): return ok(["items": comments.filter { $0.issue == i.uuid && !$0.deleted }.map(commentJSON)])
            case ("POST", "comments"): return addComment(i, r)
            default: break
            }
        default: break
        }
        return problem(404, "not_found", "No route.")
    }

    private func listIssues(_ q: [String: String]) -> (Int, [String: String], String) {
        var rows = issues
        if let p = q["project"] { rows = rows.filter { $0.project == p } }
        if let p = q["parent"] {
            if p == "none" { rows = rows.filter { $0.parent == nil } }
            else if let parent = resolve(p) { rows = rows.filter { $0.parent == parent.uuid } }
            else { return problem(404, "not_found", "No issue.") }
        }
        if let k = q["kind"] { rows = rows.filter { $0.kind == k } }
        if let e = q["epic"] {
            if e == "none" { rows = rows.filter { $0.kind == "issue" && $0.epic == nil && ($0.parent.flatMap(by) ?? $0).epic == nil } }
            else if let epic = resolve(e) {
                if epic.kind != "epic" { return problem(400, "validation", "A query value is not valid.", errors: ["epic": "is not an epic"]) }
                rows = rows.filter { $0.epic == epic.uuid || $0.parent.flatMap(by)?.epic == epic.uuid }
            } else { return problem(404, "not_found", "No issue.") }
        }
        if let s = q["status"] { rows = rows.filter { s.split(separator: ",").map(String.init).contains($0.status) } }
        if let text = q["q"]?.lowercased() {
            rows = rows.filter { $0.title.lowercased().contains(text) || ($0.details ?? "").lowercased().contains(text) }
        }
        if let since = q["updated_since"].flatMap(parseISO) { rows = rows.filter { activity($0) >= since } }
        if q["order"] == "activity" {
            rows.sort { (activity($0), $0.uuid) > (activity($1), $1.uuid) }
        } else {
            rows.sort { ($0.createdAt, $0.uuid) > ($1.createdAt, $1.uuid) }
        }
        return ok(page(rows.map(view), q))
    }

    private func createIssue(_ r: URLRequest) -> (Int, [String: String], String) {
        let b = body(r)
        guard Set(b.keys).isSubset(of: ["project_uuid", "title", "details", "status", "parent_uuid", "kind", "epic", "start_date", "due_date", "size"]) else {
            return problem(400, "validation", "Unknown field.")
        }
        guard let p = b["project_uuid"] as? String, projectRows.contains(where: { $0.uuid == p }), let title = b["title"] as? String, !title.isEmpty else {
            return problem(400, "validation", "A project and a title are required.")
        }
        let parent = b["parent_uuid"] as? String
        if let parent, let refusal = parentRefusal(parent, for: nil, project: p) { return refusal }
        let kind = b["kind"] as? String ?? "issue"
        guard ["issue", "epic"].contains(kind) else { return problem(400, "validation", "A field is not valid.", errors: ["kind": "must be issue or epic"]) }
        var epic: String?
        if let ref = b["epic"] as? String {
            guard let e = resolve(ref) else { return problem(404, "not_found", "No issue.") }
            epic = e.uuid
            if let refusal = epicRefusal(epic, kind: kind, parent: parent, project: p) { return refusal }
        }
        let id = nextID()
        let t = tick()
        let n = (issues.filter { $0.project == p }.map(\.number).max() ?? 0) + 1
        let i = Issue(uuid: id, project: p, number: n, title: title, details: b["details"] as? String, status: b["status"] as? String ?? "open",
                      size: b["size"] as? String, due: b["due_date"] as? String, assignee: nil, parent: parent, kind: kind, epic: epic,
                      start: b["start_date"] as? String, createdBy: memberRows[0].uuid, createdAt: t, updatedAt: t)
        issues.append(i)
        log(issue: i, op: "upsert")
        recordCreation(i)
        return ok(view(i), status: 201)
    }

    private func patchIssue(_ i: Issue, _ r: URLRequest) -> (Int, [String: String], String) {
        let b = body(r)
        guard Set(b.keys).isSubset(of: ["title", "details", "status", "size", "due_date", "parent_uuid", "start_date", "epic_uuid"]) else {
            return problem(400, "validation", "Unknown field.")
        }
        guard let n = issues.firstIndex(where: { $0.uuid == i.uuid }) else { return problem(404, "not_found", "No issue.") }
        let before = issues[n]
        defer { recordPatch(before, issues[n]) }
        if let parent = b["parent_uuid"] as? String {
            if parent.isEmpty { issues[n].parent = nil }
            else if let refusal = parentRefusal(parent, for: i.uuid, project: i.project) { return refusal }
            else { issues[n].parent = parent; issues[n].epic = nil }
        }
        if b.keys.contains("epic_uuid") {
            let epic = b["epic_uuid"] as? String
            if let refusal = epicRefusal(epic, kind: issues[n].kind, parent: issues[n].parent, project: i.project) { return refusal }
            issues[n].epic = epic
        }
        if let v = b["title"] as? String { issues[n].title = v }
        if b.keys.contains("details") { issues[n].details = b["details"] as? String }
        if let v = b["status"] as? String { issues[n].status = v }
        if b.keys.contains("size") { issues[n].size = b["size"] as? String }
        if b.keys.contains("due_date") { issues[n].due = b["due_date"] as? String }
        if b.keys.contains("start_date") { issues[n].start = b["start_date"] as? String }
        touch(n)
        return ok(view(issues[n]))
    }

    private func recordCreation(_ i: Issue) {
        transitions.append((i.uuid, nil, i.status, i.createdBy, i.createdAt))
        for (field, value) in [("title", i.title), ("status", i.status)] {
            audit.append(Audit(issue: i.uuid, version: 1, field: field, old: nil, new: Self.json(value), actor: i.createdBy, channel: "cli", at: i.createdAt))
        }
    }

    /// One audit row for each changed field. The version is the one that the patch makes.
    private func recordPatch(_ a: Issue, _ b: Issue) {
        let pairs: [(String, String?, String?)] = [
            ("title", a.title, b.title), ("details", a.details, b.details), ("status", a.status, b.status), ("size", a.size, b.size),
            ("due_date", a.due, b.due), ("start_date", a.start, b.start), ("parent_uuid", a.parent, b.parent), ("epic_uuid", a.epic, b.epic),
        ]
        let at = b.updatedAt
        for (field, old, new) in pairs where old != new {
            audit.append(Audit(issue: a.uuid, version: a.version + 1, field: field, old: old.map(Self.json), new: new.map(Self.json), actor: memberRows[0].uuid, channel: "cli", at: at))
        }
        if a.status != b.status { transitions.append((a.uuid, a.status, b.status, memberRows[0].uuid, at)) }
    }

    private func history(_ i: Issue) -> (Int, [String: String], String) {
        let rows: [[String: Any]] = audit.filter { $0.issue == i.uuid }.reversed().enumerated().map { n, a in
            ["id": 100 - n, "seq": 1000 - n, "entity": "issue", "uuid": a.issue, "version": a.version, "field": a.field,
             "old": a.old as Any? ?? NSNull(), "new": a.new as Any? ?? NSNull(), "actor_uuid": a.actor as Any? ?? NSNull(),
             "channel": a.channel, "token_id": NSNull(), "at": Self.time(a.at)]
        }
        let moves: [[String: Any]] = transitions.filter { $0.issue == i.uuid }.map {
            ["issue_uuid": $0.issue, "from_status": $0.from as Any? ?? NSNull(), "to_status": $0.to, "created_by": $0.by, "transitioned_at": Self.time($0.at)]
        }
        return ok(["transitions": moves, "changes": rows])
    }

    private static func json(_ s: String) -> String {
        String(decoding: (try? JSONSerialization.data(withJSONObject: s, options: .fragmentsAllowed)) ?? Data(), as: UTF8.self)
    }

    /// The sub-item rules of the server: one level, same project, not itself.
    private func parentRefusal(_ parent: String, for issue: String?, project: String) -> (Int, [String: String], String)? {
        let text: String?
        if parent == issue { text = "cannot be the issue itself" }
        else if let p = issues.first(where: { $0.uuid == parent }) {
            if p.parent != nil { text = "is a sub-item; a sub-item cannot have sub-items" }
            else if p.project != project { text = "belongs to another project" }
            else if let issue, issues.contains(where: { $0.parent == issue }) { text = "the issue has sub-items, so it cannot be a sub-item" }
            else { text = nil }
        } else { text = "does not name a live record" }
        return text.map { problem(400, "validation", "A field is not valid.", errors: ["parent_uuid": $0]) }
    }

    /// The epic rules of the server: an epic is in no epic, a sub-item has none, the epic is a live epic of the same project.
    private func epicRefusal(_ epic: String?, kind: String, parent: String?, project: String) -> (Int, [String: String], String)? {
        guard let epic else { return nil }
        let text: String?
        if kind == "epic" { text = "an epic cannot be in an epic" }
        else if parent != nil { text = "a sub-item uses the epic of its parent" }
        else if let e = by(epic) {
            if e.kind != "epic" { text = "is not an epic" }
            else if e.project != project { text = "belongs to another project" }
            else { text = nil }
        } else { text = "does not name a live record" }
        return text.map { problem(400, "validation", "A field is not valid.", errors: ["epic_uuid": $0]) }
    }

    private func assign(_ i: Issue, _ r: URLRequest) -> (Int, [String: String], String) {
        let b = body(r)
        guard Set(b.keys) == ["member"] else { return problem(400, "validation", "Unknown field.") }
        guard let n = issues.firstIndex(where: { $0.uuid == i.uuid }) else { return problem(404, "not_found", "No issue.") }
        let before = issues[n].assignee
        defer {
            if before != issues[n].assignee {
                audit.append(Audit(issue: i.uuid, version: issues[n].version, field: "assignee_uuid", old: before.map(Self.json),
                                   new: issues[n].assignee.map(Self.json), actor: memberRows[0].uuid, channel: "mcp", at: issues[n].updatedAt))
            }
        }
        switch b["member"] {
        case let m as String where m == "me": issues[n].assignee = memberRows[0].uuid
        case let m as String:
            guard memberRows.contains(where: { $0.uuid == m }) else { return problem(400, "validation", "No member.") }
            issues[n].assignee = m
        default: issues[n].assignee = nil
        }
        touch(n)
        return ok(view(issues[n]))
    }

    private func addComment(_ i: Issue, _ r: URLRequest) -> (Int, [String: String], String) {
        let b = body(r)
        guard Set(b.keys).isSubset(of: ["body", "health"]), b.keys.contains("body"), let text = b["body"] as? String else {
            return problem(400, "validation", "A body is required.")
        }
        let health = b["health"] as? String
        if let health {
            guard ["on_track", "at_risk", "off_track"].contains(health) else {
                return problem(400, "validation", "A field is not valid.", errors: ["health": "must be on_track, at_risk, or off_track"])
            }
            if i.kind != "epic" { return problem(400, "validation", "A field is not valid.", errors: ["health": "only an update on an epic has a health"]) }
        }
        let id = insertComment(issue: i.uuid, body: text, health: health)
        return ok(commentJSON(comments.first { $0.uuid == id }!), status: 201)
    }

    private func feed(_ q: [String: String]) -> (Int, [String: String], String) {
        let since = Int(q["since"] ?? "") ?? 0
        let limit = Int(q["limit"] ?? "") ?? 100
        let entities = q["entity"].map { Set($0.split(separator: ",").map(String.init)) }
        let hi = changes.last?.seq ?? 0
        let rows = changes.filter { $0.seq > since && (entities?.contains($0.entity) ?? true) }
        let out = Array(rows.prefix(limit))
        let more = rows.count > out.count
        let list: [[String: Any]] = out.map { c in
            var o: [String: Any] = ["seq": c.seq, "entity": c.entity, "op": c.op]
            if let r = c.record { o["record"] = r } else { o["uuid"] = c.uuid; o["version"] = c.version }
            return o
        }
        return ok(["changes": list, "next": more ? out.last!.seq : hi, "more": more, "head": hi, "server_time": Self.time(Date(timeIntervalSince1970: 1_800_000_000))])
    }

    // MARK: Data

    private func nextID() -> String {
        ids += 1
        return String(format: "00000000-0000-7000-8000-%012d", ids)
    }

    /// Each write moves the clock by one second, so the order of writes is the order of times.
    private func tick() -> Date {
        counter += 1
        return Date(timeIntervalSince1970: 1_790_000_000 + Double(counter))
    }

    private func touch(_ n: Int) {
        issues[n].version += 1
        issues[n].updatedAt = tick()
        log(issue: issues[n], op: "upsert")
    }

    private func insertComment(issue: String, body: String, health: String? = nil) -> String {
        let id = nextID()
        let t = tick()
        let c = Comment(uuid: id, issue: issue, author: memberRows[0].uuid, body: body, health: health, createdAt: t, updatedAt: t)
        comments.append(c)
        changes.append(Change(seq: changes.count + 1, entity: "issue_comment", op: "upsert", record: [
            "uuid": id, "issue_uuid": issue, "version": 1, "updated_at": Self.time(t), "created_at": Self.time(t), "body": body,
        ], uuid: id, version: 1))
        return id
    }

    private func log(issue i: Issue, op: String) {
        changes.append(Change(seq: changes.count + 1, entity: "issue", op: op, record: [
            "uuid": i.uuid, "version": i.version, "project_uuid": i.project, "number": i.number, "title": i.title,
            "created_at": Self.time(i.createdAt), "updated_at": Self.time(i.updatedAt), "status": i.status,
            "parent_uuid": i.parent as Any? ?? NSNull(), "kind": i.kind, "epic_uuid": i.epic as Any? ?? NSNull(),
            "start_date": i.start as Any? ?? NSNull(),
        ], uuid: i.uuid, version: i.version))
    }

    private func resolve(_ ref: String) -> Issue? {
        issues.first { $0.uuid == ref || key($0).caseInsensitiveCompare(ref) == .orderedSame }
    }

    private func by(_ uuid: String) -> Issue? { issues.first { $0.uuid == uuid } }

    private func key(_ i: Issue) -> String { "\(projectRows.first { $0.uuid == i.project }?.prefix ?? "X")-\(i.number)" }

    private func activity(_ i: Issue) -> Date {
        max(i.updatedAt, comments.filter { $0.issue == i.uuid }.map(\.updatedAt).max() ?? i.updatedAt)
    }

    private func page(_ rows: [[String: Any]], _ q: [String: String]) -> [String: Any] {
        let limit = min(Int(q["limit"] ?? "") ?? pageSize, pageSize)
        let start = Int(q["cursor"] ?? "") ?? 0
        let slice = Array(rows.dropFirst(start).prefix(limit))
        let next: Any = start + slice.count < rows.count ? String(start + slice.count) : NSNull()
        return ["items": slice, "next_cursor": next]
    }

    // MARK: JSON

    private func me() -> [String: Any] {
        ["member": member(memberRows[0]), "team": ["name": "Big Time Data"], "token": ["id": "t1", "kind": "personal", "scopes": scopes]]
    }

    private func member(_ m: (uuid: String, name: String, email: String, status: String)) -> [String: Any] {
        ["uuid": m.uuid, "name": m.name, "email": m.email, "short_name": m.name.split(separator: " ").first.map(String.init) ?? m.name, "status": m.status]
    }

    private func project(_ p: (uuid: String, name: String, prefix: String)) -> [String: Any] {
        ["uuid": p.uuid, "name": p.name, "issue_prefix": p.prefix, "archived": false, "color": "#3B82F6"]
    }

    private func view(_ i: Issue) -> [String: Any] {
        let live = comments.filter { $0.issue == i.uuid && !$0.deleted }
        var o: [String: Any] = [
            "uuid": i.uuid, "version": i.version, "project_uuid": i.project, "number": i.number, "key": key(i), "title": i.title,
            "status": i.status, "created_by": i.createdBy, "updated_by": i.createdBy, "created_at": Self.time(i.createdAt),
            "updated_at": Self.time(i.updatedAt), "activity_at": Self.time(activity(i)), "comment_count": live.count,
            "details": i.details as Any? ?? NSNull(), "size": i.size as Any? ?? NSNull(), "due_date": i.due as Any? ?? NSNull(),
            "assignee_uuid": i.assignee as Any? ?? NSNull(), "parent_uuid": i.parent as Any? ?? NSNull(),
            "parent_key": i.parent.flatMap { p in issues.first { $0.uuid == p }.map(key) } as Any? ?? NSNull(),
            "sub_item_count": issues.filter { $0.parent == i.uuid }.count,
            "sub_items_done": issues.filter { $0.parent == i.uuid && ["done", "cancelled"].contains($0.status) }.count,
            "kind": i.kind, "epic_uuid": i.epic as Any? ?? NSNull(), "start_date": i.start as Any? ?? NSNull(),
        ]
        let epicOfItem = i.epic ?? i.parent.flatMap(by)?.epic
        o["epic_key"] = epicOfItem.flatMap(by).map(key) as Any? ?? NSNull()
        // The roll-up counts the live issues of the epic and their sub-items. It is 0 for an issue.
        let members = i.kind == "epic" ? issues.filter { $0.epic == i.uuid || $0.parent.flatMap(by)?.epic == i.uuid } : []
        let sizes = ["S": 30, "M": 60, "L": 240, "XL": 480]
        o["item_count"] = members.count
        o["items_done"] = members.filter { ["done", "cancelled"].contains($0.status) }.count
        o["items_in_progress"] = members.filter { ["in_progress", "client_reviewing"].contains($0.status) }.count
        o["items_blocked"] = members.filter { $0.status == "blocked" }.count
        o["estimate_minutes"] = members.reduce(0) { $0 + ($1.size.flatMap { sizes[$0] } ?? 0) }
        let newest = live.filter { $0.health != nil }.max { $0.createdAt < $1.createdAt }
        o["health"] = i.kind == "epic" && i.due != nil ? newest?.health as Any? ?? NSNull() : NSNull()
        o["last_comment_at"] = live.map(\.createdAt).max().map(Self.time) ?? NSNull()
        return o
    }

    private func commentJSON(_ c: Comment) -> [String: Any] {
        ["uuid": c.uuid, "issue_uuid": c.issue, "author_uuid": c.author, "body": c.body, "created_at": Self.time(c.createdAt),
         "updated_at": Self.time(c.updatedAt), "health": c.health as Any? ?? NSNull()]
    }

    private func ok(_ o: [String: Any], status: Int = 200) -> (Int, [String: String], String) {
        (status, [:], String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self))
    }

    private func problem(_ status: Int, _ code: String, _ detail: String, errors: [String: String]? = nil) -> (Int, [String: String], String) {
        var o: [String: Any] = ["type": "about:blank", "title": "Problem", "status": status, "code": code, "detail": detail]
        if let errors { o["errors"] = errors }
        return (status, [:], String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self))
    }

    static func time(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}

extension BigTimerFakeServer: HTTPStreaming {
    /// A 200 answer with an event stream stays open. Any other reply gives its body and ends.
    func stream(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        lock.withLock { sent.append(request) }
        let (status, headers, text) = lock.withLock { route(request) }
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        let isStream = status == 200 && (headers["Content-Type"] ?? "").hasPrefix("text/event-stream") && text.isEmpty
        let body = AsyncThrowingStream<Data, Error> { cont in
            guard isStream else {
                cont.yield(Data(text.utf8))
                cont.finish()
                return
            }
            let id = UUID()
            lock.withLock { streams[id] = cont }
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                lock.withLock {
                    if streams.removeValue(forKey: id) != nil { ended += 1 }
                }
            }
        }
        return (resp, body)
    }
}
