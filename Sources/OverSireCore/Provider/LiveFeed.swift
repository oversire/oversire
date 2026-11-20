import Foundation

/// One hint from a live feed. The hints carry no data: the caller polls.
public struct LiveSignal: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The stream is up: a keep-alive, or an event that is not about data.
        case alive
        /// Pull the feed from your cursor.
        case changed
        /// Drop the cursor and read all.
        case resync
    }

    public let kind: Kind
    /// The id of the event, for `Last-Event-ID`.
    public let id: String?

    public init(_ kind: Kind, id: String? = nil) {
        self.kind = kind
        self.id = id
    }
}

/// A provider that pushes change hints over a long-lived connection (`Capability.liveFeed`).
public protocol LiveFeeding: Provider {
    /// The longest silence of a stream that is up. The server sends a keep-alive more often.
    var liveFeedTimeout: Duration { get }
    /// Opens the stream. The stream ends or throws when the connection drops.
    /// Errors: `.unauthorized`, `.forbidden`, `.notFound`, `.unsupported(.liveFeed)`, `.rateLimited`, `.transport`, `.vendor`.
    func liveFeed(lastEventID: String?) async throws -> AsyncThrowingStream<LiveSignal, Error>
}
