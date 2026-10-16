import Foundation

/// Open set of vendors. A vendor adds its constant in its own target.
public struct ProviderID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }
}

public enum Layer: String, Codable, Sendable, CaseIterable {
    case tracker, codeHost, ci, runtime
}

/// One connected account of one vendor: a Plane workspace, a GitHub org, an Orca host.
public struct AccountID: Hashable, Sendable, Codable {
    public let provider: ProviderID
    public let id: String

    public init(provider: ProviderID, id: String) {
        self.provider = provider
        self.id = id
    }
}

public struct PersonRef: Hashable, Sendable, Codable {
    public let id: String
    public let name: String
    public let login: String?

    public init(id: String, name: String, login: String? = nil) {
        self.id = id
        self.name = name
        self.login = login
    }
}

/// An agent CLI. The raw values are the same as the AgentBinder Harness raw values.
public struct AgentName: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    public static let claude: AgentName = "claude"
    public static let codex: AgentName = "codex"
    public static let opencode: AgentName = "opencode"
    public static let cursor: AgentName = "cursor"
}
