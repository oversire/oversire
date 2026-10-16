import Foundation

// ─── Code host model ─────────────────────────────────────────────────────────

/// A pull request or a merge request.
public struct ChangeRequest: Codable, Hashable, Sendable {
    public struct Author: Codable, Hashable, Sendable {
        public let login: String
        public init(login: String) { self.login = login }
    }

    public struct Label: Codable, Hashable, Sendable {
        public let name: String
        public let color: String?
        public init(name: String, color: String?) {
            self.name = name
            self.color = color
        }
    }

    public let number: Int
    public let title: String
    public let state: String
    public let author: Author
    public let headRefName: String
    public let baseRefName: String
    public let url: String
    public let createdAt: String
    public let updatedAt: String
    public let reviewDecision: String?
    public let additions: Int
    public let deletions: Int
    public let isDraft: Bool
    public let labels: [Label]
    public let body: String?
    public var mine = false          // authored by the user; else a review request

    enum CodingKeys: String, CodingKey {
        case number, title, state, author, headRefName, baseRefName, url, createdAt, updatedAt
        case reviewDecision, additions, deletions, isDraft, labels, body
    }

    public init(number: Int, title: String, state: String, author: Author, headRefName: String, baseRefName: String,
                url: String, createdAt: String, updatedAt: String, reviewDecision: String?, additions: Int,
                deletions: Int, isDraft: Bool, labels: [Label], body: String?, mine: Bool = false) {
        self.number = number
        self.title = title
        self.state = state
        self.author = author
        self.headRefName = headRefName
        self.baseRefName = baseRefName
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.reviewDecision = reviewDecision
        self.additions = additions
        self.deletions = deletions
        self.isDraft = isDraft
        self.labels = labels
        self.body = body
        self.mine = mine
    }
}

public enum MergeMethod: String, Codable, Sendable, CaseIterable {
    case merge, rebase, squash
}

public enum ChangeAction: Hashable, Sendable, CustomStringConvertible {
    case approve(String?)
    case requestChanges(String)
    case comment(String)
    case merge(MergeMethod)
    case close

    public var description: String {
        switch self {
        case .approve: return "approve"
        case .requestChanges: return "request-changes"
        case .comment: return "comment"
        case .merge(let m): return "merge(\(m.rawValue))"
        case .close: return "close"
        }
    }
}

// JSON: {"type": "merge", "method": "squash"}, {"type": "approve", "body": "LGTM"}.
extension ChangeAction: Codable {
    private enum CodingKeys: String, CodingKey { case type, body, method }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "approve": self = .approve(try c.decodeIfPresent(String.self, forKey: .body))
        case "request-changes": self = .requestChanges(try c.decode(String.self, forKey: .body))
        case "comment": self = .comment(try c.decode(String.self, forKey: .body))
        case "merge": self = .merge(try c.decode(MergeMethod.self, forKey: .method))
        case "close": self = .close
        case let t: throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown change action \(t)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .approve(let b):
            try c.encode("approve", forKey: .type)
            try c.encodeIfPresent(b, forKey: .body)
        case .requestChanges(let b):
            try c.encode("request-changes", forKey: .type)
            try c.encode(b, forKey: .body)
        case .comment(let b):
            try c.encode("comment", forKey: .type)
            try c.encode(b, forKey: .body)
        case .merge(let m):
            try c.encode("merge", forKey: .type)
            try c.encode(m, forKey: .method)
        case .close:
            try c.encode("close", forKey: .type)
        }
    }
}

/// Which change requests to list.
public struct ChangeFilter: Hashable, Sendable {
    public var mine: Bool
    public var reviewRequested: Bool
    public var includeDrafts: Bool
    public var limit: Int

    public init(mine: Bool = true, reviewRequested: Bool = true, includeDrafts: Bool = true, limit: Int = 50) {
        self.mine = mine
        self.reviewRequested = reviewRequested
        self.includeDrafts = includeDrafts
        self.limit = limit
    }
}
