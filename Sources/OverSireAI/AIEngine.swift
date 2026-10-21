import Foundation
import OverSireCore

// ─── AI work ─────────────────────────────────────────────────────────────────
// An AITask is one unit of AI work. An AIEngine runs it. AIRouter picks the engine.
// Contract/schema/ai-task.json has the JSON form of AITask and AIResult.

/// Open set. Today: the API key of the user and the local CLI (AgentBinder). Later: cloud credits.
public struct EngineID: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    public static let apiKey: EngineID = "api-key"
    public static let localCLI: EngineID = "local-cli"
}

/// Open set. Each kind owns its prompt (Prompts/).
public struct AITaskKind: RawRepresentable, Hashable, Sendable, Codable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { rawValue = value }
    public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
    public var description: String { rawValue }

    public static let ping: AITaskKind = "ping"
    public static let triage: AITaskKind = "triage"
    public static let enhance: AITaskKind = "enhance"
    public static let failureReason: AITaskKind = "failureReason"
    public static let digest: AITaskKind = "digest"
    public static let changeSummary: AITaskKind = "changeSummary"
    public static let draft: AITaskKind = "draft"
    public static let tidy: AITaskKind = "tidy"
    public static let check: AITaskKind = "check"
    public static let order: AITaskKind = "order"
    public static let sessionSummary: AITaskKind = "sessionSummary"
    public static let sessionEnd: AITaskKind = "sessionEnd"
    public static let question: AITaskKind = "question"
    public static let itemSummary: AITaskKind = "itemSummary"
    public static let status: AITaskKind = "status"
}

public struct AIInput: Hashable, Sendable, Codable {
    /// The main input: item text, a log snippet, a transcript.
    public var text: String
    /// Named extra inputs. The key "extra" holds the extra instructions of the user.
    public var context: [String: String]

    public init(text: String, context: [String: String] = [:]) {
        self.text = text
        self.context = context
    }

    enum CodingKeys: String, CodingKey { case text, context }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        context = try c.decodeIfPresent([String: String].self, forKey: .context) ?? [:]
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(text, forKey: .text)
        if !context.isEmpty { try c.encode(context, forKey: .context) }
    }
}

public struct AITask: Hashable, Sendable, Codable {
    public static let schemaVersion = 1

    public var schema: Int
    /// A task with the same id replaces the earlier result.
    public var id: String
    public var kind: AITaskKind
    public var subject: SubjectRef?
    public var input: AIInput
    public var deadline: Date?

    public init(id: String = UUID().uuidString, kind: AITaskKind, subject: SubjectRef? = nil, input: AIInput, deadline: Date? = nil) {
        schema = Self.schemaVersion
        self.id = id
        self.kind = kind
        self.subject = subject
        self.input = input
        self.deadline = deadline
    }
}

/// The reply of an engine. The store keeps the last results.
public struct AIResult: StoreRecord {
    public static let collection = "ai-results"

    public var schema: Int
    public var task: String
    public var engine: EngineID
    public var text: String
    public var at: Date

    public init(task: String, engine: EngineID, text: String, at: Date) {
        schema = AITask.schemaVersion
        self.task = task
        self.engine = engine
        self.text = text
        self.at = at
    }

    public var id: String { task }
}

public enum AIError: Error, Equatable, Sendable {
    case notConfigured
    /// The engine cannot run now. The router tries the next engine.
    case unavailable(String)
    case unsupported(AITaskKind)
    case http(Int, String)
    case timeout
    case network(String)
    case badReply(String)

    public var message: String {
        switch self {
        case .notConfigured: return "Set up AI in Settings → AI."
        case .unavailable(let why): return why
        case .unsupported(let k): return "No prompt for the AI task \(k)."
        case .http(let code, let msg): return msg.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(msg)"
        case .timeout: return "The AI endpoint did not reply in 30 s."
        case .network(let msg): return msg
        case .badReply(let msg): return "Unexpected reply: \(msg)"
        }
    }
}

public protocol AIEngine: Sendable {
    var id: EngineID { get }
    /// False when the engine has no setup or no credit. The router then tries the next engine.
    func available() async -> Bool
    /// The reply text. Throw AIError.unavailable to give the task to the next engine.
    func run(_ task: AITask) async throws -> String
}

// ─── Cloud routes ────────────────────────────────────────────────────────────
// The cloud picks a model endpoint for each task kind. The app does not call them.
// They are here for the contract and for the console. JSON: Contract/schema/ai-endpoint.json.

public struct AIEndpoint: Hashable, Sendable, Codable {
    public enum Format: String, Codable, Sendable, CaseIterable { case openai, anthropic }

    public var id: String
    public var format: Format
    public var baseURL: URL
    /// The name of the Worker secret that holds the key. Never the key.
    public var keySecret: String
    public var tools: Bool
    public var structured: Bool

    public init(id: String, format: Format, baseURL: URL, keySecret: String, tools: Bool, structured: Bool) {
        self.id = id
        self.format = format
        self.baseURL = baseURL
        self.keySecret = keySecret
        self.tools = tools
        self.structured = structured
    }
}

public struct AIRoute: Hashable, Sendable, Codable {
    /// Micro-USD for each million tokens.
    public struct Price: Hashable, Sendable, Codable {
        public var inputPerMTok: Int
        public var outputPerMTok: Int
        public var cachedPerMTok: Int

        public init(inputPerMTok: Int, outputPerMTok: Int, cachedPerMTok: Int) {
            self.inputPerMTok = inputPerMTok
            self.outputPerMTok = outputPerMTok
            self.cachedPerMTok = cachedPerMTok
        }
    }

    public var taskKind: AITaskKind
    public var endpoint: String
    public var model: String
    public var effort: String?
    public var maxTurns: Int
    public var maxInputTokens: Int
    public var maxOutputTokens: Int
    public var price: Price

    public init(taskKind: AITaskKind, endpoint: String, model: String, effort: String? = nil, maxTurns: Int,
                maxInputTokens: Int, maxOutputTokens: Int, price: Price) {
        self.taskKind = taskKind
        self.endpoint = endpoint
        self.model = model
        self.effort = effort
        self.maxTurns = maxTurns
        self.maxInputTokens = maxInputTokens
        self.maxOutputTokens = maxOutputTokens
        self.price = price
    }
}
