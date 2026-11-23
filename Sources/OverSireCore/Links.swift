import Foundation

/// A page to open in the app on the Mac of a click (link.json OpenRoute).
public struct OpenRoute: Codable, Hashable, Sendable {
    public enum Source: String, Codable, Sendable { case web, cli }

    public var id: String
    /// A route path such as item/OVERSIRE-400/changes.
    public var path: String
    public var focus: String?
    public var source: Source
    /// The machine of the daemon that sent the frame.
    public var daemon: String
    public var agent: String?

    public init(id: String, path: String, focus: String? = nil, source: Source, daemon: String, agent: String? = nil) {
        self.id = id
        self.path = path
        self.focus = focus
        self.source = source
        self.daemon = daemon
        self.agent = agent
    }
}

/// The frame of the daemon that opens a route in the app (link.json OpenRouteFrame).
public struct OpenRouteFrame: Codable, Hashable, Sendable {
    public var type: String
    public var open: OpenRoute

    public init(open: OpenRoute) {
        self.type = "openRoute"
        self.open = open
    }
}

/// The body of POST /v1/presence: seconds since the last user input on the Mac.
public struct AppPresence: Codable, Hashable, Sendable {
    public var idle: Int

    public init(idle: Int) { self.idle = idle }
}

/// The body of POST /v1/open.
public struct OpenRequest: Codable, Hashable, Sendable {
    public var path: String
    public var focus: String?
    public var on: String?
    public var agent: String?

    public init(path: String, focus: String? = nil, on: String? = nil, agent: String? = nil) {
        self.path = path
        self.focus = focus
        self.on = on
        self.agent = agent
    }
}

/// The answer of POST /v1/open.
public struct OpenResult: Codable, Hashable, Sendable {
    public enum How: String, Codable, Sendable { case click, input, on }

    public var id: String
    public var machine: String
    public var how: How
    public var idle: Int?
    public var group: String?

    public init(id: String, machine: String, how: How, idle: Int? = nil, group: String? = nil) {
        self.id = id
        self.machine = machine
        self.how = how
        self.idle = idle
        self.group = group
    }
}

extension DaemonClient {
    /// POST /v1/presence. An old daemon gives `ProviderError.notFound`.
    public func presence(_ p: AppPresence) async throws {
        var req = try json("POST", "/v1/presence", p)
        req.timeoutInterval = 10
        _ = try await send(req)
    }
}
