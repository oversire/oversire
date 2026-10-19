import Foundation

// ─── Tracker model ───────────────────────────────────────────────────────────
// Account → project → item. Snapshots are local. The store diffs two snapshots
// to build the activity feed.

public struct ProjectSummary: Codable, Hashable, Sendable {
    public let ref: ProjectRef
    public let identifier: String    // "ENG"
    public let title: String
    public let url: String
    public let closed: Bool          // archived
    public var logo: ProjectLogo? = nil

    public init(ref: ProjectRef, identifier: String, title: String, url: String, closed: Bool, logo: ProjectLogo? = nil) {
        self.ref = ref
        self.identifier = identifier
        self.title = title
        self.url = url
        self.closed = closed
        self.logo = logo
    }
}

public enum StatusCategory: String, Codable, CaseIterable, Sendable {
    case todo, progress, review, blocked, done

    public var label: String {
        switch self {
        case .todo: return "Todo"
        case .progress: return "In progress"
        case .review: return "In review"
        case .blocked: return "Blocked"
        case .done: return "Done"
        }
    }

    // List order: active work first, done last.
    public var rank: Int {
        switch self {
        case .progress: return 0
        case .review: return 1
        case .blocked: return 2
        case .todo: return 3
        case .done: return 4
        }
    }
}

// A status, or an option of another single-select field (Priority).
public struct StatusOption: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let color: String         // "#F59E0B" or a GitHub-style name
    public var group: String? = nil  // Plane state group: backlog, unstarted, started, completed, cancelled
    /// A category that the user set for this status. It is not part of the wire format.
    public var localCategory: StatusCategory? = nil

    private enum CodingKeys: String, CodingKey { case id, name, color, group }

    public init(id: String, name: String, color: String, group: String? = nil) {
        self.id = id
        self.name = name
        self.color = color
        self.group = group
    }

    // Urgent first, None last.
    public static let priorities: [StatusOption] = [
        StatusOption(id: "urgent", name: "Urgent", color: "#EF4444"),
        StatusOption(id: "high", name: "High", color: "#F97316"),
        StatusOption(id: "medium", name: "Medium", color: "#EAB308"),
        StatusOption(id: "low", name: "Low", color: "#3B82F6"),
        StatusOption(id: "none", name: "None", color: "#9CA3AF"),
    ]

    public var category: StatusCategory { localCategory ?? autoCategory }

    // The group decides first. The name splits "started" into review and blocked.
    public var autoCategory: StatusCategory {
        let n = name.lowercased()
        switch group {
        case "completed", "cancelled": return .done
        case "backlog", "unstarted": return .todo
        case "started":
            if n.contains("block") { return .blocked }
            if n.contains("review") { return .review }
            return .progress
        default:
            if n.contains("done") || n.contains("closed") || n.contains("shipped") { return .done }
            if n.contains("block") { return .blocked }
            if n.contains("review") { return .review }
            if n.contains("progress") || n.contains("doing") { return .progress }
            return .todo
        }
    }
}

public struct Comment: Codable, Hashable, Sendable {
    public let id: String
    public let author: String?
    public let createdAt: Date
    public let url: String
    public var body: String? = nil

    public init(id: String, author: String?, createdAt: Date, url: String, body: String? = nil) {
        self.id = id
        self.author = author
        self.createdAt = createdAt
        self.url = url
        self.body = body
    }
}

public struct Item: Codable, Hashable, Sendable {
    public let id: String
    public let key: String           // "ENG-123"
    public let title: String
    public let url: String
    public let statusOptionId: String?
    public let fields: [String: String]
    public let assignees: [String]
    public let labels: [String]
    public let author: String?
    public let updatedBy: String?
    public let updatedAt: Date
    public let activityAt: Date      // A comment changes it, updatedAt stays.
    public var commentCount: Int
    public var lastComment: Comment?
    public var mentionsMe: Bool
    public var body: String? = nil   // Markdown
    public var parentId: String? = nil

