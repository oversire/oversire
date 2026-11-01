import Foundation
import OverSireCore

// Where an item stands, from the event rows of its tree (OVERSIRE-383). No AI: the recap job adds only text.
struct CatchUp: Equatable {
    /// The mark of a sub-item or of the Now line. The glyph is the text signal; the color only repeats it.
    enum Mark: String, Equatable {
        case merged = "✓", failed = "✕", yours = "◆", works = "●", todo = "○"

        var word: String {
            switch self {
            case .merged: return "merged"
            case .failed: return "failed"
            case .yours: return "waits for you"
            case .works: return "agent works"
            case .todo: return "todo"
            }
        }
    }

    /// The one button of the Now line.
    enum Action: String, Equatable {
        case reviewCode = "Review code", reviewPlan = "Review plan", answer = "Answer", continueSession = "Continue session"
    }

    struct Now: Equatable {
        var mark: Mark
        var key: String
        var text: String
        var since: Date
        var action: Action?
    }

    struct BoardRow: Equatable {
        var key: String
        var title: String
        var mark: Mark
        var note: String
        var at: Date?
        var ships: [String] = []
    }

    struct Pending: Equatable {
        enum Kind: Equatable { case review, question, choice, notPushed }
        var kind: Kind
        var key: String?
        var text: String
        var yours: Bool
        var event: String?
        var reason: String? = nil
    }

    struct Counts: Equatable {
        var commits = 0
        var ciFails = 0
        var ciFixed = 0
        var releases = 0
        var merges = 0
        var questions = 0

        var isZero: Bool { commits + ciFails + releases + merges + questions == 0 }
    }

    /// A recap line, a decision chip or an agent choice. ids: the event rows that it cites.
    struct Line: Equatable, Codable {
        var mark: String
        var text: String
        var at: Date?
        var ids: [String]
        var reason: String? = nil
    }

    struct Words: Equatable {
        var text: String
        var key: String
        var kind: Event.Kind
        var at: Date
    }

    var now: Now?
    var board: [BoardRow] = []
    var pending: [Pending] = []
    var since: Date?
    var counts = Counts()
    var lines: [Line] = []
    var lastWords: Words?
    var decided: [Line] = []
    /// The rows after the last look, oldest first. The recap job reads them.
    var fresh: [Event] = []

    var merged: Int { board.filter { $0.mark == .merged }.count }
    var shipped: Int { board.filter { !$0.ships.isEmpty }.count }
    /// Nothing new since the last look: the panel folds to one line.
    var folded: Bool { since != nil && fresh.isEmpty }
}

/// Builds a CatchUp from the rows of an item tree. Pure, for the tests.
struct CatchUpBuilder {
    struct Sub: Equatable {
        var key: String
        var title: String
        var closed: Bool
    }

    let key: String
    var subs: [Sub] = []
    let rows: [Event]
    /// The last look of the user. Nil: the first look.
    var since: Date?
    var now = Date()
    /// Base branches with local commits: "cli main +2".
    var notPushed: [String] = []

    private var sorted: [Event] { rows.sorted { ($0.at, $0.seq) < ($1.at, $1.seq) } }

    func build() -> CatchUp {
        let all = sorted
        var c = CatchUp(since: since)
        let byKey = Dictionary(grouping: all) { ($0.item ?? key).uppercased() }
        let states = ([key] + subs.map(\.key)).map { k in (k, state(k.uppercased(), byKey[k.uppercased()] ?? [])) }
        c.board = subs.map { s in
            let st = state(s.key.uppercased(), byKey[s.key.uppercased()] ?? [])
            var mark = st.mark
            var note = st.note
            if mark == .todo, s.closed { (mark, note) = (.merged, "done") }
            return CatchUp.BoardRow(key: s.key, title: s.title, mark: mark, note: note, at: st.at, ships: ships(s.key.uppercased(), all))
        }
        c.now = nowLine(states)
        c.pending = pending(states)
        c.fresh = all.filter { e in since.map { e.at > $0 } ?? (now.timeIntervalSince(e.at) < 2 * 86400) && e.kind != .itemViewed }
        if since == nil { c.fresh = [] }
        c.counts = counts(c.fresh, all: all)
        c.lines = lines(c.fresh)
        c.lastWords = all.last { $0.actorType == .human && [.promptSubmitted, .reviewSubmitted, .commentCreated].contains($0.kind) }
            .map { CatchUp.Words(text: $0.summary, key: ($0.item ?? key).uppercased(), kind: $0.kind, at: $0.at) }
        c.decided = all.filter { $0.actorType == .human && [.questionAnswered, .reviewApproved].contains($0.kind) }.suffix(4).map {
            CatchUp.Line(mark: "◆", text: $0.summary, at: $0.at, ids: [$0.id], reason: $0.payload?["question"]?.stringValue)
        }
        return c
    }

