import Foundation
import OverSireCore

/// The result of a Groom session (Contract/schema/groom.json): the cleanup that the agent proposes for the open items of one project.
public struct GroomResult: Codable, Equatable, Sendable {
    /// Open set. An unknown kind stays in the result, and the app cannot apply it.
    public struct Kind: RawRepresentable, Hashable, Codable, Sendable, ExpressibleByStringLiteral {
        public let rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { rawValue = value }
        public init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }

        public static let merge: Kind = "merge"
        public static let done: Kind = "done"
        public static let obsolete: Kind = "obsolete"
        public static let fold: Kind = "fold"
        public static let relate: Kind = "relate"
        public static let vague: Kind = "vague"
        /// The review order.
        public static let all: [Kind] = [.merge, .done, .obsolete, .fold, .relate, .vague]

        public var isKnown: Bool { Self.all.contains(self) }
    }

    public enum Confidence: String, Codable, Sendable {
        case sure, maybe

        /// An unknown value is maybe: the line then starts cleared.
        public init(from decoder: Decoder) throws {
            self = Confidence(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .maybe
        }
    }

    public struct Relation: Codable, Equatable, Hashable, Sendable {
        public var kind: String         // blocked_by, blocks, relates_to
        public var key: String

        public init(kind: String, key: String) {
            self.kind = kind
            self.key = key
        }

        public var relationKind: RelationKind? { EnhanceResult.Relation(kind: kind, key: key, reason: "").relationKind }
    }

    public struct Proposal: Codable, Equatable, Sendable, Identifiable {
        public var kind: Kind
        public var keys: [String]
        public var keep: String?
        public var parent: String?
        public var relation: Relation?
        public var title: String?
        public var reason: String
        public var evidence: [String]
        public var confidence: Confidence
        public var description: String?

        public init(kind: Kind, keys: [String], keep: String? = nil, parent: String? = nil, relation: Relation? = nil, title: String? = nil,
                    reason: String, evidence: [String] = [], confidence: Confidence = .sure, description: String? = nil) {
            self.kind = kind
            self.keys = keys
            self.keep = keep
            self.parent = parent
            self.relation = relation
            self.title = title
            self.reason = reason
            self.evidence = evidence
            self.confidence = confidence
            self.description = description
        }

        private enum CodingKeys: String, CodingKey { case kind, keys, keep, parent, relation, title, reason, evidence, confidence, description }

        // An agent can leave out a field. Only kind is a must.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            kind = try c.decode(Kind.self, forKey: .kind)
            keys = (try? c.decodeIfPresent([String].self, forKey: .keys)) ?? []
            keep = try? c.decodeIfPresent(String.self, forKey: .keep)
            parent = try? c.decodeIfPresent(String.self, forKey: .parent)
            relation = try? c.decodeIfPresent(Relation.self, forKey: .relation)
            title = try? c.decodeIfPresent(String.self, forKey: .title)
            reason = (try? c.decodeIfPresent(String.self, forKey: .reason)) ?? ""
            evidence = (try? c.decodeIfPresent([String].self, forKey: .evidence)) ?? []
            confidence = (try? c.decodeIfPresent(Confidence.self, forKey: .confidence)) ?? .maybe
            description = try? c.decodeIfPresent(String.self, forKey: .description)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(kind, forKey: .kind)
            try c.encode(keys, forKey: .keys)
            try c.encodeIfPresent(keep, forKey: .keep)
            try c.encodeIfPresent(parent, forKey: .parent)
            try c.encodeIfPresent(relation, forKey: .relation)
            try c.encodeIfPresent(title, forKey: .title)
            try c.encode(reason, forKey: .reason)
            if !evidence.isEmpty { try c.encode(evidence, forKey: .evidence) }
            try c.encode(confidence, forKey: .confidence)
            try c.encodeIfPresent(description, forKey: .description)
        }

        public var id: String { kind.rawValue + ":" + keys.joined(separator: ",") }

        /// The rules of the schema: a known kind, and the fields that the kind needs.
        public var isApplicable: Bool {
            guard !keys.isEmpty else { return false }
            switch kind {
            case .merge: return keys.count >= 2 && keep.map { k in keys.contains { $0.caseInsensitiveCompare(k) == .orderedSame } } == true
            case .fold: return keys.count == 1 && parent?.isEmpty == false
            case .relate: return keys.count == 1 && relation?.relationKind != nil && relation?.key.isEmpty == false
            case .done, .obsolete, .vague: return true
            default: return false
            }
        }

        /// isApplicable, and each key is an item of the input.
        public func isApplicable(in input: Set<String>) -> Bool {
            isApplicable && keys.allSatisfy { input.contains($0.uppercased()) }
        }

        /// The items that the line closes: the merged items, or each done or obsolete item.
        public var closes: Int {
            switch kind {
            case .merge: return max(0, keys.count - 1)
            case .done, .obsolete: return keys.count
            default: return 0
            }
        }

        /// The keys that merge into keep.
        public var merged: [String] {
            guard kind == .merge, let keep else { return [] }
            return keys.filter { $0.caseInsensitiveCompare(keep) != .orderedSame }
        }
    }

    public var proposals: [Proposal]
    public var skipped: [String]
    public var findings: [String]

    public init(proposals: [Proposal], skipped: [String] = [], findings: [String] = []) {
        self.proposals = proposals
        self.skipped = skipped
        self.findings = findings
    }

    private enum CodingKeys: String, CodingKey { case proposals, skipped, findings }

    private struct Lossy: Decodable {
        let value: Proposal?
        init(from decoder: Decoder) throws { value = try? Proposal(from: decoder) }
    }

    // A proposal that does not decode drops. The other lines stay.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        proposals = try c.decode([Lossy].self, forKey: .proposals).compactMap(\.value)
        skipped = (try? c.decodeIfPresent([String].self, forKey: .skipped)) ?? []
        findings = (try? c.decodeIfPresent([String].self, forKey: .findings)) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(proposals, forKey: .proposals)
        if !skipped.isEmpty { try c.encode(skipped, forKey: .skipped) }
        if !findings.isEmpty { try c.encode(findings, forKey: .findings) }
    }

    /// The `oversire-result` block of the message, else the last JSON object with proposals. nil: a clipped message, or no result.
    public static func parse(lastMessage text: String) -> GroomResult? {
        if let block = ResultBlock.last(in: text) { return decode(block) }
        return ResultBlock.lastObject(in: text, decode)
    }

    private static func decode(_ raw: String) -> GroomResult? {
        guard raw.contains("\"proposals\"") else { return nil }
        return try? JSONDecoder().decode(GroomResult.self, from: Data(raw.utf8))
    }

    /// The open items after the selected lines: "142 → 110".
    public func openAfter(_ open: Int, selected: Set<String>) -> Int {
        max(0, open - proposals.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.closes })
    }
}

