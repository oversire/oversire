import Foundation
import OverSireCore
import GitHubKit
import OverSireAI
import OverSireAssistant

// The CI and PR actions. They go through REPO_CLIENT, then reload the repos.
struct RepoActions {
    let link: ActionLink

    static let repo = ("string", "The repo, for example oversire/oversire.")
    static let runId = ("string", "The run id.")
    static let number = ("integer", "The PR number.")
    /// A job log result keeps its last part.
    static let maxLog = 24_000

    var specs: [ActionSpec] {
        let link = link
        let refresh: () async -> Void = { _ = await link.main(()) { d, done in d.refresh(force: true) { }; done(()) } }
        let after: (String?, String) async -> ActionResult = { err, ok in
            await refresh()
            return err.map { .failed($0) } ?? .ok(summary: ok)
        }
        return [
            ActionSpec(id: "run.rerun", title: "Re-run", help: "Runs a workflow run again. `failedOnly` runs only the failed jobs.", kind: .change,
                       input: ActionSpec.args(["repo": Self.repo, "runId": Self.runId, "failedOnly": ("boolean", "Only the failed jobs.")], required: ["repo", "runId"]),
                       capability: .rerun) { a in
                guard let repo = a.string("repo"), let id = a.string("runId") else { return .notAllowed("Give the repo and the run id.") }
                return await after(await REPO_CLIENT.perform(a.bool("failedOnly") == true ? .rerunFailed : .rerun, repo: repo, id: id), "Run \(id) runs again.")
            },
            ActionSpec(id: "run.cancel", title: "Cancel run", help: "Cancels a running workflow run.", kind: .change,
                       input: ActionSpec.args(["repo": Self.repo, "runId": Self.runId], required: ["repo", "runId"]), capability: .cancel) { a in
                guard let repo = a.string("repo"), let id = a.string("runId") else { return .notAllowed("Give the repo and the run id.") }
                return await after(await REPO_CLIENT.perform(.cancel, repo: repo, id: id), "Run \(id) is cancelled.")
            },
            ActionSpec(id: "run.rerunJob", title: "Re-run job", help: "Runs one job of a run again.", kind: .change,
                       input: ActionSpec.args(["repo": Self.repo, "runId": Self.runId, "jobId": ("string", "The job id.")], required: ["repo", "runId", "jobId"]),
                       capability: .rerunJob) { a in
                guard let repo = a.string("repo"), let id = a.string("runId"), let job = a.string("jobId") else { return .notAllowed("Give the repo, the run id and the job id.") }
                return await after(await REPO_CLIENT.rerunJob(repo: repo, runId: id, jobId: job), "Job \(job) runs again.")
            },
            ActionSpec(id: "run.ignore", title: "Ignore failure", help: "Hides a failed run from the status light, or shows it again.", kind: .change,
                       input: ActionSpec.args(["repo": Self.repo, "runId": Self.runId, "on": ("boolean", "False shows the run again. Default true.")], required: ["repo", "runId"])) { a in
                await link.run { d, done in
                    guard let repo = a.string("repo"), let r = d.grouped.first(where: { $0.0 == repo })?.1.first(where: { $0.id == a.string("runId") }) else {
                        done(.notAllowed("OverSire has no loaded run \(a.string("runId") ?? "") in \(a.string("repo") ?? "").")); return
                    }
                    let on = a.bool("on") ?? true
                    d.setIgnored([r], ignored: on)
                    done(.ok(summary: on ? "OverSire ignores the failure of run \(r.id)." : "Run \(r.id) counts again."))
                }
            },
            ActionSpec(id: "run.log", title: "Job log", help: "Reads the log of a job. Long logs give their last part.", kind: .read,
                       input: ActionSpec.args(["repo": Self.repo, "jobId": ("string", "The job id.")], required: ["repo", "jobId"]), capability: .logs) { a in
                guard let repo = a.string("repo"), let job = a.string("jobId") else { return .notAllowed("Give the repo and the job id.") }
                guard let log = await REPO_CLIENT.rawLog(repo, jobId: job) else { return .failed("The log of job \(job) is not available.") }
                let tail = log.count > Self.maxLog ? "…\n" + String(log.suffix(Self.maxLog)) : log
                return .ok(summary: tail)
            },
            ActionSpec(id: "run.explain", title: "Explain failure", help: "Gives the saved AI explanation of a failed run: cause, fix and confidence. Without one, read run.log.", kind: .read,
                       input: ActionSpec.args(["repo": Self.repo, "runId": Self.runId], required: ["repo", "runId"])) { a in
                await link.run { d, done in
                    guard let repo = a.string("repo"), let r = d.grouped.first(where: { $0.0 == repo })?.1.first(where: { $0.id == a.string("runId") }) else {
                        done(.notAllowed("OverSire has no loaded run \(a.string("runId") ?? "") in \(a.string("repo") ?? "").")); return
                    }
                    guard let e = d.ciAssist.explanation(r) else { done(.notAllowed("Run \(r.id) has no explanation yet. Read the failed job with run.log.")); return }
                    done(.ok(summary: "Cause: \(e.cause)\nFix: \(e.fix)\nConfidence: \(e.confidence)"))
                }
            },
            ActionSpec(id: "pr.approve", title: "Approve PR", help: "Approves a pull request, with an optional review comment.", kind: .outward,
                       input: ActionSpec.args(["repo": Self.repo, "number": Self.number, "body": ("string", "A review comment.")], required: ["repo", "number"]),
                       capability: .changeActions) { a in
                guard let repo = a.string("repo"), let n = a.int("number") else { return .notAllowed("Give the repo and the PR number.") }
                return await after(await REPO_CLIENT.perform(.approve(a.string("body")), repo: repo, number: n), "\(repo)#\(n) is approved.")
            },
            ActionSpec(id: "pr.merge", title: "Merge PR", help: "Merges a pull request: squash (default), merge or rebase.", kind: .outward,
                       input: ActionSpec.args(["repo": Self.repo, "number": Self.number, "method": ("string", "squash, merge or rebase.")], required: ["repo", "number"]),
                       capability: .changeActions) { a in
                guard let repo = a.string("repo"), let n = a.int("number") else { return .notAllowed("Give the repo and the PR number.") }
                guard let m = MergeMethod(rawValue: a.string("method") ?? "squash") else { return .notAllowed("The method is squash, merge or rebase.") }
                return await after(await REPO_CLIENT.perform(.merge(m), repo: repo, number: n), "\(repo)#\(n) is merged (\(m.rawValue)).")
            },
            ActionSpec(id: "pr.requestChanges", title: "Request changes", help: "Sends a review that asks for changes.", kind: .outward,
                       input: ActionSpec.args(["repo": Self.repo, "number": Self.number, "body": ("string", "What to change.")], required: ["repo", "number", "body"]),
                       capability: .changeActions) { a in
                guard let repo = a.string("repo"), let n = a.int("number"), let body = a.string("body"), !body.isEmpty else { return .notAllowed("Give the repo, the PR number and the text.") }
                return await after(await REPO_CLIENT.perform(.requestChanges(body), repo: repo, number: n), "Changes are requested on \(repo)#\(n).")
            },
            ActionSpec(id: "pr.comment", title: "Comment on PR", help: "Adds a Markdown comment to a pull request.", kind: .outward,
                       input: ActionSpec.args(["repo": Self.repo, "number": Self.number, "body": ("string", "The Markdown comment.")], required: ["repo", "number", "body"]),
                       capability: .changeActions) { a in
                guard let repo = a.string("repo"), let n = a.int("number"), let body = a.string("body"), !body.isEmpty else { return .notAllowed("Give the repo, the PR number and the text.") }
                return await after(await REPO_CLIENT.perform(.comment(body), repo: repo, number: n), "Comment added to \(repo)#\(n).")
            },
            ActionSpec(id: "pr.close", title: "Close PR", help: "Closes a pull request without a merge.", kind: .outward,
                       input: ActionSpec.args(["repo": Self.repo, "number": Self.number], required: ["repo", "number"]), capability: .changeActions) { a in
                guard let repo = a.string("repo"), let n = a.int("number") else { return .notAllowed("Give the repo and the PR number.") }
                return await after(await REPO_CLIENT.perform(.close, repo: repo, number: n), "\(repo)#\(n) is closed.")
            },
            ActionSpec(id: "pr.deleteBranch", title: "Delete branch", help: "Deletes the head branch of a merged or closed pull request on the code host.", kind: .outward,
                       input: ActionSpec.args(["repo": Self.repo, "number": Self.number], required: ["repo", "number"]), capability: .deleteBranch) { a in
                guard let repo = a.string("repo"), let n = a.int("number") else { return .notAllowed("Give the repo and the PR number.") }
                let pr = await link.main(nil) { d, done in done(d.prGrouped.first { $0.0 == repo }?.1.first { $0.number == n }) }
                guard let pr else { return .notAllowed("OverSire has no loaded PR \(repo)#\(n).") }
                guard pr.state.lowercased() != "open" else { return .notAllowed("\(repo)#\(n) is open. Merge or close it first.") }
                guard let h = REPO_CLIENT.branchHost(repo) else { return .notAllowed("The code host of \(repo) cannot delete branches.") }
                do { try await h.host.deleteBranch(h.ref, name: pr.headRefName) } catch { return .failed((error as? ProviderError).map(GitHubClient.hint) ?? error.localizedDescription) }
                return await after(nil, "Branch \(pr.headRefName) is deleted.")
            },
        ]
    }
}

extension ChangeAction {
    /// The catalog action of a PR action.
    func action(repo: String, number: Int) -> (id: String, args: [String: JSONValue]) {
        var args: [String: JSONValue] = ["repo": .string(repo), "number": .int(number)]
        switch self {
        case .approve(let body): if let body { args["body"] = .string(body) }; return ("pr.approve", args)
        case .requestChanges(let body): args["body"] = .string(body); return ("pr.requestChanges", args)
        case .comment(let body): args["body"] = .string(body); return ("pr.comment", args)
        case .merge(let m): args["method"] = .string(m.rawValue); return ("pr.merge", args)
        case .close: return ("pr.close", args)
        }
    }
}
