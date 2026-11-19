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

    func testAwayGivesNoRow() {
        let s = snap([item("i1", "OVERSIRE-377", state: "s1", at: now)])
        XCTAssertTrue(TrackerEvents.drafts([("", .away(items: 2))], old: s, new: s, provider: "plane", machine: "mba").isEmpty)
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

    // MARK: Epics

    func epic(_ id: String, _ title: String, state: EpicState = .active, created: Date? = nil, updated: Date? = nil,
              linked: [String: Date]? = nil) -> Epic {
        Epic(id: EpicID(rawValue: id), title: title, state: state, url: "https://plane/\(id)",
             project: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE"),
             createdAt: created, updatedAt: updated, linkedAt: linked)
    }

    func epicSnap(_ items: [(String, String, String?)], index: [ItemStub]? = nil, epics: [Epic]?, at: Date? = nil) -> ProjectSnapshot {
        let list = items.map { id, key, e -> Item in
            var i = item(id, key, state: "s1", at: now)
            i.epicId = e.map(EpicID.init(rawValue:))
            return i
        }
        let base = snap(list)
        return ProjectSnapshot(summary: base.summary, statusOptions: base.statusOptions, items: list, fetchedAt: at ?? now, index: index, epics: epics)
    }

    func epicRows(old: ProjectSnapshot?, new: ProjectSnapshot, actors: [String: EventActor] = [:], me: String? = nil) -> [EventDraft] {
        EpicEvents.drafts(old: old, new: new, provider: "plane", machine: "mba", actors: actors, me: me)
    }

    func testEpicBackfillOnFirstSync() {
        let d1 = now.addingTimeInterval(-86400 * 3), d2 = now.addingTimeInterval(-86400 * 2)
        let epics = [epic("ma", "Alpha", created: d1, linked: ["i1": d1, "i2": d2]), epic("mb", "Beta", created: d2, linked: ["i3": d2])]
        let new = epicSnap([("i1", "OVERSIRE-1", "ma"), ("i2", "OVERSIRE-2", "ma"), ("i3", "OVERSIRE-3", "mb"), ("i4", "OVERSIRE-4", nil)], epics: epics)
        let rows = epicRows(old: nil, new: new)
        XCTAssertEqual(rows.filter { $0.kind == .epicCreated }.map(\.at), [d1, d2])
        let added = rows.filter { $0.kind == .epicItemAdded }
        XCTAssertEqual(added.map(\.item), ["OVERSIRE-1", "OVERSIRE-2", "OVERSIRE-3"])
        XCTAssertEqual(added.map(\.at), [d1, d2, d2])
        XCTAssertEqual(added[0].parentItem, epics[0].eventKey)
        XCTAssertEqual(added[0].id, "plane:epic-ma:add:i1:\(Int64(d1.timeIntervalSince1970 * 1000))")
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.id), epicRows(old: snap([]), new: new).map(\.id), "an old snapshot without epics backfills too")
        XCTAssertEqual(rows.map(\.id), epicRows(old: nil, new: new).map(\.id))
        let noDates = epicSnap([("i1", "OVERSIRE-1", "ma")], epics: [epic("ma", "Alpha", created: d1)])
        XCTAssertEqual(epicRows(old: nil, new: noDates).map(\.at), [d1, d1], "no link date: the epic date")
        let bare = epicSnap([("i1", "OVERSIRE-1", "ma")], epics: [epic("ma", "Alpha")])
        XCTAssertEqual(Set(epicRows(old: nil, new: bare).map(\.at)), [now], "no date at all: the fetch time")
    }

    func testEpicDiffMove() {
        let epics = [epic("ma", "Alpha"), epic("mb", "Beta")]
        let old = epicSnap([("i1", "OVERSIRE-1", "ma")], epics: epics)
        let later = now.addingTimeInterval(600)
        let new = epicSnap([("i1", "OVERSIRE-1", "mb")], epics: epics, at: later)
        let rows = epicRows(old: old, new: new)
        XCTAssertEqual(rows.map(\.kind), [.epicItemRemoved, .epicItemAdded])
        XCTAssertEqual(rows[0].payload, ["epic": .string("ma"), "title": .string("Alpha"), "to": .string("mb")])
        XCTAssertEqual(rows[1].payload, ["epic": .string("mb"), "title": .string("Beta"), "from": .string("ma")])
        XCTAssertEqual(rows[0].parentItem, epics[0].eventKey)
        XCTAssertEqual(rows[1].parentItem, epics[1].eventKey)
        XCTAssertEqual(rows.map(\.at), [later, later])
        XCTAssertEqual(rows[1].summary, "Added to Beta")
        XCTAssertEqual(epicRows(old: new, new: new), [], "no change gives no row")
        let created = epicRows(old: new, new: epicSnap([("i1", "OVERSIRE-1", "mb")], epics: epics + [epic("mc", "Gamma")]))
        XCTAssertEqual(created.map(\.kind), [.epicCreated])
        let out = epicRows(old: new, new: epicSnap([("i1", "OVERSIRE-1", nil)], epics: epics))
        XCTAssertEqual(out.map(\.kind), [.epicItemRemoved])
        XCTAssertNil(out[0].payload?["to"])
    }

    func testEpicClosedOnce() {
        let done = now.addingTimeInterval(-60)
        let open = epicSnap([("i1", "OVERSIRE-1", "ma")], epics: [epic("ma", "Alpha")])
        let closed = epicSnap([("i1", "OVERSIRE-1", "ma")], epics: [epic("ma", "Alpha", state: .done, updated: done)])
        let rows = epicRows(old: open, new: closed)
        XCTAssertEqual(rows.map(\.kind), [.epicClosed])
        XCTAssertEqual(rows[0].id, "plane:epic-ma:closed:\(Int64(done.timeIntervalSince1970 * 1000))")
        XCTAssertEqual(rows[0].item, epic("ma", "Alpha").eventKey)
        XCTAssertNil(rows[0].parentItem)
        XCTAssertEqual(rows[0].payload, ["epic": .string("ma"), "title": .string("Alpha"), "state": .string("done"), "open": .int(1)])
        XCTAssertEqual(rows[0].summary, "Alpha done")
        XCTAssertEqual(epicRows(old: closed, new: closed), [])
    }

    func testEpicRowsFollowTheCatalog() {
        let d = now.addingTimeInterval(-86400)
        let epics = [epic("ma", "Alpha", created: d, linked: ["i1": d]), epic("mb", "Beta", state: .canceled, created: d, updated: d)]
        let new = epicSnap([("i1", "OVERSIRE-1", "ma"), ("i2", "OVERSIRE-2", "mb")], epics: epics)
        let moved = epicSnap([("i1", "OVERSIRE-1", "mb"), ("i2", "OVERSIRE-2", nil)], epics: epics)
        let rows = epicRows(old: nil, new: new) + epicRows(old: new, new: moved)
        XCTAssertEqual(Set(rows.map(\.kind)), [.epicCreated, .epicItemAdded, .epicItemRemoved, .epicClosed])
        for r in rows { XCTAssertEqual(EventCatalog.repo.problems(r), [], r.id) }
    }

    func testEpicRowsByMeAreHuman() {
        let old = epicSnap([("i1", "OVERSIRE-1", nil), ("i2", "OVERSIRE-2", nil)], epics: [epic("ma", "Alpha")])
        let new = epicSnap([("i1", "OVERSIRE-1", "ma"), ("i2", "OVERSIRE-2", "ma")], epics: [epic("ma", "Alpha")])
        let rows = epicRows(old: old, new: new, actors: ["i1": .user], me: "fritz")
        XCTAssertEqual(rows.map(\.actorType), [.human, .provider])
        XCTAssertEqual(rows.map(\.actor), ["fritz", "plane"])
        XCTAssertEqual(epicRows(old: old, new: new, actors: ["i1": .user]).map(\.actorType), [.provider, .provider], "no name: the provider")
    }

    func testAgentActorFromCli() {
        let old = epicSnap([("i1", "OVERSIRE-1", nil), ("i2", "OVERSIRE-2", nil)], epics: [epic("ma", "Alpha")])
        let new = epicSnap([("i1", "OVERSIRE-1", "ma"), ("i2", "OVERSIRE-2", nil)], epics: [epic("ma", "Alpha"), epic("mb", "Beta")])
        let rows = epicRows(old: old, new: new, actors: ["i1": EventActor(type: .agent, name: "codex"), "mb": EventActor(type: .agent, name: "codex")],
                            me: "fritz")
        XCTAssertEqual(rows.map(\.kind), [.epicCreated, .epicItemAdded])
        XCTAssertEqual(rows.map(\.actorType), [.agent, .agent])
        XCTAssertEqual(rows.map(\.actor), ["codex", "codex"])
        for r in rows { XCTAssertEqual(EventCatalog.repo.problems(r), [], r.id) }
    }

    func testNoEpicRowsWithoutEpics() {
        let s = epicSnap([("i1", "OVERSIRE-1", nil)], epics: nil)
        XCTAssertEqual(epicRows(old: nil, new: s), [])
        XCTAssertEqual(epicRows(old: epicSnap([], epics: []), new: s), [])
    }

    func testIndexOnlyMemberUsesStubKey() {
        let stubs = [ItemStub(id: "x1", parentId: nil, stateId: "s1", activityAt: nil, epicId: "ma", key: "OVERSIRE-9"),
                     ItemStub(id: "x2", parentId: nil, stateId: "s1", activityAt: nil, epicId: "ma", key: nil)]
        let new = epicSnap([], index: stubs, epics: [epic("ma", "Alpha")])
        let rows = epicRows(old: nil, new: new).filter { $0.kind == .epicItemAdded }
        XCTAssertEqual(rows.map(\.item), ["OVERSIRE-9"])
        let old = epicSnap([], index: stubs.map { ItemStub(id: $0.id, parentId: nil, stateId: "s1", activityAt: nil) }, epics: [epic("ma", "Alpha")])
        XCTAssertEqual(epicRows(old: old, new: new).map(\.item), ["OVERSIRE-9"])
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
