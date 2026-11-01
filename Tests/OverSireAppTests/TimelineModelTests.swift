import Foundation
import OverSireCore
import XCTest
@testable import OverSireApp

final class TimelineModelTests: XCTestCase {
    let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 10, minute: 40))!

    func model(folded: Bool = false) -> TimelineModel {
        let subs = zip(JourneySample.subs, JourneySample.titles).map { TimelineModel.Lane(key: $0, title: $1) }
        return TimelineModel.build(key: JourneySample.key, title: "Events table", subs: subs, rows: JourneySample.rows(now: now, folded: folded), now: now)
    }

    func testLanesBarsAndMarks() {
        let m = model()
        XCTAssertEqual(m.lanes.map(\.key), [JourneySample.key] + JourneySample.subs)
        let c = 3   // OVERSIRE-380
        XCTAssertEqual(m.bars.filter { $0.lane == c }.map(\.kind), [.work, .wait, .work, .fix, .fix])
        XCTAssertEqual(m.bars.filter { $0.lane == c && $0.kind == .wait }.first?.note, "Waits for your question")
        XCTAssertFalse(m.bars.contains(where: \.open))
        XCTAssertEqual(m.marks.filter { $0.kind == .released }.count, 2)
        XCTAssertEqual(m.marks.filter { $0.lane == c }.map(\.kind), [.decide, .handoff, .steer, .ciFail, .ciPass, .handoff, .ciPass])
        XCTAssertEqual(m.releases.map(\.event.summary), ["v0.14.0", "cli v0.9.2"])
        XCTAssertEqual(m.end, now)
    }

    func testOpenTurnRunsToNow() {
        let m = model(folded: true)
        let open = m.bars.filter(\.open)
        XCTAssertEqual(open.count, 1)
        XCTAssertEqual(open.first?.end, now)
        XCTAssertEqual(open.first?.kind, .fix, "a turn after your review is a fix")
    }

    func testCutsFoldEmptyTime() {
        let m = model()
        let s = TimeScale.cut(m, width: 800)
        XCTAssertEqual(s.cuts.count, 5)
        for c in s.cuts { XCTAssertGreaterThan(c.length, TimeScale.gap) }
        // The segments touch, in order.
        for (a, b) in zip(s.segments, s.segments.dropFirst()) { XCTAssertEqual(a.end, b.start) }
        // No bar of agent time and no mark falls inside a cut.
        for c in s.cuts {
            XCTAssertFalse(m.marks.contains { $0.at > c.start && $0.at < c.end })
            XCTAssertFalse(m.bars.contains { $0.kind != .wait && $0.start < c.end && $0.end > c.start })
        }
        let frames = s.frames()
        XCTAssertEqual(frames.last?.1.upperBound ?? 0, 800, accuracy: 0.01)
        for (seg, r) in frames where seg.isCut { XCTAssertEqual(r.upperBound - r.lowerBound, TimeScale.cutWidth, accuracy: 0.01) }
    }

    func testScaleKeepsOrderAndMapsInsideTheSegment() {
        let m = model()
        let s = TimeScale.cut(m, width: 800)
        let times = (m.bars.flatMap { [$0.start, $0.end] } + m.marks.map(\.at)).sorted()
        let xs = times.map(s.x)
        XCTAssertEqual(xs, xs.sorted(), "a later time never maps to a smaller x")
        let frames = s.frames()
        for t in times {
            guard let (_, r) = frames.first(where: { t >= $0.0.start && t <= $0.0.end }) else { return XCTFail("no segment for \(t)") }
            XCTAssertTrue(r.contains(s.x(t)), "\(t) maps inside its segment")
        }
        let real = TimeScale.real(m, width: 800)
        XCTAssertEqual(real.cuts.count, 0)
        XCTAssertLessThan(real.x(m.start), real.x(m.end))
    }

    func testFoldWithNoSpans() {
        let segs = TimeScale.fold([], start: now.addingTimeInterval(-3600), end: now)
        XCTAssertEqual(segs.count, 1)
        XCTAssertFalse(segs[0].isCut)
    }

    func testActiveTimeIsTheUnionOfAgentBars() {
        let a = now.addingTimeInterval(-7200)
        func row(_ id: String, _ kind: Event.Kind, _ at: Date, _ s: String) -> Event {
            Event(seq: 0, seenAt: at, draft: EventDraft(id: id, at: at, kind: kind, item: "X-1", session: s, actorType: .agent, actor: "a", via: "d", summary: ""))
        }
        let rows = [row("1", .turnStarted, a, "s1"), row("2", .turnStarted, a.addingTimeInterval(1800), "s2"),
                    row("3", .turnEnded, a.addingTimeInterval(3600), "s1"), row("4", .turnEnded, a.addingTimeInterval(5400), "s2")]
        let m = TimelineModel.build(key: "X-1", subs: [], rows: rows, now: now)
        XCTAssertEqual(m.active, 5400)
    }

    func testFilters() {
        let rows = JourneySample.rows(now: now)
        XCTAssertEqual(rows.filter { TimelineFilter.all.matches($0) }.count, rows.count)
        XCTAssertTrue(rows.filter { TimelineFilter.you.matches($0) }.allSatisfy { $0.actorType == .human })
        XCTAssertTrue(rows.filter { TimelineFilter.ci.matches($0) }.allSatisfy { $0.kind.rawValue.hasPrefix("ci.") })
        XCTAssertEqual(rows.filter { TimelineFilter.git.matches($0) }.map(\.kind).filter { $0 == .gitCommit }.count, 3)
        XCTAssertFalse(rows.filter { TimelineFilter.system.matches($0) }.contains { $0.kind == .ciCompleted })
    }
}
