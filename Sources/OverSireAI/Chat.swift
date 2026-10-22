import Foundation
import OverSireCore

// ─── Assistant chat ──────────────────────────────────────────────────────────
// The chat of the assistant: threads, messages with parts, the events of a turn and the tool specs.
// Contract/schema/assistant.json has the JSON form. A ChatEngine runs one turn.

/// The risk of an action. ConfirmPolicy uses it. Contract: actions.json ActionKind.
public enum ActionKind: String, Codable, Sendable, CaseIterable {
    case read, change, outward, settings
}

/// Tokens of one call or one turn. Contract: ai-task.json AIUsage.
public struct AIUsage: Hashable, Sendable, Codable {
    public var input: Int
    public var output: Int
    public var cached: Int?
    public var costUSD: Double?

    public init(input: Int, output: Int, cached: Int? = nil, costUSD: Double? = nil) {
        self.input = input
        self.output = output
        self.cached = cached
        self.costUSD = costUSD
    }

    public static func + (a: AIUsage, b: AIUsage) -> AIUsage {
        let cached = (a.cached ?? 0) + (b.cached ?? 0)
        let cost = (a.costUSD ?? 0) + (b.costUSD ?? 0)
        return AIUsage(input: a.input + b.input, output: a.output + b.output, cached: cached == 0 ? nil : cached,
                       costUSD: a.costUSD == nil && b.costUSD == nil ? nil : cost)
    }
}

/// A tool that the model can call. `input` is a JSON Schema object.
public struct ToolSpec: Hashable, Sendable, Codable {
    public var name: String
    public var title: String
    public var description: String
    public var kind: ActionKind
    public var input: JSONValue

    public init(name: String, title: String, description: String, kind: ActionKind, input: JSONValue) {
        self.name = name
        self.title = title
        self.description = description
        self.kind = kind
        self.input = input
    }
}

/// One tool call of the model.
public struct ToolCall: Hashable, Sendable, Codable {
    public var id: String
    public var tool: String
    public var args: JSONValue
    public var kind: ActionKind?

    public init(id: String, tool: String, args: JSONValue = .object([:]), kind: ActionKind? = nil) {
        self.id = id
        self.tool = tool
        self.args = args
        self.kind = kind
    }
}

public struct ToolResult: Hashable, Sendable, Codable {
    public enum Status: String, Codable, Sendable { case ok, failed, denied, skipped }

    public var call: String
    public var status: Status
    /// One line for the chip.
    public var summary: String
    /// The data for the model.
    public var data: JSONValue?

    public init(call: String, status: Status, summary: String, data: JSONValue? = nil) {
        self.call = call
        self.status = status
        self.summary = summary
        self.data = data
    }
}

public struct Approval: Hashable, Sendable, Codable {
    public enum Decision: String, Codable, Sendable { case approved, denied, allowedByRule }

    public var call: String
    public var decision: Decision
    /// Who decided: "user", or the rule, for example "kind:read" or "chat:pr.merge".
    public var by: String?

    public init(call: String, decision: Decision, by: String? = nil) {
        self.call = call
        self.decision = decision
        self.by = by
    }
}

/// One part of a message. JSON: {"type": "<case>", ...fields}.
public enum AssistantPart: Hashable, Sendable, Codable {
    case text(String)
    /// The signature keeps an Anthropic thinking block valid in the next turn.
    case thought(String, signature: String?)
    case image(blob: String, mime: String, width: Int?, height: Int?)
    case file(blob: String, name: String, mime: String, bytes: Int)
    case mention(SubjectRef, label: String?)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    case approval(Approval)
    /// `from` is the route before the move, for Go back.
    case navigation(route: String, focus: String?, from: String?)
    case notice(code: String, text: String)

