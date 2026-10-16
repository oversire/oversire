import Foundation

// ─── Project model ───────────────────────────────────────────────────────────
// Layers: Plane workspace → project → work item. Snapshots are local. The store
// diffs two snapshots to build the activity feed.

struct ProjectRef: Codable, Hashable {
    let workspace: String     // slug
    let id: String            // project UUID
    var key: String

    init(workspace: String, id: String) {
        self.workspace = workspace
        self.id = id
        self.key = "\(workspace)/\(id)"
    }
}

struct ProjectSummary: Codable, Hashable {
    let ref: ProjectRef
    let identifier: String    // "ENG"
    let title: String
    let url: String
    let closed: Bool          // archived
}

enum StatusCategory: String, Codable, CaseIterable {
    case todo, progress, review, blocked, done

    var label: String {
        switch self {
        case .todo: return "Todo"
        case .progress: return "In progress"
        case .review: return "In review"
        case .blocked: return "Blocked"
        case .done: return "Done"
        }
    }

    // List order: active work first, done last.
    var rank: Int {
        switch self {
        case .progress: return 0
        case .review: return 1
        case .blocked: return 2
        case .todo: return 3
        case .done: return 4
        }
    }
}

// A Plane state, or an option of another single-select field (Priority).
struct StatusOption: Codable, Hashable {
    let id: String
    let name: String
    let color: String         // "#F59E0B" or a GitHub-style name
    var group: String? = nil  // Plane state group: backlog, unstarted, started, completed, cancelled

    // The group decides first. The name splits "started" into review and blocked.
    var category: StatusCategory {
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

struct CommentRef: Codable, Hashable {
    let id: String
    let author: String?
    let createdAt: Date
    let url: String
    var body: String? = nil
}

struct ProjectItem: Codable, Hashable {
    let id: String
    let key: String           // "ENG-123"
    let title: String
    let url: String
    let statusOptionId: String?
    let fields: [String: String]
    let assignees: [String]
    let labels: [String]
    let author: String?
    let updatedBy: String?
    let updatedAt: Date
    let activityAt: Date      // Plane's last_activity_at. A comment changes it, updated_at stays.
    var commentCount: Int
    var lastComment: CommentRef?
    var mentionsMe: Bool
    var body: String? = nil   // Markdown
    var parentId: String? = nil

    func isMine(_ me: String?) -> Bool {
        guard let me = me?.lowercased(), !me.isEmpty else { return false }
        if author?.lowercased() == me { return true }
        return assignees.contains { $0.lowercased() == me }
    }

    // Markdown for a coding agent: title, facts, link, description, comments (oldest first).
    func agentMarkdown(snap: ProjectSnapshot, comments: [CommentRef]) -> String {
        var facts = ["Project: \(snap.summary.ref.workspace)/\(snap.summary.title)", "Work item: \(key)"]
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
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return true }
        return key.localizedCaseInsensitiveContains(q) || title.localizedCaseInsensitiveContains(q)
            || (body ?? "").localizedCaseInsensitiveContains(q)
    }
}

// One entry for each item of the project, also for the items that the snapshot does not load.
struct ItemStub: Codable, Hashable {
    let id: String
    let parentId: String?
    let stateId: String?
    let activityAt: Date?
}

// A single-select field of a project: Status (the Plane states) or Priority.
struct ProjectField: Codable, Hashable {
    let id: String
    let name: String
    let options: [StatusOption]
}

struct ProjectSnapshot: Codable {
    static let statusFieldId = "state"
    static let priorityFieldId = "priority"

    let summary: ProjectSummary
    let statusOptions: [StatusOption]
    let items: [ProjectItem]
    let fetchedAt: Date
    var fields: [ProjectField] = []
    var me: String? = nil     // display name of the token owner
    var meId: String? = nil
    var index: [ItemStub]? = nil
    var intake: [IntakeItem]? = nil   // pending intake items; nil when the project has no intake

    var statusFieldId: String? { statusOptions.isEmpty ? nil : ProjectSnapshot.statusFieldId }

    // The number on a folded header.
    func notDoneCount(_ list: [ProjectItem]) -> Int { list.filter { option($0.statusOptionId)?.category != .done }.count }

