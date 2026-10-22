import Foundation
import OverSireCore

/// The people that the app knows: tracker members, code host collaborators and the owner of the group machines.
/// One person from many sources becomes one entry (PersonDetail.merge). The lists stay 10 minutes.
final class AppPeople: People, @unchecked Sendable {
    /// The people of one project, or of all projects for nil.
    typealias Source = @Sendable (ProjectRef?) async -> [PersonDetail]
    /// The name of the developer and the names of their machines.
    typealias Owner = @Sendable () async -> (name: String?, machines: [String])

    private let sources: [Source]
    private let owner: Owner
    private let ttl: TimeInterval
    private let lock = NSLock()
    private var cache: [String: (at: Date, list: [PersonDetail])] = [:]

    init(sources: [Source], owner: @escaping Owner = { (nil, []) }, ttl: TimeInterval = 600) {
        self.sources = sources
        self.owner = owner
        self.ttl = ttl
    }

    func details(for project: ProjectRef?) async -> [PersonDetail] {
        let key = project.map { "\($0.account.provider.rawValue):\($0.account.id)/\($0.id)" } ?? "*"
        if let c = lock.withLock({ cache[key] }), Date().timeIntervalSince(c.at) < ttl { return c.list }
        var lists: [[PersonDetail]] = []
        for s in sources { lists.append(await s(project)) }
        var list = PersonDetail.merge(lists)
        // The group machines are the machines of the developer.
        let o = await owner()
        if !o.machines.isEmpty {
            if let n = o.name, let i = list.firstIndex(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
                list[i].machines = o.machines
                list[i].sources.append("machines")
            } else {
                list.append(PersonDetail(id: "me", name: o.name ?? "You", sources: ["machines"], machines: o.machines))
            }
        }
        lock.withLock { cache[key] = (Date(), list) }
        return list
    }

    func people(for project: ProjectRef?) async throws -> [PersonRef] { await details(for: project).map(\.ref) }

    func person(_ ref: PersonRef) async throws -> PersonDetail {
        let all = await details(for: nil)
        guard let p = all.first(where: { $0.id == ref.id }) ?? all.first(where: { $0.login != nil && $0.login == ref.login }) else {
            throw ProviderError.notFound
        }
        return p
    }
}

extension AppPeople {
    /// The live sources. `data` is read on the main thread.
    static func live(_ data: AppData) -> AppPeople {
        weak var d = data
        let members: Source = { project in
            let projects: [ProjectRef] = await MainActor.run { project.map { [$0] } ?? d?.projectStore.tracked.prefix(10).map(\.ref) ?? [] }
            var out: [PersonDetail] = []
            for p in projects {
                guard let t = await MainActor.run(body: { ENV.provider(p.account) }) as? any ProjectSettingsReading,
                      let s = try? await t.settings(p) else { continue }
                out += s.members.map { PersonDetail($0.person, sources: ["\(p.account.provider.rawValue):\(p.account.id)"]) }
            }
            return out
        }
        let collaborators: Source = { _ in
            let repos: [String] = await MainActor.run { Array((d?.prGrouped.map(\.0) ?? []).prefix(8)) }
            var out: [PersonDetail] = []
            for r in repos {
                guard let h = await MainActor.run(body: { REPO_CLIENT.accounts.codeHost(owner: repoOwner(r)) }) as? any CollaboratorListing,
                      let list = try? await h.collaborators(RepoClient.repoRef(h, r)) else { continue }
                out += list.map { PersonDetail($0, sources: ["\(h.account.provider.rawValue):\(h.account.id)"]) }
            }
            return out
        }
        let owner: Owner = {
            await MainActor.run {
                let s = MachinesController.shared.snapshot
                let me = d?.projectStore.snapshots.values.compactMap(\.me).first
                return (me, s.group?.members.map(\.machine.rawValue) ?? s.info.map { [$0.machine.rawValue] } ?? [])
            }
        }
        return AppPeople(sources: [members, collaborators], owner: owner)
    }
}
