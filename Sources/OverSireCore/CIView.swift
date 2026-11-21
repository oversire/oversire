import Foundation

// The CI data for the agents. Contract: ci.json.
// CIRun, CIJob and CIStep are Run, Job and Step. CIRunsDoc is MirrorRuns. CIBudget is RateBudget.

public enum CICheckKind: String, Codable, Hashable, Sendable, CaseIterable {
    case checkRun, status
}

public enum CICheckState: String, Codable, Hashable, Sendable, CaseIterable {
    case pending, running, success, failure, cancelled, neutral, skipped
}

public enum CISource: String, Codable, Hashable, Sendable, CaseIterable {
    case webhook, poll
}

public enum CIRollupState: String, Codable, Hashable, Sendable, CaseIterable {
    case pending, running, success, failure, cancelled, none
}

/// Why a job failed, for an agent: the failed step, the annotations and the tail of the log.
public struct CIFailureView: Codable, Hashable, Sendable {
    public var job: String
    public var jobId: String
    public var step: String?
    public var messages: [String]
    /// At most 40 lines, with no time stamps.
    public var logTail: [String]?
    public var url: String?

    public init(job: String, jobId: String, step: String? = nil, messages: [String], logTail: [String]? = nil, url: String? = nil) {
        self.job = job
        self.jobId = jobId
        self.step = step
        self.messages = messages
        self.logTail = logTail
        self.url = url
    }

    public init(_ f: Failure, jobId: String, logTail: [String]?, url: String?) {
        self.init(job: f.job, jobId: jobId, step: f.step, messages: f.messages, logTail: logTail, url: url)
    }
}

/// The body of a `ciJobs` mirror doc. The id is `<owner>/<repo>/<run>/<attempt>`.
public struct CIJobsDoc: Codable, Hashable, Sendable {
    public var repo: String
    public var run: String
    public var attempt: Int
    public var status: String
    public var conclusion: String?
    public var workflow: String?
    public var headSha: String
    public var headBranch: String
    public var event: String
    public var url: String
    public var jobs: [Job]
    public var failures: [CIFailureView]
    /// True when the attempt is completed and the jobs, failures and log tails are complete.
    public var final: Bool
    public var fetchedAt: Date

    public init(repo: String, run: String, attempt: Int, status: String, conclusion: String? = nil, workflow: String? = nil,
                headSha: String, headBranch: String, event: String, url: String, jobs: [Job], failures: [CIFailureView],
                final: Bool, fetchedAt: Date) {
        self.repo = repo
        self.run = run
        self.attempt = attempt
        self.status = status
        self.conclusion = conclusion
        self.workflow = workflow
        self.headSha = headSha
        self.headBranch = headBranch
        self.event = event
        self.url = url
        self.jobs = jobs
        self.failures = failures
        self.final = final
        self.fetchedAt = fetchedAt
    }
}

/// A check that is not Actions: a check run of another app, or a commit status. Read only.
public struct CICheck: Codable, Hashable, Sendable {
    public var name: String
    public var app: String?
    public var kind: CICheckKind
    public var state: CICheckState
    public var conclusion: String?
    public var url: String?
    public var startedAt: String?
    public var completedAt: String?

