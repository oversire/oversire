import Foundation

// ─── OverSire state ──────────────────────────────────────────────────────────
// The state that OverSire owns (not a vendor). LocalStore keeps it on this Mac.
// A later CloudStore keeps the same records on the server. Contract/schema/store.json has the JSON form.

/// The x-oversire-schema number of Contract/schema/store.json.
public let storeSchemaVersion = 2

public protocol StoreRecord: Codable, Hashable, Sendable {
    /// The file or the table of the record type.
    static var collection: String { get }
    var id: String { get }
}

public struct StoreChange: Hashable, Sendable {
    public let collection: String
    public let id: String
    public let deleted: Bool

    public init(collection: String, id: String, deleted: Bool) {
        self.collection = collection
        self.id = id
        self.deleted = deleted
    }
}

public protocol Store: Sendable {
    func all<R: StoreRecord>(_ type: R.Type) async throws -> [R]
    func get<R: StoreRecord>(_ type: R.Type, id: String) async throws -> R?
    func put<R: StoreRecord>(_ record: R) async throws
    func delete<R: StoreRecord>(_ type: R.Type, id: String) async throws
    /// One stream for each call. It gives each put and delete after the call.
    func changes() async -> AsyncStream<StoreChange>
}

// ─── Records ─────────────────────────────────────────────────────────────────

/// One item that waits in a queue lane.
public struct QueueEntry: Codable, Hashable, Sendable {
    public enum Condition: String, Codable, Sendable, CaseIterable { case slot, ciPassed, done, tonight }
    public enum Source: String, Codable, Sendable { case you, label, assignee }

    public let key: String
    public var title: String
    public var condition: Condition
    public var added: Date
    public var source: Source

    public init(key: String, title: String, condition: Condition = .slot, added: Date, source: Source = .you) {
        self.key = key
        self.title = title
        self.condition = condition
        self.added = added
        self.source = source
    }
}

/// The queue of one project. The first entry starts when a slot is free and its condition holds.
public struct QueueLane: StoreRecord {
    public static let collection = "queue-lanes"

    public let project: String          // ProjectRef.storeKey
    public var identifier: String
    public var entries: [QueueEntry]

    public init(project: String, identifier: String, entries: [QueueEntry] = []) {
        self.project = project
        self.identifier = identifier
        self.entries = entries
    }

    public var id: String { project }
}

/// What the queue writes about a lane. The user edits the lane, the queue edits its state.
public struct QueueLaneState: StoreRecord {
    public static let collection = "queue-lane-state"

    public let project: String
    public var lastStarted: String?     // "the one above" of the first entry
    public var error: String?           // why the lane cannot start
    public var updatedAt: Date

    public init(project: String, lastStarted: String? = nil, error: String? = nil, updatedAt: Date) {
        self.project = project
        self.lastStarted = lastStarted
        self.error = error
        self.updatedAt = updatedAt
    }

    public var id: String { project }
}

/// An item key that a tracker trigger (label or assignee) added once. A removal then stays removed.
public struct QueueTrigger: StoreRecord {
    public static let collection = "queue-triggers"

    public let key: String
    public let at: Date

    public init(key: String, at: Date) {
        self.key = key
        self.at = at
    }

    public var id: String { key }
}

/// A failed run that the user ignores. The id holds the attempt, so a new failed attempt shows again.
public struct IgnoredFailure: StoreRecord {
    public static let collection = "ignored-failures"

    public let id: String               // "<run url>#<attempt>"
    public let at: Date

    public init(id: String, at: Date) {
        self.id = id
        self.at = at
    }
}

/// A subject that the user keeps at the top.
public struct Pin: StoreRecord {
    public static let collection = "pins"

    public let id: String
    public let subject: SubjectRef
    public let at: Date

    public init(id: String, subject: SubjectRef, at: Date) {
        self.id = id
        self.subject = subject
        self.at = at
    }
}

/// A subject that the user hides until a time.
public struct Snooze: StoreRecord {
    public static let collection = "snoozes"

    public let id: String
    public let subject: SubjectRef
    public let until: Date

    public init(id: String, subject: SubjectRef, until: Date) {
        self.id = id
        self.subject = subject
        self.until = until
    }
}

/// A private note on a subject. It does not go to the vendor.
public struct Note: StoreRecord {
    public static let collection = "notes"

    public let id: String
    public let subject: SubjectRef
    public var text: String
    public var at: Date

    public init(id: String, subject: SubjectRef, text: String, at: Date) {
        self.id = id
        self.subject = subject
        self.text = text
        self.at = at
    }
}

/// The agent session that OverSire started for an item.
public struct AgentLink: StoreRecord {
    public static let collection = "agent-links"

    public let key: String              // item key, upper case
    public let workspace: WorkspaceRef
    public let pane: String?
    public let at: Date

    public init(key: String, workspace: WorkspaceRef, pane: String?, at: Date) {
        self.key = key
        self.workspace = workspace
        self.pane = pane
        self.at = at
    }

    public var id: String { key }
}

/// The code areas of one item. Area tags live only in the store, not as tracker labels.
public struct ItemAreas: StoreRecord {
    public static let collection = "item-areas"

    public enum Source: String, Codable, Sendable { case user, suggestion }

    public let id: String               // ItemAreas.id(of:)
    public let item: ItemRef
    public var areas: [String]
    public var source: Source
    public var suggestion: String?
    public var updatedAt: Date

    public init(item: ItemRef, areas: [String], source: Source = .user, suggestion: String? = nil, updatedAt: Date) {
        id = Self.id(of: item)
        self.item = item
        self.areas = areas
        self.source = source
        self.suggestion = suggestion
        self.updatedAt = updatedAt
    }

    public static func id(of item: ItemRef) -> String { "\(item.project.storeKey)/\(item.id)" }

    /// Lower case, [a-z0-9-], at most 32 characters, at most 6 tags, no repeats. Other tags drop.
    public static func clean(_ tags: [String]) -> [String] {
        var out: [String] = []
        for t in tags {
            let tag = t.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
            guard !tag.isEmpty, tag.count <= 32, tag.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
                  !out.contains(tag) else { continue }
            out.append(tag)
            if out.count == SequenceDraft.maxAreas { break }
        }
        return out
    }
}

// ─── Sync ────────────────────────────────────────────────────────────────────

/// One write to a synced collection. Last write wins for each collection and id, by `hlc`.
public struct StoreOp: Hashable, Sendable, Codable {
    public enum Op: String, Codable, Sendable { case put, delete }

    public var schema: Int
    public let collection: String
    public let id: String
    public let op: Op
    public let record: JSONValue?       // nil for a delete
    /// Milliseconds (15 digits), a counter (6 digits) and the device id. The text order is the time order.
    public let hlc: String
    public let device: String

    public init(collection: String, id: String, op: Op, record: JSONValue? = nil, hlc: String, device: String) {
        schema = storeSchemaVersion
        self.collection = collection
        self.id = id
        self.op = op
        self.record = record
        self.hlc = hlc
        self.device = device
    }
}

/// Any JSON value. Integers stay integers.
public enum JSONValue: Hashable, Sendable, Codable {
    case null, bool(Bool), int(Int), double(Double), string(String), array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let i = try? c.decode(Int.self) { self = .int(i) }
        else if let d = try? c.decode(Double.self) { self = .double(d) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let i): try c.encode(i)
        case .double(let d): try c.encode(d)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}
