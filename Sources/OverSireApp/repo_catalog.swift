import Foundation

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
}

func repoOwner(_ repo: String) -> String {
    String(repo.split(separator: "/").first ?? Substring(repo))
}

// The list of repos the user can pick from. It is cached on disk and refreshed
// in the background, per owner, at most once a day unless the user asks.
final class RepoCatalog {
    static let changed = Notification.Name("RepoCatalogChanged")
    static let maxAge: TimeInterval = 24 * 3600

    private(set) var user: String?
    private(set) var authChecked = false
    private(set) var owners: [RepoOwner] = []
    private(set) var fetchedAt: Date?
    private(set) var status: [String: OwnerFetch] = [:]
    private(set) var listingOwners = false
    private var pendingOwners = 0
    private let path: String
    private let fetchQ: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    init(path: String) {
        self.path = path
        guard let data = FileManager.default.contents(atPath: path),
              let c = try? JSONDecoder().decode(RepoCatalogCache.self, from: data) else { return }
        user = c.user; owners = c.owners; fetchedAt = c.fetchedAt
    }

    var isStale: Bool { fetchedAt.map { -$0.timeIntervalSinceNow > RepoCatalog.maxAge } ?? true }
    var refreshing: Bool { listingOwners || pendingOwners > 0 }
    var loadingCount: Int { status.values.filter { if case .loading = $0 { return true }; return false }.count }

    func repos(of login: String) -> [String] {
        owners.first { $0.login.caseInsensitiveCompare(login) == .orderedSame }?.repos ?? []
    }

    func fetch(_ login: String) -> OwnerFetch { status[login] ?? .idle }

    // Explicit picks plus every cached repo of the orgs picked as a whole.
    func resolve(picked: [String], orgs: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for r in picked + orgs.flatMap({ repos(of: $0) }) where isValidRepo(r) && seen.insert(r.lowercased()).inserted {
            out.append(r)
        }
        return out.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func checkAuth() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let u = getGHUser()
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.user = u; self.authChecked = true
                self.notify()
            }
        }
    }

    func refreshIfStale() { if isStale { refreshAll() } }

    func refreshAll() {
        guard !refreshing else { return }
        listingOwners = true
        notify()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let u = getGHUser()
            let orgs = u == nil ? [] : (ghStr("api", "user/orgs", "--paginate", "--jq", ".[].login")?
                .split(separator: "\n").map(String.init) ?? [])
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.listingOwners = false
                self.user = u; self.authChecked = true
                guard let u = u else { self.notify(); return }
                let logins = [u] + orgs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                self.owners = logins.map { l in
                    self.owners.first { $0.login == l } ?? RepoOwner(login: l, repos: [], fetchedAt: nil)
                }
                self.fetchedAt = Date()
                logins.forEach { self.refresh(owner: $0) }
            }
        }
    }

    func refresh(owner login: String) {
        if case .loading = fetch(login) { return }
        status[login] = .loading
        pendingOwners += 1
        notify()
        fetchQ.addOperation { [weak self] in
            let result = RepoCatalog.list(login)
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.pendingOwners -= 1
                switch result {
                case .success(let repos):
                    self.status[login] = .idle
                    let o = RepoOwner(login: login, repos: repos, fetchedAt: Date())
                    if let i = self.owners.firstIndex(where: { $0.login == login }) { self.owners[i] = o }
                    else { self.owners.append(o) }
                case .failure(let e):
                    self.status[login] = .failed(e.message)
                }
                self.save()
                self.notify()
            }
        }
    }

    struct ListError: Error { let message: String }

    private static func list(_ login: String) -> Result<[String], ListError> {
        guard FileManager.default.isExecutableFile(atPath: GH) else {
            return .failure(ListError(message: "GitHub CLI not found at \(GH)"))
        }
        do {
            let res = try ghRun(["repo", "list", login, "--limit", "1000", "--no-archived",
                                 "--json", "nameWithOwner", "--jq", ".[].nameWithOwner"])
            guard res.ok else { return .failure(ListError(message: String(res.err.prefix(120)))) }
            let out = String(data: res.out, encoding: .utf8) ?? ""
            let repos = out.split(separator: "\n").map(String.init)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            return .success(repos)
        } catch {
            return .failure(ListError(message: error.localizedDescription))
        }
    }

    private func save() {
        let c = RepoCatalogCache(user: user, owners: owners, fetchedAt: fetchedAt)
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func notify() { NotificationCenter.default.post(name: RepoCatalog.changed, object: self) }
}
