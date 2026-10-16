import Foundation

/// What a provider event is about. Open set.
public struct EventKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let item: EventKind = "item"
    public static let comment: EventKind = "comment"
    public static let intake: EventKind = "intake"
    public static let change: EventKind = "change"
    public static let run: EventKind = "run"
    public static let job: EventKind = "job"
    public static let push: EventKind = "push"
    public static let session: EventKind = "session"
}

/// Enough for a notice without a fetch.
public struct EventSummary: Hashable, Sendable, Codable {
    public var title: String?
    public var status: String?
    public var conclusion: String?
    public var actor: String?

    public init(title: String? = nil, status: String? = nil, conclusion: String? = nil, actor: String? = nil) {
        self.title = title
        self.status = status
        self.conclusion = conclusion
        self.actor = actor
    }
}

/// A hint that a subject changed. The app gets the full data from the adapter.
public struct ProviderEvent: Hashable, Sendable, Codable {
    public static let schemaVersion = 1

    public let id: String          // delivery id; the merge step drops repeats
    public let schema: Int
    public let provider: ProviderID
    public let account: AccountID
    public let kind: EventKind
    public let action: String      // created, updated, completed, deleted, ...
    public let subject: SubjectRef
    public let at: Date
    public let summary: EventSummary?

    public init(id: String, schema: Int = ProviderEvent.schemaVersion, provider: ProviderID, account: AccountID, kind: EventKind,
                action: String, subject: SubjectRef, at: Date, summary: EventSummary? = nil) {
        self.id = id
        self.schema = schema
        self.provider = provider
        self.account = account
        self.kind = kind
        self.action = action
        self.subject = subject
        self.at = at
        self.summary = summary
    }
}

public enum SourceHealth: Hashable, Sendable {
    case off
    case connecting
    case live
    case failed(String)
}

/// A stream of provider events: polling, the cloud, or a merge of both.
public protocol EventSource: Sendable {
    /// One consumer. A second call ends the first stream.
    func events() -> AsyncStream<ProviderEvent>
    func health() async -> SourceHealth
}
