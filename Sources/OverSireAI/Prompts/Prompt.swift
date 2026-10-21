import Foundation
import OverSireCore

extension AITaskKind {
    /// The prompt of the kind for the input. The text comes from Contract/prompts/<kind>.md.
    /// Each kind has an AIInput builder next to its reply parser.
    public func prompt(_ input: AIInput) throws -> AIPrompt {
        guard let t = PromptTemplate.all[self] else { throw AIError.unsupported(self) }
        return t.render(input)
    }
}

extension AIInput {
    public subscript(_ key: String) -> String { context[key] ?? "" }
}

/// One file of Contract/prompts. Contract/prompts/README.md has the format.
public struct PromptTemplate: Sendable {
    public let taskKind: AITaskKind
    public let version: Int
    public let maxTokens: Int?
    public let inputs: [String]
    let system: String
    let user: String

    /// The user template before the fill.
    public var userTemplate: String { user }

    /// The prompt files in the app binary, by kind.
    public static let all: [AITaskKind: PromptTemplate] = Dictionary(uniqueKeysWithValues: PromptFiles.all.map { name, text in
        do { return (AITaskKind(rawValue: name), try PromptTemplate(parsing: text)) } catch {
            preconditionFailure("Contract/prompts/\(name).md: \(error)")
        }
    })

    public init(parsing text: String) throws {
        guard text.hasPrefix("---\n"), let end = text.range(of: "\n---\n") else { throw ProviderError.decoding("no front matter") }
        var meta: [String: String] = [:]
        for line in text[text.index(text.startIndex, offsetBy: 4)..<end.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { throw ProviderError.decoding("front matter line: \(line)") }
            meta[line[..<colon].trimmingCharacters(in: .whitespaces)] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let kind = meta["taskKind"], let version = meta["version"].flatMap(Int.init) else {
            throw ProviderError.decoding("front matter needs taskKind and version")
        }
        var sections: [String: [Substring]] = [:]
        var current: String?
        for line in text[end.upperBound...].split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "<!-- system -->" || line == "<!-- user -->" {
                current = String(line.dropFirst(5).dropLast(4))
                sections[current!] = []
            } else if let c = current {
                sections[c]!.append(line)
            }
        }
        func section(_ name: String) -> String? {
            sections[name].map { String($0.joined(separator: "\n").reversed().drop { $0 == "\n" }.reversed()) }
        }
        guard let user = section("user") else { throw ProviderError.decoding("no user template") }
        taskKind = AITaskKind(rawValue: kind)
        self.version = version
        maxTokens = meta["maxTokens"].flatMap(Int.init)
        inputs = (meta["inputs"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        system = section("system") ?? ""
        self.user = user
    }

    public func render(_ input: AIInput) -> AIPrompt {
        let value = { (name: String) in name == "text" ? input.text : input[name] }
        return AIPrompt(system: Self.fill(system[...], value), user: Self.fill(user[...], value), maxTokens: maxTokens)
    }

    /// One pass over the template, so a value that holds "{{" stays as it is.
    static func fill(_ t: Substring, _ value: (String) -> String) -> String {
        var out = ""
        var rest = t
        while let open = rest.range(of: "{{"), let close = rest[open.upperBound...].range(of: "}}") {
            out += rest[..<open.lowerBound]
            let tag = rest[open.upperBound..<close.lowerBound]
            rest = rest[close.upperBound...]
            if tag.hasPrefix("#if ") {
                let end = rest.range(of: "{{/if}}") ?? (rest.endIndex..<rest.endIndex)
                let shown = !value(tag.dropFirst(4).trimmingCharacters(in: .whitespaces)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if shown { out += fill(rest[..<end.lowerBound], value) }
                rest = rest[end.upperBound...]
            } else {
                let parts = tag.split(separator: "|", maxSplits: 1)
                let v = value(String(parts.first ?? ""))
                out += parts.count > 1 && parts[1] == "trim" ? v.trimmingCharacters(in: .whitespacesAndNewlines) : v
            }
        }
        return out + rest
    }
}

/// The whole reply, without a code fence around it.
public func unfenced(_ text: String) -> String {
    var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("```"), t.hasSuffix("```"), t.count > 6 else { return t }
    t = String(t.dropFirst(3).dropLast(3))
    if let nl = t.firstIndex(of: "\n"), !t[..<nl].contains(" ") { t = String(t[t.index(after: nl)...]) }
    return t.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// The first `{` to the last `}` of an unfenced reply, as a JSON object.
public func replyObject(_ text: String) -> [String: Any]? {
    let t = unfenced(text)
    guard let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"), a < b else { return nil }
    return try? JSONSerialization.jsonObject(with: Data(t[a...b].utf8)) as? [String: Any]
}