    func counts(_ list: [ProjectItem]) -> [StatusCategory: Int] {
        var c: [StatusCategory: Int] = [:]
        for item in list {
            let cat = option(item.statusOptionId)?.category ?? .todo
            c[cat, default: 0] += 1
        }
        return c
    }

    func option(_ id: String?) -> StatusOption? { statusOptions.first { $0.id == id } }
    func statusName(_ id: String?) -> String? { option(id)?.name }

    // Items without a parent, and sub-items whose parent is not loaded.
    var rootItems: [ProjectItem] {
        let ids = Set(items.map(\.id))
        return items.filter { $0.parentId.map { !ids.contains($0) } ?? true }
    }

    func listed(subItems: Bool) -> [ProjectItem] { subItems ? items : rootItems }

    func children(of id: String) -> [ProjectItem] { sorted(items.filter { $0.parentId == id }) }

    // Direct sub-items. The index counts also the sub-items that are not loaded.
    func progress(of id: String) -> (done: Int, total: Int) {
        let states = index.map { $0.filter { $0.parentId == id }.map(\.stateId) }
            ?? items.filter { $0.parentId == id }.map(\.statusOptionId)
        return (states.filter { option($0)?.category == .done }.count, states.count)
    }

    // Parent first, up to the root.
    func ancestors(of id: String) -> [String] {
        var out: [String] = []
        var next = items.first { $0.id == id }?.parentId
        while let p = next, !out.contains(p), let item = items.first(where: { $0.id == p }) {
            out.append(p)
            next = item.parentId
        }
        return out
    }

    var sortedItems: [ProjectItem] { sorted(items) }

    // Status rank, then priority (Urgent first, none last), then title A to Z.
    func sorted(_ list: [ProjectItem]) -> [ProjectItem] {
        func rank(_ i: ProjectItem) -> Int { (option(i.statusOptionId)?.category ?? .todo).rank }
        func priority(_ i: ProjectItem) -> Int {
            PlaneClient.priorities.firstIndex { $0.name == i.fields["Priority"] } ?? PlaneClient.priorities.count
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

enum ItemChange: Codable, Hashable {
    case added, removed, closed, reopened, mention
    case status(from: String?, to: String?)
    case field(name: String, from: String?, to: String?)
    case assigned(String), unassigned(String)
    case comments(new: Int, last: CommentRef)

    var text: String {
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
    var commentAuthor: String? {
        if case .comments(_, let last) = self { return last.author }
        return nil
    }
}

struct ActivityEntry: Codable, Hashable {
    let id: String
    var projectKey: String
    var itemId: String
    let change: ItemChange
    let actor: String?
    let text: String
    let url: String
    let at: Date
    var unread: Bool

    static func make(projectKey: String, itemId: String, change: ItemChange, actor: String?, url: String, at: Date) -> ActivityEntry {
        let id = "\(projectKey)|\(itemId)|\(change.text)|\(Int(at.timeIntervalSince1970))"
        return ActivityEntry(id: id, projectKey: projectKey, itemId: itemId, change: change,
                             actor: actor, text: change.text, url: url, at: at, unread: true)
    }
}

// Choices for the label and assignee menus of an item.
struct ItemOptions {
    let labels: [StatusOption]
    let members: [StatusOption]
}

// A pending item in the intake (triage) queue of a project.
struct IntakeItem: Codable, Hashable {
    let id: String
    let workItemId: String
    let name: String
    let priority: String?
    let createdAt: Date
    let author: String?
    let source: String?
}

// What the user can do with a pending intake item.
enum IntakeAction {
    case accept, decline, snooze(until: Date), duplicate(of: String), delete

    // The body for the status endpoint. Delete has its own endpoint.
    var body: [String: Any]? {
        switch self {
        case .accept: return ["status": 1]
        case .decline: return ["status": -1]
        case .snooze(let d): return ["status": 0, "snoozed_till": ISO8601DateFormatter().string(from: d)]
        case .duplicate(let id): return ["status": 2, "duplicate_to": id]
        case .delete: return nil
        }
    }

    var failure: String {
        switch self {
        case .accept: return "Could not accept: "
        case .decline: return "Could not decline: "
        case .snooze: return "Could not snooze: "
        case .duplicate: return "Could not mark as duplicate: "
        case .delete: return "Could not delete: "
        }
    }
}

struct IntakeDetail {
    let sequence: Int?
    let body: String        // Markdown
    let labels: [String]
}
