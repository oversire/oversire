import Foundation

// ─── AI client ───────────────────────────────────────────────────────────────
// Calls the user's own endpoint. Two API formats: OpenAI compatible and Anthropic.

struct AIRequest {
    let system: String
    let user: String
    let maxTokens: Int
}

enum AIError: Error, Equatable {
    case notConfigured, http(Int, String), timeout, network(String), badReply(String)

    var message: String {
        switch self {
        case .notConfigured: return "Set up AI in Settings → AI."
        case .http(let code, let msg): return msg.isEmpty ? "HTTP \(code)" : "HTTP \(code): \(msg)"
        case .timeout: return "The AI endpoint did not reply in 30 s."
        case .network(let msg): return msg
        case .badReply(let msg): return "Unexpected reply: \(msg)"
        }
    }
}

protocol AIDialect {
    func urlRequest(_ r: AIRequest, cfg: AIConfig, key: String) throws -> URLRequest
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
}

func trimmedBase(_ url: String) -> String {
    var s = url.trimmingCharacters(in: .whitespacesAndNewlines)
    while s.hasSuffix("/") { s.removeLast() }
    return s
}

struct OpenAIDialect: AIDialect {
    static let efforts = ["none", "minimal", "low", "medium", "high"]

    static func endpoint(_ base: String) -> String {
        let b = trimmedBase(base)
        return b.hasSuffix("/chat/completions") ? b : b + "/chat/completions"
    }

