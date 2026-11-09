import OverSireCore
import XCTest
@testable import OverSireApp

final class DiffFoldTests: XCTestCase {
    private func ctx(_ o: Int, _ n: Int) -> DiffLine { DiffLine(kind: .ctx, old: o, new: n, text: "c\(n)") }
    private func add(_ n: Int, _ t: String? = nil) -> DiffLine { DiffLine(kind: .add, new: n, text: t ?? "a\(n)") }
    private func del(_ o: Int, _ t: String? = nil) -> DiffLine { DiffLine(kind: .del, old: o, text: t ?? "d\(o)") }
    private func diff(_ hunks: [DiffHunk], full: Bool? = nil) -> FileDiff { FileDiff(repo: "r", path: "a.go", status: .modified, full: full, hunks: hunks) }

    func testThePartialDiffGetsGapsBetweenHunks() {
        let d = diff([
            DiffHunk(oldStart: 10, oldLines: 3, newStart: 10, newLines: 4, header: "func a() {", lines: [ctx(10, 10), add(11), ctx(11, 12), ctx(12, 13)]),
            DiffHunk(oldStart: 40, oldLines: 2, newStart: 41, newLines: 2, header: "", lines: [ctx(40, 41), add(42)]),
        ])
        let gaps = DiffFold(d).items(split: false, threads: []).compactMap { i -> DiffGap? in if case .gap(let g) = i { return g } else { return nil } }
        XCTAssertEqual(gaps.map(\.hidden), [9, 27])
        XCTAssertEqual(gaps.map(\.edge), [.top, .middle])
        XCTAssertEqual(gaps.first?.header, "@@ −10,3 +10,4 @@ func a() {")
        XCTAssertTrue(gaps.allSatisfy { $0.ways.isEmpty })

        let fromOne = diff([DiffHunk(oldStart: 1, oldLines: 1, newStart: 1, newLines: 2, header: "", lines: [ctx(1, 1), add(2)])])
        XCTAssertFalse(DiffFold(fromOne).items(split: false, threads: []).contains { if case .gap = $0 { return true } else { return false } },
                       "no top gap when the hunk starts at line 1, and no bottom gap")
    }

    func testChangeBlocks() {
        let d = diff([
            DiffHunk(oldStart: 1, oldLines: 4, newStart: 1, newLines: 4, header: "", lines: [add(1), del(1), ctx(2, 2), del(3), add(3), ctx(4, 4)]),
            DiffHunk(oldStart: 20, oldLines: 1, newStart: 20, newLines: 2, header: "", lines: [add(20)]),
            DiffHunk(oldStart: 30, oldLines: 1, newStart: 31, newLines: 2, header: "", lines: [add(31)]),
        ])
        let f = DiffFold(d)
        XCTAssertEqual(f.changes.map(\.lines), [0..<1, 1..<2, 3..<5, 6..<7, 7..<8], "add then del gives two blocks, del then add one, and a hunk start ends a block")
        XCTAssertEqual(f.changes[2].added, 1)
        XCTAssertEqual(f.changes[2].removed, 1)
        XCTAssertEqual(f.change(at: 4), 2)
        XCTAssertNil(f.change(at: 2))
    }

    func testSplitPairsRemovedWithAddedLines() {
        let lines = [ctx(1, 1), del(2, "b"), del(3, "c"), add(2, "B"), ctx(4, 3), add(4, "e")]
        let p = DiffFold.pairs(lines)
        XCTAssertEqual(p.map { $0.old?.text }, ["c1", "b", "c", "c3", nil])
        XCTAssertEqual(p.map { $0.new?.text }, ["c1", "B", nil, "c3", "e"])
    }

    func testTheGutterFitsFiveDigits() {
        XCTAssertEqual(DiffFold(diff([DiffHunk(oldStart: 3938, oldLines: 0, newStart: 3938, newLines: 1, header: "", lines: [add(3938)])])).digits, 5)
        XCTAssertEqual(DiffFold(diff([DiffHunk(oldStart: 1, oldLines: 0, newStart: 123456, newLines: 1, header: "", lines: [add(123456)])])).digits, 6)
        XCTAssertGreaterThan(DiffTable.gutterWidth(digits: 5), DiffTable.gutterWidth(digits: 4))
    }

