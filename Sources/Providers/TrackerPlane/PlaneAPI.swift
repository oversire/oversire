import Foundation
import OverSireCore

// v1 for work items, v2 for intake lists and webhooks. A token works only in its own workspace.

public struct PlaneWorkspace: Codable, Hashable, Sendable {
    public static let cloudHost = "https://api.plane.so"

    public var slug: String
    public var host: String = PlaneWorkspace.cloudHost

    public init(slug: String, host: String = PlaneWorkspace.cloudHost) {
        self.slug = slug
        self.host = host
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        host = try c.decodeIfPresent(String.self, forKey: .host) ?? PlaneWorkspace.cloudHost
    }

    // Plane Cloud has the app on another host. A self-hosted Plane has both on one host.
    public var webURL: String { host == PlaneWorkspace.cloudHost ? "https://app.plane.so" : host }
    public var url: String { "\(webURL)/\(slug)/" }

    public func projectURL(_ id: String) -> String { "\(webURL)/\(slug)/projects/\(id)/issues/" }
    public func itemURL(_ key: String) -> String { "\(webURL)/\(slug)/browse/\(key)/" }
}

/// The Plane REST calls of one workspace. Answers are JSONSerialization objects.
struct PlaneAPI: Sendable {
    let workspace: PlaneWorkspace
    let token: String
    let http: any HTTPTransport

    var ws: String { "/api/v1/workspaces/\(workspace.slug)" }

    static func id(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        if let n = value as? NSNumber { return n.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let n = value as? Int { return n }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    /// Follows the cursor until max rows or the last page.
    func list(_ path: String, query: [URLQueryItem] = [], max: Int) async throws -> [[String: Any]] {
        var out: [[String: Any]] = []
        var cursor: String?
        for _ in 0..<20 {
            var q = query + [URLQueryItem(name: "per_page", value: String(min(100, Swift.max(1, max - out.count))))]
            if let cursor { q.append(URLQueryItem(name: "cursor", value: cursor)) }
            let obj = try await send("GET", path, query: q)
            if let rows = obj as? [[String: Any]] { return Array((out + rows).prefix(max)) }
            let o = obj as? [String: Any] ?? [:]
            out += o["results"] as? [[String: Any]] ?? []
            guard out.count < max, o["next_page_results"] as? Bool == true, let next = o["next_cursor"] as? String else {
                return Array(out.prefix(max))
            }
            cursor = next
        }
        return out
    }

    /// On 429 waits for Retry-After (at most 10 s) and tries again, two times.
    func send(_ method: String, _ path: String, query: [URLQueryItem] = [], body: [String: Any]? = nil) async throws -> Any? {
        guard var comps = URLComponents(string: workspace.host.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + path) else {
            throw ProviderError.transport("Bad Plane host: \(workspace.host)")
        }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw ProviderError.transport("Bad Plane URL") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue(token, forHTTPHeaderField: "X-Api-Key")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("oversire", forHTTPHeaderField: "User-Agent")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        for attempt in 0..<3 {
            let (data, resp): (Data, HTTPURLResponse)
            do { (data, resp) = try await http.send(req) }
            catch let e as ProviderError { throw e }
            catch { throw ProviderError.transport(error.localizedDescription) }
            let wait = Double(resp.value(forHTTPHeaderField: "Retry-After") ?? "")
            if resp.statusCode == 429, attempt < 2 {
                try await Task.sleep(nanoseconds: UInt64(min(10, Swift.max(1, wait ?? 2)) * 1e9))
                continue
            }
            let obj = data.isEmpty ? nil : try? JSONSerialization.jsonObject(with: data)
            switch resp.statusCode {
            case 200..<300: return obj
            case 401: throw ProviderError.unauthorized
            case 403: throw ProviderError.forbidden
            case 404: throw ProviderError.notFound
            case 429: throw ProviderError.rateLimited(retryAfter: wait.map { .seconds($0) })
            default:
                let o = obj as? [String: Any]
                let text = (o?["detail"] as? String) ?? (o?["error"] as? String) ?? (o?["message"] as? String) ?? ""
                throw ProviderError.vendor(code: String(resp.statusCode),
                                           message: text.isEmpty ? "Plane gave HTTP \(resp.statusCode)" : "Plane: \(text.prefix(160))")
            }
        }
        throw ProviderError.rateLimited(retryAfter: nil)
    }
}
