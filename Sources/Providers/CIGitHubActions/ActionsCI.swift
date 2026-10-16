import Foundation
import GitHubKit
import OverSireCore

/// The GitHub Actions runs of one owner. `repos` limits the poll.
public final class ActionsCI: CIProvider, LogReading, RateReporting, @unchecked Sendable {
    public static let tailBytes = 16_000
    public static let snippetLines = 15

    public let id: ProviderID = .githubActions
    public let account: AccountID
    public let repoPaths: [String]
    public var capabilities: Set<Capability> { [.rerun, .cancel, .logs, .annotations, .webhooks] }
    public var pollPolicy: PollPolicy { PollPolicy(minInterval: .seconds(10), requestsPerHour: 5000) }

    let client: GitHubClient

    public init(owner: String, repos: [String] = [], client: GitHubClient) {
        account = AccountID(provider: .githubActions, id: owner)
        repoPaths = repos
        self.client = client
    }

    public func repoRef(_ path: String) -> RepoRef {
        RepoRef(account: account, path: path, url: URL(string: "https://github.com/\(path)")!)
    }

    public func runRef(_ path: String, id: String, attempt: Int? = nil) -> RunRef {
        RunRef(account: account, repo: repoRef(path), id: id, attempt: attempt ?? 1)
    }

