import Foundation
import OverSireCore

/// An in-memory CI with one pipeline and one failed run in "fake/app".
public final class FakeCI: CIProvider, CommitPolling, LogReading, JobRerunning, Dispatching, GateApproving, @unchecked Sendable {
    public let base: FakeProvider
    public var id: ProviderID { base.id }
    public var account: AccountID { base.account }
    public var capabilities: Set<Capability> { base.capabilities }
    public var pollPolicy: PollPolicy { base.pollPolicy }

    public let repo: RepoRef
    private var runList: [Run] = []
    private var commitAnswers: [Result<EventPage, ProviderError>] = []
    private var _commitPolls: [(CIInterest, Cursor?)] = []
    private var logLines: [String] = (1...40).map { "line \($0)" } + ["error: the fake failed"]

    public init(account: String = "fake", capabilities: Set<Capability> = [.rerun, .rerunJob, .cancel, .logs, .dispatch, .gates, .commitPolling]) {
        base = FakeProvider(id: "fake-ci", account: account, capabilities: capabilities)
        repo = RepoRef(account: base.account, path: "fake/app", url: URL(string: "https://code.fake/fake/app")!)
        runList = [Self.run(id: "1", status: "completed", conclusion: "failure", attempt: 1)]
    }

    private var _pending: [String: [Gate]] = [:]
    private var _dispatched: [(pipeline: String, ref: String, inputs: [String: String])] = []
    private var _vendorCalls = 0

    /// The gates that wait, for each run id.
    public var pending: [String: [Gate]] {
        get { base.lockedValue { _pending } }
        set { base.lockedValue { _pending = newValue } }
    }

    public var dispatched: [(pipeline: String, ref: String, inputs: [String: String])] { base.lockedValue { _dispatched } }

    /// The count of the writes: perform, rerun, dispatch and approve.
    public var vendorCalls: Int { base.lockedValue { _vendorCalls } }

    /// Adds a run, or replaces the run with the same id.
    public func put(_ run: Run) {
        base.lockedValue {
            if let at = runList.firstIndex(where: { $0.id == run.id }) { runList[at] = run } else { runList.append(run) }
        }
    }

    public static func run(id: String, status: String, conclusion: String?, attempt: Int) -> Run {
        Run(id: id, name: "CI", displayTitle: "Add the fake", status: status, conclusion: conclusion, headBranch: "main", headSha: "abc1234",
            event: "push", url: "https://code.fake/fake/app/runs/\(id)", updatedAt: "2026-10-01T10:05:00Z",
            createdAt: "2026-10-01T10:00:00Z", startedAt: "2026-10-01T10:00:05Z", number: Int(id) ?? 0, workflowName: "CI",
            actorLogin: "me", attempt: attempt)
    }

    public func probe() async throws -> Identity { try await base.probe() }
    public func poll(since: Cursor?) async throws -> EventPage { try await base.poll(since: since) }

    public func pipelines(_ r: RepoRef) async throws -> [Pipeline] {
        try base.locked { r.path == repo.path ? [Pipeline(id: "ci", name: "CI", path: ".fake/ci.yml")] : [] }
    }

    public func runs(_ q: RunQuery) async throws -> [Run] {
        try base.locked {
            guard q.repo == nil || q.repo == repo else { return [] }
            return Array(runList.filter { q.branch == nil || $0.headBranch == q.branch }.sorted { $0.createdAt > $1.createdAt }.prefix(q.limit))
        }
    }

    public func run(_ r: RunRef) async throws -> Run {
        try base.locked {
            guard let run = runList.first(where: { $0.id == r.id }) else { throw ProviderError.notFound }
            return run
        }
    }

    public func jobs(_ r: RunRef) async throws -> [Job] {
        let run = try await run(r)
        return [Job(id: "\(run.id)-build", name: "build", status: run.status, conclusion: run.conclusion, url: run.url,
                    startedAt: run.startedAt, completedAt: run.updatedAt, runnerName: "fake", steps: nil)]
    }

    public func failures(_ r: RunRef) async throws -> [Failure] {
        let run = try await run(r)
        return run.conclusion == "failure" ? [Failure(job: "build", step: "test", messages: ["the fake failed"])] : []
    }

