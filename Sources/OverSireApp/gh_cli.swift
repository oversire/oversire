import Cocoa
import OverSireCore


// Find gh CLI — hardcoded trusted paths only
let GH: String = {
    let trusted = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
    for p in trusted {
        if FileManager.default.isExecutableFile(atPath: p) { return p }
    }
    return trusted[0] // Will show "gh not found" error on first fetch
}()

// Minimal env for gh CLI — PATH, HOME, LANG + gh auth/config vars
let ghEnv: [String: String] = {
    let env = ProcessInfo.processInfo.environment
    let allow = ["PATH", "HOME", "LANG", "SHELL",
                 "GH_TOKEN", "GITHUB_TOKEN", "GH_CONFIG_DIR",
                 "XDG_CONFIG_HOME", "XDG_DATA_HOME",
                 "GNUPGHOME", "SSH_AUTH_SOCK"]
    var result: [String: String] = [:]
    for key in allow { if let v = env[key] { result[key] = v } }
    if result["PATH"] == nil { result["PATH"] = "/usr/bin:/bin:/opt/homebrew/bin" }
    if result["HOME"] == nil { result["HOME"] = NSHomeDirectory() }
    return result
}()

// ─── Helpers ─────────────────────────────────────────────────────────────────

private let _fetchErrQ = DispatchQueue(label: "com.oversire.app.fetchErr")
private var _lastFetchError: String? = nil
var lastFetchError: String? {
    get { _fetchErrQ.sync { _lastFetchError } }
    set { _fetchErrQ.sync { _lastFetchError = newValue } }
}

struct GHResult {
    let status: Int32
    let out: Data
    let err: String
    var ok: Bool { status == 0 }
}

// Runs gh with optional stdin, so request bodies with secrets never appear in argv.
func ghRun(_ args: [String], input: Data? = nil, timeout: TimeInterval? = nil) throws -> GHResult {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: GH)
    proc.arguments = args
    proc.environment = ghEnv
    let outPipe = Pipe()
    let errPipe = Pipe()
    proc.standardOutput = outPipe
    proc.standardError = errPipe
    let inPipe = input.map { _ in Pipe() }
    if let p = inPipe { proc.standardInput = p } else { proc.standardInput = FileHandle.nullDevice }
    try proc.run()
    if let inPipe = inPipe, let input = input {
        inPipe.fileHandleForWriting.write(input)
        try? inPipe.fileHandleForWriting.close()
    }
    if let timeout = timeout {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
            guard proc.isRunning else { return }
            proc.terminate()
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                if proc.isRunning { kill(proc.processIdentifier, SIGKILL) }
            }
        }
    }
    // Drain both pipes BEFORE waiting: a child that fills a 64KB pipe buffer
    // would otherwise block forever inside waitUntilExit, stranding a worker
    // thread per poll while new refreshes keep stacking up.
    var errData = Data()
    let errDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        errDone.signal()
    }
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    errDone.wait()
    proc.waitUntilExit()
    let errStr = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return GHResult(status: proc.terminationStatus, out: outData, err: errStr)
}

func ghShell(_ args: String...) -> Data? {
    guard FileManager.default.isExecutableFile(atPath: GH) else {
        let msg = "GitHub CLI not found at \(GH)"
        log.error("\(msg)")
        lastFetchError = msg
        return nil
    }
    do {
        let res = try ghRun(args)
        guard res.ok else {
            let errStr = res.err
            // Public on purpose: os_log redacts interpolated strings by default,
            // which turned every one of these into "gh <private> exited 1:
            // <private>" and made a whole night of failures undiagnosable.
            // Only the first two args: "api repos/x/y/actions/runs" or "pr review"
            // is all the diagnosis needs, and it keeps a `pr review -b <body>`
            // out of a log any process on the machine can read.
            log.warning("gh \(args.prefix(2).joined(separator: " "), privacy: .public) exited \(res.status): \(errStr, privacy: .public)")
            let low = errStr.lowercased()
            // Order matters: gh's unauthenticated 403 reads "API rate limit
            // exceeded ... Authenticated requests get a higher rate limit",
            // so the auth test would swallow it if it ran first.
            if low.contains("rate limit") {
                lastFetchError = "GitHub API rate limit hit — retries resume after the reset"
            } else if low.contains("auth") || low.contains("login") || low.contains("bad credentials") {
                lastFetchError = "Not authenticated. Run: gh auth login"
            } else if low.contains("404") || low.contains("could not resolve to a repository") {
                // GitHub answers 404, not 401, for a private repo when the token
                // is expired or lost a scope — so a bare 404 is an auth problem
                // far more often than a wrong repo name. Say both. `gh pr list`
                // goes through GraphQL, which words the same case as
                // "Could not resolve to a Repository".
                lastFetchError = "No access — run: gh auth login (or check the repo name)"
            } else if !errStr.isEmpty {
                lastFetchError = String(errStr.prefix(120))
            }
            return nil
        }
        lastFetchError = nil
        return res.out
    } catch {
        log.error("Failed to launch gh: \(error.localizedDescription)")
        lastFetchError = "Failed to run gh: \(error.localizedDescription)"
        return nil
    }
}

