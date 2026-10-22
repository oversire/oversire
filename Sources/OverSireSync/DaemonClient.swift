import Foundation
import OverSireCore

/// The REST calls of an oversire daemon. Contract: daemon.json.
/// A nil token sends no Authorization header: the daemon trusts loopback.
public final class DaemonClient: Sendable {
    public static let loopback = URL(string: "http://127.0.0.1:7690")!

    public let base: URL
    let token: String?
    private let http: any HTTPTransport
    private let timeout: TimeInterval

    public init(base: URL, token: String?, http: any HTTPTransport, timeout: TimeInterval = 5) {
        self.base = base
        self.token = token
        self.http = http
        self.timeout = timeout
    }

    public func whoami() async throws -> DaemonInfo { try await get("/v1/whoami") }

    public func sessions() async throws -> DaemonSessionsPage { try await get("/v1/sessions") }

    public func group() async throws -> Group { try await get("/v1/group") }

    /// Loopback only. The daemon issues a group credential for an app on this machine.
    public func issueApp(name: String) async throws -> DeviceCredential {
        try await post("/v1/group/devices", ["name": name, "kind": DeviceKind.app.rawValue])
    }

    /// Loopback only. Installs the hooks of the named harnesses, and gives the hook state of all harnesses.
    public func hooks(install: [String]) async throws -> [HarnessHooks] {
        try await post("/v1/hooks/install", ["harnesses": install])
    }

    public func questions() async throws -> DaemonQuestionsPage { try await get("/v1/questions") }

    public func answer(_ id: String, _ a: RunnerAnswer) async throws -> DaemonAnswerResult {
        try await post("/v1/questions/\(Self.escape(id))/answer", a)
    }

    /// The answer that was given in the session, if the daemon knows it.
    public func given(_ id: String) async throws -> RunnerAnswer? {
        struct Given: Decodable { let answer: RunnerAnswer? }
        let g: Given = try await get("/v1/questions/\(Self.escape(id))/given")
        return g.answer
    }

    // Question ids hold ":" and other characters that a path segment must escape.
    static func escape(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!,
                           timeoutInterval: timeout)
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        try Self.decode(try await send(request(path)))
    }

    private func post<T: Decodable, B: Encodable>(_ path: String, _ body: B) async throws -> T {
        var r = request(path)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        r.httpBody = try enc.encode(body)
        return try Self.decode(try await send(r))
    }

    private func send(_ r: URLRequest) async throws -> Data {
        let (data, resp): (Data, HTTPURLResponse)
        do { (data, resp) = try await http.send(r) } catch let e as ProviderError { throw e } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
        switch resp.statusCode {
        case 200..<300: return data
        case 401: throw ProviderError.unauthorized
        case 403: throw ProviderError.forbidden
        case 404: throw ProviderError.notFound
        default: throw ProviderError.vendor(code: String(resp.statusCode), message: String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    static func decode<T: Decodable>(_ data: Data) throws -> T {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            guard let date = parseISO(s) else {
                throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "not an ISO 8601 time: \(s)"))
            }
            return date
        }
        do { return try dec.decode(T.self, from: data) } catch { throw ProviderError.decoding(String(describing: error)) }
    }
}
