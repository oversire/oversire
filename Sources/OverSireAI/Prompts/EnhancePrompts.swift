import Foundation
import OverSireCore

/// The result that an Enhance worker sends in the body of its `worker_done`.
public struct EnhanceResult: Codable, Equatable, Sendable {
    public enum Verdict: String, Codable, Sendable, CaseIterable {
        case clear, vague, duplicate, reproduced
        case offVision = "off_vision"
        case notReproduced = "not_reproduced"

        public var word: String {
            switch self {
            case .offVision: return "Off vision"
            case .notReproduced: return "Not reproduced"
            default: return rawValue.capitalized
            }
        }
    }

    public struct Relation: Codable, Equatable, Hashable, Sendable {
        public var kind: String         // blocked_by, blocks, duplicate, relates_to
        public var key: String
        public var reason: String

        public init(kind: String, key: String, reason: String) {
            self.kind = kind
            self.key = key
            self.reason = reason
        }

        /// The tracker relation kind. A duplicate is an intake action, not a relation.
        public var relationKind: RelationKind? {
            switch kind {
            case "blocked_by": return .blockedBy
            case "blocks": return .blocks
            case "relates_to": return .relatesTo
            default: return nil
            }
        }
    }

    public var verdict: Verdict
    public var description: String
    public var priority: String?
    public var labels: [String]
    public var relations: [Relation]
    public var findings: [String]

    public init(verdict: Verdict, description: String, priority: String? = nil, labels: [String] = [], relations: [Relation] = [],
                findings: [String] = []) {
        self.verdict = verdict
        self.description = description
        self.priority = priority
        self.labels = labels
        self.relations = relations
        self.findings = findings
    }

    /// The item that this one duplicates.
    public var duplicateOf: Relation? { relations.first { $0.kind == "duplicate" } }

    /// The last JSON object with a known verdict in the text. nil: the text has no result.
    public static func parse(_ text: String) -> EnhanceResult? {
        var end = text.endIndex
        while let close = text.range(of: "}", options: .backwards, range: text.startIndex..<end) {
            var start = close.lowerBound
            while let open = text.range(of: "{", options: .backwards, range: text.startIndex..<start) {
                if let r = result(String(text[open.lowerBound...close.lowerBound])) { return r }
                start = open.lowerBound
            }
            end = close.lowerBound
        }
        return nil
    }

    private static func result(_ raw: String) -> EnhanceResult? {
        guard raw.contains("\"verdict\""), let o = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
              let v = (o["verdict"] as? String).flatMap(Verdict.init) else { return nil }
        let relations = (o["relations"] as? [[String: Any]] ?? []).compactMap { r -> Relation? in
            guard let kind = r["kind"] as? String, let key = r["key"] as? String, !key.isEmpty else { return nil }
            return Relation(kind: kind, key: key, reason: r["reason"] as? String ?? "")
        }
        let priority = (o["priority"] as? String).flatMap { $0.isEmpty || $0 == "none" ? nil : $0 }
        return EnhanceResult(verdict: v, description: o["description"] as? String ?? "", priority: priority,
                             labels: o["labels"] as? [String] ?? [], relations: relations, findings: o["findings"] as? [String] ?? [])
    }

    /// The new description with the original text in a last "Original note" section.
    public func description(keeping original: String) -> String {
        let note = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.range(of: EnhancePrompt.originalHeading, options: .caseInsensitive) != nil { return body }
        let kept = "\(EnhancePrompt.originalHeading)\n\n" + (note.isEmpty ? "(no description)" : note)
        return body.isEmpty ? kept : body + "\n\n" + kept
    }
}

/// The spec of an Enhance worker. Contract/prompts/enhance.md holds the default template.
public enum EnhancePrompt {
    public static let originalHeading = "## Original note"

    /// The user template of enhance.md. The user can change it in Settings.
    public static var template: String { PromptTemplate.all[.enhance]?.userTemplate ?? "" }

    /// What the worker enhances. The raw value fills `{{kind}}`.
    public enum Kind: String, Sendable {
        case intake = "a new intake item"
        case ticket = "a tracker item"
    }

    /// The first line of version 1. A saved template with it gets `{{kind}}`.
    static let oldOpening = "You enhance a new intake item."

    /// A template that the user saved before version 2, with `{{kind}}` in place of the intake words.
    public static func migrate(_ saved: String) -> String {
        saved.replacingOccurrences(of: oldOpening, with: "You enhance {{kind}}.")
    }

    public static func input(kind: Kind = .intake, key: String, title: String, url: String, body: String, vision: String? = nil) -> AIInput {
        var context = ["kind": kind.rawValue, "key": key, "title": title, "url": url]
        if let vision, !vision.isEmpty { context["vision"] = vision }
        return AIInput(text: body.isEmpty ? "(no description)" : String(body.prefix(6000)), context: context)
    }

    /// The template filled with the input. An empty template uses enhance.md.
    public static func render(_ template: String, _ input: AIInput) -> String {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.template : template
        return PromptTemplate.fill(t[...]) { $0 == "text" ? input.text : input[$0] }
    }
}
