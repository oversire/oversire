import Foundation
import OverSireCore
import XCTest
@testable import OverSireApp

final class CatchUpTests: XCTestCase {
    // Sun 1 Nov 10:40, local time.
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 10, minute: 40))!

    func build(folded: Bool = false, since: Date? = nil, closed: Set<String> = [], notPushed: [String] = []) -> CatchUp {
        let rows = JourneySample.rows(now: now, folded: folded)
        let subs = zip(JourneySample.subs, JourneySample.titles).map { CatchUpBuilder.Sub(key: $0, title: $1, closed: closed.contains($0)) }
        let s = since ?? lastLook(rows)
        return CatchUpBuilder(key: JourneySample.key, subs: subs, rows: rows, since: s, now: now, notPushed: notPushed).build()
    }

    /// The last item.viewed row, as the page finds it.
    func lastLook(_ rows: [Event]) -> Date? {
        let j = ItemJournal(reader: { nil }, lookPath: nil)
        j.seed(JourneySample.key, rows)
        return j.since(JourneySample.key, before: nil, opened: now)
    }

    func testBoardAndNow() {
        let c = build(notPushed: ["cli main +2"])
        XCTAssertEqual(c.board.map(\.mark), [.merged, .merged, .yours, .merged])
        XCTAssertEqual(c.board.map(\.ships), [["v0.14.0"], ["cli v0.9.2"], [], ["v0.14.0"]])
        XCTAssertEqual(c.merged, 3)
        XCTAssertEqual(c.shipped, 3)
        XCTAssertEqual(c.board[2].note, "code review round 2 · not merged")
        XCTAssertEqual(c.now?.key, "OVERSIRE-380")
        XCTAssertEqual(c.now?.mark, .yours)
        XCTAssertEqual(c.now?.action, .reviewCode)
        XCTAssertEqual(c.now?.text, "Your turn: 380: code review round 2 · not merged")
        XCTAssertEqual(c.now?.since, JourneySample.day(3, 16, 40, now))
        XCTAssertEqual(c.pending.map(\.kind), [.review, .notPushed])
        XCTAssertEqual(c.pending.map(\.text), ["Review 380, code review round 2.", "Not pushed: cli main +2"])
        XCTAssertEqual(c.lastWords?.text, "Keep the comments in SQLite. Drop the JSON copy.")
        XCTAssertEqual(c.decided.map(\.text), ["Approved 378", "Approved 381", "Approved 379", "SQLite"])
        XCTAssertEqual(c.decided.last?.reason, "One store for the daemon.")
    }

    func testCountsSinceYourLastLook() {
        let c = build()
        XCTAssertEqual(c.since, JourneySample.since(now: now))
        XCTAssertFalse(c.folded)
        XCTAssertEqual(c.counts, CatchUp.Counts(commits: 3, ciFails: 1, ciFixed: 1, releases: 1, merges: 0, questions: 0))
        XCTAssertEqual(c.counts.merges, 0, "a zero count stays")
        XCTAssertFalse(c.fresh.contains { $0.kind == .itemViewed })
        XCTAssertEqual(c.lines.map(\.mark), ["✕", "◆", "★"])
        XCTAssertEqual(c.lines.first?.text, "380: cli test #2243 failed: TestMergePartialFail")
    }

    func testFoldsWhenNothingIsNew() {
        let c = build(folded: true)
        XCTAssertTrue(c.folded)
        XCTAssertEqual(c.fresh, [])
        XCTAssertEqual(c.now?.mark, .works)
        XCTAssertEqual(c.now?.text, "Agent works on 380 · turn 6")
        XCTAssertEqual(c.board[2].mark, .works)
    }

    func testNoLookShowsNoFreshRows() {
        let rows = JourneySample.rows(now: now).filter { $0.kind != .itemViewed }
        let c = CatchUpBuilder(key: JourneySample.key, rows: rows, since: nil, now: now).build()
        XCTAssertFalse(c.folded)
        XCTAssertEqual(c.fresh, [])
        XCTAssertTrue(c.counts.isZero)
    }

    func testClosedTodoShowsDone() {
        let c = CatchUpBuilder(key: "OVERSIRE-377", subs: [.init(key: "OVERSIRE-385", title: "Docs", closed: true)], rows: [], since: nil, now: now).build()
        XCTAssertEqual(c.board.first?.mark, .merged)
        XCTAssertEqual(c.board.first?.note, "done")
    }

    func testRecapDropsALineWithNoValidId() {
        let rows = JourneySample.rows(now: now)
        let ok = rows.first { $0.kind == .ciCompleted }!.id
        let reply = """
        {"lines":[{"text":"CI failed, then passed.","ids":["\(ok)"]},{"text":"Made up.","ids":["nope"]},{"text":"No ids."}],
         "decided":[{"text":"SQLite","reason":"One store.","ids":["nope","\(ok)"]}],
         "choices":[{"text":"Bad","ids":[]}]}
        """
        let r = Recap.parse(reply, rows: rows, hash: "h")
        XCTAssertEqual(r?.lines.map(\.text), ["CI failed, then passed."])
        XCTAssertEqual(r?.decided.map(\.ids), [[ok]])
        XCTAssertEqual(r?.decided.first?.reason, "One store.")
        XCTAssertEqual(r?.choices, [])
        XCTAssertNil(Recap.parse("not json", rows: rows, hash: "h"))
    }

    func testRecapCacheNeedsTheSameRows() {
        let job = RecapJob(path: nil, ai: { nil })
        let rows = JourneySample.rows(now: now)
        var r = JourneySample.recap(rows: rows)
        r.hash = Recap.hash(rows)
        job.put("oversire-377", r)
        XCTAssertEqual(job.recap("OVERSIRE-377", rows: rows)?.lines.count, 3)
        XCTAssertNil(job.recap("OVERSIRE-377", rows: Array(rows.dropLast())), "new rows make the recap old")
        job.confirm("OVERSIRE-377", r.choices[0])
        XCTAssertEqual(job.recap("OVERSIRE-377", rows: rows)?.choices, [])
    }
}