    public init(name: String, app: String? = nil, kind: CICheckKind, state: CICheckState, conclusion: String? = nil,
                url: String? = nil, startedAt: String? = nil, completedAt: String? = nil) {
        self.name = name
        self.app = app
        self.kind = kind
        self.state = state
        self.conclusion = conclusion
        self.url = url
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// The body of a `ciChecks` mirror doc. The id is `<owner>/<repo>/<sha>`.
public struct CIChecksDoc: Codable, Hashable, Sendable {
    public var repo: String
    public var sha: String
    public var prs: [Int]
    public var checks: [CICheck]
    /// True when each check is completed.
    public var final: Bool
    public var fetchedAt: Date

    public init(repo: String, sha: String, prs: [Int], checks: [CICheck], final: Bool, fetchedAt: Date) {
        self.repo = repo
        self.sha = sha
        self.prs = prs
        self.checks = checks
        self.final = final
        self.fetchedAt = fetchedAt
    }
}

public struct CIRepoState: Codable, Hashable, Sendable {
    public var repo: String
    /// The display name of the CI provider, for example "GitHub Actions".
    public var ci: String
    /// The raw values of `Capability`.
    public var capabilities: [String]
    /// The time of the last good runs fetch of the repo.
    public var polledAt: Date?

    public init(repo: String, ci: String, capabilities: [String], polledAt: Date? = nil) {
        self.repo = repo
        self.ci = ci
        self.capabilities = capabilities
        self.polledAt = polledAt
    }
}

/// The body of the one `ciState` mirror doc. The id is `home`.
public struct CIStateDoc: Codable, Hashable, Sendable {
    /// The time of the last change of the CI data in the app.
    public var asOf: Date
    public var source: CISource
    /// True when the remaining quota is below 10 % of the limit.
    public var degraded: Bool
    public var budget: RateBudget?
    public var repos: [CIRepoState]

    public init(asOf: Date, source: CISource, degraded: Bool, budget: RateBudget? = nil, repos: [CIRepoState]) {
        self.asOf = asOf
        self.source = source
        self.degraded = degraded
        self.budget = budget
        self.repos = repos
    }
}

/// One run in an answer of the daemon.
public struct CIRunView: Codable, Hashable, Sendable {
    public var id: String
    public var attempt: Int
    public var name: String
    public var workflow: String?
    public var status: String
    public var conclusion: String?
    public var branch: String
    public var sha: String
    public var event: String
    public var url: String
    public var startedAt: String?
    public var updatedAt: String
    public var durationS: Int?
    public var etaS: Int?
    public var jobs: [Job]?
    public var failures: [CIFailureView]?

    public init(id: String, attempt: Int, name: String, workflow: String? = nil, status: String, conclusion: String? = nil,
                branch: String, sha: String, event: String, url: String, startedAt: String? = nil, updatedAt: String,
                durationS: Int? = nil, etaS: Int? = nil, jobs: [Job]? = nil, failures: [CIFailureView]? = nil) {
        self.id = id
        self.attempt = attempt
        self.name = name
        self.workflow = workflow
        self.status = status
        self.conclusion = conclusion
        self.branch = branch
        self.sha = sha
        self.event = event
        self.url = url
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.durationS = durationS
        self.etaS = etaS
        self.jobs = jobs
        self.failures = failures
    }
}

// Each answer repeats the freshness fields asOf, source, stale and degraded.

/// The answer of `GET /v1/ci/status` and `GET /v1/ci/wait`.
public struct CIRollup: Codable, Hashable, Sendable {
    public var repo: String
    public var ref: String
    public var sha: String?
    public var pr: Int?
    public var state: CIRollupState
    /// True when no run or check can change the state.
    public var done: Bool
    /// Opaque text. It changes when the rollup changes. `wait` uses it as `since`.
    public var rev: String
    public var runs: [CIRunView]
    public var checks: [CICheck]
    public var asOf: Date
    public var source: CISource
    public var stale: Bool
    public var degraded: Bool

    public init(repo: String, ref: String, sha: String? = nil, pr: Int? = nil, state: CIRollupState, done: Bool, rev: String,
                runs: [CIRunView], checks: [CICheck], asOf: Date, source: CISource, stale: Bool, degraded: Bool) {
        self.repo = repo
        self.ref = ref
        self.sha = sha
        self.pr = pr
        self.state = state
        self.done = done
        self.rev = rev
        self.runs = runs
        self.checks = checks
        self.asOf = asOf
        self.source = source
        self.stale = stale
        self.degraded = degraded
    }
}

public struct CIRunsPage: Codable, Hashable, Sendable {
    public var repo: String
    public var runs: [CIRunView]
    public var asOf: Date
    public var source: CISource
    public var stale: Bool
    public var degraded: Bool

    public init(repo: String, runs: [CIRunView], asOf: Date, source: CISource, stale: Bool, degraded: Bool) {
        self.repo = repo
        self.runs = runs
        self.asOf = asOf
        self.source = source
        self.stale = stale
        self.degraded = degraded
    }
}

public struct CIRunAnswer: Codable, Hashable, Sendable {
    public var run: CIRunView
    public var asOf: Date
    public var source: CISource
    public var stale: Bool
    public var degraded: Bool

    public init(run: CIRunView, asOf: Date, source: CISource, stale: Bool, degraded: Bool) {
        self.run = run
        self.asOf = asOf
        self.source = source
        self.stale = stale
        self.degraded = degraded
    }
}

public struct CIFailuresAnswer: Codable, Hashable, Sendable {
    public var repo: String
    public var run: String
    public var attempt: Int
    public var failures: [CIFailureView]
    public var asOf: Date
    public var source: CISource
    public var stale: Bool
    public var degraded: Bool

    public init(repo: String, run: String, attempt: Int, failures: [CIFailureView], asOf: Date, source: CISource, stale: Bool, degraded: Bool) {
        self.repo = repo
        self.run = run
        self.attempt = attempt
        self.failures = failures
        self.asOf = asOf
        self.source = source
        self.stale = stale
        self.degraded = degraded
    }
}

public struct CILogView: Codable, Hashable, Sendable {
    public var repo: String
    public var jobId: String
    public var run: String?
    public var lines: [String]
    /// True when the job is completed and the log will not change.
    public var complete: Bool
    /// True when the log has more lines than the answer.
    public var truncated: Bool
    public var cached: Bool
    public var asOf: Date
    public var source: CISource
    public var stale: Bool
    public var degraded: Bool

    public init(repo: String, jobId: String, run: String? = nil, lines: [String], complete: Bool, truncated: Bool, cached: Bool,
                asOf: Date, source: CISource, stale: Bool, degraded: Bool) {
        self.repo = repo
        self.jobId = jobId
        self.run = run
        self.lines = lines
        self.complete = complete
        self.truncated = truncated
        self.cached = cached
        self.asOf = asOf
        self.source = source
        self.stale = stale
        self.degraded = degraded
    }
}

public struct CIWorkflow: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// Empty when the vendor gives none.
    public var path: String?
    public var state: String?

    public init(id: String, name: String, path: String? = nil, state: String? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.state = state
    }
}

public struct CIWorkflows: Codable, Hashable, Sendable {
    public var repo: String
    public var workflows: [CIWorkflow]
    public var asOf: Date
    public var source: CISource
    public var stale: Bool
    public var degraded: Bool

