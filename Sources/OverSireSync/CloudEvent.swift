import Foundation
import OverSireCore

// The entries of /v1/events. The app asks for schema=1 (ProviderEvent).
// A server before cloud version 5 ignores the parameter and sends CloudEvent. Remove CloudEvent when all servers send schema 1.

public struct CloudEvent: Decodable, Hashable, Sendable {
    public let seq: Int
    public let deliveryId: String
    public let repo: String
    public let kind: String
    public let action: String?
    public let runId: Int?
    public let jobId: Int?
    public let prNumber: Int?
    public let org: String?          // "plane:<slug>" for Plane events
    public let projectId: String?
    public let itemId: String?

    public init(seq: Int, deliveryId: String, repo: String, kind: String, action: String? = nil, runId: Int? = nil,
                jobId: Int? = nil, prNumber: Int? = nil, org: String? = nil, projectId: String? = nil, itemId: String? = nil) {
        self.seq = seq
        self.deliveryId = deliveryId
        self.repo = repo
        self.kind = kind
        self.action = action
        self.runId = runId
        self.jobId = jobId
        self.prNumber = prNumber
        self.org = org
        self.projectId = projectId
        self.itemId = itemId
    }
}

public struct CloudEventsPage: Decodable, Sendable {
    public let events: [CloudEntry]
    public let head: Int
    public let next: Int
    public let more: Bool
    public let truncated: Bool
}

public enum CloudEntry: Decodable, Hashable, Sendable {
    case event(ProviderEvent)
    case legacy(CloudEvent)

    private enum Keys: String, CodingKey { case schema }

    public init(from decoder: Decoder) throws {
        if try decoder.container(keyedBy: Keys.self).contains(.schema) {
            self = .event(try ProviderEvent(from: decoder))
        } else {
            self = .legacy(try CloudEvent(from: decoder))
        }
    }

    /// A project subject with no id stands for the whole account.
    public func signal(at: Date) -> CloudSignal? {
        switch self {
        case .event(let e):
            if case .project(let p) = e.subject, p.id.isEmpty { return .resync(e.account) }
            return .event(e)
        case .legacy(let c):
            return c.signal(at: at)
        }
    }
}

public enum CloudSignal: Hashable, Sendable {
    case event(ProviderEvent)
    case resync(AccountID)   // the event names no subject: refresh the whole account
}

extension CloudEvent {
    // The provider targets own these ids, but Sync does not import them.
    static let github: ProviderID = "github", actions: ProviderID = "github-actions", plane: ProviderID = "plane"

    /// Nil for a kind that OverSire does not use.
    public func signal(at: Date) -> CloudSignal? {
        let owner = String(repo.split(separator: "/").first ?? "")
        let repoRef = RepoRef(account: AccountID(provider: Self.github, id: owner), path: repo,
                              url: URL(string: "https://github.com/\(repo)")!)
        func event(_ provider: ProviderID, _ account: AccountID, _ kind: EventKind, _ subject: SubjectRef) -> CloudSignal {
            .event(ProviderEvent(id: deliveryId, provider: provider, account: account, kind: kind,
                                 action: action ?? "updated", subject: subject, at: at))
        }
        let ci = AccountID(provider: Self.actions, id: owner)
        switch kind {
        case "workflow_run", "workflow_job":
            guard let runId else { return event(Self.actions, ci, .run, .repo(repoRef)) }
            let run = RunRef(account: ci, repo: repoRef, id: String(runId))
            if kind == "workflow_job", let jobId { return event(Self.actions, ci, .job, .job(JobRef(run: run, id: String(jobId)))) }
            return event(Self.actions, ci, .run, .run(run))
        case "pull_request", "pull_request_review":
            guard let prNumber else { return event(Self.github, repoRef.account, .change, .repo(repoRef)) }
            let change = ChangeRef(repo: repoRef, number: prNumber, url: URL(string: "https://github.com/\(repo)/pull/\(prNumber)")!)
            return event(Self.github, repoRef.account, .change, .change(change))
        case "plane":
            guard let org, org.hasPrefix("plane:") else { return nil }
            let account = AccountID(provider: Self.plane, id: String(org.dropFirst(6)))
            guard let projectId else { return .resync(account) }
            return event(Self.plane, account, .item, .project(ProjectRef(account: account, id: projectId)))
        default:
            return nil
        }
    }
}
