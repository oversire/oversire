import Foundation
import OverSireCore

/// Owns the `ciJobs` docs: the jobs, the failures and the log tails of each run attempt.
/// It fetches when a run changes, once for each state, and keeps a final attempt in a file.
@MainActor
final class CIJobsKeeper {
    static let maxLogLines = 40
    static let maxFailedJobs = 3
    static let maxAttemptsPerRepo = 50
    static let window: TimeInterval = 24 * 3600
    static let keep: TimeInterval = 7 * 24 * 3600
    static let parallel = 4

    private struct Held: Codable {
        var doc: CIJobsDoc
        /// The `updatedAt` of the run at the time of the fetch.
        var updatedAt: String
    }

    private struct Flight {
        var repo: String
        var run: Run
        var dirty = false
        var force = false
        var task: Task<Void, Never>?
    }

    let quota: CIQuota
    private let reader: any CIDetailReading
    private let store: URL
    private let clock: () -> Date
    private let touch: ([String]) -> Void
    private let saveDelay: TimeInterval
    private var held: [String: Held] = [:]
    private var made: [String: MirrorDoc] = [:]
    private var flights: [String: Flight] = [:]
    private var active = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var saving = false

    /// `touch` gets the repos of the changed docs.
    init(reader: any CIDetailReading, quota: CIQuota, store: URL, clock: @escaping () -> Date = Date.init,
         touch: @escaping ([String]) -> Void, saveDelay: TimeInterval = 2) {
        self.reader = reader
        self.quota = quota
        self.store = store
        self.clock = clock
        self.touch = touch
        self.saveDelay = saveDelay
        if let data = try? Data(contentsOf: store), let list = try? MirrorCodec.decoder().decode([Held].self, from: data) {
            for h in list { held[Self.id(h.doc)] = h }
        }
    }

    // MARK: Reads

    func docs(_ repos: [String]?) -> [MirrorDoc] {
        let want = repos.map(Set.init)
        return held.sorted { $0.key < $1.key }.compactMap { id, h in
            guard want?.contains(h.doc.repo) ?? true else { return nil }
            if let d = made[id] { return d }
            guard let d = MirrorDoc.make(.ciJobs, id: id, h.doc) else { return nil }
            made[id] = d
            return d
        }
    }

    /// `attempt` nil: the newest attempt of the run.
    func doc(repo: String, run: String, attempt: Int?) -> CIJobsDoc? {
        if let attempt { return held[MirrorCodec.ciJobsID(repo: repo, run: run, attempt: attempt)]?.doc }
        return held.values.map(\.doc).filter { $0.repo == repo && $0.run == run }.max { $0.attempt < $1.attempt }
    }

    /// The doc that holds the job.
    func doc(repo: String, job: String) -> CIJobsDoc? {
        held.values.map(\.doc).filter { $0.repo == repo && $0.jobs.contains { $0.id == job } }.max { $0.fetchedAt < $1.fetchedAt }
    }

    /// The last `lines` lines of a log, without time stamps and group markers.
    static func tail(_ log: String, lines: Int) -> [String] {
        Array(CILog.clean(log).suffix(max(0, lines)))
    }

    // MARK: Watching

    func observe(_ grouped: [(String, [Run])]) {
        let now = clock()
        for (repo, runs) in grouped {
            for run in runs {
                let h = held[Self.id(repo, run)]
                if run.status != "completed" {
                    if quota.degraded { continue }
                } else if h == nil, let at = parseISO(run.updatedAt), now.timeIntervalSince(at) > Self.window {
                    continue
                }
                if needs(repo, run) { schedule(repo, run, force: false) }
            }
        }
    }

    /// Fetches now, also when a doc exists. Waits for a fetch in flight.
    func fetchNow(repo: String, run: Run) async -> CIJobsDoc? {
        await schedule(repo, run, force: true).value
        return doc(repo: repo, run: run.id, attempt: run.attempt ?? 1)
    }

    private func needs(_ repo: String, _ run: Run) -> Bool {
        let h = held[Self.id(repo, run)]
        if run.status == "completed" { return h?.doc.final != true }
        return h == nil || h?.updatedAt != run.updatedAt
    }

    @discardableResult
    private func schedule(_ repo: String, _ run: Run, force: Bool) -> Task<Void, Never> {
        let id = Self.id(repo, run)
        if var f = flights[id], let task = f.task {
            f.run = run
            f.dirty = true
            f.force = f.force || force
            flights[id] = f
            return task
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.pump(id)
        }
        flights[id] = Flight(repo: repo, run: run, force: force, task: task)
        return task
    }

