import Foundation

// ─── OverSire state ──────────────────────────────────────────────────────────
// The state that OverSire owns (not a vendor). LocalStore keeps it on this Mac.
// A later CloudStore keeps the same records on the server. Contract/schema/store.json has the JSON form.

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
    public var lastStarted: String?     // "the one above" of the first entry
    public var error: String?           // why the lane cannot start

    public init(project: String, identifier: String, entries: [QueueEntry] = [], lastStarted: String? = nil, error: String? = nil) {
        self.project = project
        self.identifier = identifier
        self.entries = entries
        self.lastStarted = lastStarted
        self.error = error
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