    private enum Keys: String, CodingKey {
        case type, text, signature, blob, mime, width, height, name, bytes, subject, label
        case id, tool, args, kind, call, status, summary, data, decision, by, route, focus, from, code
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "text": self = .text(try c.decode(String.self, forKey: .text))
        case "thought": self = .thought(try c.decode(String.self, forKey: .text), signature: try c.decodeIfPresent(String.self, forKey: .signature))
        case "image":
            self = .image(blob: try c.decode(String.self, forKey: .blob), mime: try c.decode(String.self, forKey: .mime),
                          width: try c.decodeIfPresent(Int.self, forKey: .width), height: try c.decodeIfPresent(Int.self, forKey: .height))
        case "file":
            self = .file(blob: try c.decode(String.self, forKey: .blob), name: try c.decode(String.self, forKey: .name),
                         mime: try c.decode(String.self, forKey: .mime), bytes: try c.decode(Int.self, forKey: .bytes))
        case "mention": self = .mention(try c.decode(SubjectRef.self, forKey: .subject), label: try c.decodeIfPresent(String.self, forKey: .label))
        case "toolCall": self = .toolCall(try ToolCall(from: decoder))
        case "toolResult": self = .toolResult(try ToolResult(from: decoder))
        case "approval": self = .approval(try Approval(from: decoder))
        case "navigation":
            self = .navigation(route: try c.decode(String.self, forKey: .route), focus: try c.decodeIfPresent(String.self, forKey: .focus),
                               from: try c.decodeIfPresent(String.self, forKey: .from))
        case "notice": self = .notice(code: try c.decode(String.self, forKey: .code), text: try c.decode(String.self, forKey: .text))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown part type \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .text(let t):
            try c.encode("text", forKey: .type)
            try c.encode(t, forKey: .text)
        case .thought(let t, let sig):
            try c.encode("thought", forKey: .type)
            try c.encode(t, forKey: .text)
            try c.encodeIfPresent(sig, forKey: .signature)
        case .image(let blob, let mime, let w, let h):
            try c.encode("image", forKey: .type)
            try c.encode(blob, forKey: .blob)
            try c.encode(mime, forKey: .mime)
            try c.encodeIfPresent(w, forKey: .width)
            try c.encodeIfPresent(h, forKey: .height)
        case .file(let blob, let name, let mime, let bytes):
            try c.encode("file", forKey: .type)
            try c.encode(blob, forKey: .blob)
            try c.encode(name, forKey: .name)
            try c.encode(mime, forKey: .mime)
            try c.encode(bytes, forKey: .bytes)
        case .mention(let s, let label):
            try c.encode("mention", forKey: .type)
            try c.encode(s, forKey: .subject)
            try c.encodeIfPresent(label, forKey: .label)
        case .toolCall(let call):
            try c.encode("toolCall", forKey: .type)
            try call.encode(to: encoder)
        case .toolResult(let r):
            try c.encode("toolResult", forKey: .type)
            try r.encode(to: encoder)
        case .approval(let a):
            try c.encode("approval", forKey: .type)
            try a.encode(to: encoder)
        case .navigation(let route, let focus, let from):
            try c.encode("navigation", forKey: .type)
            try c.encode(route, forKey: .route)
            try c.encodeIfPresent(focus, forKey: .focus)
            try c.encodeIfPresent(from, forKey: .from)
        case .notice(let code, let text):
            try c.encode("notice", forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(text, forKey: .text)
        }
    }
}

/// One chat. Store collection assistant-threads.
public struct AssistantThread: StoreRecord {
    public static let collection = "assistant-threads"

    public let id: String
    public var title: String
    public let createdAt: Date
    public var updatedAt: Date
    public var engine: EngineID
    public var pinned: Bool
    /// The items, PRs, runs and sessions that the chat touched.
    public var subjects: [SubjectRef]
    /// Action ids that the user allowed for this chat.
    public var allow: [String]
    /// The group machines that the chat touched.
    public var machines: [String]?
    /// Nil: the default of the settings.
    public var follow: Bool?
    /// The session id of the local CLI, for resume.
    public var engineSession: String?

    public init(id: String = UUID().uuidString, title: String, createdAt: Date, updatedAt: Date? = nil, engine: EngineID,
                pinned: Bool = false, subjects: [SubjectRef] = [], allow: [String] = [], machines: [String]? = nil,
                follow: Bool? = nil, engineSession: String? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.engine = engine
        self.pinned = pinned
        self.subjects = subjects
        self.allow = allow
        self.machines = machines
        self.follow = follow
        self.engineSession = engineSession
    }
}

