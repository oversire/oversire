import Foundation
import OverSireCore

/// What the model can choose from when it drafts an item.
public struct DraftContext {
    public var projects: [(key: String, title: String)]   // empty when the project is set
    public var fields: [ProjectField]                      // single-select fields, without Status

    public init(projects: [(key: String, title: String)] = [], fields: [ProjectField] = []) {
        self.projects = projects
        self.fields = fields
    }

    public func input(body: String, extra: String) -> AIInput {
        var c = ["extra": extra]
        if !projects.isEmpty { c["projects"] = projects.map { "- \($0.key): \($0.title)" }.joined(separator: "\n") }
        if !fields.isEmpty {
            c["fields"] = fields.map { f in "- \(f.name): \(f.options.map(\.name).joined(separator: ", "))" }.joined(separator: "\n")
        }
        return AIInput(text: body, context: c)
    }

    static func prompt(_ input: AIInput) -> AIPrompt {
        let (projects, fields) = (input["projects"], input["fields"])
        var keys = ["\"title\": the item title, at most \(DraftSuggestion.maxTitle) characters, imperative, no period at the end",
                    "\"alternatives\": two other titles"]
        if !fields.isEmpty {
            keys.append("\"fields\": an object of field name to option name. Use only the given fields and options. Leave out a field when you are not sure")
        }
        if !projects.isEmpty {
            keys.append("\"project\": the key of the best project from the given list")
            keys.append("\"reason\": why that project, in at most 8 words")
        }
        let system = """
        You turn a note into a GitHub project item.
        Reply with one JSON object only, with no other text. Keys:
        \(keys.map { "- " + $0 }.joined(separator: "\n"))
        """
        var user = ""
        if !projects.isEmpty { user += "Projects:\n" + projects + "\n\n" }
        if !fields.isEmpty { user += "Fields:\n" + fields + "\n\n" }
        return AIPrompt(system: input.withExtra(system), user: user + "Note:\n" + input.text)
    }

    static let tidySystem = """
    Rewrite the user's note as a clear GitHub issue description in Markdown.
    Keep every fact, link, number, name and code block. Do not add facts.
    Use short paragraphs and lists. Add a heading only when it helps.
    Reply with the Markdown only.
    """

    static func tidyPrompt(_ input: AIInput) -> AIPrompt {
        AIPrompt(system: input.withExtra(tidySystem), user: input.text, maxTokens: 2048)
    }
}

public struct DraftSuggestion: Equatable, Sendable {
    public var title: String
    public var alternatives: [String]
    public var fields: [String: String]        // field name → option name
    public var project: String?
    public var reason: String?

    public static let maxTitle = 70

    public init(title: String, alternatives: [String], fields: [String: String], project: String?, reason: String?) {
        self.title = title
        self.alternatives = alternatives
        self.fields = fields
        self.project = project
        self.reason = reason
    }

    /// Takes the first `{ … }` block, then drops values that are not in the context.
    public static func parse(_ text: String, ctx: DraftContext) -> DraftSuggestion? {
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
