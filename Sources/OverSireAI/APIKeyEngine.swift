import Foundation
import OverSireCore

// Calls the endpoint of the user with the user's own key. Two API formats: OpenAI compatible and Anthropic.

public enum AIFormat: String, Codable, Sendable { case openai, anthropic }

public struct APIKeyConfig: Hashable, Sendable {
    public var format: AIFormat
    public var baseURL: String
    public var model: String
    public var effort: String           // OpenAI only. "none" leaves out the field.
    public var maxTokens: Int           // Anthropic only, when the prompt sets no limit

    public init(format: AIFormat = .openai, baseURL: String = "", model: String = "", effort: String = "low", maxTokens: Int = 1024) {
        self.format = format
        self.baseURL = baseURL
        self.model = model
        self.effort = effort
        self.maxTokens = maxTokens
    }
}

/// The system and user text of one call.
public struct AIPrompt: Hashable, Sendable {
    public var system: String
    public var user: String
    /// Nil uses the limit of the engine settings.
    public var maxTokens: Int?

    public init(system: String, user: String, maxTokens: Int? = nil) {
        self.system = system
        self.user = user
        self.maxTokens = maxTokens
    }
}

public struct APIKeyEngine: AIEngine {
    public let id = EngineID.apiKey
    public let config: APIKeyConfig
    let key: String
    let http: any HTTPTransport

    public init(config: APIKeyConfig, key: String, http: any HTTPTransport) {
        self.config = config
        self.key = key
        self.http = http
    }

    public var dialect: any AIDialect { config.format == .openai ? OpenAIDialect() : AnthropicDialect() }

    public func available() async -> Bool { !key.isEmpty && !config.baseURL.isEmpty && !config.model.isEmpty }

    public func run(_ task: AITask) async throws -> String {
        try await send(task.kind.prompt(task.input))
    }

    public func send(_ p: AIPrompt) async throws -> String {
        let dialect = self.dialect
        let req = try dialect.urlRequest(p, cfg: config, key: key)
        let data: Data, resp: HTTPURLResponse
        do { (data, resp) = try await http.send(req) } catch let ProviderError.transport(msg) {
            throw msg.localizedCaseInsensitiveContains("timed out") ? AIError.timeout : AIError.network(msg)
        } catch let e as AIError { throw e } catch {
            throw AIError.network(error.localizedDescription)
        }
        return try dialect.text(from: data, status: resp.statusCode)
    }
}

public protocol AIDialect: Sendable {
    func urlRequest(_ p: AIPrompt, cfg: APIKeyConfig, key: String) throws -> URLRequest
    func text(from data: Data, status: Int) throws -> String
}

extension AIDialect {
    // The first line of the error message in the body, or of the body itself.
    func httpError(_ data: Data, status: Int) -> AIError {
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let err = obj?["error"]
        let msg = (err as? [String: Any])?["message"] as? String ?? err as? String
            ?? obj?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)
        let line = msg.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return .http(status, String(line.prefix(160)))
    }

    static func trimmedBase(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

public struct OpenAIDialect: AIDialect {
    public static let efforts = ["none", "minimal", "low", "medium", "high"]

    public init() {}

    public static func endpoint(_ base: String) -> String {
        let b = trimmedBase(base)
        return b.hasSuffix("/chat/completions") ? b : b + "/chat/completions"
    }

    public func urlRequest(_ p: AIPrompt, cfg: APIKeyConfig, key: String) throws -> URLRequest {
        guard let url = URL(string: Self.endpoint(cfg.baseURL)), url.scheme != nil else { throw AIError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": cfg.model,
            "messages": [["role": "system", "content": p.system], ["role": "user", "content": p.user]],
        ]
        if !cfg.effort.isEmpty && cfg.effort != "none" { body["reasoning_effort"] = cfg.effort }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public func text(from data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else { throw httpError(data, status: status) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choice = (obj["choices"] as? [[String: Any]])?.first,
              let msg = choice["message"] as? [String: Any] else {
            throw AIError.badReply(String(decoding: data.prefix(120), as: UTF8.self))
        }
        if let s = msg["content"] as? String { return s }
        // Some servers send content parts.
        let parts = (msg["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
        return parts.joined()
    }
}

public struct AnthropicDialect: AIDialect {
    public init() {}

    public static func endpoint(_ base: String) -> String {
        let b = trimmedBase(base)
        if b.hasSuffix("/v1/messages") { return b }
        if b.hasSuffix("/v1") { return b + "/messages" }
        return b + "/v1/messages"
    }

    public func urlRequest(_ p: AIPrompt, cfg: APIKeyConfig, key: String) throws -> URLRequest {
        guard let url = URL(string: Self.endpoint(cfg.baseURL)), url.scheme != nil else { throw AIError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": cfg.model,
            "max_tokens": p.maxTokens ?? cfg.maxTokens,
            "system": p.system,
            "messages": [["role": "user", "content": p.user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    public func text(from data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else { throw httpError(data, status: status) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw AIError.badReply(String(decoding: data.prefix(120), as: UTF8.self))
        }
        return content.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
    }
}
