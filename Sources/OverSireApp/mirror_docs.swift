import Foundation
import OverSireCore

// The docs of this app for the mirror (OVERSIRE-526). Main thread only.

@MainActor
final class AppMirrorDocs: MirrorDocSource {
    private let store: ProjectStore
    private let runs: () -> [(String, [Run])]
    private let prs: () -> [(String, [ChangeRequest])]
    private let projects: () -> [ProjectSummary]
    private let layers: (Layer) -> Set<Capability>
    private let trackers: () -> [String]
    private let settings: () -> HomeSettings
    private let workspaces: () -> [CatalogWorkspace]
    // An item that did not change keeps its doc, so a change of one project does not encode all items again.
    private var items: [String: (item: Item, doc: MirrorDoc)] = [:]
    private var activity: [String: MirrorDoc] = [:]

    init(store: ProjectStore, runs: @escaping () -> [(String, [Run])], prs: @escaping () -> [(String, [ChangeRequest])],
         projects: @escaping () -> [ProjectSummary], layers: @escaping (Layer) -> Set<Capability>, trackers: @escaping () -> [String],
         settings: @escaping () -> HomeSettings = { homeSettings(from: currentConfig(), accounts: AccountSummary.list(ENV)) },
         workspaces: @escaping () -> [CatalogWorkspace] = { [] }) {
        self.store = store
        self.runs = runs
        self.prs = prs
        self.projects = projects
        self.layers = layers
        self.trackers = trackers
        self.settings = settings
        self.workspaces = workspaces
    }

    func projectDocs(_ keys: [String]?) -> [MirrorDoc] {
        let want = keys.map(Set.init)
        var out: [MirrorDoc] = []
        var made: [String: (item: Item, doc: MirrorDoc)] = [:]
        for p in store.tracked {
            let key = p.ref.storeKey
            guard want?.contains(key) ?? true, let snap = store.snapshots[key] else { continue }
            let bare = ProjectSnapshot(summary: snap.summary, statusOptions: snap.statusOptions, items: [], fetchedAt: snap.fetchedAt,
                                       fields: snap.fields, me: snap.me, meId: snap.meId, index: snap.index, intake: snap.intake, epics: snap.epics)
            if let d = MirrorDoc.make(.project, id: key, bare) { out.append(d) }
            for item in snap.items {
                let id = MirrorCodec.itemID(project: key, item: item.id)
                if let hit = items[id], hit.item == item {
                    made[id] = hit
                } else if let d = MirrorDoc.make(.item, id: id, item) {
                    made[id] = (item, d)
                } else { continue }
                out.append(made[id]!.doc)
            }
        }
        if let want {
            items = items.filter { id, _ in !(MirrorCodec.projectKey(ofItemDoc: id).map(want.contains) ?? false) }.merging(made) { _, new in new }
        } else {
            items = made
        }
        return out
    }

    func runDocs(_ repos: [String]?) -> [MirrorDoc] {
        let want = repos.map(Set.init)
        return runs().compactMap { repo, list in
            want?.contains(repo) ?? true ? MirrorDoc.make(.runs, id: repo, MirrorRuns(runs: list)) : nil
        }
    }

    func prDocs(_ repos: [String]?) -> [MirrorDoc] {
        let want = repos.map(Set.init)
        return prs().compactMap { repo, list in
            want?.contains(repo) ?? true ? MirrorDoc.make(.prs, id: repo, MirrorPRs(prs: list)) : nil
        }
    }

    func activityDocs(since: Date?) -> [MirrorDoc] {
        var made: [String: MirrorDoc] = [:]
        for var e in store.activityEntries where since.map({ e.at >= $0 }) ?? true {
            if let hit = activity[e.id] { made[e.id] = hit; continue }
            // Which entry a person has read is local to each Mac.
            e.unread = true
            if let d = MirrorDoc.make(.activity, id: e.id, e) { made[e.id] = d }
        }
        activity = made
        return made.values.sorted { $0.id < $1.id }
    }

    func catalogDoc() -> MirrorDoc {
        let list = projects().map { p in
            CatalogProject(summary: p, capabilities: Self.sorted(store.tracker(of: p.ref)?.capabilities ?? []))
        }
        let caps = Dictionary(uniqueKeysWithValues: [Layer.tracker, .codeHost, .ci].map { ($0.rawValue, Self.sorted(layers($0))) })
        let catalog = ClientCatalog(projects: list, capabilities: caps, trackers: trackers(), workspaces: workspaces())
        return MirrorDoc.make(.catalog, id: MirrorCodec.catalogID, catalog)
            ?? MirrorDoc(kind: .catalog, id: MirrorCodec.catalogID, v: MirrorCodec.version, at: Date(), body: .object([:]))
    }

    func settingsDoc() -> MirrorDoc {
        MirrorDoc.make(.settings, id: MirrorCodec.settingsID, settings())
            ?? MirrorDoc(kind: .settings, id: MirrorCodec.settingsID, v: MirrorCodec.version, at: Date(), body: .object([:]))
    }

    private static func sorted(_ s: Set<Capability>) -> [Capability] { s.sorted { $0.rawValue < $1.rawValue } }
}