func ghStr(_ args: String...) -> String? {
    guard FileManager.default.isExecutableFile(atPath: GH) else {
        let msg = "GitHub CLI not found at \(GH)"
        log.error("\(msg)"); lastFetchError = msg
        return nil
    }
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: GH)
    proc.arguments = Array(args)
    proc.environment = ghEnv
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = FileHandle.nullDevice
    do {
        try proc.run()
        // Read to EOF before waiting so large outputs can't deadlock the pipe.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        let s = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s?.isEmpty == false ? s : nil
    } catch { return nil }
}

let RUN_JQ = "{id, name, displayTitle: .display_title, status, conclusion, headBranch: .head_branch, headSha: .head_sha, event, url: .html_url, updatedAt: .updated_at, createdAt: .created_at, startedAt: .run_started_at, number: .run_number, workflowName: .name, actorLogin: .actor.login, attempt: .run_attempt}"

// nil means the fetch failed, which a targeted refresh must not treat as "no runs".
func fetchRuns(repo: String) -> [Run]? {
    guard let data = ghShell("api", "repos/\(repo)/actions/runs?per_page=\(RUNS_PER_REPO)", "--jq", "[.workflow_runs[] | \(RUN_JQ)]")
    else { return nil }
    return (try? JSONDecoder().decode([Run].self, from: data)) ?? []
}

func fetchRun(repo: String, id: String) -> Run? {
    guard let data = ghShell("api", "repos/\(repo)/actions/runs/\(id)", "--jq", RUN_JQ) else { return nil }
    return try? JSONDecoder().decode(Run.self, from: data)
}

// ─── Run Detail Fetching ─────────────────────────────────────────────────────

// Lazily-fetched run detail data. Main-thread access only.
var commitMsgCache: [String: String] = [:]       // head sha → full commit message
var failureCache: [String: [Failure]] = [:]      // run id → failure summaries (stable once completed)
var jobsCache: [String: (updatedAt: String, jobs: [Job])] = [:]  // run id → jobs at that run update
var detailFetchInFlight = Set<String>()

func fetchCommitMessage(repo: String, sha: String) -> String? {
    guard !sha.isEmpty,
          let data = ghShell("api", "repos/\(repo)/commits/\(sha)", "--jq", ".commit.message"),
          let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !s.isEmpty else { return nil }
    return s
}

func fetchRunJobs(repo: String, runId: String) -> [Job]? {
    let step = "{name, status, conclusion, startedAt: .started_at, completedAt: .completed_at}"
    let jq = "[.jobs[] | {id, name, status, conclusion, url: .html_url, startedAt: .started_at, " +
        "completedAt: .completed_at, runnerName: .runner_name, steps: [.steps[]? | \(step)]}]"
    guard let data = ghShell("api", "repos/\(repo)/actions/runs/\(runId)/jobs?per_page=100", "--jq", jq) else { return nil }
    return try? JSONDecoder().decode([Job].self, from: data)
}

