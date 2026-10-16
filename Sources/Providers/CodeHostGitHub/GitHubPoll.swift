import Foundation
import OverSireCore

extension GitHubCodeHost {
    struct Mark: Codable {
        var etag: String?
        var at: Date
    }

    /// The PR list of each repo with its ETag. A 304 answer does not count against the quota.
    /// A new repo sets its baseline and gives no events.
    public func poll(since: Cursor?) async throws -> EventPage {
        var marks = since.flatMap { try? JSONDecoder().decode([String: Mark].self, from: Data($0.rawValue.utf8)) } ?? [:]
        var events: [ProviderEvent] = []
        var budget: RateBudget?
        for path in repoPaths {
            let a = try await client.api("GET", "repos/\(path)/pulls?state=all&sort=updated&direction=desc&per_page=30",
                                         etag: marks[path]?.etag)
            budget = a.budget ?? budget
            if a.status == 304 { continue }
            let rows = (try? JSONSerialization.jsonObject(with: a.body)) as? [[String: Any]] ?? []
            let newest = rows.compactMap { parseISO($0["updated_at"] as? String) }.max()
            guard let mark = marks[path] else {
                marks[path] = Mark(etag: a.etag, at: newest ?? Date(timeIntervalSince1970: 0))
                continue
            }
            let repo = repoRef(path)
            for r in rows {
                guard let n = r["number"] as? Int, let at = parseISO(r["updated_at"] as? String), at > mark.at,
                      let url = (r["html_url"] as? String).flatMap(URL.init(string:)) else { continue }
                let action = Self.action(r, at: at)
                events.append(ProviderEvent(id: "github-\(path)#\(n)-\(action)-\(Int(at.timeIntervalSince1970))", provider: .github,
                                            account: account, kind: .change, action: action,
                                            subject: .change(ChangeRef(repo: repo, number: n, url: url)), at: at,
                                            summary: EventSummary(title: r["title"] as? String, status: r["state"] as? String,
                                                                  actor: (r["user"] as? [String: Any])?["login"] as? String)))
            }
            marks[path] = Mark(etag: a.etag, at: max(mark.at, newest ?? mark.at))
        }
        let data = try JSONEncoder().encode(marks)
        // Near the limit, wait for the reset.
        let wait = budget.flatMap { $0.remaining < $0.limit / 10 ? Duration.seconds(max(0, $0.resetAt.timeIntervalSinceNow)) : nil }
        return EventPage(events: events.sorted { $0.at < $1.at }, cursor: Cursor(rawValue: String(decoding: data, as: UTF8.self)),
                         retryAfter: wait)
    }

    static func action(_ r: [String: Any], at: Date) -> String {
        if r["merged_at"] is String { return "merged" }
        if r["state"] as? String == "closed" { return "closed" }
        if let c = parseISO(r["created_at"] as? String), abs(c.timeIntervalSince(at)) < 1 { return "opened" }
        return "updated"
    }
}