    public init(repo: String, workflows: [CIWorkflow], asOf: Date, source: CISource, stale: Bool, degraded: Bool) {
        self.repo = repo
        self.workflows = workflows
        self.asOf = asOf
        self.source = source
        self.stale = stale
        self.degraded = degraded
    }
}

/// The args of the write actions ci.rerun, ci.rerunJob, ci.cancel, ci.dispatch and ci.approve (P2).
public struct CIActionRequest: Codable, Hashable, Sendable {
    public var repo: String
    public var run: String?
    public var job: String?
    public var failedOnly: Bool?
    public var workflow: String?
    public var ref: String?
    public var inputs: [String: String]?
    public var environments: [String]?
    public var comment: String?
    public var agent: String?

    public init(repo: String, run: String? = nil, job: String? = nil, failedOnly: Bool? = nil, workflow: String? = nil,
                ref: String? = nil, inputs: [String: String]? = nil, environments: [String]? = nil, comment: String? = nil,
                agent: String? = nil) {
        self.repo = repo
        self.run = run
        self.job = job
        self.failedOnly = failedOnly
        self.workflow = workflow
        self.ref = ref
        self.inputs = inputs
        self.environments = environments
        self.comment = comment
        self.agent = agent
    }
}

/// The data of an ok result of a write action (P2).
public struct CIActionResult: Codable, Hashable, Sendable {
    public var ok: Bool
    /// True when the action had nothing to do, for example a rerun of a running attempt.
    public var noop: Bool
    public var summary: String
    public var run: CIRunView?
    public var url: String?

    public init(ok: Bool, noop: Bool, summary: String, run: CIRunView? = nil, url: String? = nil) {
        self.ok = ok
        self.noop = noop
        self.summary = summary
        self.run = run
        self.url = url
    }
}

/// A request to keep the CI data of a ref fresh (P3). `ttl` is in seconds.
public struct CIWatch: Codable, Hashable, Sendable {
    public var repo: String
    public var ref: String
    public var ttl: Int
    public var expiresAt: Date?

    public init(repo: String, ref: String, ttl: Int, expiresAt: Date? = nil) {
        self.repo = repo
        self.ref = ref
        self.ttl = ttl
        self.expiresAt = expiresAt
    }
}
