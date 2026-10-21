import Cocoa
import GitHubKit
import OverSireCore


// The gh CLI and the GitHub client for the rate limit.
let GH = GitHubClient.defaultPath
let GITHUB = GitHubClient(commands: ProcessRunner(environment: GitHubClient.environment), http: URLSessionTransport.noRedirects, gh: GH)

// ─── Helpers ─────────────────────────────────────────────────────────────────

private let _fetchErrQ = DispatchQueue(label: "com.oversire.app.fetchErr")
private var _lastFetchError: String? = nil
var lastFetchError: String? {
    get { _fetchErrQ.sync { _lastFetchError } }
    set { _fetchErrQ.sync { _lastFetchError = newValue } }
}

// Runs gh with optional stdin, so request bodies with secrets never appear in argv.
func ghRun(_ args: [String], input: Data? = nil, timeout: TimeInterval? = nil) throws -> CommandOutput {
    try ProcessRunner(environment: GitHubClient.environment).runSync(GH, args, stdin: input, timeout: timeout)
}

func ghStr(_ args: String...) -> String? {
    guard FileManager.default.isExecutableFile(atPath: GH) else {
        let msg = "GitHub CLI not found at \(GH)"
        log.error("\(msg)"); lastFetchError = msg
        return nil
    }
    guard let res = try? ghRun(Array(args)), res.ok else { return nil }
    let s = String(data: res.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    return s?.isEmpty == false ? s : nil
}

// ─── Repo calls ──────────────────────────────────────────────────────────────

/// The code host and CI accounts of repo owners. AppEnvironment gives the real ones.
protocol RepoAccounts: AnyObject {
    func codeHost(owner: String) -> (any CodeHost)?
    func ci(owner: String) -> (any CIProvider)?
}

/// Optional adapter features that RepoClient uses when an adapter has them.
protocol RepoAddressing: Provider { func repoRef(_ path: String) -> RepoRef }
protocol KnownJobFailures: CIProvider { func failures(_ r: RunRef, jobs: [Job]) async throws -> [Failure] }
protocol RawLogReading: CIProvider { func rawLog(_ j: JobRef) async throws -> String }

/// CI and pull request calls for repos named "owner/name". A failed list call sets lastFetchError.
struct RepoClient {
    let accounts: RepoAccounts

    private func ci(_ repo: String) throws -> any CIProvider {
        guard let c = accounts.ci(owner: repoOwner(repo)) else { throw ProviderError.unauthorized }
        return c
    }

    private func host(_ repo: String) throws -> any CodeHost {
        guard let h = accounts.codeHost(owner: repoOwner(repo)) else { throw ProviderError.unauthorized }
        return h
    }

    /// The code host of a repo, when it can delete branches.
    func branchHost(_ repo: String) -> (host: any BranchDeleting, ref: RepoRef)? {
        guard let h = (try? host(repo)) as? any BranchDeleting, h.capabilities.contains(.deleteBranch) else { return nil }
        return (h, Self.repoRef(h, repo))
    }

    static func repoRef(_ p: any Provider, _ path: String) -> RepoRef {
        (p as? any RepoAddressing)?.repoRef(path) ?? RepoRef(account: p.account, path: path, url: URL(string: "https://github.com/\(path)")!)
    }

    static func runRef(_ p: any Provider, _ path: String, id: String) -> RunRef {
        RunRef(account: p.account, repo: repoRef(p, path), id: id)
    }

    /// nil means the fetch failed, which a targeted refresh must not treat as "no runs".
    func runs(_ repo: String) async -> [Run]? {
        switch await Result(awaiting: { let c = try ci(repo); return try await c.runs(RunQuery(repo: Self.repoRef(c, repo), limit: RUNS_PER_REPO)) }) {
        case .success(let runs):
            lastFetchError = nil
            return runs
        case .failure(let e):
            log.warning("Runs of \(repo, privacy: .public) failed: \(e.message, privacy: .public)")
            lastFetchError = GitHubClient.hint(e)
            return nil
        }
    }

    func run(_ repo: String, id: String) async -> Run? {
        try? await Result(awaiting: { let c = try ci(repo); return try await c.run(Self.runRef(c, repo, id: id)) }).get()
    }

    func commitMessage(_ repo: String, sha: String) async -> String? {
        guard !sha.isEmpty else { return nil }
        return try? await Result(awaiting: { let h = try host(repo); return try await h.commitMessage(Self.repoRef(h, repo), sha: sha) }).get()
    }

    func jobs(_ repo: String, runId: String) async -> [Job]? {
        try? await Result(awaiting: { let c = try ci(repo); return try await c.jobs(Self.runRef(c, repo, id: runId)) }).get()
    }

    func failures(_ repo: String, runId: String, jobs: [Job]) async -> [Failure] {
        (try? await Result(awaiting: {
            let c = try ci(repo)
            let r = Self.runRef(c, repo, id: runId)
            if let k = c as? any KnownJobFailures { return try await k.failures(r, jobs: jobs) }
            return try await c.failures(r)
        }).get()) ?? []
    }

    /// The end of the raw job log.
    func rawLog(_ repo: String, jobId: String) async -> String? {
        try? await Result(awaiting: {
            let c = try ci(repo)
            let j = JobRef(run: Self.runRef(c, repo, id: ""), id: jobId)
            if let raw = c as? any RawLogReading { return try await raw.rawLog(j) }
            guard let l = c as? any LogReading else { throw ProviderError.unsupported(.logs) }
            return try await l.log(j, lines: 400).joined(separator: "\n")
        }).get()
    }

    /// nil on success, else the error text.
    func perform(_ a: RunAction, repo: String, id: String) async -> String? {
        if case .failure(let e) = await Result(awaiting: { let c = try ci(repo); try await c.perform(a, on: Self.runRef(c, repo, id: id)) }) {
            return GitHubClient.hint(e)
        }
        return nil
    }

    /// nil on success, else the error text.
    func rerunJob(repo: String, runId: String, jobId: String) async -> String? {
        let r = await Result(awaiting: {
            let c = try ci(repo)
            guard let jr = c as? any JobRerunning else { throw ProviderError.unsupported(.rerunJob) }
            try await jr.rerun(JobRef(run: Self.runRef(c, repo, id: runId), id: jobId))
        })
        if case .failure(let e) = r { return GitHubClient.hint(e) }
        return nil
    }

    func changes(_ repo: String) async -> [ChangeRequest] {
        switch await Result(awaiting: { let h = try host(repo); return try await h.changes(Self.repoRef(h, repo), ChangeFilter(limit: 20)) }) {
        case .success(let list):
            lastFetchError = nil
            return list
        case .failure(let e):
            log.warning("PRs of \(repo, privacy: .public) failed: \(e.message, privacy: .public)")
            lastFetchError = GitHubClient.hint(e)
            return []
        }
    }

    /// The PR tab shows lastFetchError in its error banner.
    func perform(_ action: ChangeAction, repo: String, number: Int) async {
        let r = await Result(awaiting: {
            let h = try host(repo)
            let url = Self.repoRef(h, repo).url.appendingPathComponent("pull/\(number)")
            try await h.perform(action, on: ChangeRef(repo: Self.repoRef(h, repo), number: number, url: url))
        })
        if case .failure(let e) = r {
            lastFetchError = GitHubClient.hint(e)
            log.warning("PR action \(action) for \(repo)#\(number) failed: \(e.message, privacy: .public)")
        }
    }

    /// The login of the token owner.
    func me(owner: String = "") async -> String? {
        switch await Result(awaiting: {
            guard let h = accounts.codeHost(owner: owner) else { throw ProviderError.unauthorized }
            return try await h.probe()
        }) {
        case .success(let me): return me.person.login
        case .failure(let e):
            lastFetchError = GitHubClient.hint(e)
            return nil
        }
    }
}

let REPO_CLIENT = RepoClient(accounts: ENV)

// ─── Run Detail Fetching ─────────────────────────────────────────────────────

// Lazily-fetched run detail data. Main-thread access only.
var commitMsgCache: [String: String] = [:]       // head sha → full commit message
var failureCache: [String: [Failure]] = [:]      // run id → failure summaries (stable once completed)
var jobsCache: [String: (updatedAt: String, jobs: [Job])] = [:]  // run id → jobs at that run update
var detailFetchInFlight = Set<String>()

// ─── GitHub rate limit ───────────────────────────────────────────────────────

extension RateLimit {
    var color: NSColor { fraction >= 0.9 ? C_FAILURE : fraction >= 0.7 ? C_QUEUED : .secondaryLabelColor }

    // REST and GraphQL sit side by side. The colour still follows the fuller bucket.
    var footerLabel: String {
        buckets.map { name, bucket in
            let short = name == "GraphQL" ? "GQL" : name
            return "\(short) \(Int((bucket.fraction * 100).rounded()))%"
        }.joined(separator: " · ")
    }

    var tooltip: String {
        let f = DateFormatter(); f.dateFormat = "h:mm a"
        let lines = buckets.map { n, b in
            "\(n): \(b.used) / \(b.limit) (\(Int((b.fraction * 100).rounded()))%), resets \(f.string(from: Date(timeIntervalSince1970: b.reset)))"
        }
        return (["GitHub API quota used this hour"] + lines).joined(separator: "\n")
    }
}

// Reads the quota every 10 minutes. The rate_limit endpoint does not count against it.
final class RateLimitMonitor {
    private(set) var latest: RateLimit?
    var onChange: (() -> Void)?
    private var timer: Timer?

    func start() {
        fetch()
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.fetch() }
        timer?.tolerance = 60
    }

    func fetch() {
        Task {
            guard let rl = try? await GITHUB.rateLimit() else { return }
            DispatchQueue.main.async { self.latest = rl; self.onChange?() }
        }
    }
}
