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
    private var _answers: [(id: String, answer: RunnerAnswer)] = []
    private var _requests: [URLRequest] = []
    private var _acks: [Int] = []
    private var _issued = 0
    private var _online = true
    private var _sessionsError: ProviderError?
    private var sockets: [FakeDaemonSocket] = []

    /// The credential that a call must carry. nil: no check (loopback).
    public let token: String?

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
        let parts = url.path.split(separator: "/").map(String.init).map { $0.removingPercentEncoding ?? $0 }
        switch (method, parts) {
        case ("GET", ["v1", "whoami"]): return try ok(_info)
        case ("GET", ["v1", "health"]): return (200, Data(#"{"ok":true}"#.utf8))
        case ("GET", ["v1", "sessions"]):
            if let e = _sessionsError { throw e }
            return try ok(DaemonSessionsPage(sessions: _sessions))
        case ("GET", let p) where p.count == 3 && p[1] == "sessions":
            return try _sessions.first { $0.id == p[2] }.map(ok) ?? missing
        case ("GET", ["v1", "questions"]): return try ok(DaemonQuestionsPage(questions: _questions))
        case ("POST", let p) where p.count == 4 && p[1] == "questions" && p[3] == "answer":
            let a = try Self.decoder.decode(RunnerAnswer.self, from: body ?? Data())
            _answers.append((p[2], a))
            let r = _results[p[2]] ?? DaemonAnswerResult(result: _questions.contains { $0.id.rawValue == p[2] } ? .sent : .gone)
            if r.result == .sent { _questions.removeAll { $0.id.rawValue == p[2] } }
            return try ok(r)
        case ("GET", let p) where p.count == 4 && p[1] == "questions" && p[3] == "given":
            struct Given: Encodable { let answer: RunnerAnswer? }
            return try ok(Given(answer: _given[p[2]]))
        case ("GET", ["v1", "group"]): return try _group.map(ok) ?? missing
        case ("POST", ["v1", "group", "devices"]):
            _issued += 1
            return try ok(DeviceCredential(deviceId: "APP\(_issued)", token: "osd1.APP\(_issued).secret"))
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
        default: return missing
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
