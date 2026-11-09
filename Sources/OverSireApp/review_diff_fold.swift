import Foundation
import OverSireCore

// ─── Changes › diff model ────────────────────────────────────────────────────
// The rows of the diff of one file, with no views (OVERSIRE-439). The table of `review_diff_table.swift` shows them.
// A full diff (`FileDiff.full`) holds the whole file as one hunk. The fold hides the unchanged runs.
// A partial diff (an older daemon) holds `-U3` hunks. The fold shows the gaps between them, with no lines to open.

/// A line of one side of a diff. A context line counts on the new side.
struct DiffPlace: Hashable {
    let side: ReviewAnchor.Side
    let line: Int
}

/// A run of changed lines: indexes into `DiffFold.lines`.
struct DiffChange: Hashable {
    let lines: Range<Int>
    let added: Int
    let removed: Int
}

/// The direction of a fold button.
enum DiffWay: Hashable { case down, up, all }

/// A run of lines that the diff does not show.
struct DiffGap: Hashable {
    enum Edge: Hashable { case top, middle, bottom }
    /// The hidden new-side line numbers.
    let numbers: ClosedRange<Int>
    let edge: Edge
    /// "@@ −a,b +c,d @@ fn" of the lines below. Empty for the bottom gap.
    let header: String
    /// Empty in partial mode: the app does not have the hidden text.
    let ways: [DiffWay]
    var hidden: Int { numbers.count }
}

/// One row of the diff table.
enum DiffItem: Hashable {
    /// Unified: an index into `DiffFold.lines`.
    case line(Int)
    /// Split: the old and the new side.
    case pair(old: Int?, new: Int?)
    case gap(DiffGap)
    /// The threads and the composer after a line.
    case thread(DiffPlace)
    case note(String)
}

struct DiffFold {
    /// The context lines around a change.
    static let context = 3
    /// The lines that one fold button opens.
    static let step = 20

    /// All hunk lines, in order.
    let lines: [DiffLine]
    /// The index of the first line of each hunk.
    let starts: Set<Int>
    let full: Bool
    let changes: [DiffChange]
    /// The new-side numbers of the hidden lines that the reviewer opened.
    var opened: IndexSet
    /// Full file: no line is hidden.
    var wholeFile: Bool
    private let hunks: [(start: Int, hunk: DiffHunk)]

    init(_ d: FileDiff, opened: IndexSet = [], wholeFile: Bool = false) {
        self.opened = opened
        self.wholeFile = wholeFile
        var lines: [DiffLine] = [], hunks: [(Int, DiffHunk)] = []
        for h in d.hunks {
            hunks.append((lines.count, h))
            lines += h.lines
        }
        self.lines = lines
        self.hunks = hunks
        starts = Set(hunks.map(\.0))
        full = d.full == true
        changes = Self.changes(lines, starts: starts)
    }

    /// A line starts a new change when it starts a hunk, when the line above is context,
    /// or when it is removed and the line above is added.
    private static func changes(_ lines: [DiffLine], starts: Set<Int>) -> [DiffChange] {
        var out: [DiffChange] = []
        var from: Int?, added = 0, removed = 0
        func close(_ end: Int) {
            if let f = from { out.append(DiffChange(lines: f..<end, added: added, removed: removed)) }
            from = nil
            added = 0
            removed = 0
        }
        for (i, l) in lines.enumerated() {
            if l.kind == .ctx { close(i); continue }
            if from != nil, starts.contains(i) || (l.kind == .del && lines[i - 1].kind == .add) { close(i) }
            if from == nil { from = i }
            if l.kind == .add { added += 1 } else { removed += 1 }
        }
        close(lines.count)
        return out
    }

    static func place(_ l: DiffLine) -> DiffPlace? { LinePick.place(l).map { DiffPlace(side: $0.side, line: $0.line) } }

    func index(of p: DiffPlace) -> Int? { lines.firstIndex { Self.place($0) == p } }

    /// The change that holds the line at `index`.
    func change(at index: Int) -> Int? { changes.firstIndex { $0.lines.contains(index) } }

