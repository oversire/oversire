import Foundation
import OverSireCore

/// The Plane adapter. One instance for each workspace, because a token works only in its own workspace.
public final class PlaneTracker: Tracker, IntakeCreating, AttachmentUploading, AttachmentReading, TimelineReading, LabelManaging, LinkManaging, ItemIndexing,
    RelationManaging, AssetResolving, WebhookManaging, ItemSearching, @unchecked Sendable {
    public let id: ProviderID = .plane
    public let account: AccountID
    public let keyFormat = KeyFormat.projectDash
    public var capabilities: Set<Capability> { [.intake, .intakeCreate, .attachments, .attachmentsRead, .timeline, .labels, .links, .relations, .subItems, .assets, .webhooks, .projectSettings, .projectSettingsEdit, .itemSearch] }
    // Plane allows 60 requests a minute.
    public var pollPolicy: PollPolicy { PollPolicy(minInterval: .seconds(60), requestsPerHour: 3600) }
    public var workspace: PlaneWorkspace { api.workspace }

    let api: PlaneAPI
    private let lock = NSLock()
    private var meCache: PersonRef?
    private var memberCache: (people: [PersonDetail], names: [String: String], at: Date)?
    private var identifiers: [String: String] = [:]                    // project id → "ENG"
    private var indexCache: [String: (stubs: [ItemStub], at: Date)] = [:]
    private var itemCache: [String: [String: Item]] = [:]               // project id → the last items
    private var fullAt: [String: Date] = [:]                            // project id → the last full list
    private var refCache: [String: ItemRef] = [:]                       // item id → ref, for relations
    static let fullEvery: TimeInterval = 600
    var indexMaxAge: TimeInterval = 10

    public init(workspace: PlaneWorkspace, token: String, http: any HTTPTransport) {
        api = PlaneAPI(workspace: workspace, token: token, http: http)
        account = AccountID(provider: .plane, id: workspace.slug)
    }

    var ws: String { api.ws }

    // MARK: Provider

    public func probe() async throws -> Identity { Identity(person: try await me()) }

    public func me() async throws -> PersonRef {
        if let m = lock.withLock({ meCache }) { return m }
        let o = try await api.send("GET", "/api/v1/users/me/") as? [String: Any]
        guard let o, let id = PlaneAPI.id(o["id"]) else { throw ProviderError.decoding("no user in the answer") }
        let name = (o["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (o["email"] as? String) ?? id
        let me = PersonRef(id: id, name: name, login: o["display_name"] as? String)
        lock.withLock { meCache = me }
        return me
    }

    /// User id → display name. Kept for one hour. The last names stay on a failure.
    public func memberNames() async -> [String: String] { await members().names }

    /// The people of the workspace, without bots. The display name is the login, as in `me()`.
    public func memberDetails() async -> [PersonDetail] { await members().people }

    private func members() async -> (people: [PersonDetail], names: [String: String]) {
        if let c = lock.withLock({ memberCache }), -c.at.timeIntervalSinceNow < 3600 { return (c.people, c.names) }
        guard let obj = try? await api.send("GET", "\(ws)/members/") else {
            return lock.withLock { (memberCache?.people ?? [], memberCache?.names ?? [:]) }
        }
        let rows = (obj as? [[String: Any]]) ?? ((obj as? [String: Any])?["results"] as? [[String: Any]]) ?? []
        var names: [String: String] = [:], people: [PersonDetail] = []
        for r in rows {
            let u = (r["member"] as? [String: Any]) ?? r
            guard let id = PlaneAPI.id(u["id"]) else { continue }
            let login = (u["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let email = (u["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            names[id] = (u["display_name"] as? String) ?? email ?? id
            if u["is_bot"] as? Bool != true {
                people.append(PersonDetail(id: id, name: login ?? email ?? id, login: login, email: email,
                                           sources: ["\(account.provider.rawValue):\(account.id)"]))
            }
        }
        lock.withLock { memberCache = (people, names, Date()) }
        return (people, names)
    }

    // MARK: Projects and items

    public func projects() async throws -> [ProjectSummary] {
        let rows = try await api.list("\(ws)/projects/", max: 1000)
        let out = rows.compactMap { r -> ProjectSummary? in
            guard let id = PlaneAPI.id(r["id"]), let name = r["name"] as? String else { return nil }
            let identifier = r["identifier"] as? String ?? ""
            return ProjectSummary(ref: ProjectRef(account: account, id: id, key: identifier.isEmpty ? nil : identifier),
                                  identifier: identifier, title: name, url: workspace.projectURL(id),
                                  closed: !(r["archived_at"] is NSNull || r["archived_at"] == nil), logo: Self.logo(r["logo_props"]))
        }
        lock.withLock { for p in out { identifiers[p.ref.id] = p.identifier } }
        return out.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    public func statuses(_ p: ProjectRef) async throws -> [StatusOption] {
        let rows = try await api.list("\(ws)/projects/\(p.id)/states/", max: 200)
        return rows.sorted { (($0["sequence"] as? NSNumber)?.doubleValue ?? 0) < (($1["sequence"] as? NSNumber)?.doubleValue ?? 0) }
            .compactMap { r in
                guard let id = PlaneAPI.id(r["id"]), let name = r["name"] as? String else { return nil }
                return StatusOption(id: id, name: name, color: r["color"] as? String ?? "#9CA3AF", group: r["group"] as? String)
            }
    }

    /// The items with the newest activity, and the parents and sub-items that complete each tree.
    /// Between full lists, the index tells which items changed. Only those load again.
    /// A full list each 10 minutes catches changes that do not move the activity time.
    public func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item] {
        let identifier = try await identifier(of: p)
        let names = await memberNames()
        let (previous, last) = lock.withLock { (itemCache[p.id] ?? [:], fullAt[p.id]) }
        let index = try? await index(p, maxAge: indexMaxAge)
        var rows: [[String: Any]], kept: [Item] = [], loaded: Set<String>
        if let index, !previous.isEmpty, let last, -last.timeIntervalSinceNow < Self.fullEvery {
            var top = Array(index.sorted { ($0.activityAt ?? .distantPast) > ($1.activityAt ?? .distantPast) }.prefix(limit))
            if let since { top = top.filter { ($0.activityAt ?? .distantFuture) >= since } }
            let need = Set(top.filter { $0.activityAt == nil || previous[$0.id]?.activityAt != $0.activityAt }.map(\.id))
            kept = top.compactMap { need.contains($0.id) ? nil : previous[$0.id] }
            // Changed items have the newest activity, so they are near the top of the list.
            let depth = (top.lastIndex { need.contains($0.id) } ?? 0) + 10
            rows = try await load(p, need, depth: depth)
            loaded = Set(top.map(\.id))
        } else {
            let query = [URLQueryItem(name: "expand", value: "assignees,labels"),
                         Self.newestFirst]
            rows = try await api.list("\(ws)/projects/\(p.id)/issues/", query: query, max: limit)
            if let since { rows = rows.filter { (parseISO($0["last_activity_at"] as? String) ?? .distantFuture) >= since } }
            loaded = Set(rows.compactMap { PlaneAPI.id($0["id"]) })
            lock.withLock { fullAt[p.id] = Date() }
        }
        if let index {
            let (extra, reused) = try await treeRows(p, loaded: loaded, index: index, previous: previous)
            rows += extra
            kept += reused
        }
        // A write during the refresh can give one id in a list page and in a tree row.
        let items = ProjectSnapshot.unique(kept + rows.compactMap { parseItem($0, identifier: identifier, names: names) })
        lock.withLock { itemCache[p.id] = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        return items
    }

    public func detail(_ i: ItemRef) async throws -> ItemDetail {
        let names = await memberNames()
        let obj = try await api.send("GET", "\(ws)/projects/\(i.project.id)/issues/\(i.id)/",
                                     query: [URLQueryItem(name: "expand", value: "assignees,labels")])
        guard let r = obj as? [String: Any], let item = parseItem(r, identifier: try await identifier(of: i.project), names: names) else {
            throw ProviderError.decoding("no work item in the answer")
        }
        async let comments = comments(i)
        async let links = links(i)
        return ItemDetail(item: item, comments: try await comments, links: (try? await links) ?? [])
    }

    /// Oldest first.
    public func comments(_ i: ItemRef) async throws -> [Comment] {
        let names = await memberNames()
        let rows = try await api.list("\(ws)/projects/\(i.project.id)/issues/\(i.id)/comments/", max: 500)
        return rows.compactMap { r -> Comment? in
            guard let id = PlaneAPI.id(r["id"]) else { return nil }
            let who = PlaneAPI.id(r["actor"]) ?? PlaneAPI.id(r["created_by"])
            return Comment(id: id, author: who.map { names[$0] ?? $0 }, createdAt: parseISO(r["created_at"] as? String) ?? Date(),
                           url: i.url.absoluteString,
                           body: PlaneMarkup.markdown(fromHTML: r["comment_html"] as? String ?? "") { names[$0] })
        }.sorted { $0.createdAt < $1.createdAt }
    }

    public func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef {
        let o = try await api.send("POST", "\(ws)/projects/\(p.id)/issues/", body: d.planeFields) as? [String: Any]
        guard let o, let id = PlaneAPI.id(o["id"]) else { throw ProviderError.decoding("no id for the new item") }
        let key = "\(try await identifier(of: p))-\(PlaneAPI.int(o["sequence_id"]) ?? 0)"
        return ItemRef(project: p, id: id, key: key, url: URL(string: workspace.itemURL(key))!)
    }

    public func update(_ i: ItemRef, _ patch: ItemPatch) async throws {
        _ = try await api.send("PATCH", "\(ws)/projects/\(i.project.id)/issues/\(i.id)/", body: patch.planeFields)
    }

    public func comment(_ i: ItemRef, markdown: String) async throws {
        _ = try await api.send("POST", "\(ws)/projects/\(i.project.id)/issues/\(i.id)/comments/",
                               body: ["comment_html": PlaneMarkup.html(fromMarkdown: markdown)])
    }

    /// Adds me and keeps the other assignees.
    public func assignMe(_ i: ItemRef) async throws {
        let me = try await me()
        let o = try await api.send("GET", "\(ws)/projects/\(i.project.id)/issues/\(i.id)/") as? [String: Any]
        var ids = (o?["assignees"] as? [Any] ?? []).compactMap { PlaneAPI.id($0) ?? PlaneAPI.id(($0 as? [String: Any])?["id"]) }
        if ids.contains(me.id) { return }
        ids.append(me.id)
        try await update(i, ItemPatch(assignees: ids))
    }

    // MARK: Plane description HTML (for the OverSire block merge)

    public func descriptionHTML(_ i: ItemRef) async throws -> String {
        let o = try await api.send("GET", "\(ws)/projects/\(i.project.id)/issues/\(i.id)/") as? [String: Any]
        return o?["description_html"] as? String ?? ""
    }

    public func setDescription(_ i: ItemRef, html: String) async throws {
        _ = try await api.send("PATCH", "\(ws)/projects/\(i.project.id)/issues/\(i.id)/", body: ["description_html": html])
    }

    public func labelIds(_ i: ItemRef) async throws -> [String] {
        let o = try await api.send("GET", "\(ws)/projects/\(i.project.id)/issues/\(i.id)/") as? [String: Any]
        return (o?["labels"] as? [Any] ?? []).compactMap { PlaneAPI.id($0) ?? PlaneAPI.id(($0 as? [String: Any])?["id"]) }
    }

    // MARK: Index and trees

    /// Kept for 10 s, so a call right after items(...) costs nothing.
    public func index(_ p: ProjectRef) async throws -> [ItemStub] { try await index(p, maxAge: indexMaxAge) }

    /// All items of the project, with only the fields for the tree. About 150 bytes per item.
    func index(_ p: ProjectRef, maxAge: TimeInterval) async throws -> [ItemStub] {
        if let c = lock.withLock({ indexCache[p.id] }), -c.at.timeIntervalSinceNow < maxAge { return c.stubs }
        let q = [URLQueryItem(name: "fields", value: "id,parent,state,last_activity_at")]
        let rows = try await api.list("\(ws)/projects/\(p.id)/issues/", query: q, max: 5000)
        let stubs = rows.compactMap { r in
            PlaneAPI.id(r["id"]).map { ItemStub(id: $0, parentId: PlaneAPI.id(r["parent"]), stateId: PlaneAPI.id(r["state"]),
                                                activityAt: parseISO(r["last_activity_at"] as? String)) }
        }
        lock.withLock { indexCache[p.id] = (stubs, Date()) }
        return stubs
    }

    // The parents and the sub-items of the loaded items, so that each tree is complete.
    // An item that did not change since the last call is kept. A few others load one by one.
    // More load with the full list, which costs one call for each 100 items.
    private func treeRows(_ p: ProjectRef, loaded: Set<String>, index: [ItemStub],
                          previous: [String: Item]) async throws -> (rows: [[String: Any]], kept: [Item]) {
        let byId = Dictionary(index.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let kids = Dictionary(grouping: index.filter { $0.parentId != nil }, by: { $0.parentId! })
        var tree = loaded
        for id in loaded {
            var parent = byId[id]?.parentId
            while let x = parent, !tree.contains(x) { tree.insert(x); parent = byId[x]?.parentId }
        }
        var queue = Array(tree)
        while let id = queue.popLast() {
            for c in kids[id] ?? [] where !tree.contains(c.id) { tree.insert(c.id); queue.append(c.id) }
        }
        var kept: [Item] = [], need: Set<String> = []
        for id in tree.subtracting(loaded) {
            if let prev = previous[id], prev.activityAt == byId[id]?.activityAt { kept.append(prev) } else { need.insert(id) }
        }
        return ((try? await load(p, need, depth: 2000)) ?? [], kept)
    }

    // Plane ignores order_by=-last_activity_at and sorts by creation. It obeys -updated_at.
    static let newestFirst = URLQueryItem(name: "order_by", value: "-updated_at")

    // More than a few items load from the list, `depth` rows deep. The others load one by one.
    // The list order is not the activity order, so an item can be below `depth`. It then loads alone.
    private func load(_ p: ProjectRef, _ need: Set<String>, depth: Int) async throws -> [[String: Any]] {
        if need.isEmpty { return [] }
        let expand = URLQueryItem(name: "expand", value: "assignees,labels")
        var rows: [[String: Any]] = []
        if need.count > 3 {
            let all = try await api.list("\(ws)/projects/\(p.id)/issues/", query: [expand, Self.newestFirst], max: depth)
            rows = all.filter { PlaneAPI.id($0["id"]).map(need.contains) ?? false }
        }
        for id in need.subtracting(rows.compactMap { PlaneAPI.id($0["id"]) }).sorted() {
            if let r = try? await api.send("GET", "\(ws)/projects/\(p.id)/issues/\(id)/", query: [expand]) as? [String: Any] {
                rows.append(r)
            }
        }
        return rows
    }

    private func identifier(of p: ProjectRef) async throws -> String {
        if let k = p.key ?? lock.withLock({ identifiers[p.id] }) { return k }
        let o = try await api.send("GET", "\(ws)/projects/\(p.id)/") as? [String: Any]
        let k = o?["identifier"] as? String ?? ""
        lock.withLock { identifiers[p.id] = k }
        return k
    }

    func parseItem(_ r: [String: Any], identifier: String, names: [String: String]) -> Item? {
        guard let id = PlaneAPI.id(r["id"]), let title = r["name"] as? String else { return nil }
        if let a = r["archived_at"], !(a is NSNull) { return nil }
        let key = "\(identifier)-\(PlaneAPI.int(r["sequence_id"]) ?? 0)"
        func person(_ v: Any?) -> String? {
            if let o = v as? [String: Any] { return (o["display_name"] as? String) ?? PlaneAPI.id(o["id"]).flatMap { names[$0] } }
            return PlaneAPI.id(v).map { names[$0] ?? $0 }
        }
        let state = (r["state"] as? [String: Any]).flatMap { PlaneAPI.id($0["id"]) } ?? PlaneAPI.id(r["state"])
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
                    parentId: PlaneAPI.id(r["parent"]) ?? PlaneAPI.id((r["parent"] as? [String: Any])?["id"]))
    }

    // MARK: Intake

    /// Pending intake items. Only v2 can filter by status.
    public func intake(_ p: ProjectRef) async throws -> [IntakeItem] {
        let names = await memberNames()
        let q = [URLQueryItem(name: "status", value: "-2"), URLQueryItem(name: "per_page", value: "100"),
                 URLQueryItem(name: "fields", value: "id,name,priority,work_item_id,created_at,created_by_id,source")]
        let obj = try await api.send("GET", "/api/v2/workspaces/\(workspace.slug)/projects/\(p.id)/intake-issues/", query: q)
        let rows = (obj as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return rows.compactMap { r in
            guard let id = PlaneAPI.id(r["id"]), let item = PlaneAPI.id(r["work_item_id"]) else { return nil }
            return IntakeItem(id: id, workItemId: item, name: r["name"] as? String ?? "Untitled",
                              priority: (r["priority"] as? String).flatMap { $0 == "none" ? nil : $0.capitalized },
                              createdAt: parseISO(r["created_at"] as? String) ?? Date(),
                              author: PlaneAPI.id(r["created_by_id"]).map { names[$0] ?? $0 },
                              source: r["source"] as? String)
        }
    }

    // The work item endpoints do not return pending items.
    public func intakeDetail(_ i: IntakeItem, in p: ProjectRef) async throws -> IntakeDetail {
        let names = await memberNames()
        let obj = try await api.send("GET", "\(ws)/projects/\(p.id)/intake-issues/\(i.workItemId)/")
        let d = (obj as? [String: Any])?["issue_detail"] as? [String: Any] ?? [:]
        let body = PlaneMarkup.markdown(fromHTML: d["description_html"] as? String ?? "") { names[$0] }
        return IntakeDetail(sequence: d["sequence_id"] as? Int, body: body,
                            labels: (d["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
    }

    /// Only v1 gives the new work item with its sequence number.
    public func createIntake(_ d: ItemDraft, in p: ProjectRef) async throws -> (item: ItemRef, intake: IntakeItem) {
        let o: [String: Any]?
        do {
            o = try await api.send("POST", "\(ws)/projects/\(p.id)/intake-issues/", body: ["issue": d.planeFields]) as? [String: Any]
        } catch {
            // Plane gives no clear error when the intake is off. The project tells.
            if let proj = try? await api.send("GET", "\(ws)/projects/\(p.id)/") as? [String: Any], proj["intake_view"] as? Bool == false {
                let key = proj["identifier"] as? String ?? p.key ?? "the project"
                throw ProviderError.vendor(code: ProviderError.intakeOff, message: "Intake is off for \(key) in Plane.")
            }
            throw error
        }
        let issue = o?["issue_detail"] as? [String: Any] ?? [:]
        guard let o, let id = PlaneAPI.id(o["id"]), let work = PlaneAPI.id(o["issue"]) ?? PlaneAPI.id(issue["id"]) else {
            throw ProviderError.decoding("no id for the new intake item")
        }
        let key = "\(try await identifier(of: p))-\(PlaneAPI.int(issue["sequence_id"]) ?? 0)"
        let ref = ItemRef(project: p, id: work, key: key, url: URL(string: workspace.itemURL(key))!)
        let intake = IntakeItem(id: id, workItemId: work, name: issue["name"] as? String ?? d.title, priority: nil,
                                createdAt: parseISO(o["created_at"] as? String) ?? Date(), author: nil, source: o["source"] as? String)
        return (ref, intake)
    }

    // The plain update endpoint refuses a status change, so status changes use /status/.
    public func triage(_ i: IntakeItem, in p: ProjectRef, _ a: IntakeAction) async throws {
        let path = "\(ws)/projects/\(p.id)/intake-issues/\(i.workItemId)/"
        switch a {
        case .delete: _ = try await api.send("DELETE", path)
        case .update(let e):
            let ref = ItemRef(project: p, id: i.workItemId, key: p.key ?? "", url: URL(string: workspace.itemURL(p.key ?? ""))!)
            if e.patch != ItemPatch() { try await update(ref, e.patch) }
            if !e.relations.isEmpty { try await apply(RelationPatch(add: e.relations), to: ref) }
        default: if let body = a.planeBody { _ = try await api.send("PATCH", path + "status/", body: body) }
        }
    }

    public func intakeHTML(_ p: ProjectRef, workItem: String) async throws -> String {
        let obj = try await api.send("GET", "\(ws)/projects/\(p.id)/intake-issues/\(workItem)/")
        return ((obj as? [String: Any])?["issue_detail"] as? [String: Any])?["description_html"] as? String ?? ""
    }

    public func setIntakeDescription(_ p: ProjectRef, workItem: String, html: String) async throws {
        _ = try await api.send("PATCH", "\(ws)/projects/\(p.id)/intake-issues/\(workItem)/", body: ["issue": ["description_html": html]])
    }

    /// Work item id → sequence number, for all intake items. Only v1 has the number, in the full work item.
    public func intakeSequences(_ p: ProjectRef) async throws -> [String: Int] {
        let q = [URLQueryItem(name: "fields", value: "issue,issue_detail")]
        var out: [String: Int] = [:]
        for r in try await api.list("\(ws)/projects/\(p.id)/intake-issues/", query: q, max: 2000) {
            if let id = PlaneAPI.id(r["issue"]), let n = (r["issue_detail"] as? [String: Any])?["sequence_id"] as? Int { out[id] = n }
        }
        return out
    }

    /// Work item id → detail, for the pending intake items. A row with no description_html is left out: read it with intakeDetail.
    public func intakeDetails(_ p: ProjectRef) async throws -> [String: IntakeDetail] {
        let names = await memberNames()
        let q = [URLQueryItem(name: "fields", value: "issue,status,issue_detail")]
        let rows = try await api.list("\(ws)/projects/\(p.id)/intake-issues/", query: q, max: 2000).filter { PlaneAPI.int($0["status"]) == -2 }
        // The listing gives label ids.
        let labelNames = rows.isEmpty ? [:] : Dictionary(((try? await labels(p)) ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        var out: [String: IntakeDetail] = [:]
        for r in rows {
            guard let id = PlaneAPI.id(r["issue"]), let d = r["issue_detail"] as? [String: Any], let html = d["description_html"] as? String else { continue }
            out[id] = IntakeDetail(sequence: d["sequence_id"] as? Int, body: PlaneMarkup.markdown(fromHTML: html) { names[$0] },
                                   labels: (d["labels"] as? [String] ?? []).compactMap { labelNames[$0] })
        }
        return out
    }

    // MARK: Timeline

    public func timeline(_ i: ItemRef) async throws -> [ActivityEntry] {
        try await timeline(i, statuses: statuses(i.project), current: nil)
    }

    /// Activities and comments of one item, newest last.
    /// current: the status now. Plane often leaves out the new status of a change, so the next change or this fills it.
    public func timeline(_ i: ItemRef, statuses: [StatusOption], current: String?) async throws -> [ActivityEntry] {
        let names = await memberNames()
        let url = i.url.absoluteString
        let rows = try await api.list("\(ws)/projects/\(i.project.id)/issues/\(i.id)/activities/", max: 200)
        var out = rows.compactMap { r -> ActivityEntry? in
            guard let change = Self.change(r, names: names, states: statuses) else { return nil }
            let actor = PlaneAPI.id(r["actor"]).map { names[$0] ?? $0 }
            return ActivityEntry.make(projectKey: "", itemId: i.id, change: change, actor: actor, url: url,
                                      at: parseISO(r["created_at"] as? String) ?? Date())
        }
        out.sort { $0.at < $1.at }
        var next = current
        for n in out.indices.reversed() {
            guard case .status(let from, let to) = out[n].change else { continue }
            if to == nil, let next {
                let e = out[n]
                out[n] = ActivityEntry.make(projectKey: e.projectKey, itemId: e.itemId, change: .status(from: from, to: next),
                                            actor: e.actor, url: e.url, at: e.at)
            }
            next = from
        }
        if let list = try? await comments(i) {
            out += list.map { ActivityEntry.make(projectKey: "", itemId: i.id, change: .comments(new: 1, last: $0),
                                                 actor: $0.author, url: url, at: $0.createdAt) }
        }
        return out.sorted { $0.at < $1.at }
    }

    public static func change(_ r: [String: Any], names: [String: String], states: [StatusOption]) -> ItemChange? {
        let verb = r["verb"] as? String ?? ""
        let field = r["field"] as? String
        func value(_ v: String, _ ident: String) -> String? {
            if let text = (r[v] as? String).flatMap({ $0.isEmpty ? nil : $0 }) { return text }
            guard let id = PlaneAPI.id(r[ident]) else { return nil }
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

    // MARK: Relations

    /// Plane type → OverSire kind. Plane also has the start and finish dates; OverSire drops them.
    static let relationKinds: [String: RelationKind] = ["blocked_by": .blockedBy, "blocking": .blocks, "relates_to": .relatesTo, "duplicate": .duplicate]

    public func relations(of item: ItemRef) async throws -> [ItemRelation] {
        let o = try await api.send("GET", "\(ws)/projects/\(item.project.id)/work-items/\(item.id)/relations/") as? [String: Any] ?? [:]
        var out: [ItemRelation] = []
        for (type, kind) in Self.relationKinds.sorted(by: { $0.key < $1.key }) {
            for id in (o[type] as? [Any] ?? []).compactMap(PlaneAPI.id) {
                if let ref = try await ref(id, near: item.project) { out.append(ItemRelation(kind: kind, item: ref)) }
            }
        }
        return out
    }

    /// Adds before it removes. Plane removes a relation by the other item only.
    public func apply(_ patch: RelationPatch, to item: ItemRef) async throws {
        let path = "\(ws)/projects/\(item.project.id)/work-items/\(item.id)/relations/"
        let types = Dictionary(Self.relationKinds.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        for (kind, rels) in Dictionary(grouping: patch.add, by: \.kind).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let type = types[kind] else { throw ProviderError.unsupported(.relations) }
            _ = try await api.send("POST", path, body: ["relation_type": type, "issues": rels.map(\.item.id)])
        }
        for id in Set(patch.remove.map(\.item.id)).sorted() {
            _ = try await api.send("POST", path + "remove/", body: ["related_issue": id])
        }
    }

    // The list gives ids only. A key comes from the last items, or from one GET. An item of another project is nil.
    private func ref(_ id: String, near p: ProjectRef) async throws -> ItemRef? {
        let known: ItemRef? = lock.withLock {
            if let r = refCache[id] { return r }
            for (pid, items) in itemCache {
                guard let i = items[id] else { continue }
                let project = pid == p.id ? p : ProjectRef(account: account, id: pid, key: identifiers[pid])
                return ItemRef(project: project, id: i.id, key: i.key, url: URL(string: workspace.itemURL(i.key))!)
            }
            return nil
        }
        if let known { return known }
        let o: [String: Any]?
        do {
            o = try await api.send("GET", "\(ws)/projects/\(p.id)/work-items/\(id)/",
                                   query: [URLQueryItem(name: "fields", value: "id,sequence_id")]) as? [String: Any]
        } catch ProviderError.notFound { return nil }
        guard let seq = PlaneAPI.int(o?["sequence_id"]) else { return nil }
        let key = "\(try await identifier(of: p))-\(seq)"
        let ref = ItemRef(project: p, id: id, key: key, url: URL(string: workspace.itemURL(key))!)
        lock.withLock { refCache[id] = ref }
        return ref
    }

    // MARK: Search

    /// Plane matches the name, the key and the description. A hit has only the id, the name and the key.
    /// An item in the item cache comes back in full. Another hit has no status, no people and the date distantPast.
    public func search(_ query: String, in projects: [ProjectRef]?, limit: Int) async throws -> [Item] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, limit > 0, projects?.isEmpty != true else { return [] }
        var q = [URLQueryItem(name: "search", value: text)]
        let only = projects.map { Set($0.map(\.id)) }
        if let only, only.count == 1 {
            q += [URLQueryItem(name: "project_id", value: only.first), URLQueryItem(name: "workspace_search", value: "false"),
                  URLQueryItem(name: "limit", value: String(limit))]
        } else {
            // Many projects: search the workspace and filter. More rows leave room for the filter.
            q += [URLQueryItem(name: "workspace_search", value: "true"),
                  URLQueryItem(name: "limit", value: String(only == nil ? limit : max(limit, 50)))]
        }
        let obj = try await api.send("GET", "\(ws)/work-items/search/", query: q)
        var out: [Item] = []
        for r in (obj as? [String: Any])?["issues"] as? [[String: Any]] ?? [] where out.count < limit {
            guard let id = PlaneAPI.id(r["id"]), let pid = PlaneAPI.id(r["project_id"]), only?.contains(pid) != false,
                  let seq = PlaneAPI.int(r["sequence_id"]) else { continue }
            let identifier = r["project__identifier"] as? String ?? ""
            let cached: Item? = lock.withLock {
                if !identifier.isEmpty { identifiers[pid] = identifier }
                return itemCache[pid]?[id]
            }
            if let cached {
                out.append(cached)
                continue
            }
            let key = "\(identifier)-\(seq)"
            out.append(Item(id: id, key: key, title: r["name"] as? String ?? key, url: workspace.itemURL(key), statusOptionId: nil,
                            fields: [:], assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: .distantPast,
                            activityAt: .distantPast, commentCount: 0, lastComment: nil, mentionsMe: false))
        }
        return out
    }

    // MARK: Labels, links, assets

    public func labels(_ p: ProjectRef) async throws -> [StatusOption] {
        try await api.list("\(ws)/projects/\(p.id)/labels/", max: 500).compactMap { r in
            guard let id = PlaneAPI.id(r["id"]), let name = r["name"] as? String else { return nil }
            return StatusOption(id: id, name: name, color: r["color"] as? String ?? "#9CA3AF")
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func createLabel(_ name: String, color: String, in p: ProjectRef) async throws -> String {
        let o = try await api.send("POST", "\(ws)/projects/\(p.id)/labels/", body: ["name": name, "color": color]) as? [String: Any]
        guard let id = PlaneAPI.id(o?["id"]) else { throw ProviderError.decoding("no id for the new label") }
        return id
    }

    public func links(_ i: ItemRef) async throws -> [URL] {
        try await api.list("\(ws)/projects/\(i.project.id)/issues/\(i.id)/links/", max: 200)
            .compactMap { ($0["url"] as? String).flatMap(URL.init(string:)) }
    }

    public func addLink(_ i: ItemRef, url: URL, title: String) async throws {
        _ = try await api.send("POST", "\(ws)/projects/\(i.project.id)/issues/\(i.id)/links/",
                               body: ["url": url.absoluteString, "title": title])
    }

    /// Three steps: Plane gives a presigned storage form, the file goes to storage, then Plane marks it as uploaded.
    /// A description asset does not link to the item, so this uses the attachment endpoints.
    public func attach(_ f: AttachmentUpload, to i: ItemRef) async throws -> String {
        let path = "/api/v2/workspaces/\(workspace.slug)/projects/\(i.project.id)/work-items/\(i.id)/attachments/"
        let o = try await api.send("POST", path, body: ["name": f.name, "size": f.data.count, "type": f.mimeType]) as? [String: Any]
        let form = o?["upload_data"] as? [String: Any]
        guard let id = PlaneAPI.id(o?["asset_id"]) ?? PlaneAPI.id((o?["attachment"] as? [String: Any])?["id"]),
              let url = (form?["url"] as? String).flatMap(URL.init(string:)) else {
            throw ProviderError.decoding("no upload form for \(f.name)")
        }
        let fields = (form?["fields"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
        try await api.upload(f, to: url, fields: fields)
        _ = try await api.send("PATCH", path + "\(id)/", body: ["is_uploaded": true])
        return id
    }

    public func attachments(of i: ItemRef) async throws -> [ItemAttachment] {
        let path = "/api/v2/workspaces/\(workspace.slug)/projects/\(i.project.id)/work-items/\(i.id)/attachments/"
        let obj = try await api.send("GET", path, query: [URLQueryItem(name: "per_page", value: "100")])
        let rows = ((obj as? [String: Any])?["data"] as? [[String: Any]])
            ?? ((obj as? [String: Any])?["results"] as? [[String: Any]]) ?? (obj as? [[String: Any]]) ?? []
        return rows.compactMap { r -> ItemAttachment? in
            let attrs = r["attributes"] as? [String: Any] ?? [:]
            guard r["is_uploaded"] as? Bool != false, let id = PlaneAPI.id(r["id"]),
                  let name = r["name"] as? String ?? attrs["name"] as? String else { return nil }
            return ItemAttachment(id: id, name: name, size: PlaneAPI.int(r["size"]) ?? PlaneAPI.int(attrs["size"]) ?? 0,
                                  mimeType: r["content_type"] as? String ?? attrs["type"] as? String ?? "application/octet-stream",
                                  createdAt: parseISO(r["created_at"] as? String) ?? .distantPast)
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    /// The asset route also signs an attachment id.
    public func attachmentURL(_ a: ItemAttachment, of i: ItemRef) async throws -> URL { try await assetURL(a.id) }

    /// A signed download link for an uploaded file. It is good for one hour.
    public func assetURL(_ id: String) async throws -> URL {
        let o = try await api.send("GET", "\(ws)/assets/\(id)/") as? [String: Any]
        guard let u = (o?["asset_url"] as? String).flatMap(URL.init(string:)) else { throw ProviderError.notFound }
        return u
    }

    // MARK: Webhooks (v2, workspace admin only)

    // Plane takes exact event names, not globs.
    static let hookScopes = ["project.created", "project.updated", "project.archived", "project.deleted",
                             "workitem.created", "workitem.updated", "workitem.archived", "workitem.deleted",
                             "workitem.comment.created", "workitem.comment.updated", "workitem.comment.deleted"]

    private var hooks: String { "/api/v2/workspaces/\(workspace.slug)/webhooks/" }

    public func webhooks() async throws -> [WebhookRegistration] {
        let obj = try await api.send("GET", hooks)
        let rows = ((obj as? [String: Any])?["data"] as? [[String: Any]])
            ?? ((obj as? [String: Any])?["results"] as? [[String: Any]]) ?? (obj as? [[String: Any]]) ?? []
        return rows.compactMap { r in
            guard let id = PlaneAPI.id(r["id"]), let url = (r["url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return WebhookRegistration(id: id, url: url, active: r["is_active"] as? Bool ?? false)
        }
    }

    /// Plane shows the secret only in this answer.
    public func register(url: URL) async throws -> WebhookRegistration {
        let body: [String: Any] = ["name": "OverSire relay", "url": url.absoluteString, "is_active": true,
                                   "content_type": "application/json", "scopes": Self.hookScopes]
        let o = try await api.send("POST", hooks, query: [URLQueryItem(name: "fields", value: "all")], body: body) as? [String: Any]
        guard let id = PlaneAPI.id(o?["id"]), let secret = o?["secret_key"] as? String, !secret.isEmpty else {
            throw ProviderError.decoding("no secret for the new webhook")
        }
        return WebhookRegistration(id: id, url: url, secret: secret)
    }

    public func unregister(_ id: String) async throws {
        do { _ = try await api.send("DELETE", hooks + "\(id)/") } catch ProviderError.notFound {}
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
        if let parent { f["parent"] = parent.isEmpty ? NSNull() : parent }
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

extension IntakeAction {
    // The body for the status endpoint. Delete has its own endpoint.
    var planeBody: [String: Any]? {
        switch self {
        case .accept: return ["status": 1]
        case .decline: return ["status": -1]
        case .snooze(let d): return ["status": 0, "snoozed_till": ISO8601DateFormatter().string(from: d)]
        case .duplicate(let id): return ["status": 2, "duplicate_to": id]
        case .pending: return ["status": -2]
        case .delete, .update: return nil
        }
    }
}
