import Foundation
import OverSireCore

/// Owns the `ciChecks` docs: the status checks of a commit that are not runs of the CI provider.
/// It reads the commits of open PRs and of recent runs.
@MainActor
final class CIChecksKeeper {
    static let maxShas = 20
    static let recent: TimeInterval = 30 * 60
    static let keep: TimeInterval = 24 * 3600

    private struct Held {
        var doc: CIChecksDoc
        /// The newest `updatedAt` of the runs on the commit at the time of the fetch.
        var runStamp: String
        var interestedAt: Date
        var made: MirrorDoc?
    }

    private let reader: any CIDetailReading
    private let quota: CIQuota
    private let clock: () -> Date
    private let touch: ([String]) -> Void
    private var held: [String: Held] = [:]
    private var queue: [(repo: String, sha: String, prs: [Int], stamp: String)] = []
    private var worker: Task<Void, Never>?

    /// `touch` gets the repos of the changed docs.
    init(reader: any CIDetailReading, quota: CIQuota, clock: @escaping () -> Date = Date.init, touch: @escaping ([String]) -> Void) {
        self.reader = reader
        self.quota = quota
        self.clock = clock
        self.touch = touch
    }

    func observe(runs: [(String, [Run])], prs: [(String, [ChangeRequest])]) {
        let now = clock()
        var repos = runs.map(\.0)
        for (r, _) in prs where !repos.contains(r) { repos.append(r) }
        for repo in repos {
            var shas: [String] = []
            var numbers: [String: [Int]] = [:]
            var stamps: [String: String] = [:]
            for pr in prs.first(where: { $0.0 == repo })?.1 ?? [] {
                guard let sha = pr.headSha, !sha.isEmpty else { continue }
                if !shas.contains(sha) { shas.append(sha) }
                numbers[sha, default: []].append(pr.number)
            }
            let list = (runs.first { $0.0 == repo }?.1 ?? []).sorted { $0.updatedAt > $1.updatedAt }
            for run in list where !run.headSha.isEmpty {
                stamps[run.headSha] = max(stamps[run.headSha] ?? "", run.updatedAt)
                let recent = parseISO(run.updatedAt).map { now.timeIntervalSince($0) <= Self.recent } ?? false
                if (run.status != "completed" || recent) && !shas.contains(run.headSha) { shas.append(run.headSha) }
            }
            for sha in shas.prefix(Self.maxShas) {
                let id = MirrorCodec.ciChecksID(repo: repo, sha: sha)
                let stamp = stamps[sha] ?? ""
                held[id]?.interestedAt = now
                if let h = held[id], h.doc.final, h.runStamp == stamp { continue }
                if quota.degraded { continue }
                if !queue.contains(where: { $0.repo == repo && $0.sha == sha }) {
                    queue.append((repo, sha, numbers[sha] ?? [], stamp))
                }
            }
        }
        if worker == nil, !queue.isEmpty { worker = Task { @MainActor [weak self] in await self?.drain() } }
    }

    private func drain() async {
        while !queue.isEmpty {
            let q = queue.removeFirst()
            if quota.degraded { continue }
            guard let checks = await reader.checks(q.repo, sha: q.sha) else { continue }
            let done = checks.allSatisfy { $0.state != .pending && $0.state != .running }
            let doc = CIChecksDoc(repo: q.repo, sha: q.sha, prs: q.prs, checks: checks, final: done, fetchedAt: clock())
            let id = MirrorCodec.ciChecksID(repo: q.repo, sha: q.sha)
            held[id] = Held(doc: doc, runStamp: q.stamp, interestedAt: clock())
            touch([q.repo])
        }
        worker = nil
    }

    func docs(_ repos: [String]?) -> [MirrorDoc] {
        let want = repos.map(Set.init)
        return held.keys.sorted().compactMap { id in
            guard let h = held[id], want?.contains(h.doc.repo) ?? true else { return nil }
            if let d = h.made { return d }
            guard let d = MirrorDoc.make(.ciChecks, id: id, h.doc) else { return nil }
            held[id]?.made = d
            return d
        }
    }

    /// Drops a commit that no PR or run has named for 24 hours.
    func prune(now: Date) {
        let gone = held.filter { now.timeIntervalSince($0.value.interestedAt) > Self.keep }
        guard !gone.isEmpty else { return }
        gone.keys.forEach { held[$0] = nil }
        touch(Array(Set(gone.values.map(\.doc.repo))))
    }
}
