import Foundation
import OverSireCore

// ─── Plane REST API ──────────────────────────────────────────────────────────
// v1 for work items, v2 for webhooks. A token works only in its own workspace,
// so each workspace has its own client. Calls block: run them off the main queue.

func jsonID(_ value: Any?) -> String? {
    if let s = value as? String, !s.isEmpty { return s }
    if let n = value as? NSNumber { return n.stringValue }
    return nil
}

func jsonInt(_ value: Any?) -> Int? {
    if let n = value as? Int { return n }
    if let n = value as? NSNumber { return n.intValue }
    return nil
}

struct PlaneWorkspace: Codable, Hashable {
    static let cloudHost = "https://api.plane.so"

    var slug: String
    var host: String = PlaneWorkspace.cloudHost

    init(slug: String, host: String = PlaneWorkspace.cloudHost) {
        self.slug = slug
        self.host = host
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? PlaneWorkspace.cloudHost
    }

    // Plane Cloud has the app on another host. A self-hosted Plane has both on one host.
    var webURL: String { host == PlaneWorkspace.cloudHost ? "https://app.plane.so" : host }
    var url: String { "\(webURL)/\(slug)/" }

    func projectURL(_ id: String) -> String { "\(webURL)/\(slug)/projects/\(id)/issues/" }
    func itemURL(_ key: String) -> String { "\(webURL)/\(slug)/browse/\(key)/" }
}

enum PlaneError: Error, Equatable {
    case noToken, unauthorized, forbidden, notFound
    case http(Int, String)
    case network(String)

    var message: String {
        switch self {
        case .noToken: return "Add a token for this workspace in Settings → Projects."
        case .unauthorized: return "Plane does not accept the token."
        case .forbidden: return "The token has no access to this workspace."
        case .notFound: return "Plane did not find the workspace or the item."
        case .http(let code, let text): return text.isEmpty ? "Plane gave HTTP \(code)" : "Plane: \(text)"
        case .network(let s): return s
        }
    }

    var providerError: ProviderError {
        switch self {
        case .noToken, .unauthorized: return .unauthorized
        case .forbidden: return .forbidden
        case .notFound: return .notFound
        case .http(429, _): return .rateLimited(retryAfter: nil)
        case .http(let code, let text): return .vendor(code: String(code), message: message.isEmpty ? text : message)
        case .network(let s): return .transport(s)
        }
    }
}

struct PlaneWebhook: Equatable {
    let id: String
    let url: String
    let isActive: Bool
}

final class PlaneClient {
    static let priorities = StatusOption.priorities

    let workspace: PlaneWorkspace
    private let token: String
    private let session: URLSession
    private let lock = NSLock()
    private var meCache: (id: String, name: String)?
    private var memberCache: (names: [String: String], at: Date)?

    init(workspace: PlaneWorkspace, token: String, session: URLSession = .shared) {
        self.workspace = workspace
        self.token = token
        self.session = session
    }

    private var ws: String { "/api/v1/workspaces/\(workspace.slug)" }

    // MARK: Workspace

