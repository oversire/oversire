import Foundation
import OverSireCore

/// The work orders of the app straight to the daemon of a member machine, with no hub.
/// Routes: POST /v1/orders and POST /v1/runner-sessions/{id}/answer and /permission.
/// The ack, result and session frames come on the WebSocket of the machine. `receive` takes them.
public final class DaemonRunnerTransport: RunnerTransport, RunnerAnswerSending, @unchecked Sendable {
    public let link: MachineLink
    private let client: DaemonClient
    private let http: any HTTPTransport
    private let lock = NSLock()
    private var watchers: [UUID: AsyncStream<RunnerMessage>.Continuation] = [:]

    public init(link: MachineLink, http: any HTTPTransport) {
        self.link = link
        self.http = http
        client = link.client(http: http)
    }

    /// 202: the daemon runs the order. 200: the daemon knows the id and sends its result frame again.
    public func send(_ order: WorkOrder) async throws {
        let (status, data) = try await post("/v1/orders", order)
        switch status {
        case 200..<300: return
        case 401: throw ProviderError.unauthorized
        case 403: throw ProviderError.forbidden
        default: throw ProviderError.vendor(code: String(status), message: Self.error(data))
        }
    }

    public func messages() -> AsyncStream<RunnerMessage> {
        let (stream, cont) = AsyncStream.makeStream(of: RunnerMessage.self)
        let id = UUID()
        lock.withLock { watchers[id] = cont }
        cont.onTermination = { [weak self] _ in self?.lock.withLock { _ = self?.watchers.removeValue(forKey: id) } }
        return stream
    }

    /// A text frame of the WebSocket of the machine. Only ack, result and session frames go on.
    public func receive(_ frame: String) {
        guard frame.contains("\"type\""), let m = try? DaemonClient.decode(Data(frame.utf8)) as RunnerMessage else { return }
        switch m {
        case .ack, .result, .session: break
        default: return
        }
        for w in lock.withLock({ Array(watchers.values) }) { w.yield(m) }
    }

    public func send(session: String, answer: RunnerAnswer) async throws -> AnswerResult {
        try Self.answered(try await post("/v1/runner-sessions/\(DaemonClient.escape(session))/answer", answer))
    }

    public func send(session: String, permission: PermissionAnswer) async throws -> AnswerResult {
        struct Body: Encodable { let permission: String; let allow: Bool }
        return try Self.answered(try await post("/v1/runner-sessions/\(DaemonClient.escape(session))/permission",
                                                Body(permission: permission.id, allow: permission.allow)))
    }

    /// The same answers as the hub: 409 no open prompt, 404 or 410 the prompt is gone.
    static func answered(_ r: (Int, Data)) throws -> AnswerResult {
        switch r.0 {
        case 200..<300: return .sent
        case 409: return .alreadyAnswered
        case 404, 410: return .gone
        case 401: throw ProviderError.unauthorized
        case 403: throw ProviderError.forbidden
        default: throw ProviderError.vendor(code: String(r.0), message: error(r.1))
        }
    }

    private func post<B: Encodable>(_ path: String, _ body: B) async throws -> (Int, Data) {
        var r = client.request(path)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        r.httpBody = try enc.encode(body)
        do {
            let (data, resp) = try await http.send(r)
            return (resp.statusCode, data)
        } catch let e as ProviderError { throw e } catch {
            throw ProviderError.transport(error.localizedDescription)
        }
    }

    private static func error(_ data: Data) -> String {
        struct Body: Decodable { let error: String }
        return (try? JSONDecoder().decode(Body.self, from: data))?.error ?? String(decoding: data.prefix(200), as: UTF8.self)
    }
}