    public init(id: String, key: String, title: String, url: String, statusOptionId: String?, fields: [String: String],
                assignees: [String], labels: [String], author: String?, updatedBy: String?, updatedAt: Date, activityAt: Date,
                commentCount: Int, lastComment: Comment?, mentionsMe: Bool, body: String? = nil, parentId: String? = nil) {
        self.id = id
        self.key = key
        self.title = title
        self.url = url
        self.statusOptionId = statusOptionId
        self.fields = fields
        self.assignees = assignees
        self.labels = labels
        self.author = author
        self.updatedBy = updatedBy
        self.updatedAt = updatedAt
        self.activityAt = activityAt
        self.commentCount = commentCount
        self.lastComment = lastComment
        self.mentionsMe = mentionsMe
        self.body = body
        self.parentId = parentId
    }

    public func isMine(_ me: String?) -> Bool {
        guard let me = me?.lowercased(), !me.isEmpty else { return false }
        if author?.lowercased() == me { return true }
        return assignees.contains { $0.lowercased() == me }
    }

    // Markdown for a coding agent: title, facts, link, description, comments (oldest first).
    public func agentMarkdown(snap: ProjectSnapshot, comments: [Comment]) -> String {
        var facts = ["Project: \(snap.summary.ref.account.id)/\(snap.summary.title)", "Work item: \(key)"]
        facts.append("Status: \(snap.statusName(statusOptionId) ?? "None")")
        for (k, v) in fields.sorted(by: { $0.key < $1.key }) where k != "Status" && k != "Title" { facts.append("\(k): \(v)") }
        if !labels.isEmpty { facts.append("Labels: " + labels.joined(separator: ", ")) }
        if !assignees.isEmpty { facts.append("Assignees: " + assignees.map { "@" + $0 }.joined(separator: ", ")) }
        var out = "# \(title)\n\n" + facts.joined(separator: " · ") + "\n" + url + "\n"
        let text = (body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        out += "\n" + (text.isEmpty ? "_No description_" : text) + "\n\n## Comments\n"
        if comments.isEmpty { return out + "_None_\n" }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(identifier: "UTC")
        df.dateFormat = "yyyy-MM-dd"
        for c in comments.sorted(by: { $0.createdAt < $1.createdAt }) {
            let lines = (c.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
            out += "- @\(c.author ?? "someone") (\(df.string(from: c.createdAt))): " + lines.joined(separator: "\n  ") + "\n"
        }
        return out
    }

    // Case-insensitive match on the key, the title and the body. An empty query matches all.
    public func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return key.localizedCaseInsensitiveContains(q) || title.localizedCaseInsensitiveContains(q)
            || (body ?? "").localizedCaseInsensitiveContains(q)
    }
}

// One entry for each item of the project, also for the items that the snapshot does not load.
public struct ItemStub: Codable, Hashable, Sendable {
    public let id: String
    public let parentId: String?
    public let stateId: String?
    public let activityAt: Date?

    public init(id: String, parentId: String?, stateId: String?, activityAt: Date?) {
        self.id = id
        self.parentId = parentId
        self.stateId = stateId
        self.activityAt = activityAt
    }
}

// A single-select field of a project: Status or Priority.
public struct ProjectField: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let options: [StatusOption]

    public init(id: String, name: String, options: [StatusOption]) {
        self.id = id
        self.name = name
        self.options = options
    }
}

public struct ProjectSnapshot: Codable, Sendable {
    public static let statusFieldId = "state"
    public static let priorityFieldId = "priority"

    public let summary: ProjectSummary
    public var statusOptions: [StatusOption]
    public let items: [Item]
    public let fetchedAt: Date
    public var fields: [ProjectField] = []
    public var me: String? = nil     // display name of the token owner
    public var meId: String? = nil
    public var index: [ItemStub]? = nil
    public var intake: [IntakeItem]? = nil   // pending intake items; nil when the project has no intake

