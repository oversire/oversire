import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class EventDeskTests: XCTestCase {
    actor Outlet: EventOutlet {
        var rows: [EventDraft] = []
        var links: [ItemLink] = []
        func append(_ drafts: [EventDraft]) async { rows += drafts }
        func link(_ l: [ItemLink]) async { links += l }
    }

    let start = Date(timeIntervalSince1970: 1_793_000_000)

    func desk(_ o: Outlet, clock: @escaping () -> Date) -> EventDesk {
        let d = EventDesk(outlet: o)
        d.machine = { "mba" }
        d.email = { "fritz@example.com" }
        d.now = clock
        return d
    }

    func rows(_ o: Outlet, count: Int) async -> [EventDraft] {
        for _ in 0..<200 {
            let r = await o.rows
            if r.count >= count { return r }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await o.rows
    }

    func testStateSetWritesOneHumanRow() async {
        let o = Outlet()
        let d = desk(o) { self.start }
        let p = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE")
        let item = Item(id: "i1", key: "OVERSIRE-382", title: "Capture", url: "", statusOptionId: "s1", fields: [:], assignees: [], labels: [],
                        author: "fritz", updatedBy: "fritz", updatedAt: start, activityAt: start, commentCount: 0, lastComment: nil,
                        mentionsMe: false, parentId: nil)
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: p, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                                   statusOptions: [StatusOption(id: "s1", name: "Todo", color: "", group: "unstarted"),
                                                   StatusOption(id: "s2", name: "Done", color: "", group: "completed")],
                                   items: [item], fetchedAt: start)
        d.stateSet(item, in: snap, to: "s2")
        let r = await rows(o, count: 1)
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r[0].kind, .itemStateChanged)
        XCTAssertEqual(r[0].item, "OVERSIRE-382")
        XCTAssertEqual(r[0].project, "oversire")
        XCTAssertEqual(r[0].actorType, .human)
        XCTAssertEqual(r[0].actor, "fritz@example.com")
        XCTAssertEqual(r[0].via, "app@mba")
        XCTAssertEqual(r[0].payload, ["from": .string("Todo"), "to": .string("Done"), "group": .string("completed")])
        XCTAssertEqual(r[0].summary, "Todo → Done")
        XCTAssertEqual(EventCatalog.repo.problems(r[0]), [])
    }

    func testStateSetWithAgent() async {
        let o = Outlet()
        let d = desk(o) { self.start }
        let p = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE")
        let item = Item(id: "i1", key: "OVERSIRE-382", title: "Capture", url: "", statusOptionId: "s1", fields: [:], assignees: [], labels: [],
                        author: "fritz", updatedBy: "fritz", updatedAt: start, activityAt: start, commentCount: 0, lastComment: nil,
                        mentionsMe: false, parentId: nil)
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: p, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                                   statusOptions: [StatusOption(id: "s1", name: "Todo", color: "", group: "unstarted"),
                                                   StatusOption(id: "s2", name: "Done", color: "", group: "completed")],
                                   items: [item], fetchedAt: start)
        d.stateSet(item, in: snap, to: "s2", actor: EventActor(type: .agent, name: "codex s1"))
        let r = await rows(o, count: 1)
        XCTAssertEqual(r[0].actorType, .agent)
        XCTAssertEqual(r[0].actor, "codex s1")
        XCTAssertEqual(EventCatalog.repo.problems(r[0]), [])
    }

    func testStateSetUsesActorVia() async {
        let o = Outlet()
        let d = desk(o) { self.start }
        let p = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE")
        let item = Item(id: "i1", key: "OVERSIRE-382", title: "Capture", url: "", statusOptionId: "s1", fields: [:], assignees: [], labels: [],
                        author: "fritz", updatedBy: "fritz", updatedAt: start, activityAt: start, commentCount: 0, lastComment: nil,
                        mentionsMe: false, parentId: nil)
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: p, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                                   statusOptions: [StatusOption(id: "s1", name: "Todo", color: "", group: "unstarted"),
                                                   StatusOption(id: "s2", name: "Done", color: "", group: "completed")],
                                   items: [item], fetchedAt: start)
        d.stateSet(item, in: snap, to: "s2", actor: EventActor(type: .human, name: nil, via: "app@mba"))
        let r = await rows(o, count: 1)
        XCTAssertEqual(r[0].via, "app@mba")
        XCTAssertEqual(r[0].actorType, .human)
        XCTAssertEqual(EventCatalog.repo.problems(r[0]), [])
    }

    /// Close in time to the fake runs, so the horizon of the poll keeps them.
    let pollAt = Date(timeIntervalSince1970: 1_790_849_160)

    func ciRuns(attempt: Int) -> [Run] {
        [FakeCI.run(id: "9", status: "completed", conclusion: "success", attempt: attempt)]
    }

    func testRerunByAgentNamesAgentOnPoll() async {
        let o = Outlet()
        let d = desk(o) { self.pollAt }
        d.runs([("o/r", ciRuns(attempt: 1))])
        d.ciRerunBy(repo: "o/r", run: "9", attempt: 2, actor: EventActor(type: .agent, name: "codex", via: "cli@mba"))
        d.runs([("o/r", ciRuns(attempt: 2))])
        let r = await rows(o, count: 5).filter { $0.kind == .ciRerun }
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(r.first?.actorType, .agent)
        XCTAssertEqual(r.first?.actor, "codex")
        XCTAssertEqual(r.first?.via, "cli@mba")
    }

    func testRerunActorExpires() async {
        let o = Outlet()
        let clock = CIOpsTests.Box(pollAt)
        let d = desk(o) { clock.get() }
        d.runs([("o/r", ciRuns(attempt: 1))])
        d.ciRerunBy(repo: "o/r", run: "9", attempt: 2, actor: EventActor(type: .agent, name: "codex", via: "cli@mba"))
        clock.set(pollAt.addingTimeInterval(EventDesk.rerunKept + 1))
        d.runs([("o/r", ciRuns(attempt: 2))])
        let r = await rows(o, count: 5).filter { $0.kind == .ciRerun }
        XCTAssertEqual(r.count, 1)
        XCTAssertNotEqual(r.first?.actorType, .agent)
    }

    func testViewedAtMostOnceEachTenMinutes() async {
        let o = Outlet()
        var t = start
        let d = desk(o) { t }
        d.viewed("oversire-382", page: "overview")
        t += 60
        d.viewed("OVERSIRE-382", page: "timeline")
        t += EventDesk.viewEvery
        d.viewed("OVERSIRE-382", page: "timeline")
        let r = await rows(o, count: 2)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let all = await o.rows
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(r.map(\.kind), [.itemViewed, .itemViewed])
        XCTAssertEqual(Set(all.map(\.id)).count, 2)
    }

    func testHeldOnlyOnANewReason() async {
        let o = Outlet()
        var t = start
        let d = desk(o) { t }
        d.held("OVERSIRE-384", project: "OVERSIRE", lane: "plane:ocral:p1", reason: "Waits for OVERSIRE-383")
        t += 1
        d.held("OVERSIRE-384", project: "OVERSIRE", lane: "plane:ocral:p1", reason: "Waits for OVERSIRE-383")
        d.released("OVERSIRE-384")
        t += 1
        d.held("OVERSIRE-384", project: "OVERSIRE", lane: "plane:ocral:p1", reason: "Waits for OVERSIRE-383")
        let r = await rows(o, count: 2)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].actorType, .system)
        XCTAssertEqual(r[0].onBehalf, "fritz@example.com")
        XCTAssertEqual(EventCatalog.repo.problems(r[0]), [])
    }

    func testEpicsSendsBackfillOnce() async {
        let o = Outlet()
        let d = desk(o) { self.start }
        let p = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE")
        let epic = Epic(id: "m1", title: "Review desk", state: .active, url: "", project: p, createdAt: start)
        var item = Item(id: "i1", key: "OVERSIRE-382", title: "Capture", url: "", statusOptionId: "s1", fields: [:], assignees: [], labels: [],
                        author: "fritz", updatedBy: "fritz", updatedAt: start, activityAt: start, commentCount: 0, lastComment: nil,
                        mentionsMe: false, parentId: nil)
        item.epicId = "m1"
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: p, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                                   statusOptions: [StatusOption(id: "s1", name: "Todo", color: "", group: "unstarted")],
                                   items: [item], fetchedAt: start, epics: [epic])
        d.epics(old: nil, new: snap, actors: [:])
        let first = await rows(o, count: 2)
        XCTAssertEqual(Set(first.map(\.kind)), [.epicCreated, .epicItemAdded])
        XCTAssertEqual(first.first { $0.kind == .epicItemAdded }?.parentItem, epic.eventKey)
        for r in first { XCTAssertEqual(EventCatalog.repo.problems(r), [], r.id) }
        d.epics(old: snap, new: snap, actors: [:])
        try? await Task.sleep(nanoseconds: 30_000_000)
        let all = await o.rows
        XCTAssertEqual(all.count, 2, "a poll with no change sends no row")
    }
}
