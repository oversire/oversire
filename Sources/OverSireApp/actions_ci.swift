import Foundation
import OverSireAI
import OverSireCore
import OverSireAssistant

// The CI actions for agents (ci.json). The reads use the keeper docs, and the vendor only when they must. The writes go through CIOps.
struct CIActions {
    let link: ActionLink
    let jobs: @Sendable () async -> CIJobsKeeper?
    let reader: any CIDetailReading
    let ops: CIOps
    let tracked: @Sendable () -> [String]

    init(link: ActionLink, jobs: @escaping @Sendable () async -> CIJobsKeeper?, reader: any CIDetailReading, ops: CIOps,
         tracked: @escaping @Sendable () -> [String] = { REPOS }) {
        self.link = link
        self.jobs = jobs
        self.reader = reader
        self.ops = ops
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
        [log, jobsSpec, workflows, refresh, explainSpec(id: "ci.explain"), explainSpec(id: "run.explain"), rerun, rerunJob, cancel, dispatch, approve]
    }

    // MARK: Writes

    /// A refusal or a bad input is `notAllowed`. A vendor error is `failed`. A noop is ok.
    private func write(_ body: () async throws -> CIActionResult) async -> ActionResult {
        do {
            let r = try await body()
            return data(r.summary, r)
        } catch CIOpError.vendor(let m) {
            return .failed(m)
        } catch let e as CIOpError {
            return .notAllowed(e.text)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private static let run = ("string", "The run id.")

    private var rerun: ActionSpec {
        ActionSpec(id: "ci.rerun", title: "Rerun CI run", help: "Runs a CI run again. `failedOnly` runs only the failed jobs. A run that runs now gives noop.", kind: .change,
                   input: ActionSpec.args(["repo": Self.repo, "run": Self.run, "failedOnly": ("boolean", "Only the failed jobs.")], required: ["repo", "run"]),
                   capability: .rerun) { a in
            guard let repo = a.string("repo"), let run = a.string("run") else { return .notAllowed("Give the repo and the run id.") }
            return await write { try await ops.rerun(repo: repo, run: run, failedOnly: a.bool("failedOnly") == true, by: a.caller.actor) }
        }
    }

    private var rerunJob: ActionSpec {
        ActionSpec(id: "ci.rerunJob", title: "Rerun CI job", help: "Runs one job of a CI run again.", kind: .change,
                   input: ActionSpec.args(["repo": Self.repo, "run": Self.run, "job": ("string", "The job id.")], required: ["repo", "run", "job"]),
                   capability: .rerunJob) { a in
            guard let repo = a.string("repo"), let run = a.string("run"), let job = a.string("job") else { return .notAllowed("Give the repo, the run id and the job id.") }
            return await write { try await ops.rerunJob(repo: repo, run: run, job: job, by: a.caller.actor) }
        }
    }

    private var cancel: ActionSpec {
        ActionSpec(id: "ci.cancel", title: "Cancel CI run", help: "Cancels a CI run that runs now.", kind: .change,
                   input: ActionSpec.args(["repo": Self.repo, "run": Self.run], required: ["repo", "run"]), capability: .cancel) { a in
            guard let repo = a.string("repo"), let run = a.string("run") else { return .notAllowed("Give the repo and the run id.") }
            return await write { try await ops.cancel(repo: repo, run: run, by: a.caller.actor) }
        }
    }

    private var dispatch: ActionSpec {
        ActionSpec(id: "ci.dispatch", title: "Start workflow", help: "Starts a workflow by hand on a ref. `workflow` is its id, name or file name.", kind: .outward,
                   input: ActionSpec.args(["repo": Self.repo, "workflow": ("string", "The workflow id, name or file name."),
                                           "ref": ("string", "The branch or tag."), "inputs": ("object", "The inputs of the workflow, as strings.")],
                                          required: ["repo", "workflow", "ref"]), capability: .dispatch) { a in
            guard let repo = a.string("repo"), let workflow = a.string("workflow"), let ref = a.string("ref") else {
                return .notAllowed("Give the repo, the workflow and the ref.")
            }
            var inputs: [String: String] = [:]
            for (k, v) in a["inputs"]?.object ?? [:] {
                switch v {
                case .string(let s): inputs[k] = s
                case .int(let i): inputs[k] = String(i)
                case .double(let d): inputs[k] = String(d)
                case .bool(let b): inputs[k] = String(b)
                default: return .notAllowed("The input \(k) must be a string.")
                }
            }
            return await write { try await ops.dispatch(repo: repo, workflow: workflow, ref: ref, inputs: inputs, by: a.caller.actor) }
        }
    }

    private var approve: ActionSpec {
        ActionSpec(id: "ci.approve", title: "Approve deployment", help: "Approves the deployments that wait for a review on a run. `environments` limits it.", kind: .outward,
                   input: ActionSpec.args(["repo": Self.repo, "run": Self.run, "environments": ("array", "The environment names. Default all that wait."),
                                           "comment": ("string", "The review comment.")], required: ["repo", "run"]), capability: .gates) { a in
            guard let repo = a.string("repo"), let run = a.string("run") else { return .notAllowed("Give the repo and the run id.") }
            return await write { try await ops.approve(repo: repo, run: run, environments: a.list("environments"), comment: a.string("comment"), by: a.caller.actor) }
        }
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

    private func explainSpec(id: String) -> ActionSpec {
        ActionSpec(id: id, title: "Explain failure",
                   help: "Explains a failed run: cause, fix and confidence. It uses the AI engine of the user.", kind: .read,
                   input: ActionSpec.args(["repo": Self.repo, "runId": ("string", "The run id."), "attempt": ("integer", "The attempt. Default the newest."),
                                           "job": ("string", "A job id. Default the first failed job."), "force": ("boolean", "Ask the AI engine again.")],
                                          required: ["repo", "runId"])) { a in
            await explain(a)
        }
    }

    private func explain(_ a: ActionArgs) async -> ActionResult {
        guard let repo = a.string("repo"), let id = a.string("runId") else { return .notAllowed("Give the repo and the run id.") }
        if let r = untracked(repo) { return r }
        guard let keeper = await jobs(), let assist = await link.main(CIAssist?.none, { d, done in done(d.ciAssist) }) else { return .failed("The app has no CI data.") }
        var found = await link.main(Run?.none) { d, done in done(d.grouped.first { $0.0 == repo }?.1.first { $0.id == id }) }
        if found == nil { found = await reader.run(repo, id: id) }
        guard var run = found else { return .notAllowed("OverSire has no run \(id) in \(repo).") }
        let attempt = a.int("attempt") ?? run.attempt ?? 1
        var doc = await MainActor.run { keeper.doc(repo: repo, run: id, attempt: attempt) }
        if attempt != (run.attempt ?? 1) {
            guard let held = doc else { return .notAllowed("OverSire has no attempt \(attempt) of run \(id).") }
            run = Run(id: run.id, name: run.name, displayTitle: run.displayTitle, status: held.status, conclusion: held.conclusion, headBranch: run.headBranch,
                      headSha: run.headSha, event: run.event, url: run.url, updatedAt: run.updatedAt, createdAt: run.createdAt, startedAt: run.startedAt,
                      number: run.number, workflowName: run.workflowName, actorLogin: run.actorLogin, attempt: attempt)
        }
        guard run.isFailure else { return .notAllowed("Run \(id) did not fail.") }
        let force = a.bool("force") == true
        let cached = await MainActor.run { !force && assist.explanation(run) != nil }
        if !cached, !(await MainActor.run { assist.hasEngine }) { return .notAllowed("Set an AI engine in Settings › AI.") }
        if doc == nil { doc = await keeper.fetchNow(repo: repo, run: run) }
        let wanted = a.string("job")
        let failure = doc?.failures.first { wanted == nil || $0.jobId == wanted }
        let job = doc?.jobs.first { $0.id == (wanted ?? failure?.jobId) } ?? doc?.jobs.first { $0.conclusion == "failure" }
            ?? Job(id: wanted ?? "", name: run.workflowName ?? run.name, status: nil, conclusion: nil, url: nil, startedAt: nil, completedAt: nil,
                   runnerName: nil, steps: nil)
        var lines = failure?.logTail
        if lines == nil, !job.id.isEmpty, let text = await reader.rawLog(repo, jobId: job.id) {
            lines = await MainActor.run { CIJobsKeeper.tail(text, lines: CIJobsKeeper.maxLogLines) }
        }
        let result = await assist.explainNow(repo: repo, run: run, job: job, log: lines ?? failure?.messages ?? [], force: force)
        switch result {
        case .failure(let e): return .failed(e.message)
        case .success(let e):
            let view = CIExplanation(repo: repo, run: id, attempt: attempt, job: job.id.isEmpty ? nil : job.id, cause: e.cause, fix: e.fix,
                                     confidence: e.confidence, at: e.at, source: cached ? .cache : .ai)
            return data("Cause: \(e.cause)\nFix: \(e.fix)\nConfidence: \(e.confidence)", view)
        }
    }
}