    public init(summary: ProjectSummary, statusOptions: [StatusOption], items: [Item], fetchedAt: Date,
                fields: [ProjectField] = [], me: String? = nil, meId: String? = nil,
                index: [ItemStub]? = nil, intake: [IntakeItem]? = nil) {
        self.summary = summary
        self.statusOptions = statusOptions
        self.items = ProjectSnapshot.unique(items)
        self.fetchedAt = fetchedAt
        self.fields = fields
        self.me = me
        self.meId = meId
        self.index = index
        self.intake = intake
    }

    private enum CodingKeys: String, CodingKey { case summary, statusOptions, items, fetchedAt, fields, me, meId, index, intake }

    // A saved snapshot from an older version can hold one id two times.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(summary: try c.decode(ProjectSummary.self, forKey: .summary),
                  statusOptions: try c.decode([StatusOption].self, forKey: .statusOptions),
                  items: try c.decode([Item].self, forKey: .items),
                  fetchedAt: try c.decode(Date.self, forKey: .fetchedAt),
                  fields: try c.decodeIfPresent([ProjectField].self, forKey: .fields) ?? [],
                  me: try c.decodeIfPresent(String.self, forKey: .me),
                  meId: try c.decodeIfPresent(String.self, forKey: .meId),
                  index: try c.decodeIfPresent([ItemStub].self, forKey: .index),
                  intake: try c.decodeIfPresent([IntakeItem].self, forKey: .intake))
    }

    public var statusFieldId: String? { statusOptions.isEmpty ? nil : ProjectSnapshot.statusFieldId }

    // The number on a folded header.
    public func notDoneCount(_ list: [Item]) -> Int { list.filter { option($0.statusOptionId)?.category != .done }.count }

    public func counts(_ list: [Item]) -> [StatusCategory: Int] {
        var c: [StatusCategory: Int] = [:]
        for item in list {
            let cat = option(item.statusOptionId)?.category ?? .todo
            c[cat, default: 0] += 1
        }
        return c
    }

    public func option(_ id: String?) -> StatusOption? { statusOptions.first { $0.id == id } }
    public func statusName(_ id: String?) -> String? { option(id)?.name }

    // Items without a parent, and sub-items whose parent is not loaded.
    public var rootItems: [Item] {
        let ids = Set(items.map(\.id))
        return items.filter { $0.parentId.map { !ids.contains($0) } ?? true }
    }

    public func listed(subItems: Bool) -> [Item] { subItems ? items : rootItems }

    public func children(of id: String) -> [Item] { sorted(items.filter { $0.parentId == id }) }

    // Direct sub-items. The index counts also the sub-items that are not loaded.
    public func progress(of id: String) -> (done: Int, total: Int) {
        let states = index.map { $0.filter { $0.parentId == id }.map(\.stateId) }
            ?? items.filter { $0.parentId == id }.map(\.statusOptionId)
        return (states.filter { option($0)?.category == .done }.count, states.count)
    }

    // Parent first, up to the root.
    public func ancestors(of id: String) -> [String] {
        var out: [String] = []
        var next = items.first { $0.id == id }?.parentId
        while let p = next, !out.contains(p), let item = items.first(where: { $0.id == p }) {
            out.append(p)
            next = item.parentId
        }
        return out
    }

    public var sortedItems: [Item] { sorted(items) }

    /// One item for each id, the one with the newest activity. On a tie the later copy wins. The first position stays.
    public static func unique(_ list: [Item]) -> [Item] {
        var at: [String: Int] = [:]
        var out: [Item] = []
        for i in list {
            if let n = at[i.id] {
                if i.activityAt >= out[n].activityAt { out[n] = i }
            } else {
                at[i.id] = out.count
                out.append(i)
            }
        }
        return out
    }

    /// The order in a status group: Done items by the last change, newest first. Other items as `sorted`.
    public func groupSorted(_ list: [Item]) -> [Item] {
        let done = list.filter { option($0.statusOptionId)?.category == .done }.sorted { $0.updatedAt > $1.updatedAt }
        return sorted(list.filter { option($0.statusOptionId)?.category != .done }) + done
    }

    /// A Done item hides when it did not change for `afterDays` days. 0 never hides, -1 always hides.
    public func isHiddenDone(_ item: Item, afterDays days: Int, now: Date = Date()) -> Bool {
        guard days != 0, option(item.statusOptionId)?.category == .done else { return false }
        return days < 0 || now.timeIntervalSince(item.updatedAt) > Double(days) * 86400
    }

    // Status rank, then priority (Urgent first, none last), then title A to Z.
    public func sorted(_ list: [Item]) -> [Item] {
        func rank(_ i: Item) -> Int { (option(i.statusOptionId)?.category ?? .todo).rank }
        func priority(_ i: Item) -> Int {
            StatusOption.priorities.firstIndex { $0.name == i.fields["Priority"] } ?? StatusOption.priorities.count
        }
        return list.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            if ra != rb { return ra < rb }
            let (pa, pb) = (priority(a), priority(b))
            if pa != pb { return pa < pb }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }
}

