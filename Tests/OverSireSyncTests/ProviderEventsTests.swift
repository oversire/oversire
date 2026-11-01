import Foundation
import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest

final class ProviderEventsTests: XCTestCase {
    let now = parseISO("2026-10-29T16:00:00Z")!

    func run(_ status: String, _ conclusion: String? = nil, attempt: Int = 1, id: String = "812", started: String? = "2026-10-29T15:20:00Z",
             updated: String = "2026-10-29T15:25:12Z", actor: String = "fritz") -> Run {
        Run(id: id, name: "test", displayTitle: "Fix merge", status: status, conclusion: conclusion, headBranch: "oversire-374/fix",
            headSha: "9d1e07a2c0ffee", event: "push", url: "https://github.com/oversire/cli/actions/runs/\(id)", updatedAt: updated,
            createdAt: "2026-10-29T15:19:00Z", startedAt: started, number: 2243, workflowName: "test", actorLogin: actor, attempt: attempt)
    }

    func ci(_ m: inout CIEvents, _ runs: [Run]) -> [EventDraft] {
        m.drafts(repo: "oversire/cli", runs: runs, machine: "mba", now: now) { $0.headBranch.hasPrefix("oversire-374") ? "OVERSIRE-374" : nil }
    }

    func testFailThenRerunPasses() {
        var m = CIEvents(source: "gha", provider: "github")
        XCTAssertEqual(ci(&m, [run("in_progress", updated: "2026-10-29T15:20:00Z")]).map(\.id), ["gha:812:1:started"])
        let failed = ci(&m, [run("completed", "failure")])
        XCTAssertEqual(failed.map(\.id), ["gha:812:1:completed"])
        XCTAssertEqual(failed[0].payload?["conclusion"], .string("failure"))
        XCTAssertEqual(failed[0].payload?["durationSec"], .int(312))
        XCTAssertEqual(failed[0].summary, "cli test #2243 failed")
        XCTAssertEqual(failed[0].item, "OVERSIRE-374")
        XCTAssertEqual(ci(&m, [run("completed", "failure")]), [], "a poll with no change gives no row")

        let rerun = ci(&m, [run("queued", attempt: 2, started: nil, updated: "2026-10-29T15:40:00Z")])
        XCTAssertEqual(rerun.map(\.id), ["gha:812:2:rerun", "gha:812:2:queued"])
        XCTAssertEqual(rerun[0].actorType, .human)
        XCTAssertEqual(rerun[0].actor, "fritz")
        let passed = ci(&m, [run("completed", "success", attempt: 2, started: "2026-10-29T15:41:00Z", updated: "2026-10-29T15:46:00Z")])
        XCTAssertEqual(passed.map(\.id), ["gha:812:2:started", "gha:812:2:completed"])
        XCTAssertEqual(passed[1].summary, "cli test #2243 passed")
        for d in failed + rerun + passed { XCTAssertEqual(EventCatalog.repo.problems(d), [], d.id) }
    }

    func testCancelledAndOldRuns() {
        var m = CIEvents(source: "gha", provider: "github")
        let rows = ci(&m, [run("completed", "cancelled"), run("completed", "success", id: "700", updated: "2026-10-01T10:00:00Z")])
        XCTAssertEqual(rows.map(\.id), ["gha:812:1:started", "gha:812:1:completed"], "a run older than the horizon gives no row")
        XCTAssertEqual(rows[1].summary, "cli test #2243 was cancelled")
        let f = CIEvents.withFailures(rows[1], [Failure(job: "go test", step: "TestMergePartialFail", messages: [])])
        XCTAssertEqual(f.payload?["failed"], .array([.object(["job": .string("go test"), "step": .string("TestMergePartialFail")])]))
        XCTAssertEqual(f.summary, "cli test #2243 was cancelled: TestMergePartialFail")
    }

    func pr(_ n: Int, sha: String, state: String = "OPEN", merge: String? = nil) -> ChangeRequest {
        var c = ChangeRequest(number: n, title: "OVERSIRE-374 fix", state: state, author: .init(login: "fritz"), headRefName: "oversire-374",
                              baseRefName: "main", url: "https://github.com/oversire/cli/pull/\(n)", createdAt: "2026-10-29T15:00:00Z",
                              updatedAt: "2026-10-29T15:30:00Z", reviewDecision: nil, additions: 1, deletions: 0, isDraft: false, labels: [], body: nil)
        c.headSha = sha
        c.mergeSha = merge
        return c
    }

    func testChangeRows() {
        var m = ChangeEvents(source: "gh-pr", provider: "github")
        let opened = m.drafts(repo: "oversire/cli", open: [pr(9, sha: "aaa")], machine: "mba") { _ in "OVERSIRE-374" }
        XCTAssertEqual(opened.drafts.map(\.id), ["gh-pr:oversire/cli#9:opened"])
        XCTAssertEqual(m.drafts(repo: "oversire/cli", open: [pr(9, sha: "aaa")], machine: "mba") { _ in nil }.drafts, [])
        let updated = m.drafts(repo: "oversire/cli", open: [pr(9, sha: "bbb")], machine: "mba") { _ in nil }
        XCTAssertEqual(updated.drafts.map(\.id), ["gh-pr:oversire/cli#9:updated:bbb"])
        let gone = m.drafts(repo: "oversire/cli", open: [], machine: "mba") { _ in nil }
        XCTAssertEqual(gone.gone.map(\.number), [9])
        XCTAssertNil(m.ended(repo: "oversire/cli", pr(9, sha: "bbb"), machine: "mba", item: nil), "still open: no row")
        let merged = m.ended(repo: "oversire/cli", pr(9, sha: "bbb", state: "MERGED", merge: "ccc1234567"), machine: "mba", item: "OVERSIRE-374")
        XCTAssertEqual(merged?.id, "gh-pr:oversire/cli#9:merged")
        XCTAssertEqual(merged?.payload?["mergeSha"], .string("ccc1234567"))
        for d in opened.drafts + updated.drafts + [merged!] { XCTAssertEqual(EventCatalog.repo.problems(d), [], d.id) }
    }

