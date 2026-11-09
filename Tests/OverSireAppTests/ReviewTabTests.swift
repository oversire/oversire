import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class ReviewTabTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_793_000_000)
    private func ago(_ m: Double) -> Date { t0.addingTimeInterval(-m * 60) }

    private func summary(_ key: String, _ kind: ReviewKind = .code, machine: String = "mba", state: ReviewState = .ready,
                         ready: Double, repos: [ReviewRepo] = [], pending: Int = 0) -> ReviewSummary {
        ReviewSummary(key: key, kind: kind, machine: machine, state: state, pending: pending, root: "/src",
                      repos: repos, readyAt: ago(ready), updatedAt: ago(ready))
    }

    private func repo(_ name: String, _ merge: MergeMode, behind: Int = 0) -> ReviewRepo {
        ReviewRepo(name: name, branch: "b", base: "main", ahead: 1, behind: behind, merge: merge)
    }

    private func book(_ sources: [FakeReviewSource], bus: ChangeBus = ChangeBus(schedule: { _, _ in })) -> ReviewBook {
        ReviewBook(sources: { sources }, bus: bus)
    }

    // MARK: Review tab

    func testRowsOfAllMachinesGoIntoGroupsOldestFirst() async {
        let mba = FakeReviewSource(machine: "mba"), mini = FakeReviewSource(machine: "mini")
        mba.seed([ReviewDetail(summary: summary("A-1", ready: 10)),
                  ReviewDetail(summary: summary("A-2", .plan, ready: 50)),
                  ReviewDetail(summary: summary("A-3", state: .merged, ready: 90))])
        mini.seed([ReviewDetail(summary: summary("B-1", machine: "mini", ready: 30)),
                   ReviewDetail(summary: summary("B-2", machine: "mini", state: .waiting, ready: 5)),
                   ReviewDetail(summary: summary("B-3", machine: "mini", state: .conflict, ready: 70))])
        let b = book([mba, mini])
        await b.refresh()

        XCTAssertEqual(b.groups.map(\.group), [.plans, .code, .waiting, .conflict])
        XCTAssertEqual(b.groups.first { $0.group == .code }?.rows.map(\.key), ["B-1", "A-1"], "the oldest code review is first")
        XCTAssertEqual(b.groups.map { $0.rows.count }, [1, 2, 1, 1])
        XCTAssertFalse(b.rows.contains { $0.key == "A-3" }, "a merged review shows in no group")
        XCTAssertEqual(b.yourTurn, 3, "a plan and two code reviews wait for you")
        XCTAssertEqual(b.review("B-1")?.machine, "mini")
    }

    func testAnEmptyGroupIsLeftOut() async {
        let mba = FakeReviewSource(machine: "mba")
        mba.seed([ReviewDetail(summary: summary("A-1", ready: 1))])
        let b = book([mba])
        await b.refresh()
        XCTAssertEqual(b.groups.map(\.group), [.code])
    }

    func testAFailedReadKeepsTheRowsOfTheMachine() async {
        let mba = FakeReviewSource(machine: "mba")
        mba.seed([ReviewDetail(summary: summary("A-1", ready: 1))])
        let b = book([mba])
        await b.refresh()
        mba.failure = ProviderError.transport("down")
        await b.refresh()
        XCTAssertEqual(b.rows.map(\.key), ["A-1"])
    }

    func testAFailedReadTellsTheErrorAndTheAgeOfTheRows() async {
        let mba = FakeReviewSource(machine: "mba")
        mba.seed([ReviewDetail(summary: summary("A-1", ready: 1))])
        var clock = t0
        let b = ReviewBook(sources: { [mba] }, bus: ChangeBus(schedule: { _, _ in }), log: IOLogTests.Lines(), now: { clock })
        await b.refresh()
        XCTAssertEqual(b.health("mba"), ReviewHealth(read: t0))
        XCTAssertNil(b.health("mba").notice(machine: "mba", now: t0))
        XCTAssertTrue(b.failureRows().isEmpty)

        mba.failure = ProviderError.transport("The request timed out.")
        clock = t0.addingTimeInterval(3 * 3600)
        await b.refresh()
        XCTAssertEqual(b.health("mba"), ReviewHealth(read: t0, error: "The request timed out."), "the time of the last good read stays")
        XCTAssertEqual(b.failing, ["mba"])
        let n = try? XCTUnwrap(b.health("mba").notice(machine: "mba", now: clock))
        XCTAssertEqual(n?.title, "The reviews of mba did not load: the request timed out.")
        XCTAssertEqual(n?.body, "This data is from 3 h ago. OverSire tries again each minute.")
        XCTAssertEqual(b.failureRows().count, 1)
        XCTAssertEqual(b.rows.map(\.key), ["A-1"])

        mba.failure = nil
        await b.refresh(machine: "mba")
        XCTAssertEqual(b.health("mba"), ReviewHealth(read: clock))
        XCTAssertEqual(b.failing, [])
    }

    func testAMachineWithNoGoodReadSaysSo() {
        let h = ReviewHealth(read: nil, error: "Could not connect to the server.")
        XCTAssertEqual(h.notice(machine: "mbp", now: t0)?.body, "No read worked yet. OverSire tries again each minute.")
    }

    func testThreeFailedReadsInARowOpenAProblemAndAGoodReadClearsIt() async {
        let mba = FakeReviewSource(machine: "mba")
        mba.seed([ReviewDetail(summary: summary("A-1", ready: 1))])
        let lines = IOLogTests.Lines()
        let b = ReviewBook(sources: { [mba] }, bus: ChangeBus(schedule: { _, _ in }), log: lines)
        mba.failure = ProviderError.transport("The request timed out.")
        for _ in 0..<3 { await b.refresh() }
        let problems = ProblemTracker(path: nil)
        for e in lines.all { problems.record(e) }
        // A good HTTP line of an other route of the same daemon does not touch the job.
        problems.record(LogEntry(level: .ok, area: .net, job: "HTTP", host: "mba", message: "POST /v1/leases/automations 200"))
        XCTAssertEqual(problems.open.map(\.job), ["Reviews read"])
        XCTAssertEqual(problems.open.first?.host, "mba")
        XCTAssertEqual(problems.open.first?.message, "The request timed out.")

        mba.failure = nil
        await b.refresh()
        problems.record(try! XCTUnwrap(lines.all.last))
        XCTAssertTrue(problems.open.isEmpty)
    }

    func testAMachineThatLeftLosesItsRows() async {
        let mba = FakeReviewSource(machine: "mba"), mini = FakeReviewSource(machine: "mini")
        mba.seed([ReviewDetail(summary: summary("A-1", ready: 1))])
        mini.seed([ReviewDetail(summary: summary("B-1", machine: "mini", ready: 1))])
        var list = [mba, mini]
        let b = ReviewBook(sources: { list }, bus: ChangeBus(schedule: { _, _ in }))
        await b.refresh()
        XCTAssertEqual(b.rows.count, 2)
        list = [mba]
        await b.refresh()
        XCTAssertEqual(b.rows.map(\.key), ["A-1"])
    }

    func testAReviewFrameReadsTheMachineAgainAndPostsAChange() async {
        let mba = FakeReviewSource(machine: "mba")
        mba.seed([ReviewDetail(summary: summary("A-1", ready: 1))])
        var changes: [DataChange] = []
        let bus = ChangeBus(schedule: { _, f in f() })
        let watch = bus.observe { changes.append($0) }
        let b = book([mba], bus: bus)
        await b.refresh()
        XCTAssertEqual(b.rows.count, 1)

        mba.seed([ReviewDetail(summary: summary("A-2", .plan, ready: 0))])
        await b.apply(ReviewEvent(event: .ready, key: "A-2", kind: .plan, machine: "mba"), from: "mba")
        XCTAssertEqual(b.rows.map(\.key), ["A-1", "A-2"])
        XCTAssertEqual(b.yourTurn, 2)
        XCTAssertTrue(changes.contains { $0.domains.contains(.reviews) && $0.items.contains("A-2") })
        XCTAssertEqual(mba.calls.filter { $0 == "reviews" }.count, 2)
        _ = watch
    }

    func testTheRowRouteOfEachState() {
        XCTAssertEqual(ReviewRow.route(summary("A-1", .plan, ready: 1)), .item("A-1", .plan))
        XCTAssertEqual(ReviewRow.route(summary("A-1", ready: 1)), .item("A-1", .changes))
        XCTAssertEqual(ReviewRow.route(summary("A-1", state: .waiting, ready: 1)), .item("A-1", .session))
        XCTAssertEqual(ReviewRow.route(summary("A-1", state: .conflict, ready: 1)), .item("A-1", .changes))
    }

    func testTheMarksUseAGlyphAndAWord() {
        XCTAssertEqual(ReviewMark(summary("A", ready: 1)).glyph, "◆")
        XCTAssertEqual(ReviewMark(summary("A", state: .waiting, ready: 1)).glyph, "●")
        XCTAssertEqual(ReviewMark(summary("A", state: .conflict, ready: 1)).word, "Conflict")
        XCTAssertEqual(ReviewMark(repo("x", .fastForward)).glyph, "✓")
        XCTAssertEqual(ReviewMark(repo("x", .rebase, behind: 2)).word, "main moved 2")
        XCTAssertEqual(ReviewMark(repo("x", .conflict)).glyph, "✕")
    }

    func testTheMenuIconCountsTheReviewsOfYourTurn() {
        let s = MenuIconState(runs: [], waitingAgents: 0, unread: 0, unreadDot: false, reviews: 2)
        XCTAssertTrue(s.label.contains("2 reviews to do"), s.label)
    }

    // MARK: Line picks

    func testAClickPicksOneLineAndAShiftClickARange() {
        let one = LinePick(repo: "r", path: "a.go", side: .new, line: 14)
        XCTAssertEqual(one.anchor, .code(repo: "r", path: "a.go", line: 14, from: nil, side: .new))
        XCTAssertEqual(one.label, "line 14")

        let up = one.click(11, side: .new, shift: true)
        XCTAssertEqual(up.anchor, .code(repo: "r", path: "a.go", line: 14, from: 11, side: .new), "the anchor is the last line, from the first")
        XCTAssertEqual(up.label, "lines 11–14")
        XCTAssertTrue(up.contains(12, side: .new))
        XCTAssertFalse(up.contains(12, side: .old))

        XCTAssertEqual(one.click(20, side: .old, shift: true), LinePick(repo: "r", path: "a.go", side: .old, line: 20), "a shift-click on the other side starts a new pick")
        XCTAssertEqual(up.click(30, side: .new, shift: false).label, "line 30")
    }

    func testTheSideOfADiffLine() {
        XCTAssertEqual(LinePick.place(DiffLine(kind: .del, old: 9, text: "x"))?.side, .old)
        XCTAssertEqual(LinePick.place(DiffLine(kind: .add, new: 10, text: "x"))?.line, 10)
        XCTAssertEqual(LinePick.place(DiffLine(kind: .ctx, old: 8, new: 11, text: "x"))?.side, .new)
    }

    // MARK: Desk

    private func desk(_ src: FakeReviewSource, tracker: FakeTracking? = nil) async -> ReviewDesk {
        let s = summary("A-1", ready: 1, repos: [repo("oversire", .fastForward)])
        src.seed([ReviewDetail(summary: s, files: [ReviewFile(repo: "oversire", path: "a.go", status: .modified, added: 1, removed: 1)])])
        let d = ReviewDesk(summary: s, source: src, tracker: tracker, bus: ChangeBus(schedule: { _, _ in }))
        await d.load()
        return d
    }

    func testTheBatchCountsPendingCommentsAndASubmitLocksThem() async throws {
        let src = FakeReviewSource(machine: "mba")
        let d = await desk(src)
        let ok1 = await d.add(.code(repo: "oversire", path: "a.go", line: 3, side: .new), text: "one")
        let ok2 = await d.add(.code(repo: "oversire", path: "a.go", line: 9, from: 7, side: .new), text: "two")
        XCTAssertTrue(ok1 && ok2)
        XCTAssertEqual(d.pending.count, 2)
        XCTAssertEqual(d.pendingByFile["oversire/a.go"], 2)
        XCTAssertEqual(d.nextRound, 1)
        XCTAssertTrue(d.pending.allSatisfy(ReviewDesk.canEdit))

        let round = try await d.submit(.requestChanges, summary: "  ", post: false)
        XCTAssertEqual(round.count, 2)
        XCTAssertEqual(d.pending.count, 0)
        XCTAssertEqual(d.comments.map(\.state), [.submitted, .submitted])
        XCTAssertFalse(d.comments.contains(where: ReviewDesk.canEdit), "a submitted comment belongs to its round")
        let edited = await d.edit(d.comments[0], text: "changed")
        XCTAssertFalse(edited)
        XCTAssertFalse(src.calls.contains { $0.hasPrefix("edit") })
    }

    func testASubmitSendsTheAgentOnlyWhenTheDaemonKnowsNone() async throws {
        let src = FakeReviewSource(machine: "mba")
        let d = await desk(src)
        let spec = AgentLaunchSpec(cli: "claude", profile: "claude")
        d.agent = { _ in spec }
        _ = await d.add(.code(repo: "oversire", path: "a.go", line: 3, side: .new), text: "one")
        _ = try await d.submit(.requestChanges, summary: nil, post: false)
        _ = try await d.submit(.approve, summary: nil, post: false)
        XCTAssertEqual(src.launches, [spec, nil], "no session known: the agent goes; an approve starts nothing")
    }

    func testDiscardAllDeletesOnlyThePendingComments() async {
        let src = FakeReviewSource(machine: "mba")
        let d = await desk(src)
        _ = await d.add(.code(repo: "oversire", path: "a.go", line: 3), text: "one")
        _ = await d.add(.code(repo: "oversire", path: "a.go", line: 4), text: "two")
        let ok = await d.discardAll()
        XCTAssertTrue(ok)
        XCTAssertEqual(d.pending.count, 0)
        XCTAssertEqual(d.comments.count, 0)
    }

    func testAnApprovedPlanMovesTheItemToTodoAndPostsTheRound() async throws {
        let src = FakeReviewSource(machine: "mba")
        let tracker = FakeTracking()
        let s = summary("P-1", .plan, ready: 1)
        src.seed([ReviewDetail(summary: s, plan: PlanDoc(key: "P-1", version: 1, blocks: [PlanBlock(id: "goal", heading: "Goal", markdown: "x")]))])
        let d = ReviewDesk(summary: s, source: src, tracker: tracker, bus: ChangeBus(schedule: { _, _ in }))
        await d.load()
        _ = await d.add(.plan(block: "goal"), text: "Shorter.")
        _ = try await d.submit(.approve, summary: nil, post: true)
        let posts = await MainActor.run { tracker.posts }
        let moves = await MainActor.run { tracker.moves }
        XCTAssertEqual(posts.count, 1)
        XCTAssertTrue(posts[0].contains("Plan review round 1 · Approve"), posts[0])
        XCTAssertTrue(posts[0].contains("Plan section \"Goal\""), posts[0])
        XCTAssertEqual(moves, ["P-1 unstarted"])
    }

    func testAMergeWithSetDoneMovesTheItemToDone() async throws {
        let src = FakeReviewSource(machine: "mba")
        let tracker = FakeTracking()
        let d = await desk(src, tracker: tracker)
        let r = try await d.merge(removeGroup: true, setDone: true)
        XCTAssertTrue(r.merged)
        let moves = await MainActor.run { tracker.moves }
        XCTAssertEqual(moves, ["A-1 completed"])
    }

    // MARK: Merge sheet

    func testTheMergeChoiceOfEachRepo() {
        XCTAssertEqual(MergeChoice(repo("a", .fastForward)), .merge)
        XCTAssertEqual(MergeChoice(repo("a", .rebase)), .rebase)
        XCTAssertEqual(MergeChoice(repo("a", .conflict)), .fix)
        XCTAssertEqual(MergeChoice.primary([repo("a", .fastForward), repo("b", .fastForward)]), .merge)
        XCTAssertEqual(MergeChoice.primary([repo("a", .fastForward), repo("b", .rebase)]), .rebase)
        XCTAssertEqual(MergeChoice.primary([repo("a", .rebase), repo("b", .conflict)]), .fix)
        XCTAssertEqual(MergeChoice.fix.title, "Fix with agent")
        XCTAssertEqual(MergeChoice.rebase.title, "Rebase and merge")
    }

    // MARK: Folds (OVERSIRE-441)

    private func foldDesk(_ src: FakeReviewSource) async -> (ReviewDesk, ReviewFile) {
        let s = summary("A-1", ready: 1, repos: [repo("oversire", .fastForward)])
        let f = ReviewFile(repo: "oversire", path: "a.go", status: .modified, added: 1, removed: 0)
        let lines = (1...99).map { n in n == 50 ? DiffLine(kind: .add, new: 50, text: "a") : DiffLine(kind: .ctx, old: n > 50 ? n - 1 : n, new: n, text: "\tc") }
        let d = FileDiff(repo: "oversire", path: "a.go", status: .modified, full: true,
                         hunks: [DiffHunk(oldStart: 1, oldLines: 98, newStart: 1, newLines: 99, lines: lines)])
        src.seed([ReviewDetail(summary: s, files: [f])], diffs: [d])
        let desk = ReviewDesk(summary: s, source: src, tracker: nil, bus: ChangeBus(schedule: { _, _ in }))
        await desk.load()
        await desk.diff(f)
        return (desk, f)
    }

    func testTheDeskAsksForTheWholeFile() async {
        let src = FakeReviewSource(machine: "mba")
        _ = await foldDesk(src)
        XCTAssertTrue(src.calls.contains("diff A-1 oversire/a.go full"), "\(src.calls)")
    }

    func testOpenedLinesStayOnTheDesk() async throws {
        let src = FakeReviewSource(machine: "mba")
        let (d, f) = await foldDesk(src)
        let fold = try XCTUnwrap(d.fold(f))
        let top = try XCTUnwrap(fold.items(split: false, threads: []).lazy.compactMap { i -> DiffGap? in if case .gap(let g) = i { return g }; return nil }.first)
        XCTAssertEqual(d.expand(f, top, .up), 47)
        XCTAssertEqual(d.opened[f.id], IndexSet(integersIn: 27...46))
        d.wholeFile = true
        d.wholeFile = false
        XCTAssertEqual(d.fold(f)?.opened, IndexSet(integersIn: 27...46), "Full file off keeps the opened lines")
    }

    // MARK: Steps (OVERSIRE-442)

    func testNextMarksTheFileAndFindsTheNextFileThatIsNotViewed() async throws {
        let src = FakeReviewSource(machine: "mba")
        let s = summary("A-1", ready: 1, repos: [repo("oversire", .fastForward)])
        let files = ["a.go", "b.go", "c.go"].map { ReviewFile(repo: "oversire", path: $0, status: .modified, added: 1, removed: 0) }
        var stale = files
        stale[0].viewed = false
        stale[1].viewed = true
        stale[2].viewedStale = true
        src.seed([ReviewDetail(summary: s, files: stale)])
        let d = ReviewDesk(summary: s, source: src, tracker: nil, bus: ChangeBus(schedule: { _, _ in }))
        await d.load()

        XCTAssertEqual(d.nextUnviewed(after: "oversire/a.go")?.path, "c.go", "It skips a viewed file")
        XCTAssertEqual(d.nextUnviewed(after: "oversire/c.go")?.path, "a.go", "It wraps")
        XCTAssertFalse(d.allViewed)

        d.filter.hideViewed = true
        XCTAssertEqual(d.tree.shown.map(\.path), ["a.go", "c.go"], "A stale file counts as not viewed")
        d.filter = FileFilter()
        d.filter.hideNotViewed = true
        XCTAssertEqual(d.tree.shown.map(\.path), ["b.go"])
        d.filter = FileFilter()

        for f in d.files where !f.viewed { _ = await d.setViewed(f, true) }
        XCTAssertTrue(d.allViewed)
        XCTAssertNil(d.nextUnviewed(after: "oversire/a.go"))
        XCTAssertFalse(d.files.contains(where: \.isStale), "A new mark clears the tag")
    }

    func testAStepAcrossFilesLoadsTheNextDiffAndLandsOnItsFirstChange() async throws {
        let src = FakeReviewSource(machine: "mba")
        let s = summary("A-1", ready: 1, repos: [repo("oversire", .fastForward)])
        func file(_ path: String, adds: [Int]) -> (ReviewFile, FileDiff) {
            var shift = 0
            let lines = (1...60).map { n -> DiffLine in
                if adds.contains(n) { shift += 1; return DiffLine(kind: .add, new: n, text: "a") }
                return DiffLine(kind: .ctx, old: n - shift, new: n, text: "\tc")
            }
            return (ReviewFile(repo: "oversire", path: path, status: .modified, added: adds.count, removed: 0),
                    FileDiff(repo: "oversire", path: path, status: .modified, full: true,
                             hunks: [DiffHunk(oldStart: 1, oldLines: 60 - adds.count, newStart: 1, newLines: 60, lines: lines)]))
        }
        let (a, da) = file("a.go", adds: [30])
        let (b, db) = file("b.go", adds: [10, 40])
        src.seed([ReviewDetail(summary: s, files: [a, b])], diffs: [da, db])
        let d = ReviewDesk(summary: s, source: src, tracker: nil, bus: ChangeBus(schedule: { _, _ in }))
        await d.load()
        d.file = a.id
        await d.diff(a)
        d.change = 0

        let s1 = await d.step(1)
        XCTAssertEqual(s1, .file(b.id, .first))
        XCTAssertEqual(d.file, b.id)
        XCTAssertTrue(src.calls.contains("diff A-1 oversire/b.go full"), "\(src.calls)")
        XCTAssertEqual(d.change, 0, "lands on the first change of the next file")
        let s2 = await d.step(1)
        XCTAssertEqual(s2, .change(1))
        let s3 = await d.step(1)
        XCTAssertEqual(s3, .end(.last))
        XCTAssertEqual(d.change, 1)

        d.change = 0
        let back = await d.step(-1)
        XCTAssertEqual(back, .file(a.id, .last))
        XCTAssertEqual(d.change, 0, "lands on the last change of the previous file")
        d.file = b.id
        XCTAssertNil(d.change, "a new file has no current change")
    }
}

/// The tracker writes of a desk, in memory.
final class FakeTracking: ReviewTracking {
    var posts: [String] = []
    var moves: [String] = []
    func post(_ key: String, markdown: String, done: @escaping (Bool) -> Void) { posts.append(markdown); done(true) }
    func move(key: String, group: String, else category: StatusCategory, done: @escaping (Bool) -> Void) { moves.append("\(key) \(group)"); done(true) }
}