    /// One fetch at a time for each attempt. A change during a fetch makes one more pass.
    private func pump(_ id: String) async {
        while let f = flights[id] {
            flights[id]?.dirty = false
            flights[id]?.force = false
            if f.force || needs(f.repo, f.run) {
                await acquire()
                await fetch(f.repo, f.run)
                release()
            }
            if flights[id]?.dirty != true { break }
        }
        flights[id] = nil
    }

    private func acquire() async {
        if active < Self.parallel { active += 1; return }
        await withCheckedContinuation { waiting.append($0) }
    }

    private func release() {
        if waiting.isEmpty { active -= 1 } else { waiting.removeFirst().resume() }
    }

    private func fetch(_ repo: String, _ run: Run) async {
        guard let jobs = await reader.jobs(repo, runId: run.id) else { return }
        let completed = run.status == "completed"
        var failures: [CIFailureView] = []
        if completed, run.isFailure {
            failures = await failureViews(repo, run, jobs)
        }
        let doc = CIJobsDoc(repo: repo, run: run.id, attempt: run.attempt ?? 1, status: run.status, conclusion: run.conclusion,
                            workflow: run.workflowName, headSha: run.headSha, headBranch: run.headBranch, event: run.event, url: run.url,
                            jobs: jobs, failures: failures, final: completed, fetchedAt: clock())
        let id = Self.id(doc)
        held[id] = Held(doc: doc, updatedAt: run.updatedAt)
        made[id] = nil
        changed([repo])
    }

    private func failureViews(_ repo: String, _ run: Run, _ jobs: [Job]) async -> [CIFailureView] {
        let failed = Array(jobs.filter { $0.conclusion == "failure" }.prefix(Self.maxFailedJobs))
        guard !failed.isEmpty else { return [] }
        let reasons = await reader.failures(repo, runId: run.id, jobs: jobs)
        var out: [CIFailureView] = []
        for job in failed {
            let why = reasons.first { $0.job == job.name }
            let step = why?.step ?? job.steps?.first { $0.conclusion == "failure" }?.name
            let tail = await reader.rawLog(repo, jobId: job.id).map { Self.tail($0, lines: Self.maxLogLines) }
            out.append(CIFailureView(job: job.name, jobId: job.id, step: step, messages: why?.messages ?? [], logTail: tail, url: job.url))
        }
        return out
    }

    // MARK: Keeping

    /// Drops the attempts older than 7 days, and the oldest over 50 for each repo. The next send removes their docs.
    func prune(now: Date) {
        var gone: [String] = []
        for (id, h) in held where now.timeIntervalSince(h.doc.fetchedAt) > Self.keep { gone.append(id) }
        for id in gone { held[id] = nil }
        for ids in Dictionary(grouping: held.keys, by: { held[$0]!.doc.repo }).values where ids.count > Self.maxAttemptsPerRepo {
            let old = ids.sorted { held[$0]!.doc.fetchedAt > held[$1]!.doc.fetchedAt }.dropFirst(Self.maxAttemptsPerRepo)
            gone += old
            old.forEach { held[$0] = nil }
        }
        guard !gone.isEmpty else { return }
        for id in gone { made[id] = nil }
        changed(Array(Set(gone.map(Self.repo(ofDoc:)))))
    }

    private func changed(_ repos: [String]) {
        touch(repos)
        guard !saving else { return }
        saving = true
        Task { @MainActor [weak self] in
            if let delay = self?.saveDelay, delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            self?.flush()
        }
    }

    /// Writes the docs to the file at once.
    func flush() {
        saving = false
        guard let data = try? MirrorCodec.encoder().encode(held.sorted { $0.key < $1.key }.map(\.value)) else { return }
        try? FileManager.default.createDirectory(at: store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: store, options: .atomic)
    }

    private static func id(_ repo: String, _ run: Run) -> String { MirrorCodec.ciJobsID(repo: repo, run: run.id, attempt: run.attempt ?? 1) }
    private static func id(_ d: CIJobsDoc) -> String { MirrorCodec.ciJobsID(repo: d.repo, run: d.run, attempt: d.attempt) }
    /// The repo of a doc id: `<owner>/<repo>/<run>/<attempt>`.
    private static func repo(ofDoc id: String) -> String { id.split(separator: "/").prefix(2).joined(separator: "/") }
}