    /// The digits of the gutter: the largest line number, at least five.
    var digits: Int {
        let top = lines.reduce(0) { max($0, $1.old ?? 0, $1.new ?? 0) }
        return max(5, String(top).count)
    }

    // MARK: Rows

    /// The lines that show. A full diff shows the lines near a change, the opened lines and the lines with a thread.
    func shown(threads: Set<DiffPlace>) -> [Bool] {
        guard full, !wholeFile else { return Array(repeating: true, count: lines.count) }
        var out = lines.map { $0.new.map(opened.contains) ?? false }
        for c in changes {
            for i in max(0, c.lines.lowerBound - Self.context)..<min(lines.count, c.lines.upperBound + Self.context) { out[i] = true }
        }
        for (i, l) in lines.enumerated() where !out[i] {
            if let p = Self.place(l), threads.contains(p) { out[i] = true }
        }
        return out
    }

    func items(split: Bool, threads: Set<DiffPlace>) -> [DiffItem] {
        let show = shown(threads: threads)
        var out: [DiffItem] = []
        var run: [Int] = []
        func flush() {
            out += split ? Self.splitItems(run, lines, threads) : run.flatMap { i -> [DiffItem] in
                guard let p = Self.place(lines[i]), threads.contains(p) else { return [.line(i)] }
                return [.line(i), .thread(p)]
            }
            run = []
        }
        var i = 0
        while i < lines.count {
            if let gap = partialGap(before: i) {
                flush()
                out.append(.gap(gap))
            }
            guard show[i] else {
                var j = i
                while j < lines.count, !show[j] { j += 1 }
                flush()
                out.append(.gap(fullGap(i..<j, show)))
                i = j
                continue
            }
            run.append(i)
            i += 1
        }
        flush()
        return out
    }

    private static func splitItems(_ run: [Int], _ lines: [DiffLine], _ threads: Set<DiffPlace>) -> [DiffItem] {
        var out: [DiffItem] = []
        func after(_ ids: [Int?]) {
            var seen: Set<DiffPlace> = []
            for i in ids.compactMap({ $0 }) {
                if let p = place(lines[i]), threads.contains(p), seen.insert(p).inserted { out.append(.thread(p)) }
            }
        }
        for (o, n) in pairs(run.map { ($0, lines[$0]) }) {
            out.append(.pair(old: o, new: n))
            after(o == n ? [o] : [o, n])
        }
        return out
    }

    /// The lines of a run side by side. A run of removed lines pairs with the next run of added lines.
    /// A context line shows on both sides.
    static func pairs<T>(_ lines: [(T, DiffLine)]) -> [(old: T?, new: T?)] {
        var out: [(old: T?, new: T?)] = []
        var dels: [T] = [], adds: [T] = []
        func flush() {
            for i in 0..<max(dels.count, adds.count) { out.append((i < dels.count ? dels[i] : nil, i < adds.count ? adds[i] : nil)) }
            dels = []
            adds = []
        }
        for (t, l) in lines {
            switch l.kind {
            case .del:
                if !adds.isEmpty { flush() }
                dels.append(t)
            case .add: adds.append(t)
            case .ctx:
                flush()
                out.append((t, t))
            }
        }
        flush()
        return out
    }

    static func pairs(_ lines: [DiffLine]) -> [(old: DiffLine?, new: DiffLine?)] { pairs(lines.map { ($0, $0) }) }

    // MARK: Gaps

    /// In partial mode: the gap above the hunk that starts at `i`.
    private func partialGap(before i: Int) -> DiffGap? {
        guard !full, starts.contains(i), let k = hunks.firstIndex(where: { $0.start == i }) else { return nil }
        let h = hunks[k].hunk
        let first = k == 0 ? 1 : (lines[..<i].last { $0.new != nil }?.new ?? 0) + 1
        guard h.newStart > first else { return nil }
        let header = "@@ −\(h.oldStart),\(h.oldLines) +\(h.newStart),\(h.newLines) @@" + (h.header.isEmpty ? "" : " " + h.header)
        return DiffGap(numbers: first...(h.newStart - 1), edge: k == 0 ? .top : .middle, header: header, ways: [])
    }

