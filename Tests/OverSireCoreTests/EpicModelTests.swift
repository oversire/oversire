import XCTest
@testable import OverSireCore

final class EpicModelTests: XCTestCase {
    let todo = StatusOption(id: "s1", name: "Todo", color: "", group: "unstarted")
    let doing = StatusOption(id: "s2", name: "In Progress", color: "", group: "started")
    let review = StatusOption(id: "s3", name: "In Review", color: "", group: "started")
    let done = StatusOption(id: "s4", name: "Done", color: "", group: "completed")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let project = ProjectRef(account: AccountID(provider: "plane", id: "acme"), id: "4", key: "ENG")

    func epic(_ id: String, _ title: String = "Epic", state: EpicState = .active, target: Date? = nil, key: String? = nil) -> Epic {
        Epic(id: EpicID(rawValue: id), key: key, title: title, state: state, targetDate: target, url: "https://plane/\(id)", project: project)
    }

    func item(_ id: String, _ status: String, epic: String? = nil, priority: String? = nil, title: String? = nil) -> Item {
        Item(id: id, key: "ENG-\(id)", title: title ?? "Item \(id)", url: "https://plane/\(id)", statusOptionId: status,
             fields: priority.map { ["Priority": $0] } ?? [:], assignees: [], labels: [], author: "bea", updatedBy: "bea",
             updatedAt: now, activityAt: now, commentCount: 0, lastComment: nil, mentionsMe: false, epicId: epic.map(EpicID.init(rawValue:)))
    }

    func stub(_ id: String, _ status: String, epic: String?, key: String? = nil) -> ItemStub {
        ItemStub(id: id, parentId: nil, stateId: status, activityAt: nil, epicId: epic.map(EpicID.init(rawValue:)), key: key)
    }

    func snap(_ items: [Item] = [], index: [ItemStub]? = nil, epics: [Epic]? = nil) -> ProjectSnapshot {
        ProjectSnapshot(summary: ProjectSummary(ref: project, identifier: "ENG", title: "Board", url: "", closed: false),
                        statusOptions: [todo, doing, review, done], items: items, fetchedAt: now, index: index, epics: epics)
    }

