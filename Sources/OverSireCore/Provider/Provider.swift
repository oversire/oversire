import Foundation

/// The base of each adapter. Each layer protocol (Tracker, CodeHost, CIProvider, AgentRuntime) refines it.
public protocol Provider: Sendable {
    var id: ProviderID { get }
    var account: AccountID { get }
    var capabilities: Set<Capability> { get }
    var pollPolicy: PollPolicy { get }
    /// Checks the auth and returns the user of the token.
    func probe() async throws -> Identity
    /// Each adapter must poll. Webhooks are an option on top.
    func poll(since: Cursor?) async throws -> EventPage
}

/// An optional feature of an adapter. The UI reads it for labels and settings.
public struct Capability: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }

    public static let intake: Capability = "intake"
    public static let timeline: Capability = "timeline"
    public static let labels: Capability = "labels"
    public static let links: Capability = "links"
    public static let subItems: Capability = "subItems"
    public static let assets: Capability = "assets"
    public static let webhooks: Capability = "webhooks"
    public static let changeActions: Capability = "changeActions"
    public static let rerun: Capability = "rerun"
    public static let cancel: Capability = "cancel"
    public static let logs: Capability = "logs"
    public static let annotations: Capability = "annotations"
    public static let remoteEnvironments: Capability = "remoteEnvironments"
    public static let sessionInput: Capability = "sessionInput"
    public static let sessionTail: Capability = "sessionTail"
    public static let reveal: Capability = "reveal"
    public static let cloudDispatch: Capability = "cloudDispatch"
}

/// The user of a token.
public struct Identity: Hashable, Sendable, Codable {
    public let person: PersonRef
    public let scopes: [String]

    public init(person: PersonRef, scopes: [String] = []) {
        self.person = person
        self.scopes = scopes
    }
}

/// An opaque poll position. Only the adapter reads it.
public struct Cursor: RawRepresentable, Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

public struct EventPage: Sendable {
    public let events: [ProviderEvent]
    public let cursor: Cursor
    public let retryAfter: Duration?

    public init(events: [ProviderEvent], cursor: Cursor, retryAfter: Duration? = nil) {
        self.events = events
        self.cursor = cursor
        self.retryAfter = retryAfter
    }
}

/// How often the app may poll a vendor. Plane allows 3,600 requests an hour, GitHub 5,000.
public struct PollPolicy: Hashable, Sendable {
    public let minInterval: Duration
    public let requestsPerHour: Int

    public init(minInterval: Duration, requestsPerHour: Int) {
        self.minInterval = minInterval
        self.requestsPerHour = requestsPerHour
    }
}

public struct WebhookRegistration: Hashable, Sendable, Codable {
    public let id: String
    public let url: URL
    public let secret: String?   // only in the answer to register

    public init(id: String, url: URL, secret: String? = nil) {
        self.id = id
        self.url = url
        self.secret = secret
    }
}

public protocol WebhookManaging: Provider {
    func webhooks() async throws -> [WebhookRegistration]
    func register(url: URL) async throws -> WebhookRegistration
    func unregister(_ id: String) async throws
}

public struct RateBudget: Hashable, Sendable {
    public let limit: Int
    public let remaining: Int
    public let resetAt: Date

    public init(limit: Int, remaining: Int, resetAt: Date) {
        self.limit = limit
        self.remaining = remaining
        self.resetAt = resetAt
    }

    public var used: Double { limit > 0 ? Double(limit - remaining) / Double(limit) : 0 }
}

public protocol RateReporting: Provider {
    func budget() async throws -> RateBudget
}

extension Duration {
    public var timeInterval: TimeInterval {
        let c = components
        return TimeInterval(c.seconds) + TimeInterval(c.attoseconds) / 1e18
    }
}