    /// In full mode: the gap of the hidden lines `r`.
    private func fullGap(_ r: Range<Int>, _ show: [Bool]) -> DiffGap {
        let edge: DiffGap.Edge = r.lowerBound == 0 ? .top : r.upperBound == lines.count ? .bottom : .middle
        let a = lines[r.lowerBound].new ?? 0, b = lines[r.upperBound - 1].new ?? a
        let ways: [DiffWay] = b - a + 1 <= Self.step ? [.all] : (edge == .top ? [] : [.down]) + (edge == .bottom ? [] : [.up]) + [.all]
        return DiffGap(numbers: a...b, edge: edge, header: edge == .bottom ? "" : header(below: r.upperBound, shown: show), ways: ways)
    }

    /// Opens hidden lines of a gap. It gives the new-side number of the line that must keep its place on the screen.
    /// Down opens the top 20 lines below the line above. Up opens the last 20 lines above the line below.
    /// Nil in partial mode: the app does not have the hidden text.
    mutating func expand(_ g: DiffGap, _ way: DiffWay) -> Int? {
        guard full else { return nil }
        let a = g.numbers.lowerBound, b = g.numbers.upperBound
        switch way {
        case .down:
            opened.insert(integersIn: a...min(b, a + Self.step - 1))
            return a - 1
        case .up:
            opened.insert(integersIn: max(a, b - Self.step + 1)...b)
            return b + 1
        case .all:
            opened.insert(integersIn: a...b)
            return g.edge == .bottom ? a - 1 : b + 1
        }
    }

    /// "@@ −a,b +c,d @@ fn" of the run of shown lines from `start`.
    func header(below start: Int, shown: [Bool]? = nil) -> String {
        let show = shown ?? self.shown(threads: [])
        var end = start
        while end < lines.count, show[end] { end += 1 }
        let run = lines[start..<max(start, end)]
        let olds = run.compactMap(\.old), news = run.compactMap(\.new)
        let fn = Self.function(above: start, in: lines)
        return "@@ −\(olds.first ?? 0),\(olds.count) +\(news.first ?? 0),\(news.count) @@" + (fn.isEmpty ? "" : " " + fn)
    }

    /// git's default funcname rule: the last line above that starts with a letter, "_" or "$". Cut to 80 characters.
    static func function(above start: Int, in lines: [DiffLine]) -> String {
        for l in lines[..<start].reversed() where l.kind != .del {
            guard let c = l.text.unicodeScalars.first else { continue }
            if CharacterSet.letters.contains(c) || c == "_" || c == "$" { return String(l.text.prefix(80)).trimmingCharacters(in: .whitespaces) }
        }
        return ""
    }
}

/// A text selection across the rows of a diff. It keeps one column: the unified text, or one side of a split diff.
struct DiffSelection: Equatable {
    struct End: Equatable, Comparable {
        var row: Int
        var offset: Int
        static func < (a: End, b: End) -> Bool { (a.row, a.offset) < (b.row, b.offset) }
    }
    var column: Int
    var from: End
    var to: End

    var isEmpty: Bool { from == to }
    var ordered: (End, End) { from <= to ? (from, to) : (to, from) }

    /// The line of a row in this column.
    static func line(_ item: DiffItem, column: Int, in fold: DiffFold) -> DiffLine? {
        switch item {
        case .line(let i): return column == 0 ? fold.lines[i] : nil
        case .pair(let o, let n): return (column == 0 ? o : n).map { fold.lines[$0] }
        default: return nil
        }
    }

    /// The selected range of a row, in UTF-16 units of the full line.
    func range(row: Int, length: Int) -> NSRange? {
        let (a, b) = ordered
        guard row >= a.row, row <= b.row else { return nil }
        let start = row == a.row ? min(a.offset, length) : 0, end = row == b.row ? min(b.offset, length) : length
        return NSRange(location: start, length: max(0, end - start))
    }

