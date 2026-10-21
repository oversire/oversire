import OverSireCore
import XCTest
import OverSireAI
@testable import OverSireApp

final class NeedsYouTests: XCTestCase {
    private func j(_ key: String, _ v: StatusReply.State, at: TimeInterval, headline: String = "") -> SessionStatus {
        SessionStatus(id: key, key: key, reply: StatusReply(state: v, headline: headline), ticks: [], at: Date(timeIntervalSince1970: at),
                      trigger: .idle, byAI: true, read: "")
    }

    private func n(_ k: NeedsYou.Kind, _ key: String, at: TimeInterval = 0) -> NeedsYou {
        NeedsYou(kind: k, key: key, reason: "", at: Date(timeIntervalSince1970: at), route: .home)
    }

    func testChecksGiveOneRowForEachStatus() {
        let rows = NeedsYou.checks([j("A-1", .done, at: 10), j("A-2", .stuck, at: 20, headline: "Edits the same test"),
                                    j("A-3", .unfinished, at: 30), j("A-4", .blocked, at: 40), j("A-5", .working, at: 50)])
        XCTAssertEqual(rows.map(\.kind), [.done, .stuck, .notFinished])
        XCTAssertEqual(rows.map(\.reason), ["Looks done · approve to free the slot", "Edits the same test", "Not finished"])
        XCTAssertEqual(rows.map(\.act), [.approve("A-1"), .nudge("A-2"), .ask("A-3")])
        XCTAssertTrue(NeedsYou.checks([]).isEmpty)
    }

    func testOneRowForEachItemAndTheMostUrgentWins() {
        let got = NeedsYou.merged([n(.notFinished, "A-1", at: 50), n(.needsInput, "A-1", at: 10), n(.review, "app #3", at: 99),
                                   n(.stuck, "A-2", at: 20), n(.usageLimit, "A-3", at: 5)])
        XCTAssertEqual(got.map(\.key), ["A-1", "A-3", "A-2", "app #3"])
        XCTAssertEqual(got.first?.kind, .needsInput, "the Orca row and the AI row of an item become one row")
    }

    func testFilters() {
        let kinds: [NeedsYou.Kind] = [.needsInput, .blocked, .usageLimit, .stuck, .notFinished, .openSubItems, .done, .runFailed, .review, .mention]
        func of(_ f: NeedsYou.Filter) -> [NeedsYou.Kind] { kinds.filter(f.has) }
        XCTAssertEqual(of(.all), kinds)
        XCTAssertEqual(of(.blocked), [.needsInput, .blocked])
        XCTAssertEqual(of(.stuck), [.usageLimit, .stuck])
        XCTAssertEqual(of(.notFinished), [.notFinished, .openSubItems])
        XCTAssertEqual(NeedsYou.Filter.allCases.map(\.title), ["All", "Blocked", "Stuck", "Not finished"])
    }

    func testDoneWithOpenSubItems() {
        let now = Date()
        let done = StatusOption(id: "d", name: "Done", color: "", group: "completed")
        let todo = StatusOption(id: "t", name: "Todo", color: "", group: "unstarted")
        func item(_ id: String, _ state: String, parent: String? = nil, ago: TimeInterval = 60) -> Item {
            Item(id: id, key: "A-\(id)", title: "T\(id)", url: "u", statusOptionId: state, fields: [:], assignees: [], labels: [],
                 author: nil, updatedBy: nil, updatedAt: now, activityAt: now.addingTimeInterval(-ago), commentCount: 0, lastComment: nil,
                 mentionsMe: false, parentId: parent)
        }
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: ProjectRef(workspace: "w", id: "p"), identifier: "A", title: "A", url: "", closed: false),
                                   statusOptions: [todo, done],
                                   items: [item("1", "d"), item("2", "t", parent: "1"), item("3", "t", parent: "1"),
                                           item("4", "d"), item("5", "d", parent: "4"),
                                           item("6", "d", ago: 8 * 86400), item("7", "t", parent: "6")],
                                   fetchedAt: now)
        let rows = NeedsYou.openSubItems([snap], now: now)
        XCTAssertEqual(rows.map(\.key), ["A-1"], "a finished parent and an old one give no row")
        XCTAssertEqual(rows.first?.reason, "Done with 2 open sub-items · T1")
        XCTAssertEqual(rows.first?.act, .closeSubItems("A-1"))
        XCTAssertEqual(rows.first?.kind.rawValue, NeedsYou.Kind.notFinished.rawValue + 1)
    }

    func testStepsInAFewWords() {
        func s(_ kind: String, _ text: String = "x") -> StatusReply.Step { StatusReply.Step(text: text, kind: kind) }
        XCTAssertEqual(NeedsYou.steps([]), "Blocked on you")
        XCTAssertEqual(NeedsYou.steps([s("approval", "Approve the cloud Worker deploy")]), "Approve the cloud Worker deploy")
        XCTAssertEqual(NeedsYou.steps([s("manual-check"), s("manual-check")]), "2 manual checks")
        XCTAssertEqual(NeedsYou.steps([s("secret"), s("approval"), s("login")]), "3 steps for you")
    }

    func testFailedRunCountsOnTheDefaultBranchOrOnMyPR() {
        func run(_ branch: String) -> Run {
            Run(id: "1", name: "ci", displayTitle: "", status: "completed", conclusion: "failure", headBranch: branch, headSha: "", event: "push",
                url: "", updatedAt: "", createdAt: "", startedAt: nil, number: 1, workflowName: "ci", actorLogin: nil)
        }
        func pr(_ branch: String, mine: Bool) -> ChangeRequest {
            ChangeRequest(number: 1, title: "", state: "OPEN", author: .init(login: "a"), headRefName: branch, baseRefName: "main", url: "",
                          createdAt: "", updatedAt: "", reviewDecision: nil, additions: 0, deletions: 0, isDraft: false, labels: [], body: nil, mine: mine)
        }
        let prs = [("o/app", [pr("fix-1", mine: true), pr("theirs", mine: false)])]
        XCTAssertTrue(NeedsYou.counts(run("main"), repo: "o/app", prs: prs))
        XCTAssertTrue(NeedsYou.counts(run("fix-1"), repo: "o/app", prs: prs))
        XCTAssertFalse(NeedsYou.counts(run("theirs"), repo: "o/app", prs: prs), "a PR of another author")
        XCTAssertFalse(NeedsYou.counts(run("fix-1"), repo: "o/other", prs: prs), "the PR is in another repo")
        XCTAssertFalse(NeedsYou.counts(run("spike"), repo: "o/app", prs: prs))
    }

    func testSnoozeHidesTheRowUntilItChanges() {
        let path = NSTemporaryDirectory() + "snoozes-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let now = Date(timeIntervalSince1970: 1_000_000)
        let row = n(.stuck, "A-1", at: 100)
        let s = Snoozes(path: path)
        XCTAssertFalse(s.has(row.id, now: now))
        s.snooze(row.id, now: now)
        XCTAssertTrue(s.has(row.id, now: now.addingTimeInterval(3600)))
        XCTAssertFalse(s.has(row.id, now: now.addingTimeInterval(86401)), "one day")
        XCTAssertFalse(s.has(n(.stuck, "A-1", at: 200).id, now: now), "a new status shows again")
        XCTAssertTrue(Snoozes(path: path).has(row.id, now: now), "saved")
    }
}
