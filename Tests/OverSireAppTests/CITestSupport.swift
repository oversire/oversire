import Foundation
import OverSireCore
@testable import OverSireApp

/// A CI reader with canned answers. It counts the calls.
final class FakeCIReader: CIDetailReading, @unchecked Sendable {
    private let lock = NSLock()
    private var _jobs: [String: [Job]] = [:]
    private var _failures: [String: [Failure]] = [:]
    private var _logs: [String: String] = [:]
    private var _checks: [String: [CICheck]] = [:]
    private var _counts: [String: Int] = [:]
    /// Pause in each `jobs` call, in nanoseconds.
    var jobsDelay: UInt64 = 0

    func setJobs(_ repo: String, run: String, _ jobs: [Job]) { lock.withLock { _jobs["\(repo)/\(run)"] = jobs } }
    func setFailures(_ repo: String, run: String, _ f: [Failure]) { lock.withLock { _failures["\(repo)/\(run)"] = f } }
    func setLog(_ job: String, _ text: String) { lock.withLock { _logs[job] = text } }
    func setChecks(_ repo: String, sha: String, _ c: [CICheck]) { lock.withLock { _checks["\(repo)/\(sha)"] = c } }
    func count(_ name: String) -> Int { lock.withLock { _counts[name] ?? 0 } }
    private func hit(_ name: String) { lock.withLock { _counts[name, default: 0] += 1 } }

    func jobs(_ repo: String, runId: String) async -> [Job]? {
        hit("jobs")
        if jobsDelay > 0 { try? await Task.sleep(nanoseconds: jobsDelay) }
        return lock.withLock { _jobs["\(repo)/\(runId)"] }
    }

    func failures(_ repo: String, runId: String, jobs: [Job]) async -> [Failure] {
        hit("failures")
        return lock.withLock { _failures["\(repo)/\(runId)"] ?? [] }
    }

    func rawLog(_ repo: String, jobId: String) async -> String? {
        hit("log")
        return lock.withLock { _logs[jobId] }
    }

    func checks(_ repo: String, sha: String) async -> [CICheck]? {
        hit("checks")
        return lock.withLock { _checks["\(repo)/\(sha)"] }
    }
}

enum CITestQuota {
    static let now = parseISO("2026-11-21T12:00:00Z")!

    /// A quota with `remaining` of 5000 calls left, or no budget when nil.
    @MainActor
    static func make(remaining: Int? = nil, live: @escaping () -> Bool = { false }, meter: RateMeter = RateMeter()) -> CIQuota {
        if let remaining { meter.record(RateBudget(limit: 5000, remaining: remaining, resetAt: now.addingTimeInterval(3600)), key: "gh") }
        return CIQuota(meter: meter, monitor: RateLimitMonitor(), live: live, clock: { now })
    }
}

extension Job {
    static func sample(_ id: String, name: String = "build", status: String = "completed", conclusion: String? = "success") -> Job {
        Job(id: id, name: name, status: status, conclusion: conclusion, url: "https://github.com/o/r/actions/runs/1/job/\(id)",
            startedAt: nil, completedAt: nil, runnerName: nil, steps: nil)
    }
}

extension Run {
    /// A run with the time stamp `updated` and an attempt.
    static func ci(_ id: Int, status: String = "completed", conclusion: String? = "success", updated: String = "2026-11-15T10:00:00Z", attempt: Int? = nil, sha: String? = nil) -> Run {
        var r = Run(id: "\(id)", name: "CI", displayTitle: "Run \(id)", status: status, conclusion: conclusion, headBranch: "main", headSha: sha ?? "abc\(id)",
                    event: "push", url: "https://github.com/o/r/actions/runs/\(id)", updatedAt: updated, createdAt: updated, startedAt: updated,
                    number: id, workflowName: "CI", actorLogin: nil)
        r.attempt = attempt
        return r
    }
}

/// Waits until `cond` is true, for at most two seconds.
@MainActor
func settle(_ cond: @MainActor () -> Bool) async {
    for _ in 0..<200 where !cond() { try? await Task.sleep(nanoseconds: 10_000_000) }
}
