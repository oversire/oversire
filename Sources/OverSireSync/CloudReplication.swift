import Foundation
import OverSireCore

/// The op log of the account Hub: `POST /v1/store/ops` and `GET /v1/store/ops?after=<seq>`.
/// The home daemon of a machine group has the same API. A nil token sends no Authorization header (loopback).
public struct CloudReplication: StoreReplication {
    private let base: URL
    private let token: String?
    private let http: any HTTPTransport

    public init(base: URL, token: String?, http: any HTTPTransport) {
        self.base = base
        self.token = token
        self.http = http
    }

    public func push(_ ops: [StoreOp]) async throws -> [StoreOp] {
        var req = request("v1/store/ops")
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["ops": ops])
        return try decode(Pushed.self, await http.send(req)).accepted
    }

    public func pull(after: Cursor?) async throws -> StorePull {
        let p = try decode(Pulled.self, await http.send(request("v1/store/ops?after=\(after?.rawValue ?? "0")&limit=500")))
        return StorePull(ops: p.ops, cursor: Cursor(rawValue: String(p.cursor)), more: p.more, reset: p.reset)
    }

    private struct Pushed: Decodable { let accepted: [StoreOp] }
    private struct Pulled: Decodable { let ops: [StoreOp]; let cursor: Int; let more: Bool; let reset: Bool }

    /// The 409 of a daemon: {"error", "home"} or {"error", "cloud": {...}}.
    static func notHome(_ data: Data) -> StoreNotHome {
        struct Body: Decodable {
            let error: String?
            let home: String?
            let cloud: Group.Cloud?
        }
        let b = try? JSONDecoder().decode(Body.self, from: data)
        return StoreNotHome(home: b?.home, cloud: b?.cloud != nil, message: b?.error ?? "This machine does not keep the store")
    }

    private func request(_ path: String) -> URLRequest {
        let root = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var r = URLRequest(url: URL(string: "\(root)/\(path)")!, timeoutInterval: 20)
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    private func decode<T: Decodable>(_: T.Type, _ answer: (Data, HTTPURLResponse)) throws -> T {
        let (data, resp) = answer
        switch resp.statusCode {
        case 200..<300: break
        case 401: throw ProviderError.unauthorized
        case 409: throw Self.notHome(data)
        case 429: throw ProviderError.rateLimited(retryAfter: resp.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init).map { .seconds($0) })
        default: throw ProviderError.vendor(code: String(resp.statusCode), message: String(decoding: data.prefix(200), as: UTF8.self))
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ProviderError.decoding(String(describing: error)) }
    }
}
