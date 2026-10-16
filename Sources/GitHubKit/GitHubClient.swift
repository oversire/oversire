import Foundation
import OverSireCore

/// One GitHub API answer.
public struct GitHubAnswer: Sendable {
    public let status: Int
    public let body: Data
    public let etag: String?
    public let budget: RateBudget?
}

/// The GitHub calls of the two GitHub adapters. A token sends HTTP to the API.
/// Without a token, `gh api` sends the same request with the login of the gh CLI.
public struct GitHubClient: Sendable {
    public static let trustedPaths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    public static let apiHost = "https://api.github.com"

    /// The first gh found. Else the first path, so that the first call says "not found".
    public static var defaultPath: String {
        trustedPaths.first { FileManager.default.isExecutableFile(atPath: $0) } ?? trustedPaths[0]
    }

    /// Only the variables that gh needs for its login and config.
    public static var environment: [String: String] {
        let env = ProcessInfo.processInfo.environment
        let allow = ["PATH", "HOME", "LANG", "SHELL", "GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR",
                     "XDG_CONFIG_HOME", "XDG_DATA_HOME", "GNUPGHOME", "SSH_AUTH_SOCK"]
        var out: [String: String] = [:]
        for key in allow { if let v = env[key] { out[key] = v } }
        if out["PATH"] == nil { out["PATH"] = "/usr/bin:/bin:/opt/homebrew/bin" }
        if out["HOME"] == nil { out["HOME"] = NSHomeDirectory() }
        return out
    }

    public let gh: String
    let commands: any CommandRunner
    let http: any HTTPTransport
    let token: String?

    public init(commands: any CommandRunner, http: any HTTPTransport, gh: String = GitHubClient.defaultPath, token: String? = nil) {
        self.commands = commands
        self.http = http
        self.gh = gh
        self.token = token.flatMap { $0.isEmpty ? nil : $0 }
    }

    // MARK: API

    /// A REST or GraphQL call. A 304 answer is a success with an empty body.
    public func api(_ method: String = "GET", _ path: String, body: Data? = nil, etag: String? = nil) async throws -> GitHubAnswer {
        let a = try await (token == nil ? viaCLI(method, path, body: body, etag: etag) : viaHTTP(method, path, body: body, etag: etag))
        switch a.status {
        case 200..<300, 304: return a
        case 401: throw ProviderError.unauthorized
        case 403, 429:
            if a.status == 429 || a.budget?.remaining == 0 {
                throw ProviderError.rateLimited(retryAfter: a.budget.map { .seconds(max(0, $0.resetAt.timeIntervalSinceNow)) })
            }
            throw ProviderError.forbidden
        case 404: throw ProviderError.notFound
        default:
            let o = try? JSONSerialization.jsonObject(with: a.body) as? [String: Any]
            let text = o?["message"] as? String ?? "GitHub gave HTTP \(a.status)"
            throw ProviderError.vendor(code: String(a.status), message: text)
        }
    }

