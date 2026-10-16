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
    private let trackers: TrackerDirectory
    private let path: String

    init(trackers: TrackerDirectory, path: String) {
        self.trackers = trackers
        self.path = path
        guard let data = FileManager.default.contents(atPath: path),
              let c = try? JSONDecoder().decode(ProjectCatalogCache.self, from: data) else { return }
        for w in c.workspaces {
            bySlug[w.slug] = w.projects
            fetchedAt[w.slug] = w.fetchedAt
        }
    }

    var workspaces: [String] { trackers.trackerIds }
    var refreshing: Bool { status.values.contains { if case .loading = $0 { return true }; return false } }
    var isStale: Bool {
        workspaces.contains { fetchedAt[$0].map { -$0.timeIntervalSinceNow > ProjectCatalog.maxAge } ?? true }
    }

    func projects(of slug: String) -> [ProjectSummary] { bySlug[slug] ?? [] }
    func fetch(_ slug: String) -> OwnerFetch { status[slug] ?? .idle }

    // Explicit picks plus every open project of the workspaces picked as a whole.
    func resolve(_ cfg: ProjectsConfig) -> [ProjectSummary] {
        var out: [ProjectSummary] = []
        for w in workspaces {
            let all = cfg.allOf.contains(w)
            out += projects(of: w).filter { !$0.closed && (all || cfg.picked.contains($0.ref.storeKey)) }
        }
        return cfg.sorted(out)
    }

    func refreshIfStale() { if isStale { refreshAll() } }

    func refreshAll(force: Bool = false) {
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

    private func save() {
        let c = ProjectCatalogCache(workspaces: bySlug.map { .init(slug: $0.key, projects: $0.value, fetchedAt: fetchedAt[$0.key]) })
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func notify() { NotificationCenter.default.post(name: ProjectCatalog.changed, object: self) }
}
