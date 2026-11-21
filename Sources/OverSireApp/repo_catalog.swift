import Foundation
import GitHubKit
import OverSireCore

// One GitHub account or organization and the repos it owns.
struct RepoOwner: Codable {
    var login: String
    var repos: [String]
    var fetchedAt: Date?
}

struct RepoCatalogCache: Codable {
    var user: String?
    var owners: [RepoOwner]
    var fetchedAt: Date?
}

enum OwnerFetch {
    case idle
    case loading
    case failed(String)

    var isIdle: Bool {
        if case .idle = self { return true }
        return false
    }
}

func repoOwner(_ repo: String) -> String {
    String(repo.split(separator: "/").first ?? Substring(repo))
}

// The list of repos the user can pick from. It is cached on disk and refreshed
// in the background, per owner, at most once a day unless the user asks.
final class RepoCatalog {
    static let changed = Notification.Name("RepoCatalogChanged")
    static let maxAge: TimeInterval = 24 * 3600

    private var localUser: String?
    private var localOwners: [RepoOwner] = []
    private var localFetchedAt: Date?
    private var localChecked = false
    private(set) var status: [String: OwnerFetch] = [:]
    private(set) var listingOwners = false
    private var pendingOwners = 0
    private var ticket: [String: Int] = [:]
    private var listTicket = 0
    private let path: String
    /// The repos of the home, on a client. A client has no GitHub login.
    var mirrored: CatalogRepos? { didSet { notify() } }
    /// Set on a client. It asks the home to fetch the repos of an owner, or of all (nil). `done` gets the failure text or nil, on the main thread.
    var forwardRefresh: ((_ owner: String?, _ done: @escaping (String?) -> Void) -> Void)?
    private var isClient: Bool { mirrored != nil || forwardRefresh != nil }

    init(path: String) {
        self.path = path
        guard let c = RepoCatalogCache.read(atPath: path) else { return }
        localUser = c.user; localOwners = c.owners; localFetchedAt = c.fetchedAt
    }

    var user: String? { isClient ? mirrored?.user : localUser }
    var authChecked: Bool { isClient ? mirrored != nil : localChecked }
    var owners: [RepoOwner] {
        isClient ? mirrored?.owners.map { RepoOwner(login: $0.login, repos: $0.repos, fetchedAt: $0.fetchedAt) } ?? [] : localOwners
    }
    var fetchedAt: Date? { isClient ? mirrored?.owners.compactMap(\.fetchedAt).max() : localFetchedAt }
    var isStale: Bool { fetchedAt.map { -$0.timeIntervalSinceNow > RepoCatalog.maxAge } ?? true }
    var refreshing: Bool { listingOwners || (isClient ? loadingCount > 0 : pendingOwners > 0) }
    var loadingCount: Int { status.values.filter { if case .loading = $0 { return true }; return false }.count }

    func repos(of login: String) -> [String] {
        owners.first { $0.login.caseInsensitiveCompare(login) == .orderedSame }?.repos ?? []
    }

    func fetch(_ login: String) -> OwnerFetch {
        guard isClient else { return status[login] ?? .idle }
        if let s = status[login], !s.isIdle { return s }
        return mirrored?.owners.first { $0.login == login }?.error.map(OwnerFetch.failed) ?? .idle
    }

    /// The owners with their repos and fetch errors, for the mirror. The home sends them to a client.
    func mirrorRepos() -> CatalogRepos {
        let list = owners.map { o -> CatalogRepoOwner in
            var error: String?
            if case .failed(let m) = fetch(o.login) { error = m }
            return CatalogRepoOwner(login: o.login, repos: o.repos, fetchedAt: o.fetchedAt, error: error)
        }
        return CatalogRepos(user: user, owners: list)
    }

    // Explicit picks plus every cached repo of the orgs picked as a whole.
    func resolve(picked: [String], orgs: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for r in picked + orgs.flatMap({ repos(of: $0) }) where isValidRepo(r) && seen.insert(r.lowercased()).inserted {
            out.append(r)
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func refreshIfStale() { if !isClient, isStale { refreshAll() } }

    func refreshAll() {
        guard !refreshing else { return }
        guard !isClient else { return forward(nil) }
        listingOwners = true
        notify()
        Task { [weak self] in
            let u = await REPO_CLIENT.me()
            let orgs = u == nil ? [] : (ghStr("api", "user/orgs", "--paginate", "--jq", ".[].login")?
                .split(separator: "\n").map(String.init) ?? [])
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.listingOwners = false
                self.localUser = u; self.localChecked = true
                guard let u = u else { self.notify(); return }
                let logins = [u] + orgs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                self.localOwners = logins.map { l in
                    self.localOwners.first { $0.login == l } ?? RepoOwner(login: l, repos: [], fetchedAt: nil)
                }
                self.localFetchedAt = Date()
                logins.forEach { self.refresh(owner: $0) }
            }
        }
    }

    func refresh(owner login: String) {
        if case .loading = fetch(login) { return }
        guard !isClient else { return forward(login) }
        status[login] = .loading
        pendingOwners += 1
        notify()
        Task { [weak self] in
            let result = await Result(awaiting: {
                guard let host = REPO_CLIENT.accounts.codeHost(owner: login) else { throw ProviderError.unauthorized }
                return try await host.repos().map(\.ref.path)
            })
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingOwners -= 1
                switch result {
                case .success(let repos):
                    self.status[login] = .idle
                    let o = RepoOwner(login: login, repos: repos, fetchedAt: Date())
                    if let i = self.localOwners.firstIndex(where: { $0.login == login }) { self.localOwners[i] = o }
                    else { self.localOwners.append(o) }
                case .failure(let e):
                    self.status[login] = .failed(GitHubClient.hint(e))
                }
                self.save()
                self.notify()
            }
        }
    }

    // The home fetches. A client shows the new list when the catalog doc comes.
    private func forward(_ owner: String?) {
        guard let forwardRefresh else { return }
        let targets = owner.map { [$0] } ?? owners.map(\.login)
        let tickets = Dictionary(uniqueKeysWithValues: targets.map { l -> (String, Int) in
            let n = (ticket[l] ?? 0) + 1
            ticket[l] = n
            status[l] = .loading
            return (l, n)
        })
        let list = listTicket + 1
        if owner == nil { listTicket = list; listingOwners = true }
        notify()
        forwardRefresh(owner) { [weak self] failure in
            guard let self else { return }
            for (l, n) in tickets where self.ticket[l] == n { self.status[l] = failure.map(OwnerFetch.failed) ?? .idle }
            if owner == nil, self.listTicket == list { self.listingOwners = false }
            self.notify()
        }
    }

    private func save() {
        let c = RepoCatalogCache(user: localUser, owners: localOwners, fetchedAt: localFetchedAt)
        c.write(atPath: path, makeDir: true)
    }

    private func notify() { NotificationCenter.default.post(name: RepoCatalog.changed, object: self) }
}
