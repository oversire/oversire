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
}
