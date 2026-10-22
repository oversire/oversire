import Foundation
import OverSireCore

// ─── Chat with the API key ───────────────────────────────────────────────────
// A streamed turn in each API format: tools, images, thinking and usage.
// The history of the chat is one list of parts. Each dialect splits it into the turns of its API.

/// The wire form of one turn in one API format.
public protocol ChatDialect: Sendable {
    func chatRequest(_ r: ChatRequest, cfg: APIKeyConfig, key: String) async throws -> URLRequest
    func decoder() -> any ChatStreamDecoder
}

/// Reads the SSE events of one turn. It keeps the state between events (open tool calls, usage).
public protocol ChatStreamDecoder: Sendable {
    mutating func feed(_ e: SSEEvent) throws -> [ChatEvent]
    /// The events after the last chunk.
    mutating func finish() throws -> [ChatEvent]
}

extension APIKeyEngine: ChatEngine {
    public var chatDialect: any ChatDialect { config.format == .openai ? OpenAIDialect() : AnthropicDialect() }

    public func turn(_ request: ChatRequest) -> AsyncThrowingStream<ChatEvent, Error> {
        let clock = ChunkClock(limit: timeouts.firstByte)
        let idle = timeouts.idle
        return AsyncThrowingStream { out in
            let main = Task {
                do {
                    guard let streaming else { throw AIError.notConfigured }
                    let dialect = chatDialect
                    let req = try await dialect.chatRequest(request, cfg: config, key: key)
                    let (resp, bytes) = try await streaming.stream(req)
                    clock.tick(idle)
                    guard (200..<300).contains(resp.statusCode) else {
                        var body = Data()
                        for try await c in bytes where body.count < 65_536 {
                            clock.tick(idle)
                            body += c
                        }
                        throw Self.chatError(dialect, body, status: resp.statusCode)
                    }
                    var sse = SSEParser()
                    var dec = dialect.decoder()
                    for try await chunk in bytes {
                        clock.tick(idle)
                        for e in sse.feed(chunk) { for ev in try dec.feed(e) { out.yield(ev) } }
                    }
                    for e in sse.finish() { for ev in try dec.feed(e) { out.yield(ev) } }
                    if clock.fired { throw AIError.timeout }
                    for ev in try dec.finish() { out.yield(ev) }
                    out.finish()
                } catch {
                    out.finish(throwing: clock.fired ? AIError.timeout : Self.aiError(error))
                }
                clock.stop()
            }
            let dog = Task {
                while !clock.done {
                    try? await Task.sleep(for: .milliseconds(100))
                    if clock.expired() {
                        main.cancel()
                        return
                    }
                }
            }
            out.onTermination = { _ in
                main.cancel()
                dog.cancel()
            }
        }
    }

    static func aiError(_ e: Error) -> Error {
        switch e {
        case is AIError, is CancellationError: return e
        case ProviderError.transport(let msg): return msg.localizedCaseInsensitiveContains("timed out") ? AIError.timeout : AIError.network(msg)
        default: return AIError.network(e.localizedDescription)
        }
    }

    /// 429 and 529 give unavailable, so the router can try the next engine.
    static func chatError(_ d: any ChatDialect, _ body: Data, status: Int) -> AIError {
        let e = OpenAIDialect().httpError(body, status: status)
        guard status == 429 || status == 529, case .http(_, let msg) = e else { return e }
        return .unavailable(msg.isEmpty ? "The AI endpoint is busy (HTTP \(status))." : msg)
    }
}

/// The time limits of a streamed turn: the first byte, then each next chunk. No limit for the whole turn.
public struct ChatTimeouts: Hashable, Sendable {
    public var firstByte: TimeInterval
    public var idle: TimeInterval

    public init(firstByte: TimeInterval = 30, idle: TimeInterval = 60) {
        self.firstByte = firstByte
        self.idle = idle
    }
}

final class ChunkClock: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: Date
    private var isDone = false
    private var didFire = false

    init(limit: TimeInterval) { deadline = Date().addingTimeInterval(limit) }

    func tick(_ limit: TimeInterval) { lock.withLock { deadline = Date().addingTimeInterval(limit) } }
    func stop() { lock.withLock { isDone = true } }
    var done: Bool { lock.withLock { isDone } }
    var fired: Bool { lock.withLock { didFire } }

    func expired() -> Bool {
        lock.withLock {
            if !isDone && Date() > deadline { didFire = true }
            return didFire
        }
    }
}

// ─── Shared helpers of the two dialects ──────────────────────────────────────

