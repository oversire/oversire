import Foundation
import GitHubKit
import OverSireCore

/// One GitHub owner (a user or an org). `repos` limits the poll. Empty polls nothing.
public final class GitHubCodeHost: CodeHost, RateReporting, @unchecked Sendable {
    public let id: ProviderID = .github
    public let account: AccountID
    public let repoPaths: [String]
    public var capabilities: Set<Capability> { [.changeActions, .webhooks] }
    public var pollPolicy: PollPolicy { PollPolicy(minInterval: .seconds(15), requestsPerHour: 5000) }

    let client: GitHubClient

    public init(owner: String, repos: [String] = [], client: GitHubClient) {
        account = AccountID(provider: .github, id: owner)
        repoPaths = repos
        self.client = client
    }

    public func repoRef(_ path: String) -> RepoRef {
        RepoRef(account: account, path: path, url: URL(string: "https://github.com/\(path)")!)
    }

    public func probe() async throws -> Identity {
        guard let o = try await client.json("GET", "user") as? [String: Any], let login = o["login"] as? String else {
            throw ProviderError.decoding("no user in the answer")
        }
        let id = (o["id"] as? NSNumber)?.stringValue ?? login
        let name = (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? login
        return Identity(person: PersonRef(id: id, name: name, login: login))
    }

    public func budget() async throws -> RateBudget {
        guard let b = try await client.rateLimit().budget else { throw ProviderError.decoding("no rate limit buckets") }
        return b
    }

    // MARK: CodeHost

    static let reposQuery = """
        query($login: String!, $after: String) { repositoryOwner(login: $login) {
          repositories(first: 100, after: $after, ownerAffiliations: OWNER, isArchived: false) {
            nodes { nameWithOwner isPrivate } pageInfo { hasNextPage endCursor } } } }
        """

    public func repos() async throws -> [Repo] {
        var out: [Repo] = []
        var after: String?
        for _ in 0..<20 {
            var vars: [String: Any] = ["login": account.id]
            if let after { vars["after"] = after }
            let data = try await client.graphQL(Self.reposQuery, vars)
            guard let page = (data["repositoryOwner"] as? [String: Any])?["repositories"] as? [String: Any] else {
                throw ProviderError.notFound
            }
            for n in page["nodes"] as? [[String: Any]] ?? [] {
                guard let path = n["nameWithOwner"] as? String else { continue }
                out.append(Repo(ref: repoRef(path), isPrivate: n["isPrivate"] as? Bool ?? false))
            }
            let info = page["pageInfo"] as? [String: Any]
            guard info?["hasNextPage"] as? Bool == true, let next = info?["endCursor"] as? String else { break }
            after = next
        }
        return out.sorted { $0.ref.path.localizedCaseInsensitiveCompare($1.ref.path) == .orderedAscending }
    }

    static let changesQuery = """
        query($q: String!, $n: Int!) { search(query: $q, type: ISSUE, first: $n) { nodes { ... on PullRequest {
          number title state author { login } headRefName baseRefName url createdAt updatedAt reviewDecision
          additions deletions isDraft labels(first: 20) { nodes { name color } } body } } } }
        """

    /// Review requests first, then own PRs. Own PRs link runs to items.
    public func changes(_ r: RepoRef, _ f: ChangeFilter) async throws -> [ChangeRequest] {
        var out: [ChangeRequest] = []
        if f.reviewRequested { out += try await search(r, "review-requested:@me", f) }
        if f.mine {
            for var p in try await search(r, "author:@me", f) where !out.contains(where: { $0.number == p.number }) {
                p.mine = true
                out.append(p)
            }
        }
        return out
    }

    private func search(_ r: RepoRef, _ who: String, _ f: ChangeFilter) async throws -> [ChangeRequest] {
        let q = "repo:\(r.path) is:pr is:open \(who)" + (f.includeDrafts ? "" : " draft:false")
        let data = try await client.graphQL(Self.changesQuery, ["q": q, "n": min(100, max(1, f.limit))])
        let nodes = (data["search"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []
        return nodes.compactMap(Self.change)
    }

    static func change(_ n: [String: Any]) -> ChangeRequest? {
        guard let number = n["number"] as? Int, let title = n["title"] as? String else { return nil }
        let labels = ((n["labels"] as? [String: Any])?["nodes"] as? [[String: Any]] ?? []).compactMap { l in
            (l["name"] as? String).map { ChangeRequest.Label(name: $0, color: l["color"] as? String) }
        }
        return ChangeRequest(number: number, title: title, state: n["state"] as? String ?? "OPEN",
                             author: .init(login: (n["author"] as? [String: Any])?["login"] as? String ?? "ghost"),
                             headRefName: n["headRefName"] as? String ?? "", baseRefName: n["baseRefName"] as? String ?? "",
                             url: n["url"] as? String ?? "", createdAt: n["createdAt"] as? String ?? "",
                             updatedAt: n["updatedAt"] as? String ?? "", reviewDecision: n["reviewDecision"] as? String,
                             additions: n["additions"] as? Int ?? 0, deletions: n["deletions"] as? Int ?? 0,
                             isDraft: n["isDraft"] as? Bool ?? false, labels: labels, body: n["body"] as? String)
    }

    public func perform(_ a: ChangeAction, on c: ChangeRef) async throws {
        let (method, path, body) = Self.request(a, on: c)
        _ = try await client.json(method, path, body: body)
    }

    /// The REST call for one action.
    static func request(_ a: ChangeAction, on c: ChangeRef) -> (method: String, path: String, body: [String: Any]) {
        let pr = "repos/\(c.repo.path)/pulls/\(c.number)"
        switch a {
        case .approve(let b):
            var body: [String: Any] = ["event": "APPROVE"]
            if let b, !b.isEmpty { body["body"] = b }
            return ("POST", pr + "/reviews", body)
        case .requestChanges(let b): return ("POST", pr + "/reviews", ["event": "REQUEST_CHANGES", "body": b])
        case .comment(let b): return ("POST", "repos/\(c.repo.path)/issues/\(c.number)/comments", ["body": b])
        case .merge(let m): return ("PUT", pr + "/merge", ["merge_method": m.rawValue])
        case .close: return ("PATCH", pr, ["state": "closed"])
        }
    }

    public func commitMessage(_ r: RepoRef, sha: String) async throws -> String {
        let o = try await client.json("GET", "repos/\(r.path)/commits/\(sha)") as? [String: Any]
        guard let m = (o?["commit"] as? [String: Any])?["message"] as? String else { throw ProviderError.decoding("no commit message") }
        return m.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