    // MARK: One item

    struct State: Equatable {
        var mark: CatchUp.Mark
        var note: String
        var at: Date?
        var action: CatchUp.Action?
        var event: String?
    }

    /// The state of one key from its rows, oldest first. Merged wins, then your turn, then a failed CI, then a working agent.
    func state(_ k: String, _ rows: [Event]) -> State {
        if let m = rows.last(where: { [.itemShipped, .prMerged].contains($0.kind) }) {
            return State(mark: .merged, note: "merged \(Self.day(m.at, now: now))", at: m.at, event: m.id)
        }
        if let r = openReview(rows) {
            let kind = r.payload?["kind"]?.stringValue == "plan" ? "plan" : "code"
            let round = r.payload?["round"]?.intValue.map { "round \($0)" }
            let note = ["\(kind) review", round].compactMap { $0 }.joined(separator: " ")
            return State(mark: .yours, note: note + " · not merged", at: r.at, action: kind == "plan" ? .reviewPlan : .reviewCode, event: r.id)
        }
        if let w = open(rows, start: .waitStarted, ends: [.waitEnded, .sessionEnded]) {
            let reason = w.payload?["reason"]?.stringValue ?? "input"
            let action: CatchUp.Action = ["question", "permission"].contains(reason) ? .answer : .continueSession
            return State(mark: .yours, note: "waits for your \(reason)", at: w.at, action: action, event: w.id)
        }
        if let f = rows.last(where: { $0.kind == .ciCompleted }), f.payload?["conclusion"]?.stringValue == "failure" {
            return State(mark: .failed, note: "CI failed" + (f.payload?["failed"].map { _ in ": " + Self.after(f.summary) } ?? ""), at: f.at, event: f.id)
        }
        if let t = open(rows, start: .turnStarted, ends: [.turnEnded, .turnInterrupted, .sessionEnded]) {
            let turn = t.payload?["turn"]?.intValue.map { "turn \($0)" } ?? "a turn"
            return State(mark: .works, note: "agent works · \(turn)", at: t.at, event: t.id)
        }
        return State(mark: .todo, note: rows.isEmpty ? "no events" : "idle", at: rows.last?.at)
    }

    /// The last review.ready with no later answer of yours or merge.
    private func openReview(_ rows: [Event]) -> Event? {
        guard let i = rows.lastIndex(where: { $0.kind == .reviewReady }) else { return nil }
        let after = rows[rows.index(after: i)...]
        return after.contains { [.reviewSubmitted, .reviewApproved, .itemShipped, .prMerged].contains($0.kind) } ? nil : rows[i]
    }

    /// The last start row of the session with no end row after it.
    private func open(_ rows: [Event], start: Event.Kind, ends: Set<Event.Kind>) -> Event? {
        guard let i = rows.lastIndex(where: { $0.kind == start }) else { return nil }
        let s = rows[i]
        let after = rows[rows.index(after: i)...]
        return after.contains { ends.contains($0.kind) && ($0.session == nil || $0.session == s.session) } ? nil : s
    }

    /// The release tags that hold the key: from the items of release.published.
    private func ships(_ k: String, _ all: [Event]) -> [String] {
        all.filter { e in
            e.kind == .releasePublished && (e.payload?["items"]?.arrayValue ?? []).contains { $0.stringValue?.uppercased() == k }
        }.compactMap { $0.payload?["tag"]?.stringValue ?? $0.summary }
    }

    // MARK: The tree

    /// Your turn first, the oldest wait first. Else a failure, else the newest working agent.
    private func nowLine(_ states: [(String, State)]) -> CatchUp.Now? {
        func line(_ e: (String, State)) -> CatchUp.Now {
            CatchUp.Now(mark: e.1.mark, key: e.0, text: "\(short(e.0)): \(e.1.note)", since: e.1.at ?? now, action: e.1.action)
        }
        let yours = states.filter { $0.1.mark == .yours }.sorted { ($0.1.at ?? now) < ($1.1.at ?? now) }
        if let y = yours.first {
            var n = line(y)
            n.text = "Your turn: " + n.text
            return n
        }
        if let f = states.filter({ $0.1.mark == .failed }).max(by: { ($0.1.at ?? now) < ($1.1.at ?? now) }) { return line(f) }
        if let w = states.filter({ $0.1.mark == .works }).max(by: { ($0.1.at ?? now) < ($1.1.at ?? now) }) {
            var n = line(w)
            n.text = "Agent works on " + short(w.0) + " · " + w.1.note.replacingOccurrences(of: "agent works · ", with: "")
            return n
        }
        return nil
    }