enum ChatWire {
    /// The text of a tool result for the model.
    static func resultText(_ r: ToolResult) -> String {
        let data = r.data.map { $0.string ?? $0.text }
        switch r.status {
        case .ok: return data.map { r.summary.isEmpty ? $0 : "\(r.summary)\n\($0)" } ?? r.summary
        case .failed: return "Failed: \(r.summary)"
        case .denied: return "Denied: \(r.summary)"
        case .skipped: return "Skipped: \(r.summary)"
        }
    }

    static let textMimes = ["application/json", "application/xml", "application/yaml", "application/x-yaml"]

    /// A file goes in as text when it is text and small, else as a line with its name.
    static func fileText(_ name: String, _ mime: String, _ bytes: Int, _ data: Data?) -> String {
        if let data, data.count <= 100_000, mime.hasPrefix("text/") || textMimes.contains(mime),
           let s = String(data: data, encoding: .utf8) {
            return "File \(name):\n```\n\(s)\n```"
        }
        return "[File \(name), \(mime), \(bytes) bytes. Its content is not readable here.]"
    }

    /// The label and the JSON form of the ref, so the model can pass the ref to a tool.
    static func mentionText(_ s: SubjectRef, _ label: String?) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let ref = (try? enc.encode(s)).map { String(decoding: $0, as: UTF8.self) } ?? s.kind.rawValue
        return label.map { "[\($0): \(ref)]" } ?? "[\(ref)]"
    }

    static func json(_ s: String) -> JSONValue {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? .object([:]) : ((try? JSONValue(parsing: t)) ?? .object(["_raw": .string(t)]))
    }

    static func object(_ data: String) throws -> [String: Any] {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(data.utf8))) as? [String: Any] else {
            throw AIError.badReply(String(data.prefix(120)))
        }
        return o
    }
}

// ─── Anthropic ───────────────────────────────────────────────────────────────

extension AnthropicDialect: ChatDialect {
    public func chatRequest(_ r: ChatRequest, cfg: APIKeyConfig, key: String) async throws -> URLRequest {
        var req = try urlRequest(AIPrompt(system: r.system, user: "", maxTokens: r.maxTokens), cfg: cfg, key: key)
        req.timeoutInterval = 60
        var body: [String: Any] = [
            "model": cfg.model,
            "max_tokens": r.maxTokens ?? cfg.maxTokens,
            "system": r.system,
            "stream": true,
            "messages": try await messages(r),
        ]
        if !r.tools.isEmpty {
            body["tools"] = r.tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.input.any] }
            body["tool_choice"] = ["type": "auto"]
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// The parts of an assistant message split at the tool results: assistant (text, thinking, tool_use),
    /// then user (tool_result), then assistant again. Turns of the same role merge.
    func messages(_ r: ChatRequest) async throws -> [[String: Any]] {
        var out: [(String, [[String: Any]])] = []
        func add(_ role: String, _ block: [String: Any]) {
            if out.last?.0 == role { out[out.count - 1].1.append(block) } else { out.append((role, [block])) }
        }
        for m in r.messages {
            for p in m.parts {
                switch p {
                case .text(let t) where !t.isEmpty:
                    add(m.role.rawValue, ["type": "text", "text": t])
                case .thought(let t, let sig?) where m.role == .assistant:
                    add("assistant", ["type": "thinking", "thinking": t, "signature": sig])
                case .image(let blob, let mime, _, _):
                    if let data = await r.blobs?.blob(blob) {
                        add(m.role.rawValue, ["type": "image", "source": ["type": "base64", "media_type": mime, "data": data.base64EncodedString()]])
                    } else {
                        add(m.role.rawValue, ["type": "text", "text": "[An image that is no longer on this Mac.]"])
                    }
                case .file(let blob, let name, let mime, let bytes):
                    add(m.role.rawValue, ["type": "text", "text": ChatWire.fileText(name, mime, bytes, await r.blobs?.blob(blob))])
                case .mention(let s, let label):
                    add(m.role.rawValue, ["type": "text", "text": ChatWire.mentionText(s, label)])
                case .toolCall(let c):
                    add("assistant", ["type": "tool_use", "id": c.id, "name": c.tool, "input": c.args.object != nil ? c.args.any : [String: Any]()])
                case .toolResult(let res):
                    var b: [String: Any] = ["type": "tool_result", "tool_use_id": res.call, "content": ChatWire.resultText(res)]
                    if res.status != .ok { b["is_error"] = true }
                    add("user", b)
                default:
                    break
                }
            }
        }
        return out.map { ["role": $0.0, "content": $0.1] }
    }