    /// The selected code, one line for each selected line. No line numbers and no marks.
    func text(_ fold: DiffFold, _ items: [DiffItem]) -> String {
        let (a, b) = ordered
        var out: [String] = []
        for row in a.row...min(b.row, items.count - 1) {
            guard let l = Self.line(items[row], column: column, in: fold) else { continue }
            let s = l.text as NSString
            if let r = range(row: row, length: s.length) { out.append(s.substring(with: r)) }
        }
        return out.joined(separator: "\n")
    }
}

/// The order of the files for ‹ › and ⌥⇧↑ / ⌥⇧↓: the rows of the file panel (OVERSIRE-440).
struct DiffSteps {
    let files: [String]

    /// The file `k` steps from `id`. Nil before the first file and after the last file.
    func file(_ id: String, by k: Int) -> String? {
        guard let i = files.firstIndex(of: id), files.indices.contains(i + k) else { return nil }
        return files[i + k]
    }

    /// The next stop for ⌥↓ (k = 1) or ⌥↑ (k = −1) from change `change` of `count` changes (OVERSIRE-442).
    /// No current change counts as −1. Past the ends it goes to the next or the previous file; a file with no changes is a stop.
    func step(file: String, change: Int?, count: Int, by k: Int) -> DiffStep {
        let i = (change ?? -1) + k
        if i < 0 { return self.file(file, by: -1).map { .file($0, .last) } ?? .end(.first) }
        if i >= count { return self.file(file, by: 1).map { .file($0, .first) } ?? .end(.last) }
        return .change(i)
    }
}

/// Where a step lands in a file that it opens.
enum DiffLanding: Hashable { case first, last }

enum DiffStep: Equatable {
    case change(Int)
    case file(String, DiffLanding)
    /// No change and no file in that direction: the first or the last change of the review.
    case end(DiffLanding)
}

/// A change on the ruler. `from` and `to` are fractions of the rows.
struct DiffMark: Hashable {
    let change: Int
    let rows: Range<Int>
    let from: Double
    let to: Double
    let added: Int
    let removed: Int
    var label: String { "Go to change \(change + 1): \(added) added, \(removed) removed" }
}

extension DiffFold {
    /// The marks of the changes in the rows `items`.
    func marks(_ items: [DiffItem]) -> [DiffMark] {
        guard !items.isEmpty else { return [] }
        var rows: [Int: Range<Int>] = [:]
        for (r, item) in items.enumerated() {
            let ids: [Int]
            switch item {
            case .line(let i): ids = [i]
            case .pair(let o, let n): ids = [o, n].compactMap { $0 }
            default: continue
            }
            for c in Set(ids.compactMap(change(at:))) {
                rows[c] = rows[c].map { min($0.lowerBound, r)..<max($0.upperBound, r + 1) } ?? r..<(r + 1)
            }
        }
        let n = Double(items.count)
        return rows.keys.sorted().map { c in
            let r = rows[c]!
            return DiffMark(change: c, rows: r, from: Double(r.lowerBound) / n, to: Double(r.upperBound) / n,
                            added: changes[c].added, removed: changes[c].removed)
        }
    }
}

/// A key of the diff panel.
enum DiffKey: Equatable {
    case size, files, nextChange, previousChange, nextFile, previousFile, close

    /// ⇧⌘M: size. ⌘P: files. ⌥↓ ⌥↑: changes. ⌥⇧↓ ⌥⇧↑: files. Esc: close.
    /// In a text view, the arrows and Esc go to the text, so a comment field can cancel its draft.
    init?(key: UInt16, shift: Bool, option: Bool, command: Bool, inText: Bool) {
        switch (key, shift, option, command) {
        case (46, true, false, true): self = .size
        case (35, false, false, true): self = .files
        case (125, _, true, false) where !inText: self = shift ? .nextFile : .nextChange
        case (126, _, true, false) where !inText: self = shift ? .previousFile : .previousChange
        case (53, false, false, false) where !inText: self = .close
        default: return nil
        }
    }
}
