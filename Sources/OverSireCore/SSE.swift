import Foundation

/// One server-sent event. `event` is "message" when the stream gives no name.
public struct SSEEvent: Hashable, Sendable {
    public var event: String
    public var data: String
    public var id: String?

    public init(event: String = "message", data: String, id: String? = nil) {
        self.event = event
        self.data = data
        self.id = id
    }
}

/// Bytes to events, as the WHATWG event stream format says. Chunks can cut a line or a UTF-8 character.
/// At the end of the stream, `finish` gives the last event also when no blank line follows it.
public struct SSEParser: Sendable {
    private var pending: [UInt8] = []
    private var afterCR = false
    private var event = ""
    private var data: [String] = []
    private var lastID: String?

    public init() {}

    public mutating func feed(_ chunk: Data) -> [SSEEvent] {
        var out: [SSEEvent] = []
        for b in chunk {
            if afterCR {
                afterCR = false
                if b == 0x0A { continue }
            }
            if b == 0x0A || b == 0x0D {
                afterCR = b == 0x0D
                if let e = line(pending) { out.append(e) }
                pending.removeAll(keepingCapacity: true)
            } else {
                pending.append(b)
            }
        }
        return out
    }

    public mutating func finish() -> [SSEEvent] {
        var out: [SSEEvent] = []
        if !pending.isEmpty, let e = line(pending) { out.append(e) }
        pending.removeAll()
        if let e = line([]) { out.append(e) }
        return out
    }

    private mutating func line(_ bytes: [UInt8]) -> SSEEvent? {
        if bytes.isEmpty {
            defer { event = ""; data = [] }
            guard !data.isEmpty else { return nil }
            return SSEEvent(event: event.isEmpty ? "message" : event, data: data.joined(separator: "\n"), id: lastID)
        }
        let s = String(decoding: bytes, as: UTF8.self)
        if s.hasPrefix(":") { return nil }
        let field: Substring, value: Substring
        if let colon = s.firstIndex(of: ":") {
            field = s[..<colon]
            let v = s[s.index(after: colon)...]
            value = v.hasPrefix(" ") ? v.dropFirst() : v
        } else {
            field = s[...]
            value = ""
        }
        switch field {
        case "data": data.append(String(value))
        case "event": event = String(value)
        case "id" where !value.contains("\0"): lastID = String(value)
        default: break
        }
        return nil
    }

    /// The events of a byte stream.
    public static func events(_ bytes: AsyncThrowingStream<Data, Error>) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                var p = SSEParser()
                do {
                    for try await chunk in bytes {
                        for e in p.feed(chunk) { cont.yield(e) }
                    }
                    for e in p.finish() { cont.yield(e) }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}
