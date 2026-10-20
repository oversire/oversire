import Foundation

// ─── Session history ─────────────────────────────────────────────────────────
// JSON form: Contract/schema/session-digest.json.

/// How much of a session history a reader keeps.
public struct HistoryBudget: Hashable, Sendable, Codable {
    public var earlier: Int
    public var full: Int
    public var maxChars: Int

    public init(earlier: Int = 12, full: Int = 3, maxChars: Int = 4000) {
        self.earlier = earlier
        self.full = full
        self.maxChars = maxChars
    }

    public static let standard = HistoryBudget()

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        earlier = try c.decodeIfPresent(Int.self, forKey: .earlier) ?? 12
        full = try c.decodeIfPresent(Int.self, forKey: .full) ?? 3
        maxChars = try c.decodeIfPresent(Int.self, forKey: .maxChars) ?? 4000
    }
}

/// A short record of the history of one agent session: earlier turns as prompt and closing message,
/// the last turns with the full agent text. Tool output is left out.
public struct SessionDigest: Hashable, Sendable, Codable {
    public struct Source: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }

        public static let file: Source = "file"
        public static let orcaTerminal: Source = "orca-terminal"
        public static let runner: Source = "runner"
    }

    public struct EarlierTurn: Hashable, Sendable, Codable {
        public var prompt: String
        public var closing: String
        public var interrupted: Bool?

        public init(prompt: String, closing: String, interrupted: Bool? = nil) {
            self.prompt = prompt
            self.closing = closing
            self.interrupted = interrupted
        }
    }

    public struct LastTurn: Hashable, Sendable, Codable {
        public var prompt: String
        public var text: String
        public var tools: Int
        public var interrupted: Bool?

        public init(prompt: String, text: String, tools: Int, interrupted: Bool? = nil) {
            self.prompt = prompt
            self.text = text
            self.tools = tools
            self.interrupted = interrupted
        }
    }

    public var harness: AgentName
    public var sessionId: String
    public var source: Source
    public var turns: Int
    public var earlier: [EarlierTurn]
    public var last: [LastTurn]
    public var truncated: Bool

    public init(harness: AgentName, sessionId: String, source: Source, turns: Int, earlier: [EarlierTurn] = [],
                last: [LastTurn] = [], truncated: Bool = false) {
        self.harness = harness
        self.sessionId = sessionId
        self.source = source
        self.turns = turns
        self.earlier = earlier
        self.last = last
        self.truncated = truncated
    }

    public var isEmpty: Bool { turns == 0 }
}

/// Reads the history of an agent session. Throws ProviderError.notFound when the runtime finds no record.
public protocol SessionHistoryReading: AgentRuntime {
    func history(of session: AgentSession, in workspace: Workspace, budget: HistoryBudget) async throws -> SessionDigest
}

/// Reads agent transcript files on this Mac. The app gives one through AgentBinder; adapters get it injected.
public protocol TranscriptReading: Sendable {
    /// The digest of one transcript file. The source of the result is file.
    func digest(file: String, agent: AgentName, budget: HistoryBudget) throws -> SessionDigest
    /// The transcript file of a harness session id.
    func locate(agent: AgentName, sessionId: String) -> String?
    /// The newest transcript file of the sessions that ran in `cwd`.
    func newest(agent: AgentName, cwd: String) -> String?
}
