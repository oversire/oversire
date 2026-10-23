import Foundation
import OverSireCore
import OverSireSync

/// An oversire daemon in memory: the REST routes of daemon.json and a WebSocket that pokes.
/// Set `token` to ask for a credential. Set `online` to false to refuse all calls.
public final class FakeDaemon: HTTPTransport, WebSocketConnecting, @unchecked Sendable {
    private let lock = NSLock()
    private var _info: DaemonInfo
    private var _group: Group?
    private var _sessions: [DaemonSession] = []
    private var _questions: [DaemonQuestion] = []
    private var _events: [ProviderEvent] = []
    private var _results: [String: DaemonAnswerResult] = [:]
    private var _given: [String: RunnerAnswer] = [:]
    private var _answered: Set<String> = []
    private var _answers: [(id: String, answer: RunnerAnswer)] = []
    private var _requests: [URLRequest] = []
    private var _acks: [Int] = []
    private var _issued = 0
    private var _online = true
    private var _sessionsError: ProviderError?
    private var _peers: [DaemonInfo] = []
    private var _hooks: [HarnessHooks] = []
    private var _codes: Set<String> = []
    private var _pending: [JoinRequestFrame] = []
    private var _decisions: [(id: String, approve: Bool)] = []
    private var _asked: JoinPending?
    private var _joined: JoinResult?
    private var _update: DaemonUpdate?
    private var sockets: [FakeDaemonSocket] = []

    /// The credential that a call must carry. nil: no check (loopback).
    public let token: String?
    /// The runtime routes: runtimes, workspaces, files, orders and workers.
    public let runtime = FakeDaemonRuntimes()

    public init(info: DaemonInfo, group: Group? = nil, token: String? = nil) {
        _info = info
        _group = group
        self.token = token
    }

    /// A daemon on loopback with the fixture values of daemon-info/loopback.json.
    public convenience init(machine: String = "mba", group: Group? = nil, token: String? = nil) {
        self.init(info: DaemonInfo(machine: MachineName(rawValue: machine), version: "0.4.0", contract: 1, roles: ["serve"], runtimes: ["orca"],
                                   harnesses: [], group: group?.id, listen: .init(loopback: "127.0.0.1:7690")),
                  group: group, token: token)
    }

    private func with<T>(_ f: () throws -> T) rethrows -> T { try lock.withLock(f) }

