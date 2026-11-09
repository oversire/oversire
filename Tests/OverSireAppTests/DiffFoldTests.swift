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
}
