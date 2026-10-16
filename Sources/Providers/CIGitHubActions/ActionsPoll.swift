import Foundation
import OverSireCore

extension ActionsCI {
    struct Mark: Codable {
        var etag: String?
        var at: Date
        var busy: Bool?
    }

    /// The run list of each repo with its ETag. A 304 answer does not count against the quota.
    /// A new repo sets its baseline and gives no events. A run in progress makes the page busy.
    public func poll(since: Cursor?) async throws -> EventPage {
        var marks = since.flatMap { try? JSONDecoder().decode([String: Mark].self, from: Data($0.rawValue.utf8)) } ?? [:]
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
                marks[path] = Mark(etag: a.etag, at: newest ?? Date(timeIntervalSince1970: 0), busy: busy)
                continue
            }
            for r in runs {
                guard let at = parseISO(r.updatedAt), at > mark.at else { continue }
                let ref = runRef(path, id: r.id, attempt: r.attempt)
                events.append(ProviderEvent(id: "github-actions-\(path)#\(r.id)-\(ref.attempt)-\(r.status)-\(Int(at.timeIntervalSince1970))", provider: .githubActions,
                                            account: account, kind: .run, action: r.phase == .running ? "started" : r.status,
                                            subject: .run(ref), at: at,
                                            summary: EventSummary(title: r.workflowName ?? r.name, status: r.status,
                                                                  conclusion: r.conclusion, actor: r.actorLogin)))
            }
            marks[path] = Mark(etag: a.etag, at: max(mark.at, newest ?? mark.at), busy: busy)
        }
        let data = try JSONEncoder().encode(marks)
        return EventPage(events: events.sorted { $0.at < $1.at }, cursor: Cursor(rawValue: String(decoding: data, as: UTF8.self)),
                         budget: budget, busy: marks.values.contains { $0.busy == true })
    }
}