/// One message of a chat. Store collection assistant-messages.
public struct AssistantMessage: StoreRecord {
    public static let collection = "assistant-messages"

    public enum Role: String, Codable, Sendable { case user, assistant }

    public let id: String
    public let thread: String
    public let role: Role
    public let at: Date
    public var parts: [AssistantPart]
    public var engine: EngineID?
    public var usage: AIUsage?

    public init(id: String = UUID().uuidString, thread: String, role: Role, at: Date, parts: [AssistantPart],
                engine: EngineID? = nil, usage: AIUsage? = nil) {
        self.id = id
        self.thread = thread
        self.role = role
        self.at = at
        self.parts = parts
        self.engine = engine
        self.usage = usage
    }

    /// The text parts, joined.
    public var text: String {
        parts.compactMap { if case .text(let t) = $0 { return t }; return nil }.joined()
    }
}

/// One event of a turn. JSON: {"type": "<case>", ...fields}.
public enum ChatEvent: Hashable, Sendable, Codable {
    public enum EndReason: String, Codable, Sendable { case done, cancelled, error, maxTurns }

    case textDelta(String)
    case thoughtDelta(String, signature: String?)
    case toolCall(ToolCall)
    case toolResult(ToolResult)
    /// `note` flags a call that text from a tool result asked for.
    case approvalNeeded(ToolCall, note: String?)
    case usage(AIUsage)
    case engineChanged(from: EngineID?, to: EngineID, reason: String?)
    case end(EndReason)
    case error(code: String, message: String)

    private enum Keys: String, CodingKey { case type, text, signature, call, result, note, usage, from, to, reason, code, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "textDelta": self = .textDelta(try c.decode(String.self, forKey: .text))
        case "thoughtDelta": self = .thoughtDelta(try c.decode(String.self, forKey: .text), signature: try c.decodeIfPresent(String.self, forKey: .signature))
        case "toolCall": self = .toolCall(try c.decode(ToolCall.self, forKey: .call))
        case "toolResult": self = .toolResult(try c.decode(ToolResult.self, forKey: .result))
        case "approvalNeeded": self = .approvalNeeded(try c.decode(ToolCall.self, forKey: .call), note: try c.decodeIfPresent(String.self, forKey: .note))
        case "usage": self = .usage(try c.decode(AIUsage.self, forKey: .usage))
        case "engineChanged":
            self = .engineChanged(from: try c.decodeIfPresent(EngineID.self, forKey: .from), to: try c.decode(EngineID.self, forKey: .to),
                                  reason: try c.decodeIfPresent(String.self, forKey: .reason))
        case "end": self = .end(try c.decode(EndReason.self, forKey: .reason))
        case "error": self = .error(code: try c.decode(String.self, forKey: .code), message: try c.decode(String.self, forKey: .message))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown event type \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .textDelta(let t):
            try c.encode("textDelta", forKey: .type)
            try c.encode(t, forKey: .text)
        case .thoughtDelta(let t, let sig):
            try c.encode("thoughtDelta", forKey: .type)
            try c.encode(t, forKey: .text)
            try c.encodeIfPresent(sig, forKey: .signature)
        case .toolCall(let call):
            try c.encode("toolCall", forKey: .type)
            try c.encode(call, forKey: .call)
        case .toolResult(let r):
            try c.encode("toolResult", forKey: .type)
            try c.encode(r, forKey: .result)
        case .approvalNeeded(let call, let note):
            try c.encode("approvalNeeded", forKey: .type)
            try c.encode(call, forKey: .call)
            try c.encodeIfPresent(note, forKey: .note)
        case .usage(let u):
            try c.encode("usage", forKey: .type)
            try c.encode(u, forKey: .usage)
        case .engineChanged(let from, let to, let reason):
            try c.encode("engineChanged", forKey: .type)
            try c.encodeIfPresent(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encodeIfPresent(reason, forKey: .reason)
        case .end(let r):
            try c.encode("end", forKey: .type)
            try c.encode(r, forKey: .reason)
        case .error(let code, let message):
            try c.encode("error", forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        }
    }
}