    public var online: Bool { get { with { _online } } set { with { _online = newValue } } }
    public var info: DaemonInfo { get { with { _info } } set { with { _info = newValue } } }
    public var group: Group? { get { with { _group } } set { with { _group = newValue } } }
    public var sessions: [DaemonSession] { get { with { _sessions } } set { with { _sessions = newValue } } }
    public var questions: [DaemonQuestion] { get { with { _questions } } set { with { _questions = newValue } } }
    /// The error of the next GET /v1/sessions calls.
    public var sessionsError: ProviderError? { get { with { _sessionsError } } set { with { _sessionsError = newValue } } }
    public var requests: [URLRequest] { with { _requests } }
    /// GET /v1/group/peers.
    public var peers: [DaemonInfo] { get { with { _peers } } set { with { _peers = newValue } } }
    /// GET /v1/hooks/install. POST sets the named ones to installed, DELETE to missing.
    public var hooks: [HarnessHooks] { get { with { _hooks } } set { with { _hooks = newValue } } }
    /// The codes that POST /v1/group/join and POST /v1/group/enter accept. A code works once.
    public var codes: Set<String> { get { with { _codes } } set { with { _codes = newValue } } }
    /// GET /v1/group/requests.
    public var pending: [JoinRequestFrame] { get { with { _pending } } set { with { _pending = newValue } } }
    /// The answer of POST /v1/group/ask. nil: 502, the host does not answer.
    public var asked: JoinPending? { get { with { _asked } } set { with { _asked = newValue } } }
    /// The answer of POST /v1/group/join for a valid code. Default: the group with a credential for the app.
    public var joined: JoinResult? { get { with { _joined } } set { with { _joined = newValue } } }
    /// The answer of POST /v1/update. nil: 404, as from a CLI before 0.2.2.
    public var update: DaemonUpdate? { get { with { _update } } set { with { _update = newValue } } }
    /// POST /v1/group/requests/{id}/approve and deny calls.
    public var decisions: [(id: String, approve: Bool)] { with { _decisions } }
    /// The body of each call, as a JSON object.
    public func body(of call: String) -> [String: Any]? {
        requests.last { "\($0.httpMethod ?? "GET") \($0.url!.path)" == call }
            .flatMap { $0.httpBody }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    /// "<METHOD> <path>" of each call.
    public var calls: [String] { requests.map { "\($0.httpMethod ?? "GET") \($0.url!.path)" } }
    public var answers: [(id: String, answer: RunnerAnswer)] { with { _answers } }
    public var acks: [Int] { with { _acks } }
    /// POST /v1/group/devices calls.
    public var issued: Int { with { _issued } }

    /// The answer of POST /v1/questions/{id}/answer. Default: sent.
    public func result(_ id: String, _ r: DaemonAnswerResult) { with { _results[id] = r } }
    public func given(_ id: String, _ a: RunnerAnswer) { with { _given[id] = a } }

    /// Appends an event to the log and pokes the sockets.
    public func emit(_ e: ProviderEvent) {
        with { _events.append(e) }
        push(#"{"type":"poke"}"#)
    }

    /// The daemon sends this after a roster change.
    public func groupChanged() { push(#"{"type":"group"}"#) }

    public func push(_ frame: String) { with { sockets }.forEach { $0.push(frame) } }

    /// Closes the open sockets, as a daemon that stops.
    public func dropSockets() {
        let s = with { () -> [FakeDaemonSocket] in defer { sockets = [] }; return sockets }
        s.forEach { $0.close() }
    }

    // MARK: WebSocketConnecting

    public func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        try with {
            _requests.append(request)
            guard _online else { throw ProviderError.transport("connection refused") }
            guard authorized(request) else { throw ProviderError.unauthorized }
            let s = FakeDaemonSocket()
            sockets.append(s)
            return s
        }
    }

    // MARK: HTTPTransport

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let (status, body): (Int, Data) = try with {
            _requests.append(request)
            guard _online else { throw ProviderError.transport("connection refused") }
            guard authorized(request) else { return (401, Data(#"{"error":"unauthorized"}"#.utf8)) }
            return try route(request.httpMethod ?? "GET", url, body: request.httpBody)
        }
        return (body, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    private func authorized(_ r: URLRequest) -> Bool {
        guard let token else { return true }
        return r.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)"
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func ok<T: Encodable>(_ v: T) throws -> (Int, Data) { (200, try Self.encoder.encode(v)) }
    private var missing: (Int, Data) { (404, Data(#"{"error":"not_found"}"#.utf8)) }

    // Runs under the lock.
    private func route(_ method: String, _ url: URL, body: Data?) throws -> (Int, Data) {
        // Split the escaped path: an id can hold an escaped "/".
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? url.path
        let parts = path.split(separator: "/").map(String.init).map { $0.removingPercentEncoding ?? $0 }
        switch (method, parts) {
        case ("GET", ["v1", "whoami"]): return try ok(_info)
        case ("GET", ["v1", "health"]): return (200, Data(#"{"ok":true}"#.utf8))
        case ("POST", ["v1", "update"]):
            guard let u = _update else { return missing }
            return try ok(u)
        case ("GET", ["v1", "sessions"]):
            if let e = _sessionsError { throw e }
            return try ok(DaemonSessionsPage(sessions: _sessions))
        case ("GET", let p) where p.count == 3 && p[1] == "sessions":
            return try _sessions.first { $0.id == p[2] }.map(ok) ?? missing
        case ("GET", ["v1", "questions"]): return try ok(DaemonQuestionsPage(questions: _questions))
        case ("POST", let p) where p.count == 4 && p[1] == "questions" && p[3] == "answer":
            let a = try Self.decoder.decode(RunnerAnswer.self, from: body ?? Data())
            _answers.append((p[2], a))
            let open = _questions.contains { $0.id.rawValue == p[2] }
            let r = _results[p[2]] ?? DaemonAnswerResult(result: open ? .sent : _answered.contains(p[2]) ? .alreadyAnswered : .gone)
            if r.result == .sent {
                _questions.removeAll { $0.id.rawValue == p[2] }
                _answered.insert(p[2])
            }
            return try ok(r)
        case ("GET", let p) where p.count == 4 && p[1] == "questions" && p[3] == "given":
            struct Given: Encodable { let answer: RunnerAnswer? }
            return try ok(Given(answer: _given[p[2]]))
        case ("GET", ["v1", "group"]): return try _group.map(ok) ?? missing
        case ("POST", ["v1", "group", "devices"]):
            _issued += 1
            return try ok(DeviceCredential(deviceId: "APP\(_issued)", token: "osd1.APP\(_issued).secret"))
        case ("GET", ["v1", "group", "peers"]): return try ok(_peers)
        case ("POST", ["v1", "group", "invites"]):
            let code = "K7Q2-M9XD"
            _codes.insert(code)
            return try ok(GroupInvite(code: code, via: _info.machine, expiresAt: Date().addingTimeInterval(600)))
        case ("POST", ["v1", "group", "enter"]):
            let d = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: String] ?? [:]
            guard let code = d["code"], _codes.remove(code) != nil else { return (502, Data(#"{"error":"group: the code is not valid or was used"}"#.utf8)) }
            return try _group.map(ok) ?? missing
        case ("POST", ["v1", "group", "ask"]):
            guard let p = _asked else { return (502, Data(#"{"error":"ask: the host does not answer"}"#.utf8)) }
            return try ok(p)
        case ("POST", ["v1", "group", "join"]):
            let r = try Self.decoder.decode(JoinRequest.self, from: body ?? Data())
            guard let code = r.code, _codes.remove(code) != nil else { return (403, Data(#"{"error":"group: the code is not valid or was used"}"#.utf8)) }
            guard let g = _group else { return (409, Data(#"{"error":"group: this machine has no group"}"#.utf8)) }
            _issued += 1
            return try ok(_joined ?? JoinResult(group: g, credential: DeviceCredential(deviceId: "APP\(_issued)", token: "osd1.APP\(_issued).secret")))
        case ("GET", ["v1", "group", "requests"]): return try ok(_pending)
        case ("POST", let p) where p.count == 5 && p[1] == "group" && p[2] == "requests" && ["approve", "deny"].contains(p[4]):
            guard _pending.contains(where: { $0.request == p[3] }) else { return missing }
            _pending.removeAll { $0.request == p[3] }
            _decisions.append((p[3], p[4] == "approve"))
            return (200, Data(#"{"ok":true}"#.utf8))
        case ("POST", ["v1", "group", "home"]):
            let d = try JSONSerialization.jsonObject(with: body ?? Data()) as? [String: String] ?? [:]
            guard let m = d["machine"], var g = _group, g.members.contains(where: { $0.machine.rawValue == m }) else { return missing }
            g.home = MachineName(rawValue: m)
            _group = g
            return (200, Data(#"{"ok":true}"#.utf8))
        case ("DELETE", let p) where p.count == 4 && p[1] == "group" && p[2] == "members":
            guard var g = _group, g.members.contains(where: { $0.machine.rawValue == p[3] }) else { return missing }
            g.members.removeAll { $0.machine.rawValue == p[3] }
            _group = g
            return (200, Data(#"{"ok":true}"#.utf8))
        case ("GET", ["v1", "hooks", "install"]): return try ok(_hooks)
        case (let m, ["v1", "hooks", "install"]) where m == "POST" || m == "DELETE":
            let d = try body.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: [String]] } ?? [:]
            let names = Set(d["harnesses"] ?? [])
            _hooks = _hooks.map { h in names.contains(h.name) ? HarnessHooks(name: h.name, hooks: m == "POST" ? .installed : .missing) : h }
            return try ok(_hooks)
        case ("GET", ["v1", "events"]):
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let after = q.first { $0.name == "after" }.flatMap { $0.value.flatMap(Int.init) } ?? 0
            let page = _events.enumerated().filter { $0.offset + 1 > after }
            let events = try page.map { try JSONSerialization.jsonObject(with: Self.encoder.encode($0.element)) }
            let d: [String: Any] = ["events": events, "head": _events.count, "next": max(after, _events.count), "more": false, "truncated": false]
            return (200, try JSONSerialization.data(withJSONObject: d))
        case ("POST", ["v1", "ack"]):
            if let body, let d = try JSONSerialization.jsonObject(with: body) as? [String: Int], let seq = d["seq"] { _acks.append(seq) }
            return (200, Data(#"{"ok":true}"#.utf8))
        default: return try runtime.route(method, parts, body: body, machine: _info.machine, sessions: &_sessions) ?? missing
        }
    }
}

/// One WebSocket of a FakeDaemon. It answers "ping" with "pong".
public final class FakeDaemonSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false

    public func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            let next: Result<String, Error>? = lock.withLock {
                if closed { return .failure(ProviderError.transport("closed")) }
                if queue.isEmpty { waiter = c; return nil }
                return .success(queue.removeFirst())
            }
            if let next { c.resume(with: next) }
        }
    }

    public func send(_ text: String) async throws {
        if text == "ping" { push("pong") }
    }

    public func close() {
        let w: CheckedContinuation<String, Error>? = lock.withLock {
            closed = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume(throwing: ProviderError.transport("closed"))
    }

    func push(_ text: String) {
        let w: CheckedContinuation<String, Error>? = lock.withLock {
            if closed { return nil }
            if let w = waiter { waiter = nil; return w }
            queue.append(text)
            return nil
        }
        w?.resume(returning: text)
    }
}
