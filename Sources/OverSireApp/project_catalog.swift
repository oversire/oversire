import Foundation
import OverSireCore

// The projects of each Plane workspace, for the picker. Cached on disk and
// refreshed, per workspace, at most once a day unless the user asks.

struct ProjectCatalogCache: Codable {
    var workspaces: [CachedWorkspace]

    struct CachedWorkspace: Codable {
        var slug: String
        var projects: [ProjectSummary]
        var fetchedAt: Date?
    }
}

final class ProjectCatalog {
    static let changed = Notification.Name("ProjectCatalogChanged")
    static let maxAge: TimeInterval = 24 * 3600

    private(set) var bySlug: [String: [ProjectSummary]] = [:]
    private(set) var fetchedAt: [String: Date] = [:]
    private(set) var status: [String: OwnerFetch] = [:]
    private var ticket: [String: Int] = [:]
    private var lookedUp = Set<String>()
    private let trackers: TrackerDirectory
    private let path: String
    /// The projects of the home, on a client. A client has no tracker account.
    var mirrored: ClientCatalog? { didSet { notify() } }
    /// Set on a client. It asks the home to fetch the projects of a workspace, or of all (nil). `done` gets the failure text or nil, on the main thread.
    var forwardRefresh: ((_ workspace: String?, _ done: @escaping (String?) -> Void) -> Void)?
    private var isClient: Bool { mirrored != nil || forwardRefresh != nil }

    init(trackers: TrackerDirectory, path: String) {
        self.trackers = trackers
        self.path = path
        guard let c = ProjectCatalogCache.read(atPath: path) else { return }
        for w in c.workspaces {
            bySlug[w.slug] = w.projects
            fetchedAt[w.slug] = w.fetchedAt
        }
    }

    var workspaces: [String] { isClient ? mirrored?.workspaces?.map(\.id) ?? [] : trackers.trackerIds }
    var refreshing: Bool { status.values.contains { if case .loading = $0 { return true }; return false } }
    var isStale: Bool {
        workspaces.contains { fetchedAt[$0].map { -$0.timeIntervalSinceNow > ProjectCatalog.maxAge } ?? true }
    }

    func projects(of slug: String) -> [ProjectSummary] {
        isClient ? mirrored?.workspaces?.first { $0.id == slug }?.projects ?? [] : bySlug[slug] ?? []
    }

    func fetch(_ slug: String) -> OwnerFetch {
        guard isClient else { return status[slug] ?? .idle }
        if let s = status[slug], !s.isIdle { return s }
        return mirrored?.workspaces?.first { $0.id == slug }?.error.map(OwnerFetch.failed) ?? .idle
    }

    /// The open projects of each workspace, for the mirror. The home sends them to a client.
    func mirrorWorkspaces() -> [CatalogWorkspace] {
        workspaces.map { w in
            var error: String?
            if case .failed(let m) = fetch(w) { error = m }
            return CatalogWorkspace(id: w, projects: projects(of: w).filter { !$0.closed }, fetchedAt: fetchedAt[w], error: error)
        }
    }

    // Explicit picks plus every open project of the workspaces picked as a whole.
    func resolve(_ cfg: ProjectsConfig) -> [ProjectSummary] {
        if let mirrored { return mirrored.projects.map(\.summary) }
        var out: [ProjectSummary] = []
        for w in workspaces {
            let all = cfg.allOf.contains(w)
            out += projects(of: w).filter { !$0.closed && (all || cfg.picked.contains($0.ref.storeKey)) }
        }
        return cfg.sorted(out)
    }

    func refreshIfStale() { if !isClient, isStale { refreshAll() } }

    /// The open project with this key ("MCPQ") in any workspace.
    func project(key: String) -> ProjectSummary? {
        workspaces.lazy.flatMap { self.projects(of: $0) }.first { !$0.closed && $0.identifier.uppercased() == key.uppercased() }
    }

    /// Refreshes all workspaces once for a key that OverSire does not track. A new Plane project then shows with no wait for the cache.
    /// False when the key was looked up before.
    func lookUp(_ key: String) -> Bool {
        guard lookedUp.insert(key.uppercased()).inserted else { return false }
        refreshAll(force: true)
        return true
    }

    func refreshAll(force: Bool = false) {
        guard !isClient else { return forward(nil) }
        for w in workspaces { refresh(w, force: force) }
        let known = Set(workspaces)
        if bySlug.keys.contains(where: { !known.contains($0) }) {
            bySlug = bySlug.filter { known.contains($0.key) }
            save()
        }
        notify()
    }

    // A click on Refresh starts a new request even if the last one still runs.
    func refresh(_ slug: String, force: Bool = false) {
        if !force, case .loading = fetch(slug) { return }
        guard !isClient else { return forward(slug) }
        guard let client = trackers.tracker(slug) else {
            status[slug] = .failed(ProjectStore.noToken)
            notify()
            return
        }
        let n = (ticket[slug] ?? 0) + 1
        ticket[slug] = n
        status[slug] = .loading
        notify()
        Task { [weak self] in
            let result = await Result(awaiting: { try await client.projects() })
            DispatchQueue.main.async {
                guard let self = self, self.ticket[slug] == n else { return }
                switch result {
                case .success(let list):
                    self.status[slug] = .idle
                    self.bySlug[slug] = list
                    self.fetchedAt[slug] = Date()
                    self.save()
                case .failure(let e):
                    self.status[slug] = .failed(e.message)
                }
                self.notify()
            }
        }
    }

    // The home fetches. A client shows the new list when the catalog doc comes.
    private func forward(_ slug: String?) {
        guard let forwardRefresh else { return }
        let targets = slug.map { [$0] } ?? workspaces
        let tickets = Dictionary(uniqueKeysWithValues: targets.map { w -> (String, Int) in
            let n = (ticket[w] ?? 0) + 1
            ticket[w] = n
            status[w] = .loading
            return (w, n)
        })
        notify()
        forwardRefresh(slug) { [weak self] failure in
            guard let self else { return }
            for (w, n) in tickets where self.ticket[w] == n { self.status[w] = failure.map(OwnerFetch.failed) ?? .idle }
            self.notify()
        }
    }

    private func save() {
        let c = ProjectCatalogCache(workspaces: bySlug.map { .init(slug: $0.key, projects: $0.value, fetchedAt: fetchedAt[$0.key]) })
        c.write(atPath: path, makeDir: true)
    }

    private func notify() { NotificationCenter.default.post(name: ProjectCatalog.changed, object: self) }
}
