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

    private let lock = NSLock()
    private var sent: [URLRequest] = []
    private var memberRows: [(uuid: String, name: String, email: String, status: String)] = []
    private var projectRows: [(uuid: String, name: String, prefix: String)] = []
    private var issues: [Issue] = []
    private var comments: [Comment] = []
    private var changes: [Change] = []
    private var counter = 0
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
    func addIssue(project: String, title: String, status: String = "open", assignee: String? = nil, size: String? = nil, due: String? = nil) -> String {
        lock.withLock {
            let id = nextID()
            let n = (issues.filter { $0.project == project }.map(\.number).max() ?? 0) + 1
            let t = tick()
            let i = Issue(uuid: id, project: project, number: n, title: title, details: nil, status: status, size: size, due: due,
                          assignee: assignee, createdBy: memberRows[0].uuid, createdAt: t, updatedAt: t)
            issues.append(i)
            log(issue: i, op: "upsert")
            return id
        }
    }

    @discardableResult
    func addComment(issue: String, body: String) -> String {
        lock.withLock { insertComment(issue: issue, body: body) }
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
        guard Set(b.keys).isSubset(of: ["project_uuid", "title", "details", "status"]) else { return problem(400, "validation", "Unknown field.") }
        guard let p = b["project_uuid"] as? String, projectRows.contains(where: { $0.uuid == p }), let title = b["title"] as? String, !title.isEmpty else {
            return problem(400, "validation", "A project and a title are required.")
        }
        let id = nextID()
        let t = tick()
        let n = (issues.filter { $0.project == p }.map(\.number).max() ?? 0) + 1
        let i = Issue(uuid: id, project: p, number: n, title: title, details: b["details"] as? String, status: b["status"] as? String ?? "open",
                      size: nil, due: nil, assignee: nil, createdBy: memberRows[0].uuid, createdAt: t, updatedAt: t)
        issues.append(i)
        log(issue: i, op: "upsert")
        return ok(view(i), status: 201)
    }

    private func patchIssue(_ i: Issue, _ r: URLRequest) -> (Int, [String: String], String) {
        let b = body(r)
        guard Set(b.keys).isSubset(of: ["title", "details", "status", "size", "due_date"]) else { return problem(400, "validation", "Unknown field.") }
        guard let n = issues.firstIndex(where: { $0.uuid == i.uuid }) else { return problem(404, "not_found", "No issue.") }
        if let v = b["title"] as? String { issues[n].title = v }
        if let v = b["details"] as? String { issues[n].details = v }
        if let v = b["status"] as? String { issues[n].status = v }
        touch(n)
        return ok(view(issues[n]))
    }

    private func assign(_ i: Issue, _ r: URLRequest) -> (Int, [String: String], String) {
        let b = body(r)
        guard Set(b.keys) == ["member"] else { return problem(400, "validation", "Unknown field.") }
        guard let n = issues.firstIndex(where: { $0.uuid == i.uuid }) else { return problem(404, "not_found", "No issue.") }
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
        guard Set(b.keys) == ["body"], let text = b["body"] as? String else { return problem(400, "validation", "A body is required.") }
        let id = insertComment(issue: i.uuid, body: text)
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

    private func insertComment(issue: String, body: String) -> String {
        let id = nextID()
        let t = tick()
        let c = Comment(uuid: id, issue: issue, author: memberRows[0].uuid, body: body, createdAt: t, updatedAt: t)
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
        ], uuid: i.uuid, version: i.version))
    }

    private func resolve(_ ref: String) -> Issue? {
        issues.first { $0.uuid == ref || key($0).caseInsensitiveCompare(ref) == .orderedSame }
    }

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
            "assignee_uuid": i.assignee as Any? ?? NSNull(),
        ]
        o["last_comment_at"] = live.map(\.createdAt).max().map(Self.time) ?? NSNull()
        return o
    }

    private func commentJSON(_ c: Comment) -> [String: Any] {
        ["uuid": c.uuid, "issue_uuid": c.issue, "author_uuid": c.author, "body": c.body, "created_at": Self.time(c.createdAt),
         "updated_at": Self.time(c.updatedAt)]
    }

    private func ok(_ o: [String: Any], status: Int = 200) -> (Int, [String: String], String) {
        (status, [:], String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self))
    }

    private func problem(_ status: Int, _ code: String, _ detail: String) -> (Int, [String: String], String) {
        let o: [String: Any] = ["type": "about:blank", "title": "Problem", "status": status, "code": code, "detail": detail]
        return (status, [:], String(decoding: (try? JSONSerialization.data(withJSONObject: o)) ?? Data(), as: UTF8.self))
    }

    static func time(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }
}
