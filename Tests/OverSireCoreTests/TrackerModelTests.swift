import XCTest
@testable import OverSireCore

final class TrackerModelTests: XCTestCase {
    let todo = StatusOption(id: "s1", name: "Todo", color: "#888888", group: "unstarted")
    let doing = StatusOption(id: "s2", name: "In progress", color: "#F59E0B", group: "started")
    let next = StatusOption(id: "s3", name: "Next", color: "BLUE")
    let review = StatusOption(id: "s4", name: "In review", color: "PURPLE")
    let done = StatusOption(id: "s5", name: "Done", color: "GREEN")

    func item(_ id: String, status: String?, fields: [String: String] = [:], assignees: [String] = [],
              author: String? = "bea", parent: String? = nil, at: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> Item {
        Item(id: id, key: "ENG-\(id)", title: "Item \(id)", url: "https://app.plane.so/acme/browse/ENG-\(id)/",
             statusOptionId: status, fields: fields, assignees: assignees, labels: [], author: author, updatedBy: author,
             updatedAt: at, activityAt: at,
             commentCount: 0, lastComment: nil, mentionsMe: false, parentId: parent)
    }

    func snap(_ items: [Item], _ options: [StatusOption], workspace: String = "acme", title: String = "Board") -> ProjectSnapshot {
        let ref = ProjectRef(account: AccountID(provider: "plane", id: workspace), id: "4")
        return ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "ENG", title: title, url: "", closed: false),
                               statusOptions: options, items: items, fetchedAt: Date())
    }

    func testCategoryByName() {
        let cases: [(String, StatusCategory)] = [("Done", .done), ("Closed", .done), ("Shipped", .done), ("Blocked", .blocked),
                                                 ("In review", .review), ("In progress", .progress), ("Doing", .progress),
                                                 ("Backlog", .todo)]
        for (name, want) in cases {
            XCTAssertEqual(StatusOption(id: "1", name: name, color: "").category, want, name)
        }
    }

    func testCategoryByGroup() {
        XCTAssertEqual(StatusOption(id: "1", name: "Blocked", color: "", group: "started").category, .blocked)
        XCTAssertEqual(StatusOption(id: "1", name: "Ready", color: "", group: "completed").category, .done)
        XCTAssertEqual(StatusOption(id: "1", name: "Won't do", color: "", group: "cancelled").category, .done)
        XCTAssertEqual(StatusOption(id: "1", name: "Done soon", color: "", group: "backlog").category, .todo, "group wins over name")
    }

    func testStatusOrderAndFoldCount() {
        let s = snap([item("1", status: "s3"), item("2", status: "s4"), item("3", status: "s5"), item("4", status: nil)],
                     [todo, next, review, done])
        XCTAssertEqual(s.notDoneCount(s.items), 3)
        XCTAssertEqual(s.sortedItems.map(\.id), ["2", "1", "4", "3"])
    }

    func testPriorityOrder() {
        func pri(_ id: String, _ status: String, _ p: String?) -> Item { item(id, status: status, fields: p.map { ["Priority": $0] } ?? [:]) }
        let s = snap([pri("a", "s1", "Low"), pri("b", "s1", nil), pri("c", "s1", "Urgent"),
                      pri("d", "s5", "Urgent"), pri("e", "s2", "Low"), pri("f", "s2", "High")], [todo, doing, done])
        XCTAssertEqual(s.sortedItems.map(\.id), ["f", "e", "c", "a", "b", "d"])
    }

    func testDoneGroupSortsByLastChange() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let s = snap([item("old", status: "s5", fields: ["Priority": "Urgent"], at: t0),
                      item("new", status: "s5", fields: ["Priority": "Low"], at: t0 + 3600),
                      item("a", status: "s1", fields: ["Priority": "Low"], at: t0 + 7200),
                      item("b", status: "s1", fields: ["Priority": "High"], at: t0)], [todo, done])
        XCTAssertEqual(s.groupSorted(s.items).map(\.id), ["b", "a", "new", "old"])
    }

    func testHiddenDone() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let s = snap([], [todo, done])
        let fresh = item("1", status: "s5", at: now - 3600)
        let edge = item("2", status: "s5", at: now - 86400)
        let old = item("3", status: "s5", at: now - 86401)
        let open = item("4", status: "s1", at: now - 86400 * 9)
        XCTAssertTrue([fresh, edge, old].allSatisfy { s.isHiddenDone($0, afterDays: -1, now: now) }, "-1 always hides")
        XCTAssertFalse([fresh, edge, old].contains { s.isHiddenDone($0, afterDays: 0, now: now) }, "0 never hides")
        XCTAssertFalse(s.isHiddenDone(fresh, afterDays: 1, now: now))
        XCTAssertFalse(s.isHiddenDone(edge, afterDays: 1, now: now), "one day exactly still shows")
        XCTAssertTrue(s.isHiddenDone(old, afterDays: 1, now: now))
        XCTAssertFalse(s.isHiddenDone(open, afterDays: -1, now: now), "only Done items hide")
    }

    func testFinishedRule() {
        let cancelled = StatusOption(id: "s6", name: "Cancelled", color: "GREY", group: "cancelled")
        let completed = StatusOption(id: "s7", name: "Shipped", color: "GREEN", group: "completed")
        var s = snap([item("p", status: "s7"), item("c1", status: "s6", parent: "p"), item("c2", status: "s7", parent: "p"),
                      item("g1", status: "s1", parent: "c2"), item("g2", status: "s7", parent: "c2"),
                      item("q", status: "s1"), item("q1", status: "s7", parent: "q"), item("lone", status: "s6")],
                     [todo, doing, done, cancelled, completed])
        XCTAssertEqual(s.openSubItems(of: "p"), 1, "the open grandchild counts")
        XCTAssertEqual(s.openSubItems(of: "c2"), 1)
        XCTAssertFalse(s.isFinished(s.items[0]), "a Done parent with an open grandchild is not finished")
        XCTAssertTrue(s.isDoneWithOpenSubItems(s.items[0]))
        XCTAssertTrue(s.isFinished(s.items[1]), "cancelled counts as closed")
        XCTAssertTrue(s.isFinished(s.items[7]), "no sub-items")
        XCTAssertFalse(s.isFinished(s.items[5]), "an open item is not finished")
        XCTAssertTrue(s.canCloseParent(s.items[5]), "all sub-items finished, parent open")
        XCTAssertFalse(s.canCloseParent(s.items[7]), "no sub-items: no hint")
        XCTAssertTrue(s.progress(of: "p") == (1, 2), "c2 is closed but not finished")
        XCTAssertEqual(s.notDoneCount(s.rootItems), 2, "p stays in the open count")
        XCTAssertFalse(s.isHiddenDone(s.items[0], afterDays: -1), "Hide Done does not hide p")
        XCTAssertEqual(s.groupSorted(s.rootItems).map(\.id), ["q", "p", "lone"])

        s.index = [ItemStub(id: "p", parentId: nil, stateId: "s7", activityAt: nil),
                   ItemStub(id: "c3", parentId: "p", stateId: "s1", activityAt: nil)]
        XCTAssertEqual(s.openSubItems(of: "p"), 2, "a sub-item in the index only counts")
        s.statusOptions[0].localCategory = .done
        XCTAssertEqual(s.openSubItems(of: "p"), 0, "a status set to Done counts as closed")
        XCTAssertTrue(s.isFinished(s.items[0]))
    }

    func testFinishedRuleSurvivesACycle() {
        let s = snap([item("a", status: "s5", parent: "b"), item("b", status: "s1", parent: "a")], [todo, done])
        XCTAssertEqual(s.openSubItems(of: "a"), 1)
        XCTAssertFalse(s.isFinished(s.items[0]))
    }

    func testSnapshotKeepsOneItemPerId() {
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let s = snap([item("1", status: "s1", at: t0), item("2", status: "s1"), item("1", status: "s5", parent: "2", at: t0 + 60),
                      item("1", status: "s1", at: t0 + 30)], [todo, done])
        XCTAssertEqual(s.items.map(\.id), ["1", "2"])
        XCTAssertEqual(s.items[0].parentId, "2", "the newest copy wins")
        var json = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as! [String: Any]
        json["items"] = (json["items"] as! [Any]) + (json["items"] as! [Any])
        let back = try! JSONDecoder().decode(ProjectSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(back.items.map(\.id), ["1", "2"], "a saved snapshot with one id two times decodes to one")
    }

    func testSubItemTree() {
        var s = snap([item("p", status: "s1"), item("c1", status: "s5", parent: "p"), item("c2", status: "s1", parent: "p"),
                      item("g1", status: "s5", parent: "c2"), item("o", status: "s1", parent: "gone")], [todo, doing, done])
        XCTAssertEqual(s.rootItems.map(\.id), ["p", "o"], "roots keep orphans")
        XCTAssertEqual(s.listed(subItems: true).count, 5)
        XCTAssertEqual(s.children(of: "p").map(\.id), ["c2", "c1"], "children sort done last")
        XCTAssertTrue(s.progress(of: "p") == (1, 2) && s.progress(of: "c1") == (0, 0))
        XCTAssertEqual(s.ancestors(of: "g1"), ["c2", "p"])
        XCTAssertTrue(s.ancestors(of: "o").isEmpty)
        s.index = [ItemStub(id: "c1", parentId: "p", stateId: "s5", activityAt: nil),
                   ItemStub(id: "c2", parentId: "p", stateId: "s1", activityAt: nil),
                   ItemStub(id: "c3", parentId: "p", stateId: "s5", activityAt: nil)]
        XCTAssertTrue(s.progress(of: "p") == (2, 3), "the index counts sub-items that are not loaded")
        XCTAssertEqual(s.notDoneCount(s.rootItems), 2)
    }

    func testItemMatchesAndDecodes() throws {
        var i = item("9", status: nil)
        i.body = "The Relay drops events"
        XCTAssertTrue(i.matches("relay") && i.matches("ITEM 9") && i.matches("eng-9") && i.matches("  "))
        XCTAssertFalse(i.matches("nope"))
        let back = try JSONDecoder().decode(Item.self, from: JSONEncoder().encode(item("z", status: nil)))
        XCTAssertNil(back.parentId)
    }

    func testIsMine() {
        XCTAssertTrue(item("1", status: nil).isMine("BEA"))
        XCTAssertFalse(item("1", status: nil).isMine(nil))
        XCTAssertTrue(item("2", status: nil, assignees: ["Ada"], author: nil).isMine("ada"))
    }

    func testAgentMarkdown() {
        let s = snap([], [todo, doing], workspace: "ocral", title: "Fritz")
        let draft = Item(id: "u-1", key: "FRITZ-7", title: "Add quick capture", url: "https://app.plane.so/ocral/browse/FRITZ-7/",
                         statusOptionId: "s1", fields: ["Priority": "High", "Title": "Add quick capture"], assignees: [],
                         labels: ["ui"], author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(),
                         commentCount: 0, lastComment: nil, mentionsMe: false, body: "Use ⌃⌥N.\n")
        XCTAssertEqual(draft.agentMarkdown(snap: s, comments: []), """
        # Add quick capture

        Project: ocral/Fritz · Work item: FRITZ-7 · Status: Todo · Priority: High · Labels: ui
        https://app.plane.so/ocral/browse/FRITZ-7/

        Use ⌃⌥N.

        ## Comments
        _None_

        """)
        let issue = Item(id: "u-2", key: "FRITZ-5", title: "Fix login", url: "https://app.plane.so/ocral/browse/FRITZ-5/",
                         statusOptionId: "s2", fields: [:], assignees: ["ada"], labels: [], author: "bea", updatedBy: "bea",
                         updatedAt: Date(), activityAt: Date(), commentCount: 2, lastComment: nil, mentionsMe: false)
        let c1 = Comment(id: "c1", author: "bea", createdAt: Date(timeIntervalSince1970: 1_700_000_000), url: "", body: "First\nline two")
        let c2 = Comment(id: "c2", author: "ada", createdAt: Date(timeIntervalSince1970: 1_700_100_000), url: "", body: "Done?")
        XCTAssertEqual(issue.agentMarkdown(snap: s, comments: [c2, c1]), """
        # Fix login

        Project: ocral/Fritz · Work item: FRITZ-5 · Status: In progress · Assignees: @ada
        https://app.plane.so/ocral/browse/FRITZ-5/

        _No description_

        ## Comments
        - @bea (2023-11-14): First
          line two
        - @ada (2023-11-16): Done?

        """)
    }

    func testItemChangeText() {
        let c = Comment(id: "c", author: "grace", createdAt: Date(), url: "")
        XCTAssertEqual(ItemChange.status(from: "Todo", to: "Done").text, "Status: Todo → Done")
        XCTAssertEqual(ItemChange.status(from: "Done", to: "Done").text, "Status: Done (set again)")
        XCTAssertEqual(ItemChange.comments(new: 1, last: c).text, "New comment by grace")
        XCTAssertEqual(ItemChange.comments(new: 3, last: c).commentAuthor, "grace")
        let e = ActivityEntry.make(projectKey: "acme/4", itemId: "1", change: .added, actor: nil, url: "", at: Date(timeIntervalSince1970: 10))
        XCTAssertEqual(e.id, "acme/4|1|Added|10")
        XCTAssertTrue(e.unread)
    }

    func testItemPatch() {
        XCTAssertTrue(ItemPatch().isEmpty)
        XCTAssertFalse(ItemPatch(status: "s1").isEmpty)
    }
}