/// What a Groom run reads.
public enum GroomScope: String, Codable, Sendable, CaseIterable {
    case intake
    case all     // the intake and the backlog

    /// The words in the prompt and the start sheet.
    public var words: String { self == .intake ? "the intake" : "the intake and the backlog" }
}

/// One line of the Groom input file.
public struct GroomItem: Codable, Equatable, Sendable {
    public static let bodyLimit = 600

    public var key: String
    public var title: String
    public var body: String
    public var state: String
    public var labels: [String]
    public var areas: [String]
    public var created: Date?
    public var updated: Date
    public var comments: Int
    public var intake: Bool

    /// `markers` are the start and end lines of the OverSire block. The block and the text after the limit drop.
    public init(key: String, title: String, body: String, state: String, labels: [String] = [], areas: [String] = [], created: Date? = nil,
                updated: Date, comments: Int = 0, intake: Bool = false, markers: [(String, String)] = []) {
        self.key = key
        self.title = title
        self.body = Self.clip(body, markers: markers)
        self.state = state
        self.labels = labels
        self.areas = areas
        self.created = created
        self.updated = updated
        self.comments = comments
        self.intake = intake
    }

    static func clip(_ body: String, markers: [(String, String)]) -> String {
        var text = body
        for (start, end) in markers {
            guard let s = text.range(of: start) else { continue }
            let e = text.range(of: end, range: s.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
            text.removeSubrange(s.lowerBound..<e)
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count > bodyLimit ? String(t.prefix(bodyLimit)) + "…" : t
    }
}

/// The file that a Groom session reads: one JSON object on each line.
public enum GroomInput {
    public static let limit = 200

    public struct TooMany: Error, Equatable, CustomStringConvertible {
        public let count: Int
        public var description: String {
            "One Groom run holds at most \(GroomInput.limit) items. The scope has \(count). Select Intake only or a label to stay under \(GroomInput.limit) items."
        }
    }

    public static func jsonLines(_ items: [GroomItem]) throws -> Data {
        guard items.count <= limit else { throw TooMany(count: items.count) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var out = Data()
        for i in items {
            out += try enc.encode(i)
            out += Data("\n".utf8)
        }
        return out
    }
}

/// The prompt of a Groom session. Contract/prompts/groom.md holds the default template.
public enum GroomPrompt {
    public static var template: String { PromptTemplate.all[.groom]?.userTemplate ?? "" }

    /// `note` fills `{{text}}`: the item count and the items that Groom skips.
    public static func input(project: String, file: String, scope: GroomScope, staleDays: Int, vision: String? = nil, note: String = "") -> AIInput {
        var context = ["project": project, "file": file, "scope": scope.words, "staleDays": String(staleDays)]
        if let vision, !vision.isEmpty { context["vision"] = vision }
        return AIInput(text: note, context: context)
    }

    /// The template filled with the input. An empty template uses groom.md.
    public static func render(_ template: String, _ input: AIInput) -> String {
        let t = template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.template : template
        return PromptTemplate.fill(t[...]) { $0 == "text" ? input.text : input[$0] }.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