    public func decoder() -> any ChatStreamDecoder { AnthropicStream() }
}

struct AnthropicStream: ChatStreamDecoder {
    struct Block {
        var type: String
        var id = ""
        var name = ""
        var json = ""
    }

    var blocks: [Int: Block] = [:]
    var usage = AIUsage(input: 0, output: 0)
    var ended = false

    mutating func feed(_ e: SSEEvent) throws -> [ChatEvent] {
        guard !e.data.isEmpty else { return [] }
        let o = try ChatWire.object(e.data)
        let idx = o["index"] as? Int ?? 0
        switch o["type"] as? String ?? e.event {
        case "message_start":
            let u = (o["message"] as? [String: Any])?["usage"] as? [String: Any] ?? [:]
            let cached = (u["cache_read_input_tokens"] as? Int ?? 0)
            usage = AIUsage(input: (u["input_tokens"] as? Int ?? 0) + cached + (u["cache_creation_input_tokens"] as? Int ?? 0),
                            output: u["output_tokens"] as? Int ?? 0, cached: cached == 0 ? nil : cached)
            return []
        case "content_block_start":
            let cb = o["content_block"] as? [String: Any] ?? [:]
            blocks[idx] = Block(type: cb["type"] as? String ?? "", id: cb["id"] as? String ?? "", name: cb["name"] as? String ?? "")
            if let t = cb["text"] as? String, !t.isEmpty { return [.textDelta(t)] }
            if let t = cb["thinking"] as? String, !t.isEmpty { return [.thoughtDelta(t, signature: nil)] }
            return []
        case "content_block_delta":
            let d = o["delta"] as? [String: Any] ?? [:]
            switch d["type"] as? String {
            case "text_delta": return [.textDelta(d["text"] as? String ?? "")]
            case "thinking_delta": return [.thoughtDelta(d["thinking"] as? String ?? "", signature: nil)]
            case "signature_delta": return [.thoughtDelta("", signature: d["signature"] as? String)]
            case "input_json_delta":
                blocks[idx]?.json += d["partial_json"] as? String ?? ""
                return []
            default: return []
            }
        case "content_block_stop":
            guard let b = blocks.removeValue(forKey: idx), b.type == "tool_use" else { return [] }
            return [.toolCall(ToolCall(id: b.id, tool: b.name, args: ChatWire.json(b.json)))]
        case "message_delta":
            if let u = o["usage"] as? [String: Any], let out = u["output_tokens"] as? Int { usage.output = out }
            return []
        case "message_stop":
            ended = true
            return [.usage(usage), .end(.done)]
        case "error":
            let err = o["error"] as? [String: Any] ?? [:]
            let type = err["type"] as? String ?? "error"
            let msg = err["message"] as? String ?? type
            if type == "overloaded_error" || type == "rate_limit_error" { throw AIError.unavailable(msg) }
            ended = true
            return [.error(code: type, message: msg), .end(.error)]
        default:
            return []
        }
    }

    mutating func finish() throws -> [ChatEvent] {
        if ended { return [] }
        throw AIError.badReply("the stream ended before message_stop")
    }
}

// ─── OpenAI ──────────────────────────────────────────────────────────────────