public enum ItemChange: Codable, Hashable, Sendable {
    case added, removed, closed, reopened, mention
    case status(from: String?, to: String?)
    case field(name: String, from: String?, to: String?)
    case assigned(String), unassigned(String)
    case comments(new: Int, last: Comment)

    public var text: String {
        switch self {
        case .added: return "Added"
        case .removed: return "Removed"
        case .closed: return "Closed"
        case .reopened: return "Reopened"
        case .mention: return "Mentioned you"
        case .status(let from, let to):
            if let to, from == to { return "Status: \(to) (set again)" }
            return "Status: \(from ?? "none") → \(to ?? "none")"
        case .field(let name, let from, let to): return "\(name): \(from ?? "none") → \(to ?? "none")"
        case .assigned(let u): return "Assigned \(u)"
        case .unassigned(let u): return "Unassigned \(u)"
        case .comments(let n, let last):
            let who = last.author ?? "someone"
            return n == 1 ? "New comment by \(who)" : "\(n) new comments"
        }
    }

    // Comment author, when the change itself names one. Used to skip the user's own comments.
    public var commentAuthor: String? {
        if case .comments(_, let last) = self { return last.author }
        return nil
    }
}

public struct ActivityEntry: Codable, Hashable, Sendable {
    public let id: String
    public var projectKey: String
    public var itemId: String
    public let change: ItemChange
    public let actor: String?
    public let text: String
    public let url: String
    public let at: Date
    public var unread: Bool

    public init(id: String, projectKey: String, itemId: String, change: ItemChange, actor: String?,
                text: String, url: String, at: Date, unread: Bool) {
        self.id = id
        self.projectKey = projectKey
        self.itemId = itemId
        self.change = change
        self.actor = actor
        self.text = text
        self.url = url
        self.at = at
        self.unread = unread
    }

    public static func make(projectKey: String, itemId: String, change: ItemChange, actor: String?, url: String, at: Date) -> ActivityEntry {
        let id = "\(projectKey)|\(itemId)|\(change.text)|\(Int(at.timeIntervalSince1970))"
        return ActivityEntry(id: id, projectKey: projectKey, itemId: itemId, change: change,
                             actor: actor, text: change.text, url: url, at: at, unread: true)
    }
}

// Choices for the label and assignee menus of an item.
public struct ItemOptions: Sendable {
    public let labels: [StatusOption]
    public let members: [StatusOption]

    public init(labels: [StatusOption], members: [StatusOption]) {
        self.labels = labels
        self.members = members
    }
}

// A pending item in the intake (triage) queue of a project.
public struct IntakeItem: Codable, Hashable, Sendable {
    public let id: String
    public let workItemId: String
    public let name: String
    public let priority: String?
    public let createdAt: Date
    public let author: String?
    public let source: String?

