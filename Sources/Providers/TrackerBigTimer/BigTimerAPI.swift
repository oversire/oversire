import Foundation
import OverSireCore

/// The HTTP client of one server and token. It holds the 401 latch.
/// The server blocks an IP after 10 failed auths, so a refused token stops all calls for 15 minutes.
final class BigTimerAPI: @unchecked Sendable {
    static let latchTime: Duration = .seconds(900)

    private let base: URL
    private let token: String
    private let http: any HTTPTransport
    private let elapsed: @Sendable () -> Duration
    private let lock = NSLock()
    private var latchedAt: Duration?

    init(base: URL, token: String, http: any HTTPTransport, clock: any Clock<Duration>) {
        self.base = base
        self.token = token
        self.http = http
        elapsed = Self.stopwatch(clock)
    }

    /// The time since the client was made, on the injected clock.
    var now: Duration { elapsed() }

    static func stopwatch<C: Clock>(_ c: C) -> @Sendable () -> Duration where C.Duration == Duration {
        let start = c.now
        return { start.duration(to: c.now) }
    }

    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json body: (any Encodable)? = nil) async throws -> Data {
        let t = elapsed()
        if let at = lock.withLock({ latchedAt }), t - at < Self.latchTime { throw ProviderError.unauthorized }
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
            if e == .unauthorized { lock.withLock { latchedAt = elapsed() } }
            throw e
        }
        return data
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
        return "Big Timer: the parent is not valid (\(field))."
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