    func testAThreadFollowsItsLine() {
        let d = diff([DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, header: "", lines: [ctx(1, 1), del(2), add(2)])])
        let f = DiffFold(d)
        let old = DiffPlace(side: .old, line: 2)
        XCTAssertEqual(f.items(split: false, threads: [old]), [.line(0), .line(1), .thread(old), .line(2)])
        XCTAssertEqual(f.items(split: true, threads: [old]), [.pair(old: 0, new: 0), .pair(old: 1, new: 2), .thread(old)])
        XCTAssertEqual(DiffFold.place(f.lines[1]), old, "the old side applies to a removed line")
    }

    func testAFullDiffFoldsTheUnchangedRuns() {
        let lines = (1...9).map { ctx($0, $0) } + [add(10)] + (11...30).map { ctx($0 - 1, $0) }
        let f = DiffFold(diff([DiffHunk(oldStart: 1, oldLines: 29, newStart: 1, newLines: 30, header: "", lines: lines)], full: true))
        let items = f.items(split: false, threads: [DiffPlace(side: .new, line: 25)])
        let gaps = items.compactMap { i -> DiffGap? in if case .gap(let g) = i { return g } else { return nil } }
        XCTAssertEqual(gaps.map(\.numbers), [1...6, 14...24, 26...30])
        XCTAssertEqual(gaps.map(\.edge), [.top, .middle, .bottom])
        XCTAssertEqual(gaps.last?.header, "")
        XCTAssertTrue(items.contains(.thread(DiffPlace(side: .new, line: 25))), "a line with a thread always shows")
    }

    func testTheIndexOfAPlace() {
        let f = DiffFold(diff([DiffHunk(oldStart: 1, oldLines: 2, newStart: 1, newLines: 2, header: "", lines: [ctx(1, 1), del(2), add(2)])]))
        XCTAssertEqual(f.index(of: DiffPlace(side: .old, line: 2)), 1)
        XCTAssertEqual(f.index(of: DiffPlace(side: .new, line: 2)), 2)
        XCTAssertNil(f.index(of: DiffPlace(side: .new, line: 9)))
    }

    func testCopyAcrossRows() {
        let lines = [DiffLine(kind: .ctx, old: 1, new: 1, text: "func a() {"), DiffLine(kind: .del, old: 2, text: "    return 1"),
                     DiffLine(kind: .add, new: 2, text: "    return 2"), DiffLine(kind: .ctx, old: 3, new: 3, text: "}")]
        let f = DiffFold(diff([DiffHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, header: "", lines: lines)]))
        let unified = f.items(split: false, threads: [])
        let s = DiffSelection(column: 0, from: .init(row: 3, offset: 1), to: .init(row: 0, offset: 5))
        XCTAssertEqual(s.text(f, unified), "a() {\n    return 1\n    return 2\n}", "a selection up keeps its order and has no marks")

        let split = f.items(split: true, threads: [])
        let right = DiffSelection(column: 1, from: .init(row: 0, offset: 0), to: .init(row: split.count - 1, offset: Int.max / 2))
        XCTAssertEqual(right.text(f, split), "func a() {\n    return 2\n}", "a split diff copies one side")
        XCTAssertTrue(DiffSelection(column: 0, from: .init(row: 1, offset: 2), to: .init(row: 1, offset: 2)).isEmpty)
    }

    func testFileStepsFollowThePanelOrder() {
        let s = DiffSteps(files: ["a", "b", "c"])
        XCTAssertEqual(s.file("b", by: 1), "c")
        XCTAssertEqual(s.file("b", by: -1), "a")
        XCTAssertNil(s.file("a", by: -1), "no file before the first file")
        XCTAssertNil(s.file("c", by: 1), "no file after the last file")
        XCTAssertNil(s.file("x", by: 1))
    }

    func testKeysInATextFieldGoToTheField() {
        XCTAssertNil(DiffKey(key: 53, shift: false, option: false, command: false, inText: true), "Esc cancels the draft")
        XCTAssertNil(DiffKey(key: 125, shift: false, option: true, command: false, inText: true))
        XCTAssertNil(DiffKey(key: 126, shift: true, option: true, command: false, inText: true))
        XCTAssertEqual(DiffKey(key: 53, shift: false, option: false, command: false, inText: false), .close)
        XCTAssertEqual(DiffKey(key: 125, shift: false, option: true, command: false, inText: false), .nextChange)
        XCTAssertEqual(DiffKey(key: 126, shift: true, option: true, command: false, inText: false), .previousFile)
        XCTAssertEqual(DiffKey(key: 35, shift: false, option: false, command: true, inText: true), .files, "⌘P works in a field")
        XCTAssertNil(DiffKey(key: 125, shift: false, option: false, command: false, inText: false), "a plain ↓ moves the cursor")
    }

    func testShiftCommandMTogglesTheSize() {
        XCTAssertEqual(DiffKey(key: 46, shift: true, option: false, command: true, inText: false), .size)
        XCTAssertEqual(DiffKey(key: 46, shift: true, option: false, command: true, inText: true), .size)
        XCTAssertNil(DiffKey(key: 46, shift: false, option: false, command: true, inText: false), "⌘M stays Minimize")
    }

    // MARK: Fold buttons (OVERSIRE-441)

    /// A full diff of `count` lines with one added line at each of `adds`. Line `fn` starts a function.
    private func full(_ count: Int, adds: [Int], fn: Int? = nil) -> DiffFold {
        var shift = 0
        let lines = (1...count).map { n -> DiffLine in
            if adds.contains(n) { shift += 1; return add(n) }
            return DiffLine(kind: .ctx, old: n - shift, new: n, text: n == fn ? "func run() {" : "\tc\(n)")
        }
        return DiffFold(diff([DiffHunk(oldStart: 1, oldLines: count - adds.count, newStart: 1, newLines: count, header: "", lines: lines)], full: true))
    }

    private func gaps(_ f: DiffFold) -> [DiffGap] {
        f.items(split: false, threads: []).compactMap { i -> DiffGap? in if case .gap(let g) = i { return g } else { return nil } }
    }

    func testContextIsThreeLines() {
        let f = full(100, adds: [50])
        XCTAssertEqual(gaps(f).map(\.numbers), [1...46, 54...100])
        XCTAssertEqual(f.lines.indices.filter { f.shown(threads: [])[$0] }.compactMap { f.lines[$0].new }, Array(47...53))
    }

    func testAGapOf20LinesHasOneButton() {
        let g = gaps(full(60, adds: [10, 37]))
        XCTAssertEqual(g[1].numbers, 14...33)
        XCTAssertEqual(g[1].ways, [.all])
    }

    func testALargerGapHasDownUpAndAll() {
        let g = gaps(full(100, adds: [10, 60]))
        XCTAssertEqual(g[1].numbers, 14...56)
        XCTAssertEqual(g[1].ways, [.down, .up, .all])
    }

    func testTheTopGapHasOnlyUpAndTheBottomGapOnlyDown() {
        let g = gaps(full(100, adds: [50]))
        XCTAssertEqual(g.map(\.edge), [.top, .bottom])
        XCTAssertEqual(g[0].ways, [.up, .all])
        XCTAssertEqual(g[1].ways, [.down, .all])
    }

    func testDownOpens20LinesWithTheAnchorAbove() {
        var f = full(100, adds: [10, 60])
        XCTAssertEqual(f.expand(gaps(f)[1], .down), 13)
        XCTAssertEqual(f.opened, IndexSet(integersIn: 14...33))
        XCTAssertEqual(gaps(f)[1].numbers, 34...56)
    }

    func testUpOpens20LinesWithTheAnchorBelow() {
        var f = full(100, adds: [10, 60])
        XCTAssertEqual(f.expand(gaps(f)[1], .up), 57)
        XCTAssertEqual(f.opened, IndexSet(integersIn: 37...56))
        XCTAssertEqual(gaps(f)[1].numbers, 14...36)
    }

    func testShowAllKeepsTheAnchorBelowOrAboveAtTheEnd() {
        var f = full(100, adds: [10, 60])
        XCTAssertEqual(f.expand(gaps(f)[1], .all), 57)
        XCTAssertEqual(gaps(f).map(\.edge), [.top, .bottom], "the middle gap is open")
        var e = full(100, adds: [50])
        let g = gaps(e)
        XCTAssertEqual(e.expand(g[0], .all), 47, "the top gap keeps the line below")
        XCTAssertEqual(e.expand(g[1], .all), 53, "the bottom gap keeps the line above")
        XCTAssertTrue(gaps(e).isEmpty)
    }

    func testTheGapHeaderCountsTheRunBelow() {
        let g = gaps(full(100, adds: [50], fn: 20))
        XCTAssertEqual(g[0].header, "@@ −47,6 +47,7 @@ func run() {")
        XCTAssertEqual(g[1].header, "")
    }

    func testTheFunctionNameRule() {
        let long = String(repeating: "x", count: 100)
        let lines = [ctx(1, 1), DiffLine(kind: .ctx, old: 2, new: 2, text: "func a() {"), DiffLine(kind: .ctx, old: 3, new: 3, text: "\tbody"),
                     del(4, "func gone() {"), DiffLine(kind: .ctx, old: 5, new: 4, text: "1 // a number"), DiffLine(kind: .ctx, old: 6, new: 5, text: "  indented")]
        XCTAssertEqual(DiffFold.function(above: lines.count, in: lines), "func a() {", "a removed line, a digit and an indent do not count")
        XCTAssertEqual(DiffFold.function(above: 1, in: [DiffLine(kind: .ctx, old: 1, new: 1, text: "_init:")]), "_init:")
        XCTAssertEqual(DiffFold.function(above: 1, in: [DiffLine(kind: .ctx, old: 1, new: 1, text: "$x = 1")]), "$x = 1")
        XCTAssertEqual(DiffFold.function(above: 1, in: [DiffLine(kind: .ctx, old: 1, new: 1, text: long)]).count, 80)
        XCTAssertEqual(DiffFold.function(above: 0, in: lines), "")
    }

    func testFullFileOffKeepsOpenedLines() {
        let base = full(100, adds: [50])
        let d = diff([DiffHunk(oldStart: 1, oldLines: 99, newStart: 1, newLines: 100, header: "", lines: base.lines)], full: true)
        XCTAssertTrue(gaps(DiffFold(d, opened: [20], wholeFile: true)).isEmpty, "Full file hides no line")
        XCTAssertEqual(gaps(DiffFold(d, opened: [20], wholeFile: false)).map(\.numbers), [1...19, 21...46, 54...100])
    }

    func testAnOlderDaemonGivesNoButtons() {
        var f = DiffFold(diff([DiffHunk(oldStart: 40, oldLines: 1, newStart: 40, newLines: 2, header: "", lines: [ctx(40, 40), add(41)])]))
        let g = gaps(f)
        XCTAssertEqual(g.map(\.numbers), [1...39])
        XCTAssertTrue(g[0].ways.isEmpty)
        XCTAssertNil(f.expand(g[0], .all))
        XCTAssertTrue(f.opened.isEmpty)
    }

    // MARK: Steps and ruler (OVERSIRE-442)

    private let three = DiffSteps(files: ["a", "b", "c"])

    func testAStepInsideAFile() {
        XCTAssertEqual(three.step(file: "b", change: nil, count: 3, by: 1), .change(0), "no current change starts at the first")
        XCTAssertEqual(three.step(file: "b", change: 0, count: 3, by: 1), .change(1))
        XCTAssertEqual(three.step(file: "b", change: 2, count: 3, by: -1), .change(1))
    }

    func testAStepPastTheLastChangeOpensTheNextFileAtItsFirst() {
        XCTAssertEqual(three.step(file: "b", change: 2, count: 3, by: 1), .file("c", .first))
    }

    func testAStepBeforeTheFirstChangeOpensThePreviousFileAtItsLast() {
        XCTAssertEqual(three.step(file: "b", change: 0, count: 3, by: -1), .file("a", .last))
        XCTAssertEqual(three.step(file: "b", change: nil, count: 3, by: -1), .file("a", .last))
    }

    func testTheEndOfTheReviewInBothDirections() {
        XCTAssertEqual(three.step(file: "c", change: 1, count: 2, by: 1), .end(.last))
        XCTAssertEqual(three.step(file: "a", change: 0, count: 2, by: -1), .end(.first))
    }

    func testAFileWithNoChangesIsAStop() {
        XCTAssertEqual(three.step(file: "b", change: nil, count: 0, by: 1), .file("c", .first))
        XCTAssertEqual(three.step(file: "b", change: nil, count: 0, by: -1), .file("a", .last))
    }

    func testRulerMarksFollowTheRows() throws {
        let f = full(60, adds: [10, 37])
        let items = f.items(split: false, threads: [])
        let marks = f.marks(items)
        XCTAssertEqual(marks.map(\.change), [0, 1])
        for m in marks {
            XCTAssertEqual(m.rows.count, 1)
            guard case .line(let i) = items[m.rows.lowerBound] else { return XCTFail("a mark is on a line row") }
            XCTAssertEqual(f.lines[i].new, m.change == 0 ? 10 : 37)
            XCTAssertEqual(m.from, Double(m.rows.lowerBound) / Double(items.count), accuracy: 0.0001)
            XCTAssertEqual(m.added, 1)
        }
        XCTAssertLessThan(marks[0].to, marks[1].from)
        XCTAssertEqual(f.marks([]), [])
    }

    func testTheMarkLabel() {
        let m = DiffMark(change: 1, rows: 4..<6, from: 0.1, to: 0.2, added: 1, removed: 1)
        XCTAssertEqual(m.label, "Go to change 2: 1 added, 1 removed")
    }
}