    func me() -> Result<(id: String, name: String), PlaneError> {
        if let m = lock.withLock({ meCache }) { return .success(m) }
        return send("GET", "/api/v1/users/me/").flatMap { obj in
            guard let o = obj as? [String: Any], let id = jsonID(o["id"]) else { return .failure(.http(200, "no user in the answer")) }
            let name = (o["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (o["email"] as? String) ?? id
            lock.withLock { meCache = (id, name) }
            return .success((id, name))
        }
    }

    // User id → display name. Kept for one hour.
    func memberNames() -> [String: String] {
        if let c = lock.withLock({ memberCache }), -c.at.timeIntervalSinceNow < 3600 { return c.names }
        guard case .success(let obj) = send("GET", "\(ws)/members/") else { return lock.withLock { memberCache?.names ?? [:] } }
        let rows = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        var names: [String: String] = [:]
        for r in rows {
            let u = (r["member"] as? [String: Any]) ?? r
            guard let id = jsonID(u["id"]) else { continue }
            names[id] = (u["display_name"] as? String) ?? (u["email"] as? String) ?? id
        }
        lock.withLock { memberCache = (names, Date()) }
        return names
    }

    func projects() -> Result<[ProjectSummary], PlaneError> {
        list("\(ws)/projects/", max: 1000).map { rows in
            rows.compactMap { r -> ProjectSummary? in
                guard let id = jsonID(r["id"]), let name = r["name"] as? String else { return nil }
                let identifier = r["identifier"] as? String ?? ""
                return ProjectSummary(ref: ProjectRef(workspace: workspace.slug, id: id, key: identifier.isEmpty ? nil : identifier),
                                      identifier: identifier,
                                      title: name, url: workspace.projectURL(id),
                                      closed: !(r["archived_at"] is NSNull || r["archived_at"] == nil))
            }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        }
    }

    func states(project: String) -> Result<[StatusOption], PlaneError> {
        list("\(ws)/projects/\(project)/states/", max: 200).map { rows in
            rows.sorted { (($0["sequence"] as? NSNumber)?.doubleValue ?? 0) < (($1["sequence"] as? NSNumber)?.doubleValue ?? 0) }
                .compactMap { r in
                    guard let id = jsonID(r["id"]), let name = r["name"] as? String else { return nil }
                    return StatusOption(id: id, name: name, color: r["color"] as? String ?? "#9CA3AF", group: r["group"] as? String)
                }
        }
    }

    // MARK: Snapshot

    // Comments cost one call per item, so they load only for items with new activity
    // since `previous`. Other items keep the comment data of `previous`.
    func snapshot(_ summary: ProjectSummary, limit: Int, previous: ProjectSnapshot?) -> Result<ProjectSnapshot, PlaneError> {
        let p = summary.ref.id
        let meResult = me()
        if case .failure(let e) = meResult { return .failure(e) }
        let me = try? meResult.get()
        let names = memberNames()
        let states: [StatusOption]
        switch self.states(project: p) {
        case .success(let s): states = s
        case .failure(let e): return .failure(e)
        }
        let query = [URLQueryItem(name: "expand", value: "assignees,labels"),
                     URLQueryItem(name: "order_by", value: "-last_activity_at")]
        var rows: [[String: Any]]
        switch list("\(ws)/projects/\(p)/issues/", query: query, max: limit) {
        case .success(let r): rows = r
        case .failure(let e): return .failure(e)
        }
        let prevById = Dictionary((previous?.items ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let index = try? self.index(project: p).get()
        var reused: [Item] = []
        if let index {
            let (extra, kept) = treeRows(project: p, loaded: Set(rows.compactMap { jsonID($0["id"]) }), index: index, previous: prevById)
            rows += extra
            reused = kept
        }
        let items = reused + rows.compactMap { r -> Item? in
            guard var item = parseItem(r, summary: summary, names: names) else { return nil }
            let prev = prevById[item.id]
            if let prev, prev.activityAt == item.activityAt {
                item.commentCount = prev.commentCount
                item.lastComment = prev.lastComment
                item.mentionsMe = prev.mentionsMe
            } else if previous != nil, case .success(let list) = comments(project: p, item: item.id, url: item.url, names: names) {
                item.commentCount = list.count
                item.lastComment = list.last
                let since = previous?.fetchedAt ?? .distantPast
                let fresh = list.filter { $0.createdAt > since }.compactMap(\.body)
                let text = prev == nil ? fresh + [item.body ?? ""] : fresh
                item.mentionsMe = me.map { m in text.contains { $0.localizedCaseInsensitiveContains("@" + m.name) } } ?? false
            }
            return item
        }
        let fields = [ProjectField(id: ProjectSnapshot.statusFieldId, name: "Status", options: states),
                      ProjectField(id: ProjectSnapshot.priorityFieldId, name: "Priority",
                                   options: PlaneClient.priorities.filter { $0.id != "none" })]
        return .success(ProjectSnapshot(summary: summary, statusOptions: states, items: items, fetchedAt: Date(),
                                        fields: fields, me: me?.name, meId: me?.id, index: index,
                                        intake: intake(project: p, names: names)))
    }

    // MARK: Intake

    // Pending intake items. Only v2 can filter by status. Nil when the project has no intake.
    func intake(project: String, names: [String: String]) -> [IntakeItem]? {
        let q = [URLQueryItem(name: "status", value: "-2"), URLQueryItem(name: "per_page", value: "100"),
                 URLQueryItem(name: "fields", value: "id,name,priority,work_item_id,created_at,created_by_id,source")]
        guard case .success(let obj) = send("GET", "/api/v2/workspaces/\(workspace.slug)/projects/\(project)/intake-issues/", query: q)
        else { return nil }
        let rows = (obj as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return rows.compactMap { r in
            guard let id = jsonID(r["id"]), let item = jsonID(r["work_item_id"]) else { return nil }
            return IntakeItem(id: id, workItemId: item, name: r["name"] as? String ?? "Untitled",
                              priority: (r["priority"] as? String).flatMap { $0 == "none" ? nil : $0.capitalized },
                              createdAt: parseISO(r["created_at"] as? String) ?? Date(),
                              author: jsonID(r["created_by_id"]).map { names[$0] ?? $0 },
                              source: r["source"] as? String)
        }
    }

    // The description of an intake item. The work item endpoints do not return pending items.
    func intakeDetail(project: String, workItem: String) -> Result<IntakeDetail, PlaneError> {
        let names = memberNames()
        return send("GET", "\(ws)/projects/\(project)/intake-issues/\(workItem)/").map { obj in
            let d = (obj as? [String: Any])?["issue_detail"] as? [String: Any] ?? [:]
            let html = d["description_html"] as? String ?? ""
            let body = PlaneMarkup.markdown(fromHTML: html) { names[$0] }
            return IntakeDetail(sequence: d["sequence_id"] as? Int, body: body,
                                labels: (d["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        }
    }

    // The plain update endpoint refuses a status change, so status changes use /status/.
    func triage(project: String, workItem: String, action: IntakeAction) -> Result<Void, PlaneError> {
        let path = "\(ws)/projects/\(project)/intake-issues/\(workItem)/"
        guard let body = action.body else { return send("DELETE", path).map { _ in () } }
        return send("PATCH", path + "status/", body: body).map { _ in () }
    }

    // Work item id → sequence number, for all intake items. Only v1 has the number, in the full work item.
    func intakeSequences(project: String) -> Result<[String: Int], PlaneError> {
        let q = [URLQueryItem(name: "fields", value: "issue,issue_detail")]
        return list("\(ws)/projects/\(project)/intake-issues/", query: q, max: 2000).map { rows in
            var out: [String: Int] = [:]
            for r in rows {
                if let id = jsonID(r["issue"]), let n = (r["issue_detail"] as? [String: Any])?["sequence_id"] as? Int { out[id] = n }
            }
            return out
        }
    }

    // A signed download link for an uploaded file, for example an image in a description. It is good for one hour.
    func assetURL(_ id: String) -> Result<String, PlaneError> {
        send("GET", "\(ws)/assets/\(id)/").flatMap { obj in
            guard let u = (obj as? [String: Any])?["asset_url"] as? String else { return .failure(.notFound) }
            return .success(u)
        }
    }

    // All items of the project, with only the fields for the tree. About 150 bytes per item.
    func index(project: String) -> Result<[ItemStub], PlaneError> {
        let q = [URLQueryItem(name: "fields", value: "id,parent,state,last_activity_at")]
        return list("\(ws)/projects/\(project)/issues/", query: q, max: 5000).map { rows in
            rows.compactMap { r in
                jsonID(r["id"]).map { ItemStub(id: $0, parentId: jsonID(r["parent"]), stateId: jsonID(r["state"]),
                                               activityAt: parseISO(r["last_activity_at"] as? String)) }
            }
        }
    }

    // The parents and the sub-items of the loaded items, so that each tree is complete.
    // An item that did not change since `previous` is kept. A few others load one by one.
    // More load with the full list, which costs one call for each 100 items.
    private func treeRows(project: String, loaded: Set<String>, index: [ItemStub],
                          previous: [String: Item]) -> (rows: [[String: Any]], kept: [Item]) {
        let byId = Dictionary(index.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kids = Dictionary(grouping: index.filter { $0.parentId != nil }, by: { $0.parentId! })
        var tree = loaded
        for id in loaded {
            var p = byId[id]?.parentId
            while let x = p, !tree.contains(x) { tree.insert(x); p = byId[x]?.parentId }
        }
        var queue = Array(tree)
        while let id = queue.popLast() {
            for c in kids[id] ?? [] where !tree.contains(c.id) { tree.insert(c.id); queue.append(c.id) }
        }
        var kept: [Item] = [], need: Set<String> = []
        for id in tree.subtracting(loaded) {
            if let prev = previous[id], prev.activityAt == byId[id]?.activityAt { kept.append(prev) } else { need.insert(id) }
        }
        if need.isEmpty { return ([], kept) }
        let query = [URLQueryItem(name: "expand", value: "assignees,labels")]
        var rows: [[String: Any]] = []
        if need.count <= 3 {
            for id in need.sorted() {
                if case .success(let obj) = send("GET", "\(ws)/projects/\(project)/issues/\(id)/", query: query),
                   let r = obj as? [String: Any] { rows.append(r) }
            }
        } else if case .success(let all) = list("\(ws)/projects/\(project)/issues/", query: query, max: 2000) {
            rows = all.filter { jsonID($0["id"]).map(need.contains) ?? false }
        }
        return (rows, kept)
    }

    private func parseItem(_ r: [String: Any], summary: ProjectSummary, names: [String: String]) -> Item? {
        guard let id = jsonID(r["id"]), let title = r["name"] as? String else { return nil }
        if let a = r["archived_at"], !(a is NSNull) { return nil }
        let key = "\(summary.identifier)-\(jsonInt(r["sequence_id"]) ?? 0)"
        func person(_ v: Any?) -> String? {
            if let o = v as? [String: Any] { return (o["display_name"] as? String) ?? jsonID(o["id"]).flatMap { names[$0] } }
            return jsonID(v).map { names[$0] ?? $0 }
        }
        let state = (r["state"] as? [String: Any]).flatMap { jsonID($0["id"]) } ?? jsonID(r["state"])
        var fields: [String: String] = [:]
        if let pr = r["priority"] as? String, pr != "none" { fields["Priority"] = pr.capitalized }
        if let d = r["target_date"] as? String, !d.isEmpty { fields["Due"] = d }
        if let d = r["start_date"] as? String, !d.isEmpty { fields["Start"] = d }
        let labels = (r["labels"] as? [Any] ?? []).compactMap { ($0 as? [String: Any])?["name"] as? String }
        let html = r["description_html"] as? String ?? ""
        let updated = parseISO(r["updated_at"] as? String) ?? Date()
        return Item(id: id, key: key, title: title, url: workspace.itemURL(key), statusOptionId: state,
                           fields: fields, assignees: (r["assignees"] as? [Any] ?? []).compactMap(person),
                           labels: labels, author: person(r["created_by"]), updatedBy: person(r["updated_by"]),
                           updatedAt: updated, activityAt: parseISO(r["last_activity_at"] as? String) ?? updated,
                           commentCount: 0, lastComment: nil, mentionsMe: false,
                           body: PlaneMarkup.markdown(fromHTML: html) { names[$0] },
                           parentId: jsonID(r["parent"]) ?? jsonID((r["parent"] as? [String: Any])?["id"]))
    }

    // Oldest first.
    func comments(project: String, item: String, url: String, names: [String: String]? = nil) -> Result<[Comment], PlaneError> {
        let names = names ?? memberNames()
        return list("\(ws)/projects/\(project)/issues/\(item)/comments/", max: 500).map { rows in
            rows.compactMap { r -> Comment? in
                guard let id = jsonID(r["id"]) else { return nil }
                let who = jsonID(r["actor"]) ?? jsonID(r["created_by"])
                return Comment(id: id, author: who.map { names[$0] ?? $0 },
                                  createdAt: parseISO(r["created_at"] as? String) ?? Date(), url: url,
                                  body: PlaneMarkup.markdown(fromHTML: r["comment_html"] as? String ?? "") { names[$0] })
            }.sorted { $0.createdAt < $1.createdAt }
        }
    }

    // Activities and comments of one item, newest last.
    // current: the status now. Plane often leaves out the new status of a change, so the next change or this fills it.
    func timeline(project: String, item: String, url: String, states: [StatusOption], current: String?) -> Result<[ActivityEntry], PlaneError> {
        let names = memberNames()
        let rows: [[String: Any]]
        switch list("\(ws)/projects/\(project)/issues/\(item)/activities/", max: 200) {
        case .success(let r): rows = r
        case .failure(let e): return .failure(e)
        }
        var out = rows.compactMap { r -> ActivityEntry? in
            guard let change = PlaneClient.change(r, names: names, states: states) else { return nil }
            let actor = jsonID(r["actor"]).map { names[$0] ?? $0 }
            return ActivityEntry.make(projectKey: "", itemId: item, change: change, actor: actor, url: url,
                                      at: parseISO(r["created_at"] as? String) ?? Date())
        }
        out.sort { $0.at < $1.at }
        var next = current
        for i in out.indices.reversed() {
            guard case .status(let from, let to) = out[i].change else { continue }
            if to == nil, let next {
                let e = out[i]
                out[i] = ActivityEntry.make(projectKey: e.projectKey, itemId: e.itemId, change: .status(from: from, to: next),
                                            actor: e.actor, url: e.url, at: e.at)
            }
            next = from
        }
        if case .success(let list) = comments(project: project, item: item, url: url, names: names) {
            out += list.map { ActivityEntry.make(projectKey: "", itemId: item, change: .comments(new: 1, last: $0),
                                                 actor: $0.author, url: url, at: $0.createdAt) }
        }
        return .success(out.sorted { $0.at < $1.at })
    }

    static func change(_ r: [String: Any], names: [String: String], states: [StatusOption]) -> ItemChange? {
        let verb = r["verb"] as? String ?? ""
        let field = r["field"] as? String
        func value(_ v: String, _ ident: String) -> String? {
            let text = (r[v] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let text { return text }
            guard let id = jsonID(r[ident]) else { return nil }
            return states.first { $0.id == id }?.name ?? names[id]
        }
        let old = value("old_value", "old_identifier"), new = value("new_value", "new_identifier")
        switch (verb, field) {
        case ("created", nil): return .added
        case (_, "state"?): return .status(from: old, to: new)
        case (_, "assignees"?):
            if let new { return .assigned(names[new] ?? new) }
            if let old { return .unassigned(names[old] ?? old) }
            return nil
        case (_, "priority"?): return .field(name: "Priority", from: old?.capitalized, to: new?.capitalized)
        case (_, "name"?): return .field(name: "Title", from: old, to: new)
        case (_, "labels"?): return .field(name: "Labels", from: old, to: new)
        case (_, "target_date"?): return .field(name: "Due", from: old, to: new)
        case (_, "start_date"?): return .field(name: "Start", from: old, to: new)
        case (_, "archived_at"?): return new == nil ? .reopened : .closed
        default: return nil
        }
    }

    func labels(project: String) -> Result<[StatusOption], PlaneError> {
        list("\(ws)/projects/\(project)/labels/", max: 500).map { rows in
            rows.compactMap { r in
                guard let id = jsonID(r["id"]), let name = r["name"] as? String else { return nil }
                return StatusOption(id: id, name: name, color: r["color"] as? String ?? "#9CA3AF")
            }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: Writes

    func update(project: String, item: String, _ patch: ItemPatch) -> Result<Void, PlaneError> {
        self.patch(project: project, item: item, patch.planeFields)
    }

    // The raw description HTML, for the OverSire block merge.
    func setDescription(project: String, item: String, html: String) -> Result<Void, PlaneError> {
        patch(project: project, item: item, ["description_html": html])
    }

    private func patch(project: String, item: String, _ fields: [String: Any]) -> Result<Void, PlaneError> {
        send("PATCH", "\(ws)/projects/\(project)/issues/\(item)/", body: fields).map { _ in () }
    }

    // Returns the new item id.
    func create(project: String, _ draft: ItemDraft) -> Result<String, PlaneError> {
        send("POST", "\(ws)/projects/\(project)/issues/", body: draft.planeFields).flatMap { obj in
            jsonID((obj as? [String: Any])?["id"]).map { .success($0) } ?? .failure(.http(200, "no id for the new item"))
        }
    }

    func comment(project: String, item: String, markdown: String) -> Result<Void, PlaneError> {
        send("POST", "\(ws)/projects/\(project)/issues/\(item)/comments/",
             body: ["comment_html": PlaneMarkup.html(fromMarkdown: markdown)]).map { _ in () }
    }

    func descriptionHTML(project: String, item: String) -> Result<String, PlaneError> {
        send("GET", "\(ws)/projects/\(project)/issues/\(item)/").map { ($0 as? [String: Any])?["description_html"] as? String ?? "" }
    }

    func links(project: String, item: String) -> Result<[String], PlaneError> {
        list("\(ws)/projects/\(project)/issues/\(item)/links/", max: 200).map { $0.compactMap { $0["url"] as? String } }
    }

    func addLink(project: String, item: String, url: String, title: String) -> Result<Void, PlaneError> {
        send("POST", "\(ws)/projects/\(project)/issues/\(item)/links/", body: ["url": url, "title": title]).map { _ in () }
    }

    // Returns the id of the new label.
    func createLabel(project: String, name: String, color: String) -> Result<String, PlaneError> {
        send("POST", "\(ws)/projects/\(project)/labels/", body: ["name": name, "color": color]).flatMap { obj in
            jsonID((obj as? [String: Any])?["id"]).map { .success($0) } ?? .failure(.http(200, "no id for the new label"))
        }
    }

    // The label ids of a work item.
    func labelIds(project: String, item: String) -> Result<[String], PlaneError> {
        send("GET", "\(ws)/projects/\(project)/issues/\(item)/").map { obj in
            ((obj as? [String: Any])?["labels"] as? [Any] ?? []).compactMap { jsonID($0) ?? jsonID(($0 as? [String: Any])?["id"]) }
        }
    }

    // The body of a pending intake item. The work item endpoints do not see it.
    func intakeHTML(project: String, workItem: String) -> Result<String, PlaneError> {
        send("GET", "\(ws)/projects/\(project)/intake-issues/\(workItem)/").map { obj in
            ((obj as? [String: Any])?["issue_detail"] as? [String: Any])?["description_html"] as? String ?? ""
        }
    }

    func updateIntake(project: String, workItem: String, _ fields: [String: Any]) -> Result<Void, PlaneError> {
        send("PATCH", "\(ws)/projects/\(project)/intake-issues/\(workItem)/", body: ["issue": fields]).map { _ in () }
    }

    // Adds me and keeps the other assignees.
    func assignMe(project: String, item: String) -> Result<Void, PlaneError> {
        me().flatMap { me in
            send("GET", "\(ws)/projects/\(project)/issues/\(item)/").flatMap { obj in
                var ids = ((obj as? [String: Any])?["assignees"] as? [Any] ?? []).compactMap { v in
                    jsonID(v) ?? jsonID((v as? [String: Any])?["id"])
                }
                if ids.contains(me.id) { return .success(()) }
                ids.append(me.id)
                return update(project: project, item: item, ItemPatch(assignees: ids))
            }
        }
    }

    // MARK: Webhooks (v2, workspace admin only)

    // Plane takes exact event names, not globs.
    static let hookScopes = ["project.created", "project.updated", "project.archived", "project.deleted",
                             "workitem.created", "workitem.updated", "workitem.archived", "workitem.deleted",
                             "workitem.comment.created", "workitem.comment.updated", "workitem.comment.deleted"]

    private var hooks: String { "/api/v2/workspaces/\(workspace.slug)/webhooks/" }

    func webhooks() -> Result<[PlaneWebhook], PlaneError> {
        send("GET", hooks).map { obj in
            let rows = ((obj as? [String: Any])?["data"] as? [[String: Any]])
                ?? ((obj as? [String: Any])?["results"] as? [[String: Any]]) ?? (obj as? [[String: Any]]) ?? []
            return rows.compactMap { r in
                guard let id = jsonID(r["id"]), let url = r["url"] as? String else { return nil }
                return PlaneWebhook(id: id, url: url, isActive: r["is_active"] as? Bool ?? false)
            }
        }
    }

    // Returns the hook id and its secret. Plane shows the secret only in this answer.
    func createWebhook(url: String) -> Result<(id: String, secret: String), PlaneError> {
        let body: [String: Any] = ["name": "OverSire relay", "url": url, "is_active": true,
                                   "content_type": "application/json", "scopes": PlaneClient.hookScopes]
        return send("POST", hooks, query: [URLQueryItem(name: "fields", value: "all")], body: body).flatMap { obj in
            let o = obj as? [String: Any] ?? [:]
            guard let id = jsonID(o["id"]), let secret = o["secret_key"] as? String, !secret.isEmpty else {
                return .failure(.http(200, "no secret for the new webhook"))
            }
            return .success((id, secret))
        }
    }

    func deleteWebhook(id: String) -> Result<Void, PlaneError> {
        switch send("DELETE", hooks + "\(id)/") {
        case .success, .failure(.notFound): return .success(())
        case .failure(let e): return .failure(e)
        }
    }

    // MARK: HTTP

    // Follows the cursor until `max` rows or the last page.
    private func list(_ path: String, query: [URLQueryItem] = [], max: Int) -> Result<[[String: Any]], PlaneError> {
        var out: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<20 {
            var q = query + [URLQueryItem(name: "per_page", value: String(min(100, Swift.max(1, max - out.count))))]
            if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
            switch send("GET", path, query: q) {
            case .failure(let e): return .failure(e)
            case .success(let obj):
                if let rows = obj as? [[String: Any]] { return .success(Array((out + rows).prefix(max))) }
                let o = obj as? [String: Any] ?? [:]
                out += o["results"] as? [[String: Any]] ?? []
                guard out.count < max, o["next_page_results"] as? Bool == true, let next = o["next_cursor"] as? String else {
                    return .success(Array(out.prefix(max)))
                }
                cursor = next
            }
        }
        return .success(out)
    }

    // On 429 waits for Retry-After (at most 10 s) and tries again, two times.
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Any? = nil) -> Result<Any?, PlaneError> {
        guard var comps = URLComponents(string: workspace.host.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            return .failure(.network("Bad Plane host: \(workspace.host)"))
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { return .failure(.network("Bad Plane URL")) }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-Api-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("oversire", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        for attempt in 0..<3 {
            let (data, resp, err) = session.syncData(req)
            if let err { return .failure(.network(err.localizedDescription)) }
            guard let http = resp as? HTTPURLResponse else { return .failure(.network("No answer from Plane")) }
            if http.statusCode == 429, attempt < 2 {
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                Thread.sleep(forTimeInterval: min(10, Swift.max(1, wait)))
                continue
            }
            let obj = data.flatMap { $0.isEmpty ? nil : try? JSONSerialization.jsonObject(with: $0) }
            switch http.statusCode {
            case 200..<300: return .success(obj)
            case 401: return .failure(.unauthorized)
            case 403: return .failure(.forbidden)
            case 404: return .failure(.notFound)
            default:
                let o = obj as? [String: Any]
                let text = (o?["detail"] as? String) ?? (o?["error"] as? String) ?? (o?["message"] as? String) ?? ""
                return .failure(.http(http.statusCode, String(text.prefix(160))))
            }
        }
        return .failure(.http(429, "too many requests"))
    }
}

extension URLSession {
    func syncData(_ req: URLRequest) -> (Data?, URLResponse?, Error?) {
        let sem = DispatchSemaphore(value: 0)
        var out: (Data?, URLResponse?, Error?) = (nil, nil, nil)
        dataTask(with: req) { d, r, e in out = (d, r, e); sem.signal() }.resume()
        sem.wait()
        return out
    }
}

// Workspaces from the config and their tokens from the Keychain.
final class PlaneAccounts {
    static let changed = Notification.Name("PlaneAccountsChanged")

    private let secrets: SecretStore
    private var clients: [String: PlaneClient] = [:]

    init(secrets: SecretStore = SecretStore(service: "com.oversire.app.plane")) {
        self.secrets = secrets
    }

    var workspaces: [PlaneWorkspace] { PROJECTS_CFG.workspaces }

    func workspace(_ slug: String) -> PlaneWorkspace? { workspaces.first { $0.slug == slug } }
    func hasToken(_ slug: String) -> Bool { !(token(slug) ?? "").isEmpty }
    private func token(_ slug: String) -> String? { secrets.get("PLANE_TOKEN_\(slug)") }

    func client(for slug: String) -> PlaneClient? {
        guard let w = workspace(slug), let t = token(slug), !t.isEmpty else { return nil }
        if let c = clients[slug], c.workspace == w { return c }
        let c = PlaneClient(workspace: w, token: t)
        clients[slug] = c
        return c
    }

    // Adds the workspace or changes its host and token.
    func save(_ w: PlaneWorkspace, token: String) {
        secrets.set("PLANE_TOKEN_\(w.slug)", token)
        clients[w.slug] = nil
        PROJECTS_CFG.workspaces.removeAll { $0.slug == w.slug }
        PROJECTS_CFG.workspaces.append(w)
        saveConfig()
        NotificationCenter.default.post(name: PlaneAccounts.changed, object: self)
    }

    func remove(_ slug: String) {
        secrets.delete("PLANE_TOKEN_\(slug)")
        clients[slug] = nil
        PROJECTS_CFG.workspaces.removeAll { $0.slug == slug }
        PROJECTS_CFG.allOf.removeAll { $0 == slug }
        PROJECTS_CFG.picked.removeAll { $0.hasPrefix(slug + "/") }
        saveConfig()
        NotificationCenter.default.post(name: PlaneAccounts.changed, object: self)
    }
}

extension ItemPatch {
    var planeFields: [String: Any] {
        var f: [String: Any] = [:]
        if let title { f["name"] = title }
        if let status { f["state"] = status }
        if let priority { f["priority"] = priority }
        if let assignees { f["assignees"] = assignees }
        if let labels { f["labels"] = labels }
        if let parent { f["parent"] = parent }
        if let bodyMarkdown { f["description_html"] = PlaneMarkup.html(fromMarkdown: bodyMarkdown) }
        return f
    }
}

extension ItemDraft {
    var planeFields: [String: Any] {
        var f: [String: Any] = ["name": title]
        if let bodyMarkdown, !bodyMarkdown.isEmpty { f["description_html"] = PlaneMarkup.html(fromMarkdown: bodyMarkdown) }
        if let status { f["state"] = status }
        if let priority { f["priority"] = priority }
        if !labels.isEmpty { f["labels"] = labels }
        if let parent { f["parent"] = parent }
        return f
    }
}
