import Foundation

// DTOs of the Big Timer server (api/openapi.yaml). Unknown keys are ignored.

struct BTMember: Decodable {
    let uuid: String
    let name: String
    let email: String?
    let short_name: String?
    let status: String   // invited, active, deactivated
}

struct BTMemberList: Decodable { let items: [BTMember] }

struct BTToken: Decodable { let scopes: [String] }

struct BTTeam: Decodable { let name: String }

struct BTMe: Decodable {
    let member: BTMember
    let team: BTTeam
    let token: BTToken
}

struct BTProject: Decodable {
    let uuid: String
    let name: String
    let issue_prefix: String
    let archived: Bool?
    let color: String?
}

/// A list page with a cursor.
protocol BTPage: Decodable {
    associatedtype Row
    var items: [Row] { get }
    var next_cursor: String? { get }
}

struct BTProjectPage: Decodable, BTPage {
    let items: [BTProject]
    let next_cursor: String?
}

struct BTIssue: Decodable {
    let uuid: String
    let version: Int
    let project_uuid: String
    let number: Int
    let key: String
    let title: String
    let details: String?
    let status: String
    let size: String?
    let due_date: String?
    let assignee_uuid: String?
    // The sub-item fields come with the server change of sub-items. An older server has no value.
    let parent_uuid: String?
    let created_by: String?
    let updated_by: String?
    let created_at: Date
    let updated_at: Date
    // The activity fields come with the server change of OVERSIRE-513. An older server has no value.
    let activity_at: Date?
    let comment_count: Int?
    let last_comment_at: Date?
    // The epic fields come with the server change of epics. An older server has no value.
    let kind: String?
    let epic_uuid: String?
    let epic_key: String?
    let start_date: String?
    // The roll-up. The server sends 0 for an item that is not an epic.
    let item_count: Int?
    let items_done: Int?
    let items_in_progress: Int?
    let items_blocked: Int?
    let estimate_minutes: Int?
    let health: String?
}

struct BTIssuePage: Decodable, BTPage {
    let items: [BTIssue]
    let next_cursor: String?
}

struct BTComment: Decodable {
    let uuid: String
    let issue_uuid: String
    let author_uuid: String?
    let body: String
    let created_at: Date
    let updated_at: Date
}

struct BTCommentList: Decodable { let items: [BTComment] }

struct BTIssueRecord: Decodable {
    let uuid: String
    let project_uuid: String
    let number: Int
    let title: String
    let version: Int
    let created_at: Date
    let updated_at: Date
    let parent_uuid: String?
    let kind: String?
    let epic_uuid: String?
    let start_date: String?
}

struct BTCommentRecord: Decodable {
    let uuid: String
    let issue_uuid: String
    let version: Int
    let updated_at: Date
}

/// One row of the change feed. Only the issue and comment entities carry a record.
struct BTChange: Decodable {
    enum Record {
        case issue(BTIssueRecord)
        case comment(BTCommentRecord)
    }

    let seq: Int
    let entity: String
    let op: String
    let uuid: String?
    let version: Int?
    let record: Record?

    private enum Keys: String, CodingKey { case seq, entity, op, record, uuid, version }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        entity = try c.decode(String.self, forKey: .entity)
        op = try c.decode(String.self, forKey: .op)
        switch entity {
        case "issue": record = try c.decodeIfPresent(BTIssueRecord.self, forKey: .record).map(Record.issue)
        case "issue_comment": record = try c.decodeIfPresent(BTCommentRecord.self, forKey: .record).map(Record.comment)
        default: record = nil
        }
        // An upsert has its uuid and version in the record. A delete has them next to seq.
        var ids: (uuid: String, version: Int)?
        switch record {
        case .issue(let r): ids = (r.uuid, r.version)
        case .comment(let r): ids = (r.uuid, r.version)
        case nil: break
        }
        uuid = try ids?.uuid ?? c.decodeIfPresent(String.self, forKey: .uuid)
        version = try ids?.version ?? c.decodeIfPresent(Int.self, forKey: .version)
    }
}

struct BTChangesPage: Decodable {
    let changes: [BTChange]
    let next: Int
    let more: Bool
    let head: Int
    let server_time: Date?
}

struct BTProblem: Decodable {
    let code: String?
    let detail: String?
    let errors: [String: String]?
}

// Request bodies. The server refuses unknown keys, so each body has only its own keys.

struct BTIssueCreate: Encodable {
    let project_uuid: String
    let title: String
    let details: String?
    let status: String?
    let parent_uuid: String?
    var kind: String? = nil
    var epic: String? = nil
    var start_date: String? = nil
    var due_date: String? = nil
    var size: String? = nil
}

/// A nil field is not encoded. An empty parent_uuid removes the parent. A key in `clear` encodes as null.
struct BTIssuePatch: Encodable {
    var title: String?
    var details: String?
    var status: String?
    var parent_uuid: String?
    var start_date: String? = nil
    var due_date: String? = nil
    var size: String? = nil
    var epic_uuid: String? = nil
    var clear: Set<String> = []

    var isEmpty: Bool {
        title == nil && details == nil && status == nil && parent_uuid == nil && start_date == nil && due_date == nil && size == nil
            && epic_uuid == nil && clear.isEmpty
    }

    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Key.self)
        let values: [(String, String?)] = [("title", title), ("details", details), ("status", status), ("parent_uuid", parent_uuid),
                                           ("start_date", start_date), ("due_date", due_date), ("size", size), ("epic_uuid", epic_uuid)]
        for (name, value) in values {
            if let value { try c.encode(value, forKey: Key(name)) }
            else if clear.contains(name) { try c.encodeNil(forKey: Key(name)) }
        }
    }
}

/// A nil member encodes as null, which removes the assignee.
struct BTAssign: Encodable {
    let member: String?

    private enum Keys: String, CodingKey { case member }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(member, forKey: .member)
    }
}

struct BTCommentCreate: Encodable {
    let body: String
    var health: String? = nil
}
