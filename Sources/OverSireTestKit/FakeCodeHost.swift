import Foundation
import OverSireCore

/// An in-memory code host with one repo "fake/app" and one open change.
public final class FakeCodeHost: CodeHost, @unchecked Sendable {
    public let base: FakeProvider
    public var id: ProviderID { base.id }
    public var account: AccountID { base.account }
    public var capabilities: Set<Capability> { base.capabilities }
    public var pollPolicy: PollPolicy { base.pollPolicy }

    private var repoList: [Repo] = []
    private var changeList: [RepoRef: [ChangeRequest]] = [:]
    private var done: [(ChangeAction, ChangeRef)] = []

    public init(account: String = "fake", capabilities: Set<Capability> = [.changeActions]) {
        base = FakeProvider(id: "fake-code", account: account, capabilities: capabilities)
        let repo = RepoRef(account: base.account, path: "fake/app", url: URL(string: "https://code.fake/fake/app")!)
        repoList = [Repo(ref: repo, isPrivate: false)]
        changeList[repo] = [ChangeRequest(number: 1, title: "Add the fake", state: "OPEN", author: .init(login: "me"), headRefName: "FAKE-1",
                                          baseRefName: "main", url: "https://code.fake/fake/app/pull/1", createdAt: "2026-10-01T10:00:00Z",
                                          updatedAt: "2026-10-01T10:00:00Z", reviewDecision: nil, additions: 3, deletions: 1,
                                          isDraft: false, labels: [], body: nil, mine: true)]
    }

    public var repo: RepoRef { repoList[0].ref }
    public var performed: [(ChangeAction, ChangeRef)] { (try? base.locked { done }) ?? [] }

    public func probe() async throws -> Identity { try await base.probe() }
    public func poll(since: Cursor?) async throws -> EventPage { try await base.poll(since: since) }

    public func repos() async throws -> [Repo] { try base.locked { repoList } }

    public func changes(_ r: RepoRef, _ f: ChangeFilter) async throws -> [ChangeRequest] {
        try base.locked {
            Array((changeList[r] ?? []).filter { (f.includeDrafts || !$0.isDraft) && $0.state == "OPEN" }.prefix(f.limit))
        }
    }

    public func perform(_ a: ChangeAction, on c: ChangeRef) async throws {
        guard capabilities.contains(.changeActions) else { throw ProviderError.unsupported(.changeActions) }
        try base.locked {
            guard let at = changeList[c.repo]?.firstIndex(where: { $0.number == c.number }) else { throw ProviderError.notFound }
            done.append((a, c))
            let o = changeList[c.repo]![at]
            let state: String
            switch a {
            case .merge: state = "MERGED"
            case .close: state = "CLOSED"
            default: state = o.state
            }
            changeList[c.repo]![at] = ChangeRequest(number: o.number, title: o.title, state: state, author: o.author, headRefName: o.headRefName,
                                                     baseRefName: o.baseRefName, url: o.url, createdAt: o.createdAt, updatedAt: o.updatedAt,
                                                     reviewDecision: a == .approve(nil) ? "APPROVED" : o.reviewDecision, additions: o.additions,
                                                     deletions: o.deletions, isDraft: o.isDraft, labels: o.labels, body: o.body, mine: o.mine)
            base.emit(.change, a.description, .change(c), title: o.title)
        }
    }

    public func commitMessage(_ r: RepoRef, sha: String) async throws -> String {
        try base.locked {
            guard repoList.contains(where: { $0.ref == r }) else { throw ProviderError.notFound }
            return "Commit \(sha.prefix(7))"
        }
    }
}
