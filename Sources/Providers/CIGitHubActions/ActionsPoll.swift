import Foundation
import GitHubKit
import OverSireCore

extension ActionsCI {
    /// The run list of each repo with its ETag. A 304 answer does not count against the quota.
    /// A new repo sets its baseline and gives no events. A run in progress makes the page busy.
    public func poll(since: Cursor?) async throws -> EventPage {
        var marks = since?.decoded(as: [String: ETagMark].self) ?? [:]
        var events: [ProviderEvent] = []
        var budget: RateBudget?
        for path in repoPaths {
            let a = try await client.api("GET", "repos/\(path)/actions/runs?per_page=20", etag: marks[path]?.etag)
            budget = a.budget ?? budget
            if a.status == 304 { continue }
            let o = (try? JSONSerialization.jsonObject(with: a.body)) as? [String: Any]
            let runs = (o?["workflow_runs"] as? [[String: Any]] ?? []).compactMap(Self.run)
            let newest = runs.compactMap { parseISO($0.updatedAt) }.max()
            let busy = runs.contains { $0.phase != .completed }
            guard let mark = marks[path] else {
                marks[path] = ETagMark(etag: a.etag, at: newest ?? Date(timeIntervalSince1970: 0), busy: busy)
                continue
            }
            events += runEvents(runs, path: path, after: mark.at)
            marks[path] = ETagMark(etag: a.etag, at: max(mark.at, newest ?? mark.at), busy: busy)
        }
        return EventPage(events: events.sorted { $0.at < $1.at }, cursor: try Cursor(encoding: marks),
                         budget: budget, busy: marks.values.contains { $0.busy == true })
    }

    func runEvents(_ runs: [Run], path: String, after: Date) -> [ProviderEvent] {
        runs.compactMap { r in
            guard let at = parseISO(r.updatedAt), at > after else { return nil }
            let ref = runRef(path, id: r.id, attempt: r.attempt)
            return ProviderEvent(id: "github-actions-\(path)#\(r.id)-\(ref.attempt)-\(r.status)-\(Int(at.timeIntervalSince1970))", provider: .githubActions,
                                 account: account, kind: .run, action: r.phase == .running ? "started" : r.status,
                                 subject: .run(ref), at: at,
                                 summary: EventSummary(title: r.workflowName ?? r.name, status: r.status,
                                                       conclusion: r.conclusion, actor: r.actorLogin))
        }
    }
}

extension ActionsCI {
    /// The runs of one commit (or the newest runs of a branch), with the ETag in the cursor.
    /// A 304 answer gives no events, the same cursor and the budget. The first poll gives the events of all listed runs.
    public func pollCommit(_ i: CIInterest, since: Cursor?) async throws -> EventPage {
        let mark = since?.decoded(as: ETagMark.self)
        let query: String
        if let sha = i.sha { query = "head_sha=\(sha)&per_page=20" }
        else if let b = i.branch?.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { query = "branch=\(b)&per_page=5" }
        else { throw ProviderError.notFound }
        let a = try await client.api("GET", "repos/\(i.repo)/actions/runs?\(query)", etag: mark?.etag)
        let cursor = try since ?? Cursor(encoding: ETagMark(etag: nil, at: Date(timeIntervalSince1970: 0)))
        if a.status == 304 { return EventPage(events: [], cursor: cursor, budget: a.budget, busy: mark?.busy ?? false) }
        let o = (try? JSONSerialization.jsonObject(with: a.body)) as? [String: Any]
        let runs = (o?["workflow_runs"] as? [[String: Any]] ?? []).compactMap(Self.run)
        let newest = runs.compactMap { parseISO($0.updatedAt) }.max()
        let busy = runs.contains { $0.phase != .completed }
        let after = mark?.at ?? Date(timeIntervalSince1970: 0)
        let next = ETagMark(etag: a.etag, at: max(after, newest ?? after), busy: busy)
        return EventPage(events: runEvents(runs, path: i.repo, after: after).sorted { $0.at < $1.at },
                         cursor: try Cursor(encoding: next), budget: a.budget, busy: busy)
    }
}
