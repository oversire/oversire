import Cocoa
import GitHubKit
import CodeHostGitHub
import CIGitHubActions
import OverSireCore


// The gh CLI and the shared GitHub client. GitHub adapters get GITHUB.
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

/// The Actions adapter for one repo. The owner is the first part of the path.
func actions(_ repo: String) -> ActionsCI { ActionsCI(owner: repoOwner(repo), client: GITHUB) }

// nil means the fetch failed, which a targeted refresh must not treat as "no runs".
func fetchRuns(repo: String) -> [Run]? {
    let ci = actions(repo)
    switch Result(blocking: { try await ci.runs(RunQuery(repo: ci.repoRef(repo), limit: RUNS_PER_REPO)) }) {
    case .success(let runs):
        lastFetchError = nil
        return runs
    case .failure(let e):
        log.warning("Runs of \(repo, privacy: .public) failed: \(e.message, privacy: .public)")
        lastFetchError = GitHubClient.hint(e)
        return nil
    }
}

func fetchRun(repo: String, id: String) -> Run? {
    let ci = actions(repo)
    return try? Result(blocking: { try await ci.run(ci.runRef(repo, id: id)) }).get()
}

// ─── Run Detail Fetching ─────────────────────────────────────────────────────

// Lazily-fetched run detail data. Main-thread access only.
var commitMsgCache: [String: String] = [:]       // head sha → full commit message
var failureCache: [String: [Failure]] = [:]      // run id → failure summaries (stable once completed)
var jobsCache: [String: (updatedAt: String, jobs: [Job])] = [:]  // run id → jobs at that run update
var detailFetchInFlight = Set<String>()

func fetchCommitMessage(repo: String, sha: String) -> String? {
    guard !sha.isEmpty else { return nil }
    let host = GitHubCodeHost(owner: repoOwner(repo), client: GITHUB)
    return try? Result(blocking: { try await host.commitMessage(host.repoRef(repo), sha: sha) }).get()
}

func fetchRunJobs(repo: String, runId: String) -> [Job]? {
    let ci = actions(repo)
    return try? Result(blocking: { try await ci.jobs(ci.runRef(repo, id: runId)) }).get()
}

func fetchRunFailures(repo: String, runId: String, jobs: [Job]) -> [Failure] {
    let ci = actions(repo)
    return (try? Result(blocking: { try await ci.failures(ci.runRef(repo, id: runId), jobs: jobs) }).get()) ?? []
}

/// nil on success, else the error text.
func runAction(_ a: RunAction, repo: String, id: String) -> String? {
    let ci = actions(repo)
    if case .failure(let e) = Result(blocking: { try await ci.perform(a, on: ci.runRef(repo, id: id)) }) { return GitHubClient.hint(e) }
    return nil
}

// Sets lastFetchError on a failure.
func fetchPRs(repo: String) -> [ChangeRequest] {
    let host = GitHubCodeHost(owner: repoOwner(repo), client: GITHUB)
    switch Result(blocking: { try await host.changes(host.repoRef(repo), ChangeFilter(limit: 20)) }) {
    case .success(let list):
        lastFetchError = nil
        return list
    case .failure(let e):
        log.warning("PRs of \(repo, privacy: .public) failed: \(e.message, privacy: .public)")
        lastFetchError = GitHubClient.hint(e)
        return []
    }
}

func executePRAction(repo: String, number: Int, action: ChangeAction, completion: @escaping () -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let host = GitHubCodeHost(owner: repoOwner(repo), client: GITHUB)
        let ref = ChangeRef(repo: host.repoRef(repo), number: number, url: URL(string: "https://github.com/\(repo)/pull/\(number)")!)
        // The PR tab shows lastFetchError in its error banner.
        if case .failure(let e) = Result(blocking: { try await host.perform(action, on: ref) }) {
            lastFetchError = GitHubClient.hint(e)
            log.warning("PR action \(action) for \(repo)#\(number) failed: \(e.message, privacy: .public)")
        }
        DispatchQueue.main.async { completion() }
    }
}

func getGHUser() -> String? {
    let host = GitHubCodeHost(owner: "", client: GITHUB)
    switch Result(blocking: { try await host.probe() }) {
    case .success(let me): return me.person.login
    case .failure(let e):
        lastFetchError = GitHubClient.hint(e)
        return nil
    }
}

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
        DispatchQueue.global(qos: .utility).async {
            guard let rl = try? Result(blocking: { try await GITHUB.rateLimit() }).get() else { return }
            DispatchQueue.main.async { self.latest = rl; self.onChange?() }
        }
    }
}
