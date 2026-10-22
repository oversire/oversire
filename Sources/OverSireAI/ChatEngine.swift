import Foundation
import OverSireCore

// ─── Chat engines ────────────────────────────────────────────────────────────
// A ChatEngine runs one turn of the assistant chat. AIEngine stays for the short jobs.
// ChatRouter picks the engine of the thread and moves to the next one on AIError.unavailable.

/// One message of the history that a turn sends. The dialects skip the parts that the model does not read
/// (approval, navigation, notice).
public struct ChatMessage: Hashable, Sendable {
    public var role: AssistantMessage.Role
    public var parts: [AssistantPart]

    public init(role: AssistantMessage.Role, parts: [AssistantPart]) {
        self.role = role
        self.parts = parts
    }

    public init(_ m: AssistantMessage) { self.init(role: m.role, parts: m.parts) }
}

/// Gives the bytes of an image or file part.
public protocol BlobReading: Sendable {
    func blob(_ id: String) async -> Data?
}

public struct ChatRequest: Sendable {
    public var thread: String
    public var system: String
    public var messages: [ChatMessage]
    public var tools: [ToolSpec]
    public var maxTokens: Int?
    public var blobs: (any BlobReading)?
    /// The session of a local CLI, for resume.
    public var session: String?
    /// Gets the session id of a local CLI when it starts a new one.
    public var onSession: (@Sendable (String) -> Void)?

    public init(thread: String, system: String, messages: [ChatMessage], tools: [ToolSpec] = [], maxTokens: Int? = nil,
                blobs: (any BlobReading)? = nil, session: String? = nil, onSession: (@Sendable (String) -> Void)? = nil) {
        self.thread = thread
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.blobs = blobs
        self.session = session
        self.onSession = onSession
    }
}

public protocol ChatEngine: Sendable {
    var id: EngineID { get }
    /// True: the engine calls the tools itself (a local CLI through MCP). The loop then runs each call
    /// when the MCP server gets it, and ignores the toolCall and toolResult events of the engine.
    var runsTools: Bool { get }
    func available() async -> Bool
    /// One assistant turn. It ends after the tool calls that need a result, or at the end of the answer.
    /// The last event is end. Throw AIError.unavailable before the first text to give the turn to the next engine.
    func turn(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error>
}

extension ChatEngine {
    public var runsTools: Bool { false }
}

/// Runs a turn on the engine of the thread, or on the next available engine.
public struct ChatRouter: Sendable {
    public let engines: [any ChatEngine]

    public init(engines: [any ChatEngine]) { self.engines = engines }

    public func engine(_ id: EngineID) -> (any ChatEngine)? { engines.first { $0.id == id } }

    /// `prefer` goes first. A move to another engine gives engineChanged before the first event of that engine.
    /// The router moves on only while the engine gave no text and no tool call.
    public func turn(_ request: ChatRequest, prefer: EngineID?) -> AsyncThrowingStream<ChatEvent, Error> {
        let order = engines.filter { $0.id == prefer } + engines.filter { $0.id != prefer }
        return AsyncThrowingStream { out in
            let task = Task {
                var from = prefer
                var why: String?
                for e in order {
                    guard await e.available() else {
                        why = why ?? "\(e.id) is not set up."
                        continue
                    }
                    if e.id != from {
                        out.yield(.engineChanged(from: from, to: e.id, reason: why))
                        from = e.id
                    }
                    var started = false
                    do {
                        for try await ev in e.turn(request) {
                            if case .usage = ev {} else { started = true }
                            out.yield(ev)
                        }
                        out.finish()
                        return
                    } catch AIError.unavailable(let reason) where !started {
                        why = reason
                    } catch {
                        out.finish(throwing: error)
                        return
                    }
                }
                out.finish(throwing: why.map(AIError.unavailable) ?? AIError.notConfigured)
            }
            out.onTermination = { _ in task.cancel() }
        }
    }
}