    public func perform(_ a: RunAction, on r: RunRef) async throws {
        let need: Capability = a == .cancel ? .cancel : .rerun
        guard capabilities.contains(need) else { throw ProviderError.unsupported(need) }
        try base.locked {
            _vendorCalls += 1
            guard let at = runList.firstIndex(where: { $0.id == r.id }) else { throw ProviderError.notFound }
            let o = runList[at]
            switch a {
            case .rerun, .rerunFailed: runList[at] = Self.run(id: o.id, status: "queued", conclusion: nil, attempt: (o.attempt ?? 1) + 1)
            case .cancel: runList[at] = Self.run(id: o.id, status: "completed", conclusion: "cancelled", attempt: o.attempt ?? 1)
            }
            base.emit(.run, a.rawValue, .run(RunRef(account: account, repo: repo, id: o.id, attempt: runList[at].attempt ?? 1)))
        }
    }

    public func rerun(_ j: JobRef) async throws {
        guard capabilities.contains(.rerunJob) else { throw ProviderError.unsupported(.rerunJob) }
        try base.locked {
            _vendorCalls += 1
            guard let at = runList.firstIndex(where: { $0.id == j.run.id }) else { throw ProviderError.notFound }
            let o = runList[at]
            runList[at] = Self.run(id: o.id, status: "queued", conclusion: nil, attempt: (o.attempt ?? 1) + 1)
            base.emit(.job, "rerun", .job(JobRef(run: RunRef(account: account, repo: repo, id: o.id, attempt: runList[at].attempt ?? 1), id: j.id)))
        }
    }

    public func dispatch(_ r: RepoRef, pipeline: String, ref: String, inputs: [String: String]) async throws -> RunRef? {
        guard capabilities.contains(.dispatch) else { throw ProviderError.unsupported(.dispatch) }
        return try base.locked {
            guard r.path == repo.path, ["ci", "ci.yml", ".fake/ci.yml"].contains(pipeline) else { throw ProviderError.notFound }
            _vendorCalls += 1
            _dispatched.append((pipeline, ref, inputs))
            let id = String(100 + _dispatched.count)
            runList.append(Self.run(id: id, status: "queued", conclusion: nil, attempt: 1))
            return RunRef(account: account, repo: repo, id: id)
        }
    }

    public func gates(_ r: RunRef) async throws -> [Gate] {
        guard capabilities.contains(.gates) else { throw ProviderError.unsupported(.gates) }
        return try base.locked {
            guard runList.contains(where: { $0.id == r.id }) else { throw ProviderError.notFound }
            return _pending[r.id] ?? []
        }
    }

    public func approve(_ r: RunRef, gates: [String], comment: String) async throws {
        guard capabilities.contains(.gates) else { throw ProviderError.unsupported(.gates) }
        try base.locked {
            guard let at = runList.firstIndex(where: { $0.id == r.id }) else { throw ProviderError.notFound }
            let waiting = _pending[r.id] ?? []
            guard !gates.isEmpty, gates.allSatisfy({ g in waiting.contains { $0.id == g } }) else {
                throw ProviderError.vendor(code: "422", message: "The gate does not wait.")
            }
            guard waiting.filter({ gates.contains($0.id) }).allSatisfy(\.canApprove) else { throw ProviderError.forbidden }
            _vendorCalls += 1
            _pending[r.id] = waiting.filter { !gates.contains($0.id) }
            let o = runList[at]
            runList[at] = Self.run(id: o.id, status: "queued", conclusion: nil, attempt: o.attempt ?? 1)
        }
    }

    /// The pages (or errors) of the next `pollCommit` calls, in order. The last one repeats. With none, a quiet 304-like page.
    public func queueCommitPages(_ answers: [Result<EventPage, ProviderError>]) { base.lockedValue { commitAnswers = answers } }

    /// The interests and cursors of the `pollCommit` calls.
    public var commitPolls: [(interest: CIInterest, since: Cursor?)] { base.lockedValue { _commitPolls } }

    public func pollCommit(_ i: CIInterest, since: Cursor?) async throws -> EventPage {
        let next: Result<EventPage, ProviderError> = base.lockedValue {
            _commitPolls.append((i, since))
            guard let first = commitAnswers.first else { return .success(EventPage(events: [], cursor: since ?? Cursor(rawValue: "0"))) }
            if commitAnswers.count > 1 { commitAnswers.removeFirst() }
            return first
        }
        return try next.get()
    }

    public func log(_ j: JobRef, lines: Int) async throws -> [String] {
        guard capabilities.contains(.logs) else { throw ProviderError.unsupported(.logs) }
        // A job ref with no run id is how the app reads a log by job id.
        if !j.run.id.isEmpty { _ = try await run(j.run) }
        return try base.locked { Array(logLines.suffix(lines)) }
    }
}