    public init(id: String, workItemId: String, name: String, priority: String?, createdAt: Date, author: String?, source: String?) {
        self.id = id
        self.workItemId = workItemId
        self.name = name
        self.priority = priority
        self.createdAt = createdAt
        self.author = author
        self.source = source
    }
}

// What the user can do with a pending intake item.
public enum IntakeAction: Hashable, Sendable {
    case accept, decline, snooze(until: Date), duplicate(of: String), delete
}

public struct IntakeDetail: Sendable {
    public let sequence: Int?
    public let body: String        // Markdown
    public let labels: [String]

    public init(sequence: Int?, body: String, labels: [String]) {
        self.sequence = sequence
        self.body = body
        self.labels = labels
    }
}

/// A typed write to an item. Nil fields stay as they are.
public struct ItemPatch: Hashable, Sendable, Codable {
    public var title: String?
    public var status: String?        // status option id
    public var priority: String?      // priority option id
    public var assignees: [String]?   // person ids
    public var labels: [String]?      // label ids
    public var parent: String?        // item id
    public var bodyMarkdown: String?

    public init(title: String? = nil, status: String? = nil, priority: String? = nil, assignees: [String]? = nil,
                labels: [String]? = nil, parent: String? = nil, bodyMarkdown: String? = nil) {
        self.title = title
        self.status = status
        self.priority = priority
        self.assignees = assignees
        self.labels = labels
        self.parent = parent
        self.bodyMarkdown = bodyMarkdown
    }

    public var isEmpty: Bool { self == ItemPatch() }
}

/// A new item.
/// Open set, seen from the item that holds the relation: A blocks B is B blockedBy A.
public struct RelationKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    public static let blockedBy: RelationKind = "blockedBy"
    public static let blocks: RelationKind = "blocks"
    public static let relatesTo: RelationKind = "relatesTo"

    /// The same relation, seen from the other item.
    public var inverse: RelationKind {
        switch self {
        case .blockedBy: return .blocks
        case .blocks: return .blockedBy
        default: return self
        }
    }
}

public struct ItemRelation: Hashable, Sendable, Codable {
    public var kind: RelationKind
    public var item: ItemRef             // the other item

    public init(kind: RelationKind, item: ItemRef) {
        self.kind = kind
        self.item = item
    }
}

/// A write to the relations of one item. The adapter adds before it removes.
public struct RelationPatch: Hashable, Sendable, Codable {
    public var add: [ItemRelation]
    public var remove: [ItemRelation]

    public init(add: [ItemRelation] = [], remove: [ItemRelation] = []) {
        self.add = add
        self.remove = remove
    }

    public var isEmpty: Bool { add.isEmpty && remove.isEmpty }
}

public struct ItemDraft: Hashable, Sendable {
    public var title: String
    public var bodyMarkdown: String?
    public var status: String?
    public var priority: String?
    public var labels: [String]
    public var parent: String?

    public init(title: String, bodyMarkdown: String? = nil, status: String? = nil, priority: String? = nil,
                labels: [String] = [], parent: String? = nil) {
        self.title = title
        self.bodyMarkdown = bodyMarkdown
        self.status = status
        self.priority = priority
        self.labels = labels
        self.parent = parent
    }
}

// ─── Tracker protocols ───────────────────────────────────────────────────────

/// One item with the data that the list does not carry.
public struct ItemDetail: Hashable, Sendable {
    public var item: Item
    public var comments: [Comment]   // oldest first
    public var links: [URL]

    public init(item: Item, comments: [Comment], links: [URL] = []) {
        self.item = item
        self.comments = comments
        self.links = links
    }
}

/// Finds item keys such as OVERSIRE-12 in text and branch names.
public struct KeyFormat: Hashable, Sendable {
    public static let projectDash = KeyFormat(pattern: "\\b([A-Za-z][A-Za-z0-9]*-[0-9]+)\\b")

    public let pattern: String   // capture group 1 is the key