    func urlRequest(_ r: AIRequest, cfg: AIConfig, key: String) throws -> URLRequest {
        guard let url = URL(string: OpenAIDialect.endpoint(cfg.baseURL)), url.scheme != nil else { throw AIError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": cfg.model,
            "messages": [["role": "system", "content": r.system], ["role": "user", "content": r.user]],
        ]
        if !cfg.effort.isEmpty && cfg.effort != "none" { body["reasoning_effort"] = cfg.effort }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    func text(from data: Data, status: Int) throws -> String {
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

struct AnthropicDialect: AIDialect {
    static func endpoint(_ base: String) -> String {
        let b = trimmedBase(base)
        if b.hasSuffix("/v1/messages") { return b }
        if b.hasSuffix("/v1") { return b + "/messages" }
        return b + "/v1/messages"
    }

    func urlRequest(_ r: AIRequest, cfg: AIConfig, key: String) throws -> URLRequest {
        guard let url = URL(string: AnthropicDialect.endpoint(cfg.baseURL)), url.scheme != nil else { throw AIError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        let body: [String: Any] = [
            "model": cfg.model,
            "max_tokens": r.maxTokens,
            "system": r.system,
            "messages": [["role": "user", "content": r.user]],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    func text(from data: Data, status: Int) throws -> String {
        guard (200..<300).contains(status) else { throw httpError(data, status: status) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = obj["content"] as? [[String: Any]] else {
            throw AIError.badReply(String(decoding: data.prefix(120), as: UTF8.self))
        }
        return content.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
    }
}

// What the model can choose from.
struct DraftContext {
    var projects: [(key: String, title: String)] = []   // empty when the project is set
    var fields: [ProjectField] = []                      // single-select fields, without Status
}

struct DraftSuggestion: Equatable {
    var title: String
    var alternatives: [String]
    var fields: [String: String]        // field name → option name
    var project: String?
    var reason: String?

    static let maxTitle = 70

    // Takes the first `{ … }` block, then drops values that are not in the context.
    static func parse(_ text: String, ctx: DraftContext) -> DraftSuggestion? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any] else { return nil }
        func clean(_ s: String) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`")))
            if t.hasSuffix(".") { t.removeLast() }
            return String(t.prefix(maxTitle)).trimmingCharacters(in: .whitespaces)
        }
        let title = clean(obj["title"] as? String ?? "")
        guard !title.isEmpty else { return nil }
        let alts = (obj["alternatives"] as? [Any] ?? []).compactMap { ($0 as? String).map(clean) }
            .filter { !$0.isEmpty && $0 != title }
        var fields: [String: String] = [:]
        for (name, value) in obj["fields"] as? [String: Any] ?? [:] {
            guard let v = value as? String,
                  let field = ctx.fields.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
                  let opt = field.options.first(where: { $0.name.caseInsensitiveCompare(v) == .orderedSame }) else { continue }
            fields[field.name] = opt.name
        }
        let key = obj["project"] as? String
        let project = ctx.projects.first { $0.key.caseInsensitiveCompare(key ?? "") == .orderedSame }?.key
        let reason = project == nil ? nil : (obj["reason"] as? String)
        return DraftSuggestion(title: title, alternatives: Array(alts.prefix(3)), fields: fields, project: project, reason: reason)
    }
}

// The whole reply, without a code fence around it.
func unfenced(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("```"), t.hasSuffix("```"), t.count > 6 else { return t }
    t = String(t.dropFirst(3).dropLast(3))
    if let nl = t.firstIndex(of: "\n"), !t[..<nl].contains(" ") { t = String(t[t.index(after: nl)...]) }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

final class AIClient {
    static let keyStore = SecretStore(service: "com.oversire.app.ai")
    static let keyName = "API_KEY"

    let cfg: AIConfig
    let key: String
    let session: URLSession

    init(cfg: AIConfig, key: String, session: URLSession = .shared) {
        self.cfg = cfg
        self.key = key
        self.session = session
    }

    // The saved config, when AI is on.
    static var current: AIClient? {
        let key = keyStore.get(keyName)
        guard AI_CFG.isOn(key: key), let key else { return nil }
        return AIClient(cfg: AI_CFG, key: key)
    }

    var dialect: AIDialect { cfg.format == .openai ? OpenAIDialect() : AnthropicDialect() }

    // `done` runs on the main queue.
    func send(_ r: AIRequest, done: @escaping (Result<String, AIError>) -> Void) {
        let dialect = self.dialect
        let req: URLRequest
        do { req = try dialect.urlRequest(r, cfg: cfg, key: key) } catch {
            done(.failure(error as? AIError ?? .notConfigured)); return
        }
        session.dataTask(with: req) { data, resp, err in
            let result: Result<String, AIError>
            if let err = err as? URLError {
                result = .failure(err.code == .timedOut ? .timeout : .network(err.localizedDescription))
            } else if let err {
                result = .failure(.network(err.localizedDescription))
            } else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                do { result = .success(try dialect.text(from: data ?? Data(), status: status)) }
                catch { result = .failure(error as? AIError ?? .badReply("\(error)")) }
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }

    func test(done: @escaping (Result<TimeInterval, AIError>) -> Void) {
        let start = Date()
        send(AIRequest(system: "Reply with OK.", user: "ping", maxTokens: 32)) { r in
            done(r.map { _ in Date().timeIntervalSince(start) })
        }
    }

    func draft(body: String, ctx: DraftContext, done: @escaping (Result<DraftSuggestion, AIError>) -> Void) {
        send(AIRequest(system: AIClient.draftSystem(ctx: ctx, extra: cfg.extraContext),
                       user: AIClient.draftUser(body: body, ctx: ctx), maxTokens: cfg.maxTokens)) { r in
            done(r.flatMap { text in
                DraftSuggestion.parse(text, ctx: ctx).map { .success($0) } ?? .failure(.badReply(String(text.prefix(80))))
            })
        }
    }

    func tidy(body: String, done: @escaping (Result<String, AIError>) -> Void) {
        send(AIRequest(system: AIClient.withExtra(AIClient.tidySystem, cfg.extraContext), user: body,
                       maxTokens: max(cfg.maxTokens, 2048))) { r in
            done(r.flatMap { text in
                let t = unfenced(text)
                return t.isEmpty ? .failure(.badReply("empty")) : .success(t)
            })
        }
    }

    // MARK: Prompts

    static let tidySystem = """
    Rewrite the user's note as a clear GitHub issue description in Markdown.
    Keep every fact, link, number, name and code block. Do not add facts.
    Use short paragraphs and lists. Add a heading only when it helps.
    Reply with the Markdown only.
    """

    static func withExtra(_ system: String, _ extra: String) -> String {
        let e = extra.trimmingCharacters(in: .whitespacesAndNewlines)
        return e.isEmpty ? system : system + "\n\nExtra instructions from the user:\n" + e
    }

    static func draftSystem(ctx: DraftContext, extra: String) -> String {
        var keys = ["\"title\": the item title, at most \(DraftSuggestion.maxTitle) characters, imperative, no period at the end",
                    "\"alternatives\": two other titles"]
        if !ctx.fields.isEmpty {
            keys.append("\"fields\": an object of field name to option name. Use only the given fields and options. Leave out a field when you are not sure")
        }
        if !ctx.projects.isEmpty {
            keys.append("\"project\": the key of the best project from the given list")
            keys.append("\"reason\": why that project, in at most 8 words")
        }
        let system = """
        You turn a note into a GitHub project item.
        Reply with one JSON object only, with no other text. Keys:
        \(keys.map { "- " + $0 }.joined(separator: "\n"))
        """
        return withExtra(system, extra)
    }

    static func draftUser(body: String, ctx: DraftContext) -> String {
        var out = ""
        if !ctx.projects.isEmpty {
            out += "Projects:\n" + ctx.projects.map { "- \($0.key): \($0.title)" }.joined(separator: "\n") + "\n\n"
        }
        if !ctx.fields.isEmpty {
            out += "Fields:\n" + ctx.fields.map { f in "- \(f.name): \(f.options.map(\.name).joined(separator: ", "))" }
                .joined(separator: "\n") + "\n\n"
        }
        return out + "Note:\n" + body
    }
}
