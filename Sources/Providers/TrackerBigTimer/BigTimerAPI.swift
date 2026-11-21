import Foundation
import OverSireCore

/// The HTTP client of one server and token. It holds the 401 latch.
/// The server blocks an IP for 15 minutes after more than 10 failed auths in 1 minute.
/// Thus a refused token stops all calls for 15 minutes.
final class BigTimerAPI: @unchecked Sendable {
    static let latchTime: Duration = .seconds(900)

    private let base: URL
    private let token: String
    private let http: any HTTPTransport
    private let streaming: (any HTTPStreaming)?
    private let elapsed: @Sendable () -> Duration
    private let lock = NSLock()
    private var latchedAt: Duration?

    init(base: URL, token: String, http: any HTTPTransport, streaming: (any HTTPStreaming)?, clock: any Clock<Duration>) {
        self.base = base
        self.token = token
        self.http = http
        self.streaming = streaming
        elapsed = Self.stopwatch(clock)
    }

    /// The time since the client was made, on the injected clock.
    var now: Duration { elapsed() }

    static func stopwatch<C: Clock>(_ c: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let start = c.now
        return { start.duration(to: c.now) }
    }

    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json body: (any Encodable)? = nil) async throws -> Data {
        try checkLatch()
        var req = URLRequest(url: try url(path, query), timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONEncoder().encode(body)
        }
        let (data, resp): (Data, HTTPURLResponse)
        do { (data, resp) = try await http.send(req) }
        catch let e as ProviderError { throw e }
        catch { throw ProviderError.transport(error.localizedDescription) }
        if let e = Self.error(status: resp.statusCode, body: data, response: resp) {
            if e == .unauthorized { setLatch() }
            throw e
        }
        return data
    }

    private func checkLatch() throws {
        if let at = lock.withLock({ latchedAt }), elapsed() - at < Self.latchTime { throw ProviderError.unauthorized }
    }

    private func setLatch() { lock.withLock { latchedAt = elapsed() } }

    /// The longest wait of a stream with no byte. It is more than the feed timeout, so the source cuts first.
    static let streamTimeout: TimeInterval = 90

    /// Opens an event stream. It uses the latch as `send` does. A status that is not 2xx gives the mapped error.
    func stream(_ path: String, lastEventID: String?) async throws -> AsyncThrowingStream<Data, Error> {
        guard let streaming else { throw ProviderError.unsupported(.liveFeed) }
        try checkLatch()
        var req = URLRequest(url: try url(path, []), timeoutInterval: Self.streamTimeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let lastEventID { req.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID") }
        let resp: HTTPURLResponse, body: AsyncThrowingStream<Data, Error>
        do { (resp, body) = try await streaming.stream(req) }
        catch let e as ProviderError { throw e }
        catch is CancellationError { throw CancellationError() }
        catch { throw ProviderError.transport(error.localizedDescription) }
        guard (200..<300).contains(resp.statusCode) else {
            var head = Data()
            do {
                for try await chunk in body {
                    head.append(chunk)
                    if head.count >= 4096 { break }
                }
            } catch {}
            let e = Self.error(status: resp.statusCode, body: head.prefix(4096), response: resp) ?? .transport("HTTP \(resp.statusCode)")
            if e == .unauthorized { setLatch() }
            if resp.statusCode == 503, let wait = Double(resp.value(forHTTPHeaderField: "Retry-After") ?? "") {
                throw ProviderError.rateLimited(retryAfter: .seconds(wait))
            }
            throw e
        }
        if let type = resp.value(forHTTPHeaderField: "Content-Type")?.lowercased(), !type.hasPrefix("text/event-stream") {
            throw ProviderError.vendor(code: "not_a_stream", message: "The server did not answer with an event stream.")
        }
        return body
    }

    func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        try Self.decode(T.self, from: try await send("GET", path, query: query))
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            guard let date = parseISO(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad time \(s)"))
            }
            return date
        }
        do { return try d.decode(T.self, from: data) }
        catch { throw ProviderError.decoding(String(describing: error)) }
    }

    static func error(status: Int, body: Data, response: HTTPURLResponse) -> ProviderError? {
        if (200..<300).contains(status) { return nil }
        let problem = try? JSONDecoder().decode(BTProblem.self, from: body)
        switch status {
        case 401: return .unauthorized
        case 403: return .forbidden
        case 404: return .notFound
        case 429:
            let wait = Double(response.value(forHTTPHeaderField: "Retry-After") ?? "")
            return .rateLimited(retryAfter: wait.map { .seconds($0) })
        case 400 where problem?.code == "validation" && problem?.errors?["parent_uuid"] != nil:
            return .vendor(code: "validation", message: parentMessage(problem?.errors?["parent_uuid"] ?? ""))
        case 400 where problem?.code == "validation" && problem?.errors?.keys.contains(where: epicFields.contains) == true:
            let errors = problem?.errors ?? [:]
            let field = epicFields.first(where: { errors[$0] != nil }) ?? ""
            return .vendor(code: "validation", message: epicMessage(field, errors[field] ?? ""))
        default:
            return .vendor(code: problem?.code ?? String(status),
                           message: problem?.detail ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }

    /// Simple text for a broken sub-item rule. An unknown server text stays in the message.
    static func parentMessage(_ field: String) -> String {
        if field.contains("a sub-item cannot have sub-items") { return "Big Timer: a sub-item cannot have sub-items." }
        if field.contains("so it cannot be a sub-item") { return "Big Timer: an item with sub-items cannot become a sub-item." }
        if field.contains("another project") { return "Big Timer: a sub-item must be in the project of its parent." }
        if field.contains("the issue itself") { return "Big Timer: an item cannot be its own parent." }
        if field.contains("is an epic") { return "Big Timer: an epic is not a parent. Put the item in the epic." }
        if field.contains("epic cannot be a sub-item") { return "Big Timer: an epic cannot be a sub-item." }
        return "Big Timer: the parent is not valid (\(field))."
    }

    private static let epicFields = ["epic_uuid", "kind", "health", "epic"]

    /// Simple text for a broken epic rule. An unknown server text stays in the message.
    static func epicMessage(_ field: String, _ text: String) -> String {
        switch field {
        case "epic_uuid" where text.contains("sub-item uses the epic of its parent"): return "Big Timer: a sub-item uses the epic of its parent."
        case "epic_uuid" where text.contains("epic cannot be in an epic"): return "Big Timer: an epic cannot be in an epic."
        case "epic_uuid" where text.contains("another project"): return "Big Timer: an epic must be in the project of its items."
        case "epic_uuid" where text.contains("is not an epic"): return "Big Timer: the item is not an epic."
        case "kind": return "Big Timer: the kind of an item is fixed after create."
        case "health" where text.contains("only an update on an epic"): return "Big Timer: only an update on an epic has a health."
        case "health": return "Big Timer: the health must be on_track, at_risk or off_track."
        case "epic": return "Big Timer: the item is not an epic."
        default: return "Big Timer: the epic is not valid (\(text))."
        }
    }

    /// The path joins the path of the base URL. Query values keep "+" and "&" safe.
    private func url(_ path: String, _ query: [URLQueryItem]) throws -> URL {
        guard var c = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw ProviderError.transport("Bad server URL") }
        let prefix = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        c.path = (prefix.isEmpty ? "" : "/" + prefix) + path
        if !query.isEmpty {
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&+=#")
            c.percentEncodedQuery = query.map { q in
                let v = (q.value ?? "").addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
                return "\(q.name)=\(v)"
            }.joined(separator: "&")
        }
        guard let url = c.url else { throw ProviderError.transport("Bad server URL") }
        return url
    }
}