    public func probe() async throws -> Identity {
        guard let o = try await client.json("GET", "user") as? [String: Any], let login = o["login"] as? String else {
            throw ProviderError.decoding("no user in the answer")
        }
        let id = (o["id"] as? NSNumber)?.stringValue ?? login
        return Identity(person: PersonRef(id: id, name: (o["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? login, login: login))
    }

    public func budget() async throws -> RateBudget {
        guard let b = try await client.rateLimit().budget else { throw ProviderError.decoding("no rate limit buckets") }
        return b
    }

    // MARK: CIProvider

    public func pipelines(_ r: RepoRef) async throws -> [Pipeline] {
        let o = try await client.json("GET", "repos/\(r.path)/actions/workflows?per_page=100") as? [String: Any]
        return (o?["workflows"] as? [[String: Any]] ?? []).compactMap { w in
            guard let id = w["id"] as? NSNumber, let name = w["name"] as? String else { return nil }
            return Pipeline(id: id.stringValue, name: name, path: w["path"] as? String ?? "")
        }
    }

    /// Without a repo, the runs of all repos of the account.
    public func runs(_ q: RunQuery) async throws -> [Run] {
        let paths = q.repo.map { [$0.path] } ?? repoPaths
        var out: [Run] = []
        for path in paths {
            var url = "repos/\(path)/actions/" + (q.pipeline.map { "workflows/\($0)/" } ?? "") + "runs?per_page=\(min(100, max(1, q.limit)))"
            if let b = q.branch?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { url += "&branch=\(b)" }
            let o = try await client.json("GET", url) as? [String: Any]
            out += (o?["workflow_runs"] as? [[String: Any]] ?? []).compactMap(Self.run)
        }
        return paths.count > 1 ? Array(out.sorted { $0.createdAt > $1.createdAt }.prefix(q.limit)) : out
    }

    public func run(_ r: RunRef) async throws -> Run {
        let o = try await client.json("GET", "repos/\(try path(r))/actions/runs/\(r.id)") as? [String: Any]
        guard let run = o.flatMap(Self.run) else { throw ProviderError.decoding("no run \(r.id)") }
        return run
    }

    public func jobs(_ r: RunRef) async throws -> [Job] {
        let o = try await client.json("GET", "repos/\(try path(r))/actions/runs/\(r.id)/jobs?per_page=100") as? [String: Any]
        return (o?["jobs"] as? [[String: Any]] ?? []).compactMap(Self.job)
    }

    public func failures(_ r: RunRef) async throws -> [Failure] {
        try await failures(r, jobs: jobs(r))
    }

    /// The text of the GitHub annotations box: the failed step and the failure annotations of each failed job.
    /// A job id is also its check-run id. At most 3 jobs, and 3 messages for each.
    public func failures(_ r: RunRef, jobs: [Job]) async throws -> [Failure] {
        let repo = try path(r)
        var out: [Failure] = []
        for job in jobs.filter({ $0.conclusion == "failure" }).prefix(3) {
            let step = job.steps?.first { $0.conclusion == "failure" }?.name
            let anns = (try? await client.json("GET", "repos/\(repo)/check-runs/\(job.id)/annotations")) as? [[String: Any]] ?? []
            out.append(Failure(job: job.name, step: step, messages: Self.messages(anns)))
        }
        return out
    }

    static func messages(_ anns: [[String: Any]]) -> [String] {
        var msgs: [String] = []
        for a in anns where a["annotation_level"] as? String == "failure" {
            guard var m = (a["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else { continue }
            if m.count > 400 { m = String(m.prefix(400)) + "\u{2026}" }
            if let p = a["path"] as? String, !p.isEmpty, p != ".github", let ln = a["start_line"] as? Int { m = "\(p):\(ln)\n\(m)" }
            msgs.append(m)
            if msgs.count >= 3 { break }
        }
        return msgs
    }

    public func perform(_ a: RunAction, on r: RunRef) async throws {
        let (method, path) = try Self.request(a, on: r)
        _ = try await client.api(method, path)
    }

    static func request(_ a: RunAction, on r: RunRef) throws -> (method: String, path: String) {
        guard let repo = r.repo?.path else { throw ProviderError.notFound }
        let verb = switch a {
        case .rerun: "rerun"
        case .rerunFailed: "rerun-failed-jobs"
        case .cancel: "cancel"
        }
        return ("POST", "repos/\(repo)/actions/runs/\(r.id)/\(verb)")
    }

    // MARK: LogReading

    /// GitHub gives the log only after the job ends.
    public func log(_ j: JobRef, lines: Int) async throws -> [String] {
        Array(Self.clean(try await rawLog(j)).suffix(lines))
    }

    /// The end of the raw log, about `tailBytes` long.
    public func rawLog(_ j: JobRef) async throws -> String {
        try await client.tail("repos/\(try path(j.run))/actions/jobs/\(j.id)/logs", bytes: Self.tailBytes)
    }

    /// The lines up to the last "##[error]" marker, or the last lines when there is no marker.
    public static func errorSnippet(_ log: String) -> String {
        let lines = clean(log)
        let end = lines.lastIndex { $0.hasPrefix("##[error]") }.map { $0 + 1 } ?? lines.count
        return lines[max(0, end - snippetLines)..<end].joined(separator: "\n")
    }

    /// Log lines without time stamps, color codes, group markers and empty lines.
    public static func clean(_ log: String) -> [String] {
        let stamp = try! NSRegularExpression(pattern: #"^\d{4}-\d\d-\d\dT[\d:.]+Z ?|\u001B?\[[0-9;]*m"#)
        return log.components(separatedBy: "\n").compactMap { raw in
            let ns = raw.trimmingCharacters(in: .newlines) as NSString
            var l = stamp.stringByReplacingMatches(in: ns as String, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            if l.hasPrefix("##[group]") || l.hasPrefix("##[endgroup]") || l.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            if l.count > 220 { l = String(l.prefix(220)) + "\u{2026}" }
            return l
        }
    }

    public static func isError(_ line: String) -> Bool {
        if line.hasPrefix("##[error]") { return true }
        let l = line.lowercased()
        return l.contains("error:") || l.hasPrefix("fail") || l.contains("--- fail") || l.contains("panic:") || l.contains("exit code 1")
    }

    // MARK: Mapping

    func path(_ r: RunRef) throws -> String {
        guard let p = r.repo?.path else { throw ProviderError.notFound }
        return p
    }

    static func run(_ o: [String: Any]) -> Run? {
        guard let id = o["id"] as? NSNumber, let status = o["status"] as? String else { return nil }
        let name = o["name"] as? String ?? ""
        return Run(id: id.stringValue, name: name, displayTitle: o["display_title"] as? String ?? name, status: status,
                   conclusion: o["conclusion"] as? String, headBranch: o["head_branch"] as? String ?? "",
                   headSha: o["head_sha"] as? String ?? "", event: o["event"] as? String ?? "", url: o["html_url"] as? String ?? "",
                   updatedAt: o["updated_at"] as? String ?? "", createdAt: o["created_at"] as? String ?? "",
                   startedAt: o["run_started_at"] as? String, number: o["run_number"] as? Int ?? 0,
                   workflowName: o["name"] as? String, actorLogin: (o["actor"] as? [String: Any])?["login"] as? String,
                   attempt: o["run_attempt"] as? Int)
    }

    static func job(_ o: [String: Any]) -> Job? {
        guard let id = o["id"] as? NSNumber, let name = o["name"] as? String else { return nil }
        let steps = (o["steps"] as? [[String: Any]] ?? []).compactMap { s in
            (s["name"] as? String).map {
                Step(name: $0, status: s["status"] as? String, conclusion: s["conclusion"] as? String,
                     startedAt: s["started_at"] as? String, completedAt: s["completed_at"] as? String)
            }
        }
        return Job(id: id.stringValue, name: name, status: o["status"] as? String, conclusion: o["conclusion"] as? String,
                   url: o["html_url"] as? String, startedAt: o["started_at"] as? String, completedAt: o["completed_at"] as? String,
                   runnerName: o["runner_name"] as? String, steps: steps)
    }
}
