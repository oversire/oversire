import Foundation
import OverSireCore
import OverSireAI

// ─── MCP server ──────────────────────────────────────────────────────────────
// The agent CLIs call the OverSire tools through MCP (streamable HTTP, one POST /mcp endpoint).
// The app owns the socket (assistant_mcp.swift). This file has the HTTP and JSON-RPC logic.
// A bearer token names the thread. tools/call goes through AssistantLoop, so the cards and the log apply.

public struct HTTPMessage: Sendable, Equatable {
    public var method: String
    public var path: String
    /// Lowercase names.
    public var headers: [String: String]
    public var body: Data
}

public struct HTTPReply: Sendable, Equatable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    static func json(_ v: Any, status: Int = 200) -> HTTPReply {
        let data = (try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return HTTPReply(status: status, headers: ["Content-Type": "application/json"], body: data)
    }

    /// The bytes on the wire. The connection closes after each reply.
    public var wire: Data {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 404: "Not Found",
                      405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        return Data((head + "\r\n").utf8) + body
    }
}

/// Reads one HTTP/1.1 request from the bytes of a connection.
public struct HTTPRequestReader: Sendable {
    public static let maxBody = 4 << 20
    private var buf = Data()

    public init() {}

    public enum Result: Sendable, Equatable {
        case more
        case done(HTTPMessage)
        case bad(HTTPReply)
    }

    public mutating func feed(_ chunk: Data) -> Result {
        buf += chunk
        guard let end = buf.range(of: Data("\r\n\r\n".utf8)) else {
            return buf.count > 65_536 ? .bad(HTTPReply(status: 400)) : .more
        }
        let lines = String(decoding: buf[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return .bad(HTTPReply(status: 400)) }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? -1
        guard length >= 0 else { return .bad(HTTPReply(status: 400)) }
        guard length <= Self.maxBody else { return .bad(HTTPReply(status: 413)) }
        let bodyStart = end.upperBound
        guard buf.count - bodyStart >= length else { return .more }
        let body = Data(buf[bodyStart..<(bodyStart + length)])
        return .done(HTTPMessage(method: String(first[0]), path: String(first[1]), headers: headers, body: body))
    }
}

public actor MCPServer {
    public static let name = "oversire"
    public static let versions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    struct Grant {
        let thread: String
        var last: Date
    }

    /// Weak: the loop owns the engines, and the engines reach this server.
    private weak var loop: AssistantLoop?
    let idle: TimeInterval
    let now: @Sendable () -> Date
    private var grants: [String: Grant] = [:]

    /// `loop` nil: the app calls attach after it makes the loop.
    public init(loop: AssistantLoop? = nil, idle: TimeInterval = 30 * 60, now: @escaping @Sendable () -> Date = Date.init) {
        self.loop = loop
        self.idle = idle
        self.now = now
    }

    public func attach(_ loop: AssistantLoop) { self.loop = loop }

    /// The bearer token of the thread. The same thread gets the same token while it is open.
    public func token(for thread: String) -> String {
        if let t = grants.first(where: { $0.value.thread == thread })?.key {
            grants[t]?.last = now()
            return t
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        let t = bytes.map { String(format: "%02x", $0) }.joined()
        grants[t] = Grant(thread: thread, last: now())
        return t
    }

    public func close(thread: String) {
        grants = grants.filter { $0.value.thread != thread }
    }

    /// Removes the threads with no call in the idle time. True when no thread is left: the app stops the listener.
    public func prune() -> Bool {
        let t = now()
        grants = grants.filter { t.timeIntervalSince($0.value.last) < idle }
        return grants.isEmpty
    }

    public var isEmpty: Bool { grants.isEmpty }

    public func handle(_ m: HTTPMessage) async -> HTTPReply {
        guard m.path == "/mcp" || m.path.hasPrefix("/mcp?") else { return HTTPReply(status: 404) }
        let auth = m.headers["authorization"] ?? ""
        guard auth.hasPrefix("Bearer "), let grant = grants[String(auth.dropFirst(7))] else {
            return HTTPReply(status: 401, headers: ["WWW-Authenticate": "Bearer"])
        }
        // No stream from the server: GET is not served.
        guard m.method == "POST" else { return HTTPReply(status: 405, headers: ["Allow": "POST"]) }
        grants[String(auth.dropFirst(7))]?.last = now()
        guard let any = try? JSONSerialization.jsonObject(with: m.body) else {
            return .json(Self.error(nil, -32700, "Parse error"), status: 400)
        }
        if let batch = any as? [[String: Any]] {
            var out: [[String: Any]] = []
            for r in batch { if let x = await call(r, thread: grant.thread) { out.append(x) } }
            return out.isEmpty ? HTTPReply(status: 202) : .json(out)
        }
        guard let r = any as? [String: Any] else { return .json(Self.error(nil, -32600, "Invalid Request"), status: 400) }
        guard let x = await call(r, thread: grant.thread) else { return HTTPReply(status: 202) }
        return .json(x)
    }

    /// One JSON-RPC message. Nil for a notification or a response.
    func call(_ r: [String: Any], thread: String) async -> [String: Any]? {
        guard let method = r["method"] as? String else { return nil }
        guard let id = r["id"], !(id is NSNull) else { return nil }
        let params = r["params"] as? [String: Any] ?? [:]
        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            return Self.result(id, [
                "protocolVersion": Self.versions.contains(asked) ? asked : Self.versions[0],
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": Self.name, "version": "1"],
                "instructions": "The tools of the OverSire app. Read tools run at once. The developer approves the other tools in the app.",
            ])
        case "ping":
            return Self.result(id, [String: Any]())
        case "tools/list":
            let specs: [ToolSpec] = await loop?.tools() ?? []
            let tools = specs.map { t -> [String: Any] in
                ["name": t.name, "title": t.title, "description": t.description, "inputSchema": t.input.any,
                 "annotations": ["readOnlyHint": t.kind == .read, "destructiveHint": t.kind == .outward, "openWorldHint": t.kind == .outward]]
            }
            return Self.result(id, ["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return Self.error(id, -32602, "No tool name") }
            let args = (params["arguments"] as? [String: Any]).map { JSONValue(any: $0) } ?? .object([:])
            guard let loop else { return Self.error(id, -32603, "The assistant is off") }
            let res = await loop.runTool(ToolCall(id: "mcp-\(UUID().uuidString.prefix(8).lowercased())", tool: name, args: args), thread: thread)
            return Self.result(id, ["content": [["type": "text", "text": Self.text(res)]], "isError": res.status != .ok])
        default:
            return Self.error(id, -32601, "Method not found")
        }
    }

    static func text(_ r: ToolResult) -> String {
        let data = r.data.map { $0.string ?? $0.text }
        switch r.status {
        case .ok: return data.map { "\(r.summary)\n\($0)" } ?? r.summary
        case .failed: return "Failed: \(r.summary)"
        case .denied: return "Denied: \(r.summary)"
        case .skipped: return "Skipped: \(r.summary)"
        }
    }

    static func result(_ id: Any, _ result: Any) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": result] }

    static func error(_ id: Any?, _ code: Int, _ message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
}
