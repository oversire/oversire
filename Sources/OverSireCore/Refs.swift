import Foundation

public struct ProjectRef: Sendable, Codable {
    public let account: AccountID
    public let id: String
    public var key: String?   // "OVERSIRE"

    public init(account: AccountID, id: String, key: String? = nil) {
        self.account = account
        self.id = id
        self.key = key
    }

    /// "<account>/<id>": the key of stored snapshots and settings.
    public var storeKey: String { "\(account.id)/\(id)" }

    private enum CodingKeys: String, CodingKey { case account, id, key, workspace }

    // Cat Eye stored Plane refs as {workspace, id, key: "<workspace>/<id>"}.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        if let account = try c.decodeIfPresent(AccountID.self, forKey: .account) {
            self.account = account
            key = try c.decodeIfPresent(String.self, forKey: .key)
        } else {
            account = AccountID(provider: "plane", id: try c.decode(String.self, forKey: .workspace))
            key = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(account, forKey: .account)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(key, forKey: .key)
    }
}

// The key is a label. Two refs to the same project are equal.
extension ProjectRef: Hashable {
    public static func == (a: ProjectRef, b: ProjectRef) -> Bool { a.account == b.account && a.id == b.id }
    public func hash(into h: inout Hasher) {
        h.combine(account)
        h.combine(id)
    }
}

public struct ItemRef: Hashable, Sendable, Codable {
    public let project: ProjectRef
    public let id: String
    public let key: String    // "OVERSIRE-12", "ENG-4", "#12"
    public let url: URL

    public init(project: ProjectRef, id: String, key: String, url: URL) {
        self.project = project
        self.id = id
        self.key = key
        self.url = url
    }
}

public struct RepoRef: Hashable, Sendable, Codable {
    public let account: AccountID
    public let path: String   // "org/repo", "group/sub/proj"
    public let url: URL

    public init(account: AccountID, path: String, url: URL) {
        self.account = account
        self.path = path
        self.url = url
    }
}

/// A pull request or a merge request.
public struct ChangeRef: Hashable, Sendable, Codable {
    public let repo: RepoRef
    public let number: Int
    public let url: URL

    public init(repo: RepoRef, number: Int, url: URL) {
        self.repo = repo
        self.number = number
        self.url = url
    }
}

public struct RunRef: Hashable, Sendable, Codable {
    public let account: AccountID
    public let repo: RepoRef?   // nil for a pipeline without a repo link
    public let id: String
    public let attempt: Int

    public init(account: AccountID, repo: RepoRef?, id: String, attempt: Int = 1) {
        self.account = account
        self.repo = repo
        self.id = id
        self.attempt = attempt
    }
}

public struct JobRef: Hashable, Sendable, Codable {
    public let run: RunRef
    public let id: String

    public init(run: RunRef, id: String) {
        self.run = run
        self.id = id
    }
}

public struct WorkspaceRef: Hashable, Sendable, Codable {
    public let account: AccountID
    public let id: String

    public init(account: AccountID, id: String) {
        self.account = account
        self.id = id
    }
}

public struct SessionRef: Hashable, Sendable, Codable {
    public let workspace: WorkspaceRef
    public let id: String

    public init(workspace: WorkspaceRef, id: String) {
        self.workspace = workspace
        self.id = id
    }
}

/// Any thing that an event or an AI task can name. JSON: {"kind": "item", "ref": {...}}.
public enum SubjectRef: Hashable, Sendable, Codable {
    case project(ProjectRef), item(ItemRef), repo(RepoRef), change(ChangeRef)
    case run(RunRef), job(JobRef), workspace(WorkspaceRef), session(SessionRef)

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case project, item, repo, change, run, job, workspace, session
    }

    public var kind: Kind {
        switch self {
        case .project: return .project
        case .item: return .item
        case .repo: return .repo
        case .change: return .change
        case .run: return .run
        case .job: return .job
        case .workspace: return .workspace
        case .session: return .session
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, ref }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .project: self = .project(try c.decode(ProjectRef.self, forKey: .ref))
        case .item: self = .item(try c.decode(ItemRef.self, forKey: .ref))
        case .repo: self = .repo(try c.decode(RepoRef.self, forKey: .ref))
        case .change: self = .change(try c.decode(ChangeRef.self, forKey: .ref))
        case .run: self = .run(try c.decode(RunRef.self, forKey: .ref))
        case .job: self = .job(try c.decode(JobRef.self, forKey: .ref))
        case .workspace: self = .workspace(try c.decode(WorkspaceRef.self, forKey: .ref))
        case .session: self = .session(try c.decode(SessionRef.self, forKey: .ref))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .project(let r): try c.encode(r, forKey: .ref)
        case .item(let r): try c.encode(r, forKey: .ref)
        case .repo(let r): try c.encode(r, forKey: .ref)
        case .change(let r): try c.encode(r, forKey: .ref)
        case .run(let r): try c.encode(r, forKey: .ref)
        case .job(let r): try c.encode(r, forKey: .ref)
        case .workspace(let r): try c.encode(r, forKey: .ref)
        case .session(let r): try c.encode(r, forKey: .ref)
        }
    }
}
