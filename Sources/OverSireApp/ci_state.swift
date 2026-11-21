import Foundation
import OverSireCore

/// Builds the one `ciState` doc: how fresh the CI data is, and the quota.
@MainActor
final class CIStateBook {
    private let quota: CIQuota
    private let repos: () -> [String]
    private let info: (String) -> (name: String, capabilities: Set<Capability>)?
    private let clock: () -> Date
    private var polledAt: [String: Date] = [:]
    private var asOf: Date

    init(quota: CIQuota, repos: @escaping () -> [String], info: @escaping (String) -> (name: String, capabilities: Set<Capability>)?,
         clock: @escaping () -> Date = Date.init) {
        self.quota = quota
        self.repos = repos
        self.info = info
        self.clock = clock
        asOf = clock()
    }

    /// The repos with a good runs fetch, or with a webhook hint that the app applied. A repo that is not here keeps its old time.
    func polled(_ repos: [String], at: Date) {
        for r in repos { polledAt[r] = at }
    }

    func changed() { asOf = clock() }

    func doc() -> MirrorDoc {
        let states = repos().compactMap { repo -> CIRepoState? in
            guard let i = info(repo) else { return nil }
            return CIRepoState(repo: repo, ci: i.name, capabilities: i.capabilities.map(\.rawValue).sorted(), polledAt: polledAt[repo])
        }
        let state = CIStateDoc(asOf: asOf, source: quota.source, degraded: quota.degraded, budget: quota.budget, repos: states)
        return MirrorDoc.make(.ciState, id: MirrorCodec.ciStateID, state)
            ?? MirrorDoc(kind: .ciState, id: MirrorCodec.ciStateID, v: MirrorCodec.version, at: Date(), body: .object([:]))
    }
}