    public func json(_ method: String = "GET", _ path: String, body: [String: Any]? = nil) async throws -> Any? {
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) }
        let a = try await api(method, path, body: data)
        return a.body.isEmpty ? nil : try? JSONSerialization.jsonObject(with: a.body)
    }

    /// The `data` object of a GraphQL answer.
    public func graphQL(_ query: String, _ variables: [String: Any]) async throws -> [String: Any] {
        let o = try await json("POST", "graphql", body: ["query": query, "variables": variables]) as? [String: Any]
        if let errors = o?["errors"] as? [[String: Any]], let first = errors.first {
            let text = first["message"] as? String ?? "GraphQL error"
            if (first["type"] as? String) == "RATE_LIMITED" { throw ProviderError.rateLimited(retryAfter: nil) }
            if (first["type"] as? String) == "NOT_FOUND" { throw ProviderError.notFound }
            throw ProviderError.vendor(code: "graphql", message: text)
        }
        guard let data = o?["data"] as? [String: Any] else { throw ProviderError.decoding("no data in the GraphQL answer") }
        return data
    }

    /// The quota. This call does not count against it.
    public func rateLimit() async throws -> RateLimit {
        let a = try await api("GET", "rate_limit")
        do { return try JSONDecoder().decode(RateLimit.self, from: a.body) } catch { throw ProviderError.decoding("rate_limit") }
    }

    // MARK: Transports

    func viaHTTP(_ method: String, _ path: String, body: Data?, etag: String?) async throws -> GitHubAnswer {
        guard let url = URL(string: GitHubClient.apiHost + "/" + path) else { throw ProviderError.transport("Bad GitHub path \(path)") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = method
        req.setValue("Bearer \(token ?? "")", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("oversire", forHTTPHeaderField: "User-Agent")
        if let etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, resp) = try await http.send(req)
        return GitHubAnswer(status: resp.statusCode, body: data, etag: resp.value(forHTTPHeaderField: "ETag"),
                            budget: Self.budget { resp.value(forHTTPHeaderField: $0) })
    }

    // The body goes through stdin, so that text never shows in the process list.
    func viaCLI(_ method: String, _ path: String, body: Data?, etag: String?) async throws -> GitHubAnswer {
        guard FileManager.default.isExecutableFile(atPath: gh) else { throw ProviderError.transport("GitHub CLI not found at \(gh)") }
        var args = ["api", "-i", "-X", method, path]
        if let etag { args += ["-H", "If-None-Match: \(etag)"] }
        if body != nil { args += ["--input", "-"] }
        let out = try await commands.run(gh, args, stdin: body, timeout: .seconds(60))
        guard let a = Self.parse(out.stdout) else { throw Self.error(stderr: out.stderr) }
        return a
    }

    /// Splits `gh api -i` output into the status, the headers and the body.
    static func parse(_ out: Data) -> GitHubAnswer? {
        let sep = Data("\r\n\r\n".utf8), sep2 = Data("\n\n".utf8)
        guard let r = out.range(of: sep) ?? out.range(of: sep2),
              let head = String(data: out[..<r.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return GitHubAnswer(status: status, body: Data(out[r.upperBound...]), etag: headers["etag"],
                            budget: budget { headers[$0.lowercased()] })
    }

    static func budget(_ header: (String) -> String?) -> RateBudget? {
        guard let limit = header("X-RateLimit-Limit").flatMap(Int.init), let left = header("X-RateLimit-Remaining").flatMap(Int.init),
              let reset = header("X-RateLimit-Reset").flatMap(TimeInterval.init) else { return nil }
        return RateBudget(limit: limit, remaining: left, resetAt: Date(timeIntervalSince1970: reset))
    }

    /// A gh failure before any HTTP answer, from its error text.
    public static func error(stderr: String) -> ProviderError {
        let low = stderr.lowercased()
        // gh words an anonymous 403 as "API rate limit exceeded ... Authenticated requests get a higher rate limit".
        if low.contains("rate limit") { return .rateLimited(retryAfter: nil) }
        if low.contains("auth") || low.contains("login") || low.contains("bad credentials") { return .unauthorized }
        // GitHub answers 404 for a private repo when the token lost a scope.
        if low.contains("404") || low.contains("could not resolve to a repository") { return .notFound }
        return .vendor(code: "gh", message: stderr.isEmpty ? "gh failed" : String(stderr.prefix(120)))
    }

    /// The text for the UI, with the fix for GitHub.
    public static func hint(_ e: ProviderError) -> String {
        switch e {
        case .rateLimited: return "GitHub API rate limit hit — retries resume after the reset"
        case .unauthorized: return "Not authenticated. Run: gh auth login"
        case .notFound: return "No access — run: gh auth login (or check the repo name)"
        default: return e.message
        }
    }
}

/// The GitHub quota of REST and GraphQL.
public struct RateLimit: Decodable, Sendable {
    public struct Bucket: Decodable, Sendable {
        public let limit: Int, used: Int, reset: TimeInterval
        public var fraction: Double { limit > 0 ? Double(used) / Double(limit) : 0 }
    }

    public let resources: [String: Bucket]

    // Runs use REST and PRs use GraphQL. The UI shows the bucket nearest its limit.
    public var buckets: [(name: String, bucket: Bucket)] {
        [("REST", resources["core"]), ("GraphQL", resources["graphql"])].compactMap { n, b in b.map { (n, $0) } }
    }
    public var fraction: Double { buckets.map { $0.bucket.fraction }.max() ?? 0 }
    public var percent: Int { Int((fraction * 100).rounded()) }

    public var budget: RateBudget? {
        guard let b = buckets.max(by: { $0.bucket.fraction < $1.bucket.fraction })?.bucket else { return nil }
        return RateBudget(limit: b.limit, remaining: b.limit - b.used, resetAt: Date(timeIntervalSince1970: b.reset))
    }
}
