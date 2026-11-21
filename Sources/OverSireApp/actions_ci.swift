import Foundation
import OverSireCore
import OverSireAssistant

// The CI read actions for agents (ci.json). They read the keeper docs, and the vendor only when they must.
struct CIActions {
    let link: ActionLink
    let jobs: @Sendable () async -> CIJobsKeeper?
    let reader: any CIDetailReading
    let tracked: @Sendable () -> [String]

    init(link: ActionLink, jobs: @escaping @Sendable () async -> CIJobsKeeper?, reader: any CIDetailReading,
         tracked: @escaping @Sendable () -> [String] = { REPOS }) {
        self.link = link
        self.jobs = jobs
        self.reader = reader
        self.tracked = tracked
    }

    static let repo = ("string", "The repo, for example oversire/oversire.")

    private func quota() async -> (source: CISource, degraded: Bool) {
        guard let k = await jobs() else { return (.poll, false) }
        return await MainActor.run { (k.quota.source, k.quota.degraded) }
    }

    private func untracked(_ repo: String) -> ActionResult? {
        tracked().contains(repo) ? nil : .notAllowed("OverSire does not track \(repo). Add the repo in Settings › Code hosts.")
    }

    private func data<T: Encodable>(_ summary: String, _ value: T) -> ActionResult {
        guard let body = try? MirrorCodec.body(value) else { return .failed("The answer cannot be encoded.") }
        return .ok(summary: summary, data: body)
    }

    var specs: [ActionSpec] {
        [log, jobsSpec, workflows, refresh]
    }

    private var log: ActionSpec {
        ActionSpec(id: "ci.log", title: "CI job log", help: "Reads the last lines of the log of a CI job.", kind: .read,
                   input: ActionSpec.args(["repo": Self.repo, "jobId": ("string", "The job id."), "lines": ("integer", "How many last lines. 1 to 2000, default 200.")],
                                          required: ["repo", "jobId"]), capability: .logs) { a in
            guard let repo = a.string("repo"), let job = a.string("jobId") else { return .notAllowed("Give the repo and the job id.") }
            if let r = untracked(repo) { return r }
            let n = min(2000, max(1, a.int("lines") ?? 200))
            guard let text = await reader.rawLog(repo, jobId: job) else { return .failed("The log of job \(job) is not available.") }
            let all = await MainActor.run { CIJobsKeeper.tail(text, lines: n + 1) }
            let keeper = await jobs()
            let doc = await MainActor.run { keeper?.doc(repo: repo, job: job) }
            let complete = doc?.jobs.first { $0.id == job }?.status == "completed"
            let q = await quota()
            let view = CILogView(repo: repo, jobId: job, run: doc?.run, lines: Array(all.suffix(n)), complete: complete, truncated: all.count > n,
                                 cached: false, asOf: Date(), source: q.source, stale: false, degraded: q.degraded)
            return data("\(view.lines.count) lines of job \(job).", view)
        }
    }

    private var jobsSpec: ActionSpec {
        ActionSpec(id: "ci.jobs", title: "CI run jobs", help: "Gives the jobs, the failures and the log tails of a CI run. `fresh` fetches them again.", kind: .read,
                   input: ActionSpec.args(["repo": Self.repo, "runId": ("string", "The run id."), "attempt": ("integer", "The attempt. Default the newest."),
                                           "fresh": ("boolean", "Fetch again from the vendor.")], required: ["repo", "runId"])) { a in
            guard let repo = a.string("repo"), let id = a.string("runId") else { return .notAllowed("Give the repo and the run id.") }
            if let r = untracked(repo) { return r }
            guard let keeper = await jobs() else { return .failed("The app has no CI data.") }
            let attempt = a.int("attempt")
            if a.bool("fresh") != true, let doc = await MainActor.run(body: { keeper.doc(repo: repo, run: id, attempt: attempt) }) {
                return data("Run \(id) has \(doc.jobs.count) jobs.", doc)
            }
            let run = await link.main(Run?.none) { d, done in
                done(d.grouped.first { $0.0 == repo }?.1.first { $0.id == id && (attempt == nil || ($0.attempt ?? 1) == attempt) })
            }
            guard let run else { return .notAllowed("OverSire has no loaded run \(id) in \(repo).") }
            guard let doc = await keeper.fetchNow(repo: repo, run: run) else { return .failed("The jobs of run \(id) are not available.") }
            return data("Run \(id) has \(doc.jobs.count) jobs.", doc)
        }
    }

    private var workflows: ActionSpec {
        ActionSpec(id: "ci.workflows", title: "CI workflows", help: "Lists the workflows of a repo.", kind: .read,
                   input: ActionSpec.args(["repo": Self.repo], required: ["repo"])) { a in
            guard let repo = a.string("repo") else { return .notAllowed("Give the repo.") }
            if let r = untracked(repo) { return r }
            do {
                let list = try await REPO_CLIENT.pipelines(repo)
                let q = await quota()
                let view = CIWorkflows(repo: repo, workflows: list.map { CIWorkflow(id: $0.id, name: $0.name, path: $0.path.isEmpty ? nil : $0.path) },
                                       asOf: Date(), source: q.source, stale: false, degraded: q.degraded)
                return data("\(list.count) workflows in \(repo).", view)
            } catch {
                return .failed("The workflows of \(repo) are not available: \(error.localizedDescription)")
            }
        }
    }

    private var refresh: ActionSpec {
        ActionSpec(id: "ci.refresh", title: "Refresh CI", help: "Fetches the runs of a repo once.", kind: .read,
                   input: ActionSpec.args(["repo": Self.repo], required: ["repo"])) { a in
            guard let repo = a.string("repo") else { return .notAllowed("Give the repo.") }
            if let r = untracked(repo) { return r }
            let ok = await link.main(false) { d, done in d.ciRefresh(repo, done: done) }
            return ok ? .ok(summary: "The runs of \(repo) are fresh.") : .failed("The runs of \(repo) did not load.")
        }
    }
}
