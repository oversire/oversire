import Foundation

// The repo list of Settings › Projects and repos › Repos: the filter, the owner groups and the webhook badges.
struct RepoListModel {
    enum Filter: CaseIterable { case all, tracked, problems }

    // The webhook state of a tracked repo. Missing and failed hooks can be fixed. A polling-only repo needs an admin.
    enum Badge: Equatable {
        case webhook, missing, pollingOnly(String), failed(String)

        var problem: Bool { self != .webhook }
        var fixable: Bool {
            switch self {
            case .missing, .failed: return true
            case .webhook, .pollingOnly: return false
            }
        }

        init(_ s: HookStatus?) {
            switch s {
            case .live?, .waiting?: self = .webhook
            case .pollingOnly(let d)?: self = .pollingOnly(d)
            case .error(let d)?: self = .failed(d)
            default: self = .missing
            }
        }
    }

    struct Repo: Equatable {
        let name: String
        let tracked: Bool
        let badge: Badge?
        var short: String { String(name.split(separator: "/", maxSplits: 1).last ?? Substring(name)) }
    }

    struct Group: Equatable {
        let owner: String
        let repos: [Repo]
        let tracked: Int
        let total: Int
        let wholeOwner: Bool
        // Rows of the filter that the cap hides.
        let hidden: Int
    }

    static let firstRows = 10
    static let moreRows = 50

    private(set) var picked: Set<String>
    private(set) var orgs: Set<String>
    private let catalog: [(owner: String, repos: [String])]
    // Nil when the cloud is off: then no repo has a badge.
    private let hooks: [String: HookStatus]?
    var text = ""
    var filter = Filter.all
    // The row cap of each owner. An owner with no entry shows firstRows.
    var limits: [String: Int] = [:]

    init(catalog: [(owner: String, repos: [String])], picked: Set<String>, orgs: Set<String>, hooks: [String: HookStatus]?) {
        self.catalog = catalog
        self.picked = picked
        self.orgs = orgs
        self.hooks = hooks
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
    private static func byName(_ a: String, _ b: String) -> Bool { a.localizedCaseInsensitiveCompare(b) == .orderedAscending }

    func isOwnerPicked(_ owner: String) -> Bool { orgs.contains { Self.same($0, owner) } }
    func isTracked(_ repo: String) -> Bool { isOwnerPicked(repoOwner(repo)) || picked.contains(repo) }

    // Owners of the catalog first, then owners that only the picks name.
    var owners: [String] {
        var out = catalog.map(\.owner)
        let known = Set(out.map { $0.lowercased() })
        out += Set((picked.map(repoOwner) + orgs).filter { !known.contains($0.lowercased()) }).sorted(by: Self.byName)
        return out
    }

    func repos(of owner: String) -> [String] {
        var all = catalog.first { Self.same($0.owner, owner) }?.repos ?? []
        let known = Set(all.map { $0.lowercased() })
        all += picked.filter { Self.same(repoOwner($0), owner) && !known.contains($0.lowercased()) }
        return all.sorted(by: Self.byName)
    }

    private func repo(_ name: String) -> Repo {
        let tracked = isTracked(name)
        return Repo(name: name, tracked: tracked, badge: tracked ? hooks.map { Badge($0[name]) } : nil)
    }

    private var everything: [Repo] { owners.flatMap { repos(of: $0) }.map(repo) }

    var counts: [Filter: Int] {
        let all = everything
        return [.all: all.count, .tracked: all.filter(\.tracked).count, .problems: all.filter { $0.badge?.problem == true }.count]
    }

    private func keep(_ r: Repo) -> Bool {
        let q = text.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty, !r.name.localizedCaseInsensitiveContains(q) { return false }
        switch filter {
        case .all: return true
        case .tracked: return r.tracked
        case .problems: return r.badge?.problem == true
        }
    }

    // Groups with no row after the filter go away. With no filter, an owner with no repos stays, for its Loading or No repos state.
    var groups: [Group] {
        let open = filter == .all && text.trimmingCharacters(in: .whitespaces).isEmpty
        return owners.compactMap { owner in
            let all = repos(of: owner).map(repo)
            let shown = all.filter(keep)
            guard !shown.isEmpty || (open && all.isEmpty) else { return nil }
            let rows = Self.cap(shown, limits[owner] ?? Self.firstRows)
            return Group(owner: owner, repos: rows, tracked: all.filter(\.tracked).count, total: all.count,
                         wholeOwner: isOwnerPicked(owner), hidden: shown.count - rows.count)
        }
    }

    // Tracked repos take the cap first. The rows keep the name order.
    private static func cap(_ repos: [Repo], _ n: Int) -> [Repo] {
        guard repos.count > n else { return repos }
        let keep = Set((repos.filter(\.tracked) + repos.filter { !$0.tracked }).prefix(n).map(\.name))
        return repos.filter { keep.contains($0.name) }
    }

    mutating func showMore(_ owner: String) { limits[owner] = (limits[owner] ?? Self.firstRows) + Self.moreRows }

    // The filter text, when it is an owner/repo that the list does not have.
    var addable: String? {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard isValidRepo(q), !everything.contains(where: { Self.same($0.name, q) }) else { return nil }
        return q
    }

    // Untracking one repo of a whole-owner pick turns the rest into single picks.
    mutating func set(_ repo: String, tracked on: Bool) {
        if on { picked.insert(repo); return }
        let owner = repoOwner(repo)
        if isOwnerPicked(owner) {
            orgs = orgs.filter { !Self.same($0, owner) }
            picked.formUnion(repos(of: owner))
        }
        picked.remove(repo)
    }

    // Off or partial goes to all; all goes to none.
    mutating func toggleOwner(_ owner: String) {
        let wasAll = isOwnerPicked(owner)
        orgs = orgs.filter { !Self.same($0, owner) }
        picked = picked.filter { !Self.same(repoOwner($0), owner) }
        if !wasAll { orgs.insert(owner) }
    }

    // The picks to save. A repo of a picked owner needs no own pick.
    var savedRepos: [String] { picked.filter { !isOwnerPicked(repoOwner($0)) }.sorted(by: Self.byName) }
    var savedOrgs: [String] { orgs.sorted(by: Self.byName) }
}
