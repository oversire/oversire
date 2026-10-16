import Foundation
import OverSireCore

/// An in-memory CI with one pipeline and one failed run in "fake/app".
public final class FakeCI: CIProvider, LogReading, @unchecked Sendable {
    public let base: FakeProvider
    public var id: ProviderID { base.id }
    public var account: AccountID { base.account }
    public var capabilities: Set<Capability> { base.capabilities }
    public var pollPolicy: PollPolicy { base.pollPolicy }

    public let repo: RepoRef
    private var runList: [Run] = []
    private var logLines: [String] = (1...40).map { "line \($0)" } + ["error: the fake failed"]

    public init(account: String = "fake", capabilities: Set<Capability> = [.rerun, .cancel, .logs]) {
        base = FakeProvider(id: "fake-ci", account: account, capabilities: capabilities)
        repo = RepoRef(account: base.account, path: "fake/app", url: URL(string: "https://code.fake/fake/app")!)
        runList = [Self.run(id: "1", status: "completed", conclusion: "failure", attempt: 1)]
    }

    static func run(id: String, status: String, conclusion: String?, attempt: Int) -> Run {
        Run(id: id, name: "CI", displayTitle: "Add the fake", status: status, conclusion: conclusion, headBranch: "main", headSha: "abc1234",
            event: "push", url: "https://code.fake/fake/app/runs/\(id)", updatedAt: "2026-10-01T10:05:00Z",
            createdAt: "2026-10-01T10:00:00Z", startedAt: "2026-10-01T10:00:05Z", number: Int(id) ?? 0, workflowName: "CI",
            actorLogin: "me", attempt: attempt)
    }

    public func probe() async throws -> Identity { try await base.probe() }
    public func poll(since: Cursor?) async throws -> EventPage { try await base.poll(since: since) }

    public func pipelines(_ r: RepoRef) async throws -> [Pipeline] {
        try base.locked { r == repo ? [Pipeline(id: "ci", name: "CI", path: ".fake/ci.yml")] : [] }
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
            guard let at = runList.firstIndex(where: { $0.id == r.id }) else { throw ProviderError.notFound }
            let o = runList[at]
            switch a {
            case .rerun, .rerunFailed: runList[at] = Self.run(id: o.id, status: "queued", conclusion: nil, attempt: (o.attempt ?? 1) + 1)
            case .cancel: runList[at] = Self.run(id: o.id, status: "completed", conclusion: "cancelled", attempt: o.attempt ?? 1)
            }
            base.emit(.run, a.rawValue, .run(RunRef(account: account, repo: repo, id: o.id, attempt: runList[at].attempt ?? 1)))
        }
    }

    public func log(_ j: JobRef, lines: Int) async throws -> [String] {
        guard capabilities.contains(.logs) else { throw ProviderError.unsupported(.logs) }
        _ = try await run(j.run)
        return try base.locked { Array(logLines.suffix(lines)) }
    }
}