// The failure message GitHub shows in its annotations box: for each failed job, pull its
// check-run annotations (a job's id IS its check-run id) plus the name of the step that failed.
func fetchRunFailures(repo: String, jobs: [Job]) -> [Failure] {
    var out: [Failure] = []
    for job in jobs where job.conclusion == "failure" {
        if out.count >= 3 { break }
        let step = job.steps?.first(where: { $0.conclusion == "failure" })?.name
        var msgs: [String] = []
        let ajq = "[.[] | {message, path, startLine: .start_line, annotationLevel: .annotation_level}]"
        if let aData = ghShell("api", "repos/\(repo)/check-runs/\(job.id)/annotations", "--jq", ajq),
           let anns = try? JSONDecoder().decode([CheckAnnotation].self, from: aData) {
            for a in anns where a.annotationLevel == "failure" {
                guard var m = a.message?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { continue }
                if m.count > 400 { m = String(m.prefix(400)) + "\u{2026}" }
                if let p = a.path, !p.isEmpty, p != ".github", let ln = a.startLine {
                    m = "\(p):\(ln)\n\(m)"
                }
                msgs.append(m)
                if msgs.count >= 3 { break }
            }
        }
        out.append(Failure(job: job.name, step: step, messages: msgs))
    }
    return out
}

func fetchPRs(repo: String) -> [ChangeRequest] {
    let fields = "number,title,state,author,headRefName,baseRefName,url,createdAt,updatedAt,reviewDecision,additions,deletions,isDraft,labels,body"
    func list(_ search: String) -> [ChangeRequest] {
        guard let data = ghShell("pr", "list", "--repo", repo, "--limit", "20", "--state", "open",
                                 "--search", search, "--json", fields) else { return [] }
        return (try? JSONDecoder().decode([ChangeRequest].self, from: data)) ?? []
    }
    // Own PRs link runs to items. Review requests are the PRs tab.
    var out = list("review-requested:@me")
    for var p in list("author:@me") where !out.contains(where: { $0.number == p.number }) {
        p.mine = true
        out.append(p)
    }
    return out
}

func executePRAction(repo: String, number: Int, action: ChangeAction, completion: @escaping () -> Void) {
    DispatchQueue.global(qos: .userInitiated).async {
        let n = "\(number)", r = repo
        var ok = true
        switch action {
        case .approve(let body):
            if let b = body, !b.isEmpty {
                ok = ghShell("pr", "review", "--approve", "-b", b, "-R", r, n) != nil
            } else {
                ok = ghShell("pr", "review", "--approve", "-R", r, n) != nil
            }
        case .requestChanges(let body):
            ok = ghShell("pr", "review", "--request-changes", "-b", body, "-R", r, n) != nil
        case .comment(let body):
            ok = ghShell("pr", "comment", "-b", body, "-R", r, n) != nil
        case .merge(let method):
            ok = ghShell("pr", "merge", method.ghFlag, "-R", r, n) != nil
        case .close:
            ok = ghShell("pr", "close", "-R", r, n) != nil
        }
        // ghShell sets lastFetchError on failure; surface it via the PR tab's error banner.
        if !ok {
            log.warning("PR action \(action) for \(r)#\(number) failed: \(lastFetchError ?? "unknown")")
        }
        DispatchQueue.main.async { completion() }
    }
}


func getGHUser() -> String? { ghStr("api", "user", "--jq", ".login") }

// ─── GitHub rate limit ───────────────────────────────────────────────────────

struct RateLimit: Decodable {
    struct Bucket: Decodable {
        let limit: Int, used: Int, reset: TimeInterval
        var fraction: Double { limit > 0 ? Double(used) / Double(limit) : 0 }
    }
    let resources: [String: Bucket]

    // Runs use REST and PRs use GraphQL. Show the bucket nearest its limit.
    var buckets: [(name: String, bucket: Bucket)] {
        [("REST", resources["core"]), ("GraphQL", resources["graphql"])].compactMap { n, b in b.map { (n, $0) } }
    }
    var fraction: Double { buckets.map { $0.bucket.fraction }.max() ?? 0 }
    var percent: Int { Int((fraction * 100).rounded()) }
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
            guard let r = try? ghRun(["api", "rate_limit"]), r.status == 0,
                  let rl = try? JSONDecoder().decode(RateLimit.self, from: r.out) else { return }
            DispatchQueue.main.async { self.latest = rl; self.onChange?() }
        }
    }
}


extension MergeMethod {
    var ghFlag: String {
        switch self {
        case .merge: return "-m"
        case .rebase: return "-r"
        case .squash: return "-s"
        }
    }
}
