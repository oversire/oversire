import Foundation

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

    /// Member route. 404: the daemon has no session with this id.
    public func session(id: String) async throws -> DaemonSession { try await get("/v1/sessions/\(Self.escape(id))") }

    /// Member route. The state of a direct work order. 404: the daemon does not know the order.
    public func order(id: String) async throws -> DaemonOrderState { try await get("/v1/orders/\(Self.escape(id))") }

    /// Member route. The daemon sends the text to the session and waits for the end of its turn.
    /// The daemon accepts 1 to 600 s. The HTTP request waits 30 s more than the ask.
    /// Throws SessionAskError for 409 (busy, unsupported) and 504 (timeout), and ProviderError.notFound for 404.
    public func ask(session id: String, text: String, timeout: TimeInterval = 180, readOnly: Bool = true) async throws -> SessionAskReply {
        let sec = min(max(Int(timeout.rounded(.up)), 1), 600)
        var r = try json("POST", "/v1/sessions/\(Self.escape(id))/ask", SessionAsk(text: text, timeoutSec: sec, readOnly: readOnly))
        r.timeoutInterval = TimeInterval(sec + 30)
        let (data, resp) = try await exchange(r)
        if resp.statusCode >= 300, ![401, 403, 404].contains(resp.statusCode),
           let reply = try? Self.decode(data) as SessionAskReply, let code = reply.error {
            throw SessionAskError(status: resp.statusCode, code: code, message: reply.message ?? "", screenTail: reply.screenTail)
        }
        return try Self.decode(try Self.check(data, resp))
    }

    public func group() async throws -> Group { try await get("/v1/group") }

    /// Member route. The daemon installs a newer CLI and then restarts. A download can take minutes.
    public func update() async throws -> DaemonUpdate {
        var r = request("/v1/update")
        r.httpMethod = "POST"
        r.timeoutInterval = 360
        return try Self.decode(try await send(r))
    }

    /// Loopback only. The daemon issues a group credential for an app on this machine.
    public func issueApp(name: String) async throws -> DeviceCredential {
        try await post("/v1/group/devices", ["name": name, "kind": DeviceKind.app.rawValue])
    }

    /// Loopback only. Installs the hooks of the named harnesses, and gives the hook state of all harnesses.
    public func hooks(install: [String]) async throws -> [HarnessHooks] {
        try await post("/v1/hooks/install", ["harnesses": install])
    }

    /// Loopback only. The hook state of all harnesses.
    public func hookState() async throws -> [HarnessHooks] { try await get("/v1/hooks/install") }

    /// Loopback only. Removes the hooks of the named harnesses, and gives the hook state of all harnesses.
    public func removeHooks(_ names: [String]) async throws -> [HarnessHooks] {
        try await call("DELETE", "/v1/hooks/install", ["harnesses": names])
    }

    // MARK: Group (loopback)

    /// The daemons on the tailnet that answer GET /v1/whoami.
    public func peers() async throws -> [DaemonInfo] { try await get("/v1/group/peers") }

    /// A one-use code that admits a new machine or app to the group of this daemon.
    public func invite() async throws -> GroupInvite { try await post("/v1/group/invites", [String: String]()) }

    /// This daemon joins the group of the member at host with a code from that member.
    public func enter(host: String, code: String) async throws -> Group {
        try await post("/v1/group/enter", ["host": host, "code": code])
    }

    /// This daemon asks the member at host to join. The decision comes as a joinResult frame on the local WebSocket.
    public func ask(host: String) async throws -> JoinPending { try await post("/v1/group/ask", ["host": host]) }

    public func decide(_ request: String, approve: Bool) async throws {
        let _: Done = try await post("/v1/group/requests/\(Self.escape(request))/\(approve ? "approve" : "deny")", [String: String]())
    }

    /// Removes a member from the group.
    public func remove(_ machine: String) async throws {
        let _: Done = try await call("DELETE", "/v1/group/members/\(Self.escape(machine))", Optional<[String: String]>.none)
    }

    /// Public route of a member: an app on a machine without a daemon joins with a code (kind app).
    public func join(_ r: JoinRequest) async throws -> JoinResult { try await post("/v1/group/join", r) }

    package struct Done: Decodable {}

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

    // MARK: Runtimes (member routes)

    public func runtimes() async throws -> DaemonRuntimesPage { try await runtimeGet("/v1/runtimes") }

    /// Connects the live view of the runtime again, when it can, and gives its new state.
    public func retryRuntime(_ id: String) async throws -> DaemonRuntime {
        var r = try json("POST", "/v1/runtimes/\(Self.escape(id))/retry", Optional<[String: String]>.none)
        r.timeoutInterval = 30
        return try Self.decode(try await send(r))
    }

    /// The daemon checks the pairing link with the runtime, then keeps it. HTTP 400: the link did not pair.
    public func pairRuntime(_ id: String, link: String) async throws -> DaemonRuntime {
        var r = try json("POST", "/v1/runtimes/\(Self.escape(id))/pair", RuntimePair(link: link))
        r.timeoutInterval = 30
        return try Self.decode(try await send(r))
    }

    public func unpairRuntime(_ id: String) async throws -> DaemonRuntime {
        try Self.decode(try await send(try json("DELETE", "/v1/runtimes/\(Self.escape(id))/pair", Optional<[String: String]>.none)))
    }

    public func repos() async throws -> DaemonReposPage { try await runtimeGet("/v1/repos") }

    /// The models of an agent CLI on the machine. The first call can start the CLI, so it takes more time. 404: an unknown agent.
    public func models(agent: String) async throws -> AgentModels {
        var r = request("/v1/agents/\(Self.escape(agent))/models")
        r.timeoutInterval = 40
        return try Self.decode(try await send(r))
    }

    public func workspaces() async throws -> DaemonWorkspacesPage { try await runtimeGet("/v1/workspaces") }

    /// The daemon asks each runtime. Orca under load, or with many workspaces, takes more than the default timeout.
    private func runtimeGet<T: Decodable>(_ path: String) async throws -> T {
        var r = request(path)
        r.timeoutInterval = 30
        return try Self.decode(try await send(r))
    }

    public func removeWorkspace(_ id: String, _ rm: WorkspaceRemove) async throws -> WorkspaceRemoval {
        var r = try json("DELETE", "/v1/workspaces/\(Self.escape(id))", rm)
        r.timeoutInterval = 120
        return try Self.decode(try await send(r))
    }

    /// The daemon writes the files into a new folder of its own and gives their paths.
    public func writeFiles(_ files: WorkspaceFiles) async throws -> WorkspaceFilesResult {
        var r = try json("POST", "/v1/files", files)
        r.timeoutInterval = 120
        return try Self.decode(try await send(r))
    }

    /// Loopback only. Shows the session in the runtime UI.
    public func reveal(_ s: SessionRef) async throws { _ = try await send(try json("POST", "/v1/reveal", s)) }

    /// Starts a direct work order. nil: the daemon runs it (202). Else the daemon knows the id and gives its state (200).
    public func start(_ order: WorkOrder) async throws -> DaemonOrderState? {
        let (data, resp) = try await exchange(try json("POST", "/v1/orders", order))
        return resp.statusCode == 202 ? nil : try Self.decode(try Self.check(data, resp))
    }

    /// The WebSocket of the live view of a session (session-stream.json). The socket stays open for a long time.
    public func streamRequest(session id: String) -> URLRequest {
        var r = request("/v1/sessions/\(Self.escape(id))/stream")
        r.timeoutInterval = 300
        if let u = r.url, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.scheme = c.scheme == "https" ? "wss" : "ws"
            r.url = c.url
        }
        return r
    }

    // MARK: Leases (member routes on the home daemon)

    /// 409 with a Lease: another holder has it. 409 with error and home: throws StoreNotHome.
    public func acquire(_ name: String, _ r: LeaseRequest) async throws -> LeaseResult {
        let (data, resp) = try await exchange(try json("POST", "/v1/leases/\(Self.escape(name))", r))
        if resp.statusCode == 409 {
            if let l = try? Self.decode(data) as Lease { return .other(l) }
            struct Body: Decodable { let error: String?; let home: String? }
            let b = try? JSONDecoder().decode(Body.self, from: data)
            throw StoreNotHome(home: b?.home, message: b?.error ?? "This machine is not home")
        }
        return .held(try Self.decode(try Self.check(data, resp)))
    }

    public func release(_ name: String, holder: String) async throws {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "holder", value: holder)]
        _ = try await send(try json("DELETE", "/v1/leases/\(Self.escape(name))\(c.percentEncodedQuery.map { "?" + $0 } ?? "")", Optional<[String: String]>.none))
    }

    // Question ids hold ":" and other characters that a path segment must escape.
    package static func escape(_ id: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
    }

    package func request(_ path: String) -> URLRequest {
        var r = URLRequest(url: URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path)!,
                           timeoutInterval: timeout)
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        r.setValue(String(format: "%08x", UInt32.random(in: 0...UInt32.max)), forHTTPHeaderField: Self.requestID)
        return r
    }

    /// The app log and the daemon log both show it.
    public static let requestID = "X-Request-Id"

    package func get<T: Decodable>(_ path: String) async throws -> T {
        try Self.decode(try await send(request(path)))
    }

    package func post<T: Decodable, B: Encodable>(_ path: String, _ body: B) async throws -> T {
        try await call("POST", path, body)
    }

    package func call<T: Decodable, B: Encodable>(_ method: String, _ path: String, _ body: B?) async throws -> T {
        try Self.decode(try await send(try json(method, path, body)))
    }

    package func json<B: Encodable>(_ method: String, _ path: String, _ body: B?) throws -> URLRequest {
        var r = request(path)
        r.httpMethod = method
        // The loopback listener refuses a write that is not JSON, also with no body.
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            r.httpBody = try enc.encode(body)
        }
        return r
    }

    package func exchange(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do { return try await http.send(r) } catch let e as ProviderError { throw e } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }

    package func send(_ r: URLRequest) async throws -> Data {
        let (data, resp) = try await exchange(r)
        return try Self.check(data, resp)
    }

    package static func check(_ data: Data, _ resp: HTTPURLResponse) throws -> Data {
        if (200..<300).contains(resp.statusCode) { return data }
        throw refusal(resp.statusCode, data)
    }

    /// The error of a reply that is not 2xx. A 403 with a JSON `{"error": ...}` body keeps the daemon text.
    public static func refusal(_ status: Int, _ data: Data) -> ProviderError {
        struct Body: Decodable { let error: String }
        let text = (try? JSONDecoder().decode(Body.self, from: data))?.error
        switch status {
        case 401: return .unauthorized
        case 403: return text.map { .vendor(code: "forbidden", message: $0) } ?? .forbidden
        case 404: return .notFound
        default: return .vendor(code: String(status), message: text ?? String(decoding: data.prefix(200), as: UTF8.self))
        }
    }

    package static func decode<T: Decodable>(_ data: Data) throws -> T {
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

/// The daemon did not give a reply to an ask. The status is 409 (busy, unsupported), 504 (timeout), 410 (gone) or 502 (sendFailed).
public struct SessionAskError: Error, Hashable, Sendable, LocalizedError {
    /// A turn is active and the session takes no steering.
    public static let busy = "busy"
    /// OverSire cannot type into the session.
    public static let unsupported = "unsupported"
    /// The turn did not end in time.
    public static let timeout = "timeout"

    public let status: Int
    /// Open set: busy, unsupported, timeout, gone, sendFailed.
    public let code: String
    public let message: String
    /// The last lines of the screen, when the runtime has a screen.
    public let screenTail: String?

    public init(status: Int, code: String, message: String, screenTail: String? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.screenTail = screenTail
    }

    public var errorDescription: String? { message.isEmpty ? "The ask failed: \(code)" : message }
}
