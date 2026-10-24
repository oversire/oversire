import Foundation

// ─── live session stream ─────────────────────────────────────────────────────
// GET /v1/sessions/{id}/stream on the daemon of the session's machine. Contract: session-stream.json.

public enum StreamView: String, Codable, Sendable { case terminal, chat }

public enum StreamSource: String, Codable, Sendable { case stream, poll, wire }

public enum LeaseHolder: String, Codable, Sendable { case you, other, desktop, none }

public struct TurnTool: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable { case running, done, failed }

    public var name: String
    public var status: Status
    public var input: String?
    public var summary: String?

    public init(name: String, status: Status, input: String? = nil, summary: String? = nil) {
        self.name = name
        self.status = status
        self.input = input
        self.summary = summary
    }
}

/// One turn of the chat view. A tool turn that changes state comes again with the same seq.
public struct SessionTurn: Codable, Hashable, Sendable, Identifiable {
    public enum Role: String, Codable, Sendable { case user, assistant, tool, system }

    public var seq: Int
    public var role: Role
    public var at: Date
    public var text: String                 // Markdown
    public var tool: TurnTool?

    public var id: Int { seq }

    public init(seq: Int, role: Role, at: Date, text: String, tool: TurnTool? = nil) {
        self.seq = seq
        self.role = role
        self.at = at
        self.text = text
        self.tool = tool
    }
}

/// A JSON frame from the client. JSON: {"type": "<case>", ...fields}.
public enum StreamClientFrame: Hashable, Sendable, Codable {
    case attach(view: StreamView, cols: Int?, rows: Int?, after: Int?)
    case ack(seq: UInt64)
    case control(cols: Int, rows: Int)
    case release
    case send(text: String)

    private enum Keys: String, CodingKey { case type, view, cols, rows, after, seq, text }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "attach":
            self = .attach(view: try c.decode(StreamView.self, forKey: .view), cols: try c.decodeIfPresent(Int.self, forKey: .cols),
                           rows: try c.decodeIfPresent(Int.self, forKey: .rows), after: try c.decodeIfPresent(Int.self, forKey: .after))
        case "ack": self = .ack(seq: try c.decode(UInt64.self, forKey: .seq))
        case "control": self = .control(cols: try c.decode(Int.self, forKey: .cols), rows: try c.decode(Int.self, forKey: .rows))
        case "release": self = .release
        case "send": self = .send(text: try c.decode(String.self, forKey: .text))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown frame type \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .attach(let view, let cols, let rows, let after):
            try c.encode("attach", forKey: .type)
            try c.encode(view, forKey: .view)
            try c.encodeIfPresent(cols, forKey: .cols)
            try c.encodeIfPresent(rows, forKey: .rows)
            try c.encodeIfPresent(after, forKey: .after)
        case .ack(let seq):
            try c.encode("ack", forKey: .type)
            try c.encode(seq, forKey: .seq)
        case .control(let cols, let rows):
            try c.encode("control", forKey: .type)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
        case .release:
            try c.encode("release", forKey: .type)
        case .send(let text):
            try c.encode("send", forKey: .type)
            try c.encode(text, forKey: .text)
        }
    }
}

/// The answer to attach.
public struct StreamAttached: Codable, Hashable, Sendable {
    public var source: StreamSource
    public var cols: Int
    public var rows: Int
    public var writable: Bool
    public var resizable: Bool
    public var title: String?
    public var reason: String?              // why the source is poll

    public init(source: StreamSource, cols: Int, rows: Int, writable: Bool, resizable: Bool, title: String? = nil, reason: String? = nil) {
        self.source = source
        self.cols = cols
        self.rows = rows
        self.writable = writable
        self.resizable = resizable
        self.title = title
        self.reason = reason
    }
}

/// A JSON frame from the daemon. JSON: {"type": "<case>", ...fields}.
public enum StreamDaemonFrame: Hashable, Sendable, Codable {
    case attached(StreamAttached)
    case resized(cols: Int, rows: Int)
    case lease(LeaseHolder)
    case turns(from: Int, to: Int, turns: [SessionTurn])
    case ended(reason: String)
    case error(code: String, message: String)

    private enum Keys: String, CodingKey { case type, cols, rows, holder, from, to, turns, reason, code, message }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "attached": self = .attached(try StreamAttached(from: decoder))
        case "resized": self = .resized(cols: try c.decode(Int.self, forKey: .cols), rows: try c.decode(Int.self, forKey: .rows))
        case "lease": self = .lease(try c.decode(LeaseHolder.self, forKey: .holder))
        case "turns":
            self = .turns(from: try c.decode(Int.self, forKey: .from), to: try c.decode(Int.self, forKey: .to),
                          turns: try c.decode([SessionTurn].self, forKey: .turns))
        case "ended": self = .ended(reason: try c.decode(String.self, forKey: .reason))
        case "error": self = .error(code: try c.decode(String.self, forKey: .code), message: try c.decode(String.self, forKey: .message))
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown frame type \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .attached(let a):
            try c.encode("attached", forKey: .type)
            try a.encode(to: encoder)
        case .resized(let cols, let rows):
            try c.encode("resized", forKey: .type)
            try c.encode(cols, forKey: .cols)
            try c.encode(rows, forKey: .rows)
        case .lease(let holder):
            try c.encode("lease", forKey: .type)
            try c.encode(holder, forKey: .holder)
        case .turns(let from, let to, let turns):
            try c.encode("turns", forKey: .type)
            try c.encode(from, forKey: .from)
            try c.encode(to, forKey: .to)
            try c.encode(turns, forKey: .turns)
        case .ended(let reason):
            try c.encode("ended", forKey: .type)
            try c.encode(reason, forKey: .reason)
        case .error(let code, let message):
            try c.encode("error", forKey: .type)
            try c.encode(code, forKey: .code)
            try c.encode(message, forKey: .message)
        }
    }
}

/// A binary frame: op (1 byte) | seq (8 bytes, big endian) | data.
public struct StreamBinaryFrame: Hashable, Sendable {
    public enum Op: UInt8, Sendable { case snapshot = 1, output = 2, input = 3 }

    public var op: Op
    public var seq: UInt64                  // daemon frames: the byte count sent so far, this frame included
    public var data: Data

    public static let headerSize = 9

    public init(op: Op, seq: UInt64, data: Data) {
        self.op = op
        self.seq = seq
        self.data = data
    }

    public init?(_ bytes: Data) {
        guard bytes.count >= Self.headerSize, let op = Op(rawValue: bytes[bytes.startIndex]) else { return nil }
        var seq: UInt64 = 0
        for b in bytes[(bytes.startIndex + 1)..<(bytes.startIndex + Self.headerSize)] { seq = seq << 8 | UInt64(b) }
        self.init(op: op, seq: seq, data: Data(bytes[(bytes.startIndex + Self.headerSize)...]))
    }

    public var encoded: Data {
        var out = Data([op.rawValue])
        out.append(contentsOf: (0..<8).reversed().map { UInt8(truncatingIfNeeded: seq >> (UInt64($0) * 8)) })
        out.append(data)
        return out
    }
}