extension OpenAIDialect: ChatDialect {
    public func chatRequest(_ r: ChatRequest, cfg: APIKeyConfig, key: String) async throws -> URLRequest {
        var req = try urlRequest(AIPrompt(system: r.system, user: ""), cfg: cfg, key: key)
        req.timeoutInterval = 60
        var body: [String: Any] = [
            "model": cfg.model,
            "stream": true,
            "stream_options": ["include_usage": true],
            "messages": [["role": "system", "content": r.system]] + (try await messages(r)),
        ]
        if !cfg.effort.isEmpty && cfg.effort != "none" { body["reasoning_effort"] = cfg.effort }
        if !r.tools.isEmpty {
            body["tools"] = r.tools.map { ["type": "function", "function": ["name": $0.name, "description": $0.description, "parameters": $0.input.any]] }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    /// A user message has text and image_url parts. An assistant message has the text and the tool_calls,
    /// then one tool message for each result.
    func messages(_ r: ChatRequest) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        for m in r.messages {
            if m.role == .user {
                var content: [[String: Any]] = []
                for p in m.parts {
                    switch p {
                    case .text(let t) where !t.isEmpty: content.append(["type": "text", "text": t])
                    case .image(let blob, let mime, _, _):
                        if let data = await r.blobs?.blob(blob) {
                            content.append(["type": "image_url", "image_url": ["url": "data:\(mime);base64,\(data.base64EncodedString())"]])
                        } else {
                            content.append(["type": "text", "text": "[An image that is no longer on this Mac.]"])
                        }
                    case .file(let blob, let name, let mime, let bytes):
                        content.append(["type": "text", "text": ChatWire.fileText(name, mime, bytes, await r.blobs?.blob(blob))])
                    case .mention(let s, let label): content.append(["type": "text", "text": ChatWire.mentionText(s, label)])
                    default: break
                    }
                }
                if content.count == 1, let t = content[0]["text"] as? String { out.append(["role": "user", "content": t]) }
                else if !content.isEmpty { out.append(["role": "user", "content": content]) }
                continue
            }
            var text = ""
            var calls: [[String: Any]] = []
            func flush() {
                guard !text.isEmpty || !calls.isEmpty else { return }
                var msg: [String: Any] = ["role": "assistant", "content": text.isEmpty ? NSNull() : text]
                if !calls.isEmpty { msg["tool_calls"] = calls }
                out.append(msg)
                text = ""
                calls = []
            }
            for p in m.parts {
                switch p {
                case .text(let t): text += t
                case .toolCall(let c):
                    calls.append(["id": c.id, "type": "function", "function": ["name": c.tool, "arguments": c.args.object != nil ? c.args.text : "{}"]])
                case .toolResult(let res):
                    flush()
                    out.append(["role": "tool", "tool_call_id": res.call, "content": ChatWire.resultText(res)])
                default: break
                }
            }
            flush()
        }
        return out
    }

    public func decoder() -> any ChatStreamDecoder { OpenAIStream() }
}

struct OpenAIStream: ChatStreamDecoder {
    struct Call {
        var id = ""
        var name = ""
        var args = ""
    }

    var calls: [Int: Call] = [:]
    var usage: AIUsage?
    var ended = false

    mutating func feed(_ e: SSEEvent) throws -> [ChatEvent] {
        let data = e.data.trimmingCharacters(in: .whitespaces)
        if data.isEmpty { return [] }
        if data == "[DONE]" { return done() }
        let o = try ChatWire.object(data)
        if let err = o["error"] as? [String: Any] {
            ended = true
            let msg = err["message"] as? String ?? "error"
            let code = (err["code"] as? String) ?? (err["type"] as? String) ?? "error"
            if code == "rate_limit_exceeded" || code == "insufficient_quota" { throw AIError.unavailable(msg) }
            return [.error(code: code, message: msg), .end(.error)]
        }
        var out: [ChatEvent] = []
        if let u = o["usage"] as? [String: Any] {
            let cached = (u["prompt_tokens_details"] as? [String: Any])?["cached_tokens"] as? Int
            usage = AIUsage(input: u["prompt_tokens"] as? Int ?? 0, output: u["completion_tokens"] as? Int ?? 0,
                            cached: cached == 0 ? nil : cached)
        }
        for ch in o["choices"] as? [[String: Any]] ?? [] {
            let d = ch["delta"] as? [String: Any] ?? [:]
            if let r = (d["reasoning_content"] ?? d["reasoning"]) as? String, !r.isEmpty { out.append(.thoughtDelta(r, signature: nil)) }
            if let t = d["content"] as? String, !t.isEmpty { out.append(.textDelta(t)) }
            for tc in d["tool_calls"] as? [[String: Any]] ?? [] {
                let i = tc["index"] as? Int ?? 0
                var c = calls[i] ?? Call()
                if let id = tc["id"] as? String, !id.isEmpty { c.id = id }
                let f = tc["function"] as? [String: Any] ?? [:]
                if let n = f["name"] as? String, !n.isEmpty { c.name = n }
                c.args += f["arguments"] as? String ?? ""
                calls[i] = c
            }
            if ch["finish_reason"] as? String != nil { out += flushCalls() }
        }
        return out
    }

    mutating func flushCalls() -> [ChatEvent] {
        defer { calls = [:] }
        return calls.keys.sorted().compactMap { i in
            let c = calls[i]!
            return c.name.isEmpty ? nil : .toolCall(ToolCall(id: c.id.isEmpty ? "call_\(i)" : c.id, tool: c.name, args: ChatWire.json(c.args)))
        }
    }

    mutating func done() -> [ChatEvent] {
        guard !ended else { return [] }
        ended = true
        return flushCalls() + (usage.map { [.usage($0)] } ?? []) + [.end(.done)]
    }

    /// Some servers close the stream with no [DONE].
    mutating func finish() throws -> [ChatEvent] { done() }
}