    func item(_ id: String, _ key: String, state: String, at: Date, parent: String? = nil) -> Item {
        Item(id: id, key: key, title: "Title \(key)", url: "https://plane/\(key)", statusOptionId: state, fields: [:], assignees: [], labels: [],
             author: "fritz", updatedBy: "fritz", updatedAt: at, activityAt: at, commentCount: 0, lastComment: nil, mentionsMe: false,
             parentId: parent)
    }

    func snap(_ items: [Item]) -> ProjectSnapshot {
        let p = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE")
        return ProjectSnapshot(summary: ProjectSummary(ref: p, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                               statusOptions: [StatusOption(id: "s1", name: "Todo", color: "", group: "unstarted"),
                                               StatusOption(id: "s2", name: "In Progress", color: "", group: "started")],
                               items: items, fetchedAt: now)
    }

    func testTrackerStateChange() {
        let old = snap([item("i1", "OVERSIRE-377", state: "s1", at: now), item("i2", "OVERSIRE-382", state: "s1", at: now, parent: "i1")])
        let new = snap([item("i1", "OVERSIRE-377", state: "s1", at: now), item("i2", "OVERSIRE-382", state: "s2", at: now, parent: "i1")])
        let changes: [(itemId: String, ItemChange)] = [("i2", .status(from: "Todo", to: "In Progress"))]
        let rows = TrackerEvents.drafts(changes, old: old, new: new, provider: "plane", machine: "mba")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].kind, .itemStateChanged)
        XCTAssertEqual(rows[0].item, "OVERSIRE-382")
        XCTAssertEqual(rows[0].payload, ["from": .string("Todo"), "to": .string("In Progress"), "group": .string("started")])
        XCTAssertEqual(rows[0].id, "plane:i2:state:s2:\(Int64(now.timeIntervalSince1970 * 1000))")
        XCTAssertEqual(EventCatalog.repo.problems(rows[0]), [])
        XCTAssertEqual(TrackerEvents.drafts(changes, old: old, new: new, provider: "plane", machine: "mba", skipState: ["i2"]), [],
                       "a state that the app set gives no second row")
        XCTAssertEqual(Set(TrackerEvents.links(new)), [ItemLink(item: "OVERSIRE-377", parent: nil), ItemLink(item: "OVERSIRE-382", parent: "OVERSIRE-377")])
    }

    func testTrackerFieldsAndComments() {
        let s = snap([item("i1", "OVERSIRE-377", state: "s1", at: now)])
        let c = Comment(id: "c9", author: "fritz", createdAt: now, url: "https://plane/c9", body: "Looks good\nmore")
        let rows = TrackerEvents.drafts([("i1", .field(name: "Priority", from: nil, to: "High")), ("i1", .assigned("bob")), ("i1", .comments(new: 1, last: c))],
                                        old: s, new: s, provider: "plane", machine: "mba")
        XCTAssertEqual(rows.map(\.kind), [.commentCreated, .itemUpdated])
        XCTAssertEqual(rows[0].summary, "Looks good")
        XCTAssertEqual(rows[1].payload?["fields"], .array([.string("Assignees"), .string("Priority")]))
        for d in rows { XCTAssertEqual(EventCatalog.repo.problems(d), [], d.id) }
    }

    func testSenderKeepsRowsUntilTheDaemonAnswers() async throws {
        let d = FakeDaemon()
        d.online = false
        let client = DaemonClient(base: DaemonClient.loopback, token: nil, http: d)
        let s = EventSender { client }
        var m = CIEvents(source: "gha", provider: "github")
        let rows = ci(&m, [run("completed", "failure")])
        await s.append(rows)
        let waiting = await s.waiting
        XCTAssertEqual(waiting, 2)
        d.online = true
        await s.append(rows)
        await s.link([ItemLink(item: "OVERSIRE-374", parent: "OVERSIRE-371")])
        XCTAssertEqual(d.rows.map(\.id), ["gha:812:1:started", "gha:812:1:completed"])
        XCTAssertEqual(d.itemLinks, ["OVERSIRE-374": "OVERSIRE-371"])
        let page = try await client.events(Event.Query(item: "OVERSIRE-374"))
        XCTAssertEqual(page.events.count, 2)
    }

    func testEventFrame() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Contract/fixtures/event/ci.completed.json")
        let row = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        let text = #"{"type":"event","event":"# + row + "}"
        guard case .event(let e)? = DaemonFrame.parse(text) else { return XCTFail("no event frame") }
        XCTAssertEqual(e.id, "gha:2243:1:completed")
        XCTAssertEqual(e.seq, 127)
    }
}
