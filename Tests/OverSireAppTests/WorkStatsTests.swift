import OverSireCore
import XCTest
@testable import OverSireApp

final class WorkStatsTests: XCTestCase {
    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }()
    // Tuesday 2026-10-20 10:00 UTC. The week starts on Monday 2026-10-19.
    private let now = parseISO("2026-10-20T10:00:00Z")!

    private func run(_ conclusion: String?, at: String, status: String = "completed") -> Run {
        Run(id: at, name: "ci", displayTitle: "", status: status, conclusion: conclusion, headBranch: "main", headSha: "", event: "push",
            url: "", updatedAt: at, createdAt: at, startedAt: at, number: 1, workflowName: "ci", actorLogin: nil)
    }

    private func pr(mine: Bool, draft: Bool = false, created: String) -> ChangeRequest {
        ChangeRequest(number: 1, title: "", state: "OPEN", author: .init(login: "a"), headRefName: "", baseRefName: "main", url: "",
                      createdAt: created, updatedAt: created, reviewDecision: nil, additions: 0, deletions: 0, isDraft: draft,
                      labels: [], body: nil, mine: mine)
    }

    private func closed(_ item: String, at: String, change: ItemChange = .closed) -> ActivityEntry {
        ActivityEntry(id: item + at, projectKey: "p", itemId: item, change: change, actor: nil, text: "", url: "", at: parseISO(at)!, unread: false)
    }

    func testWeekStartsOnTheFirstWeekday() {
        let w = WorkStats.week(now, calendar: cal)
        XCTAssertEqual(w.count, 7)
        XCTAssertEqual(w.first, parseISO("2026-10-19T00:00:00Z"))
        XCTAssertEqual(w.last, parseISO("2026-10-25T00:00:00Z"))
        var sunday = cal
        sunday.firstWeekday = 1
        XCTAssertEqual(WorkStats.week(now, calendar: sunday).first, parseISO("2026-10-18T00:00:00Z"))
    }

    func testPerDayUsesTheDayBoundaries() {
        let dates = ["2026-10-18T23:59:59Z", "2026-10-19T00:00:00Z", "2026-10-19T23:59:59Z", "2026-10-20T00:00:00Z"].compactMap(parseISO)
        XCTAssertEqual(WorkStats.perDay(dates, now: now, calendar: cal), [2, 1, 0, 0, 0, 0, 0], "Sunday is last week")
    }

    func testPassRate() {
        let runs = [
            run("success", at: "2026-10-20T09:00:00Z"), run("failure", at: "2026-10-20T08:00:00Z"),
            run("success", at: "2026-10-14T00:00:00Z"),                         // the first of the 7 days
            run("failure", at: "2026-10-13T23:59:59Z"),                         // too old
            run("cancelled", at: "2026-10-19T09:00:00Z"), run(nil, at: "2026-10-19T09:00:00Z", status: "in_progress"),
        ]
        let p = WorkStats.passRate(runs, now: now, calendar: cal)
        XCTAssertEqual(p.rate!, 2.0 / 3, accuracy: 0.001)
        XCTAssertEqual(p.daily.count, 7)
        XCTAssertEqual(p.daily.first!, 1)
        XCTAssertEqual(p.daily.last!, 0.5)
        XCTAssertNil(p.daily[5], "only a cancelled run on Monday")
        XCTAssertNil(WorkStats.passRate([], now: now, calendar: cal).rate)
    }

    func testReviewsSkipOwnAndDraftPRs() {
        let prs = [pr(mine: false, created: "2026-10-18T00:00:00Z"), pr(mine: false, created: "2026-10-15T00:00:00Z"),
                   pr(mine: true, created: "2026-10-01T00:00:00Z"), pr(mine: false, draft: true, created: "2026-10-02T00:00:00Z")]
        let r = WorkStats.reviews(prs)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r.oldest, parseISO("2026-10-15T00:00:00Z"))
        XCTAssertNil(WorkStats.reviews([]).oldest)
    }

    func testClosedCountsMineOnceEachDay() {
        let entries = [closed("1", at: "2026-10-19T09:00:00Z"), closed("1", at: "2026-10-19T11:00:00Z"),
                       closed("1", at: "2026-10-20T09:00:00Z"), closed("2", at: "2026-10-20T09:00:00Z"),
                       closed("3", at: "2026-10-20T09:00:00Z"), closed("4", at: "2026-10-18T09:00:00Z"),
                       closed("5", at: "2026-10-20T09:00:00Z", change: .reopened)]
        let c = WorkStats.closed(entries, mine: { $0.itemId != "3" }, now: now, calendar: cal)
        XCTAssertEqual(c, [1, 2, 0, 0, 0, 0, 0])
    }

    func testUsageLimit() {
        let cases: [(String, String?)] = [
            ("  5-hour limit reached ∙ resets 3pm", "3pm"),
            ("Claude usage limit reached. Your limit will reset at 3pm (Europe/Paris).", "3pm"),
            ("You've hit your usage limit. Upgrade to Pro or try again at 3:05 PM.", "3:05 PM"),
            ("The rate limit resets at 14:30", "14:30"),
            ("Context left until auto-compact: 12%", nil),
            ("It resets at 3pm", nil),
        ]
        for (line, want) in cases { XCTAssertEqual(WorkStats.usageLimit(["> hi", line, ""]), want, line) }
        XCTAssertNil(WorkStats.usageLimit(["5-hour limit reached ∙ resets 3pm"] + Array(repeating: "x", count: 12)), "too far up")
    }

    func testSessionMinutesCapTheGapAndKeepTwoWeeks() throws {
        let path = NSTemporaryDirectory() + "work-stats-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let s = WorkStats(path: path) { _ in nil }
        s.calendar = cal
        s.now = { self.now }
        let old = now.addingTimeInterval(-20 * 86400)
        s.sample(working: 1, at: old)
        s.sample(working: 1, at: old.addingTimeInterval(60))
        s.sample(working: 2, at: now.addingTimeInterval(-600))      // 20 days gap: nothing
        s.sample(working: 1, at: now.addingTimeInterval(-540))      // 1 min × 2
        s.sample(working: 1, at: now)                               // 9 min gap: nothing
        s.sample(working: 0, at: now.addingTimeInterval(60))        // 1 min × 1
        s.sample(working: 0, at: now.addingTimeInterval(120))
        XCTAssertEqual(s.sessionHours[1] * 60, 3, accuracy: 0.001)
        XCTAssertEqual(s.sessionHours.reduce(0, +) * 60, 3, accuracy: 0.001)

        let again = WorkStats(path: path) { _ in nil }
        again.calendar = cal
        again.now = { self.now }
        XCTAssertEqual(again.sessionHours[1] * 60, 3, accuracy: 0.001, "saved")
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(raw.contains("2026-09-30"), "older than 14 days")
    }

    func testMergedFiltersTheTrackedRepos() {
        let path = NSTemporaryDirectory() + "work-stats-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        var since: Date?
        let s = WorkStats(path: path) { d in
            since = d
            return [.init(repo: "Org/App", number: 1, at: parseISO("2026-10-20T08:00:00Z")!),
                    .init(repo: "org/other", number: 2, at: parseISO("2026-10-20T08:00:00Z")!),
                    .init(repo: "org/app", number: 3, at: parseISO("2026-10-19T08:00:00Z")!)]
        }
        s.calendar = cal
        s.now = { self.now }
        XCTAssertNil(s.merged(repos: ["org/app"]), "not fetched yet")
        let done = expectation(forNotification: WorkStats.changed, object: s)
        s.refreshMerged()
        wait(for: [done], timeout: 5)
        XCTAssertEqual(since, parseISO("2026-10-19T00:00:00Z"))
        XCTAssertEqual(s.merged(repos: ["org/app"]), [1, 1, 0, 0, 0, 0, 0])
    }
}
