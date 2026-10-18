import Foundation
import OverSireCore

/// Pairs this Mac with an OverSire Cloud account. The console shows a code. The cloud gives a device token for it once.
public struct CloudPairing: Sendable {
    private let base: URL
    private let http: any HTTPTransport

    public init(base: URL, http: any HTTPTransport) {
        self.base = base
        self.http = http
    }

    /// Eight Crockford base32 characters. Spaces and dashes do not count. A 64-hex device token is not a code.
    public static func code(_ typed: String) -> String? {
        let c = typed.uppercased().filter { $0 != "-" && !$0.isWhitespace }
        return c.count == 8 && c.allSatisfy({ "0123456789ABCDEFGHJKMNPQRSTVWXYZ".contains($0) }) ? c : nil
    }

    /// Throws ProviderError.unauthorized for an unknown or old code.
    public func pair(code: String, name: String) async throws -> PairResult {
        var req = URLRequest(url: base.appendingPathComponent("pair"), timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["code": code, "name": name])
        return try await decode(PairResult.self, http.send(req))
    }

    public func whoami(token: String) async throws -> WhoAmI {
        var req = URLRequest(url: base.appendingPathComponent("v1/whoami"), timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await decode(WhoAmI.self, http.send(req))
    }

    private func decode<T: Decodable>(_: T.Type, _ answer: (Data, HTTPURLResponse)) throws -> T {
        let (data, resp) = answer
        switch resp.statusCode {
        case 200..<300: break
        case 401: throw ProviderError.unauthorized
        default: throw ProviderError.vendor(code: String(resp.statusCode), message: "Cloud answered HTTP \(resp.statusCode)")
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ProviderError.decoding(String(describing: error)) }
    }
}