    public init(pattern: String) { self.pattern = pattern }

    /// Keys in text order, uppercased, without repeats. A non-empty known set keeps only keys of those project keys.
    public func keys(in text: String, known: Set<String> = []) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range(at: m.numberOfRanges > 1 ? 1 : 0), in: text) else { continue }
            let key = text[r].uppercased()
            guard !out.contains(key), known.isEmpty || known.contains(Self.project(of: key)) else { continue }
            out.append(key)
        }
        return out
    }

    /// The first key in a branch name: "FRITZ-28/desktop-app", "feature/oversire-12-fix".
    public func key(inBranch b: String, known: Set<String> = []) -> String? {
        keys(in: b.replacingOccurrences(of: "_", with: "/"), known: known).first
    }

    static func project(of key: String) -> String {
        String(key[..<(key.lastIndex(of: "-") ?? key.endIndex)])
    }
}

public protocol Tracker: Provider {
    var keyFormat: KeyFormat { get }
    func projects() async throws -> [ProjectSummary]
    func statuses(_ p: ProjectRef) async throws -> [StatusOption]
    /// The items with the newest activity first, up to limit. A since date stops at older activity.
    func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item]
    func detail(_ i: ItemRef) async throws -> ItemDetail
    func comments(_ i: ItemRef) async throws -> [Comment]
    func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef
    func update(_ i: ItemRef, _ patch: ItemPatch) async throws
    func comment(_ i: ItemRef, markdown: String) async throws
}

public protocol IntakeTriaging: Tracker {
    func intake(_ p: ProjectRef) async throws -> [IntakeItem]
    func intakeDetail(_ i: IntakeItem, in p: ProjectRef) async throws -> IntakeDetail
    func triage(_ i: IntakeItem, in p: ProjectRef, _ a: IntakeAction) async throws
}

/// Makes items in the intake of a project.
public protocol IntakeCreating: IntakeTriaging {
    /// The item ref has the work item key. The intake item is for triage, for example a delete.
    func createIntake(_ d: ItemDraft, in p: ProjectRef) async throws -> (item: ItemRef, intake: IntakeItem)
}

public struct AttachmentUpload: Hashable, Sendable {
    public var name: String        // "snap-1.png"
    public var mimeType: String    // "image/png"
    public var data: Data

    public init(name: String, mimeType: String, data: Data) {
        self.name = name
        self.mimeType = mimeType
        self.data = data
    }
}

public protocol AttachmentUploading: Tracker {
    /// Uploads the file and links it to the item. Returns the attachment id.
    func attach(_ f: AttachmentUpload, to i: ItemRef) async throws -> String
}

public protocol TimelineReading: Tracker {
    func timeline(_ i: ItemRef) async throws -> [ActivityEntry]
}

public protocol LabelManaging: Tracker {
    func labels(_ p: ProjectRef) async throws -> [StatusOption]
    /// Returns the id of the new label.
    func createLabel(_ name: String, color: String, in p: ProjectRef) async throws -> String
}

public protocol LinkManaging: Tracker {
    func links(_ i: ItemRef) async throws -> [URL]
    func addLink(_ i: ItemRef, url: URL, title: String) async throws
}

/// The tracker keeps the relations between items. OverSire keeps no second graph.
public protocol RelationManaging: Tracker {
    func relations(of item: ItemRef) async throws -> [ItemRelation]
    func apply(_ patch: RelationPatch, to item: ItemRef) async throws
}

/// A fast list of all items for trees and key links.
public protocol ItemIndexing: Tracker {
    func index(_ p: ProjectRef) async throws -> [ItemStub]
}

public protocol AssetResolving: Tracker {
    /// A signed download link for an uploaded file.
    func assetURL(_ id: String) async throws -> URL
}

extension Item {
    public func ref(in project: ProjectRef) -> ItemRef? {
        URL(string: url).map { ItemRef(project: project, id: id, key: key, url: $0) }
    }
}