    private func pending(_ states: [(String, State)]) -> [CatchUp.Pending] {
        var out: [CatchUp.Pending] = []
        for (k, s) in states where s.mark == .yours {
            let kind: CatchUp.Pending.Kind = s.action == .answer ? .question : .review
            let what = s.action == .answer ? "Answer \(short(k)): " + s.note : "Review \(short(k)), " + s.note.replacingOccurrences(of: " · not merged", with: "")
            out.append(CatchUp.Pending(kind: kind, key: k, text: what + ".", yours: true, event: s.event))
        }
        out += notPushed.map { CatchUp.Pending(kind: .notPushed, key: nil, text: "Not pushed: " + $0, yours: true, event: nil) }
        return out
    }

    private func counts(_ fresh: [Event], all: [Event]) -> CatchUp.Counts {
        var c = CatchUp.Counts()
        var merged: Set<String> = []
        for e in fresh {
            switch e.kind {
            case .gitCommit: c.commits += 1
            case .releasePublished: c.releases += 1
            case .itemShipped, .prMerged: merged.insert((e.item ?? e.id).uppercased())
            case .waitStarted where ["question", "permission"].contains(e.payload?["reason"]?.stringValue ?? ""): c.questions += 1
            case .ciCompleted where e.payload?["conclusion"]?.stringValue == "failure":
                c.ciFails += 1
                if all.contains(where: { $0.kind == .ciCompleted && $0.item == e.item && $0.at > e.at && $0.payload?["conclusion"]?.stringValue == "success" }) {
                    c.ciFixed += 1
                }
            default: break
            }
        }
        c.merges = merged.count
        return c
    }

    /// The 3 most important new rows in plain words: a failed CI, your turn, a release, a merge.
    private func lines(_ fresh: [Event]) -> [CatchUp.Line] {
        func rank(_ e: Event) -> (Int, String)? {
            switch e.kind {
            case .ciCompleted where e.payload?["conclusion"]?.stringValue == "failure": return (0, "✕")
            case .reviewReady, .waitStarted: return (1, "◆")
            case .releasePublished: return (2, "★")
            case .itemShipped, .prMerged: return (3, "◉")
            default: return nil
            }
        }
        let ranked = fresh.compactMap { e in rank(e).map { (e, $0.0, $0.1) } }
            .sorted { ($0.1, $1.0.at) < ($1.1, $0.0.at) }
        return ranked.prefix(3).map { e, _, mark in
            CatchUp.Line(mark: mark, text: "\(short((e.item ?? key).uppercased())): \(e.summary)", at: e.at, ids: [e.id])
        }
    }

    // MARK: Words

    /// "374" for a sub-item of the same project, else the full key.
    func short(_ k: String) -> String {
        let p = key.split(separator: "-").first.map(String.init) ?? ""
        let parts = k.split(separator: "-")
        return parts.count == 2 && String(parts[0]) == p && k.uppercased() != key.uppercased() ? String(parts[1]) : k
    }

    /// The text after "failed: " of a CI summary.
    static func after(_ s: String) -> String { s.range(of: ": ").map { String(s[$0.upperBound...]) } ?? s }

    /// "Wed", or "Wed 1 Nov" for an older day.
    static func day(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = now.timeIntervalSince(d) < 6 * 86400 ? "EEE" : "EEE d MMM"
        return f.string(from: d)
    }
}

extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
}

/// "12 min", "16h", "2d 18h".
func spanText(_ s: TimeInterval) -> String {
    let m = Int(max(0, s) / 60)
    if m < 60 { return "\(m) min" }
    let h = m / 60
    if h < 24 { return "\(h)h" }
    return h % 24 == 0 ? "\(h / 24)d" : "\(h / 24)d \(h % 24)h"
}

/// "Thu 15:05", or "Thu 1 Nov, 15:05" for an older day.
func dayTime(_ d: Date, now: Date = Date()) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = now.timeIntervalSince(d) < 6 * 86400 ? "EEE HH:mm" : "EEE d MMM, HH:mm"
    return f.string(from: d)
}