    func testEpicIDCodesAsAString() throws {
        let id = try JSONDecoder().decode(EpicID.self, from: Data(#""m1""#.utf8))
        XCTAssertEqual(id, "m1")
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(id), as: UTF8.self), #""m1""#)
    }

    func testEventKeyFollowsTheKeyPattern() {
        let e = epic("m1")
        XCTAssertEqual(e.eventKey, "EPIC-3EA344900703", "the first 12 hex characters of SHA-256(\"acme/4m1\")")
        XCTAssertNotNil(e.eventKey.wholeMatch(of: /[A-Z0-9][A-Z0-9_-]*/))
        XCTAssertLessThanOrEqual(e.eventKey.count, 60)
        XCTAssertEqual(e.eventKey, epic("m1").eventKey)
        let other = Epic(id: "m1", title: "Epic", state: .active, url: "", project: ProjectRef(account: project.account, id: "5"))
        XCTAssertNotEqual(e.eventKey, other.eventKey)
        XCTAssertEqual(epic("m1", key: "proj-5").eventKey, "PROJ-5")
    }

    func testSnapshotDecodesWithoutEpics() throws {
        let json = """
        {"summary":{"ref":{"account":{"provider":"plane","id":"acme"},"id":"4"},"identifier":"ENG","title":"Board","url":"","closed":false},
         "statusOptions":[],"fetchedAt":0,
         "items":[{"id":"1","key":"ENG-1","title":"T","url":"u","fields":{},"assignees":[],"labels":[],"updatedAt":0,"activityAt":0,
                   "commentCount":0,"mentionsMe":false}],
         "index":[{"id":"1"}]}
        """
        let s = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(s.epics)
        XCTAssertNil(s.items[0].epicId)
        XCTAssertNil(s.items[0].otherEpicIds)
        XCTAssertNil(s.index?[0].key)
        XCTAssertNil(s.index?[0].epicId)
    }

    func testSnapshotRoundTripsEpics() throws {
        var i = item("1", "s1", epic: "m1")
        i.otherEpicIds = ["m2"]
        let s = snap([i], epics: [epic("m1", target: now)])
        let back = try JSONDecoder().decode(ProjectSnapshot.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.epics, s.epics)
        XCTAssertEqual(back.items[0].epicId, "m1")
        XCTAssertEqual(back.items[0].otherEpicIds, ["m2"])
    }

    func testEpicIdOfReadsItemsThenIndex() {
        let s = snap([item("1", "s1", epic: "m1")], index: [stub("1", "s1", epic: "m9"), stub("2", "s1", epic: "m2"), stub("3", "s1", epic: nil)])
        XCTAssertEqual(s.epicId(of: "1"), "m1", "the loaded item wins")
        XCTAssertEqual(s.epicId(of: "2"), "m2")
        XCTAssertNil(s.epicId(of: "3"))
        XCTAssertNil(s.epicId(of: "unknown"))
        XCTAssertEqual(s.members(of: "m2").map(\.id), ["2"])
    }

    func testRollupCountsIndexOnlyMembers() {
        let e = epic("m1")
        let loaded = (1...4).map { item("a\($0)", "s4", epic: "m1") } + [item("a5", "s2", epic: "m1")]
        let index = loaded.map { stub($0.id, $0.statusOptionId!, epic: "m1") }
            + [stub("b1", "s4", epic: "m1", key: "ENG-11"), stub("b2", "s4", epic: "m1"), stub("b3", "s1", epic: "m1")]
        let r = snap(loaded, index: index, epics: [e]).rollup(e, now: now)
        XCTAssertEqual([r.done, r.total, r.started, r.open], [6, 8, 1, 2])
        XCTAssertFalse(r.readyToClose)
    }

    func testRollupLate() {
        let cal = Calendar.current
        let past = cal.date(byAdding: .day, value: -2, to: now)!
        func rollup(_ e: Epic, _ status: String = "s1") -> EpicRollup {
            snap([item("1", status, epic: "m1")], epics: [e]).rollup(e, now: now)
        }
        XCTAssertEqual(rollup(epic("m1", target: past)).lateDays, 2)
        XCTAssertNil(rollup(epic("m1", target: past), "s4").lateDays, "all done")
        XCTAssertNil(rollup(epic("m1")).lateDays, "no target")
        XCTAssertNil(rollup(epic("m1", state: .canceled, target: past)).lateDays)
        XCTAssertNil(rollup(epic("m1", target: now)).lateDays, "the target is today")
    }

    func testReadyToClose() {
        func ready(_ e: Epic, _ items: [Item]) -> Bool { snap(items, epics: [e]).rollup(e, now: now).readyToClose }
        let closed = [item("1", "s4", epic: "m1"), item("2", "s4", epic: "m1")]
        XCTAssertTrue(ready(epic("m1"), closed))
        XCTAssertFalse(ready(epic("m1"), []))
        XCTAssertFalse(ready(epic("m1", state: .done), closed))
        XCTAssertFalse(ready(epic("m1"), closed + [item("3", "s1", epic: "m1")]))
    }

    func testNextReadyOrder() {
        let items = [item("started", "s2", epic: "m1", priority: "Urgent"), item("review", "s3", epic: "m1", priority: "Urgent"),
                     item("done", "s4", epic: "m1", priority: "Urgent"), item("blocked", "s1", epic: "m1", priority: "Urgent"),
                     item("other", "s1", epic: "m2", priority: "Urgent"),
                     item("high", "s1", epic: "m1", priority: "High"), item("urgent", "s1", epic: "m1", priority: "Urgent"),
                     item("b-low", "s1", epic: "m1", priority: "Low", title: "B"), item("a-low", "s1", epic: "m1", priority: "Low", title: "A")]
        let s = snap(items, epics: [epic("m1")])
        XCTAssertEqual(s.nextReady(in: "m1", blocked: ["blocked"]).map(\.id), ["urgent", "high", "a-low", "b-low"])
        XCTAssertEqual(s.rollup(epic("m1"), blocked: ["blocked"], now: now).next, ["urgent", "high", "a-low", "b-low"])
    }

    func testEpicGroupsPutNoEpicLast() {
        let t = { (d: Int) in Calendar.current.date(byAdding: .day, value: d, to: self.now)! }
        let epics = [epic("a", "Zed", target: t(20)), epic("b", "Beta", target: t(5)), epic("c", "Alpha"),
                     epic("d", "Old", state: .done), epic("e", "Empty and closed", state: .canceled)]
        let items = [item("1", "s1", epic: "b"), item("2", "s1", epic: "a"), item("3", "s4", epic: "d"), item("4", "s1"),
                     item("5", "s1", epic: "gone")]
        let groups = snap(items, epics: epics).epicGroups(items)
        XCTAssertEqual(groups.map { $0.epic?.id.rawValue }, ["b", "a", "c", "d", nil])
        XCTAssertEqual(groups.map { $0.items.map(\.id) }, [["1"], ["2"], [], ["3"], ["4", "5"]])
        XCTAssertEqual(snap(items).epicGroups(items).map { $0.epic?.id }, [nil], "no epics loaded: one group")
    }

    func testEpicPatchIsEmpty() {
        XCTAssertTrue(EpicPatch().isEmpty)
        XCTAssertFalse(EpicPatch(clear: [.lead]).isEmpty)
        XCTAssertFalse(EpicPatch(state: .done).isEmpty)
    }

    func testBurnUpFromRows() {
        let key = "EPIC-3EA344900703"
        var seq: Int64 = 0
        func row(_ kind: Event.Kind, _ item: String, _ minute: Int, parent: String? = nil, group: String? = nil) -> Event {
            seq += 1
            let d = EventDraft(id: "x:\(seq)", at: now.addingTimeInterval(Double(minute) * 60), kind: kind, item: item, parentItem: parent,
                               actorType: .provider, actor: "plane", via: "poll", summary: "",
                               payload: group.map { ["group": .string($0)] })
            return Event(seq: seq, seenAt: now, draft: d)
        }
        let rows = [row(.epicItemAdded, "ENG-1", 1, parent: key), row(.epicItemAdded, "ENG-2", 2, parent: key),
                    row(.epicItemAdded, "ENG-3", 3, parent: key), row(.itemStateChanged, "ENG-1", 4, group: "completed"),
                    row(.epicItemRemoved, "ENG-3", 5, parent: key), row(.itemStateChanged, "ENG-2", 6, group: "cancelled"),
                    row(.itemStateChanged, "ENG-9", 7, group: "completed"),
                    row(.epicItemAdded, "ENG-8", 8, parent: "EPIC-OTHER")]
        let e = epic("m1", target: now)
        let current = snap([item("1", "s4", epic: "m1"), item("2", "s4", epic: "m1")], epics: [e]).rollup(e, now: now)
        // The rows come in a different order than their times.
        let b = EpicBurnUp.build(epicKey: key, rows: rows.reversed(), now: now.addingTimeInterval(3600), current: current)
        XCTAssertEqual(b.points.map(\.scope), [1, 2, 3, 3, 2, 2, 2])
        XCTAssertEqual(b.points.map(\.done), [0, 0, 0, 1, 1, 2, 2])
        XCTAssertEqual(b.points.last, EpicBurnUp.Point(at: now.addingTimeInterval(3600), scope: 2, done: 2))
        XCTAssertEqual(b.target, now)
    }
}
