import Foundation
import OverSireCore

// The lane graph of the Timeline tab (OVERSIRE-384), from the event rows of an item tree. Pure, for the tests.
struct TimelineModel: Equatable {
    struct Lane: Equatable {
        var key: String
        var title: String
        /// The parent lane on a sub-item page.
        var dim = false
    }

    struct Bar: Equatable {
        enum Kind: String, Equatable { case work = "agent works", fix = "agent fixes", wait = "waits for you" }
        var lane: Int
        var kind: Kind
        var start: Date
        var end: Date
        var open: Bool
        var note: String
        var ids: [String]
    }

    struct Mark: Equatable {
        enum Kind: String, Equatable {
            case steer = "▲", decide = "◆", handoff = "▶", ciPass = "✓", ciFail = "✕", merged = "◉", released = "★", created = "○"

            var word: String {
                switch self {
                case .steer: return "You steered"
                case .decide: return "You decided"
                case .handoff: return "Agent hand-off"
                case .ciPass: return "CI passed"
                case .ciFail: return "CI failed"
                case .merged: return "Merged"
                case .released: return "Released"
                case .created: return "Created"
                }
            }
        }
        var lane: Int
        var kind: Kind
        var at: Date
        var event: Event
    }

    var lanes: [Lane] = []
    var bars: [Bar] = []
    var marks: [Mark] = []
    var start: Date
    var end: Date

    /// The releases: a dashed line across the lanes.
    var releases: [Mark] { marks.filter { $0.kind == .released } }

    /// The time that agents worked: the union of the work and fix bars.
    var active: TimeInterval {
        let spans = bars.filter { $0.kind != .wait }.map { ($0.start, $0.end) }.sorted { $0.0 < $1.0 }
        var total: TimeInterval = 0
        var cur: (Date, Date)?
        for s in spans {
            if let c = cur, s.0 <= c.1 { cur = (c.0, max(c.1, s.1)) } else {
                if let c = cur { total += c.1.timeIntervalSince(c.0) }
                cur = s
            }
        }
        if let c = cur { total += c.1.timeIntervalSince(c.0) }
        return total
    }

    static func build(key: String, title: String = "", subs: [Lane], parent: Lane? = nil, rows: [Event], now: Date) -> TimelineModel {
        let lanes = (parent.map { [Lane(key: $0.key, title: $0.title, dim: true)] } ?? []) + [Lane(key: key, title: title)] + subs
        func lane(_ e: Event) -> Int? {
            let k = (e.item ?? key).uppercased()
            return lanes.firstIndex { $0.key.uppercased() == k }
        }
        let sorted = rows.sorted { ($0.at, $0.seq) < ($1.at, $1.seq) }
        var bars: [Bar] = []
        var marks: [Mark] = []
        var turn: [String: (Event, Bool)] = [:]     // lane/session → turn.started, a fix
        var wait: [String: Event] = [:]
        var fixNext: Set<Int> = []
        for e in sorted {
            guard let l = lane(e) else { continue }
            let s = "\(l)/\(e.session ?? "-")"
            switch e.kind {
            case .turnStarted:
                if let (t, fix) = turn[s] { bars.append(bar(l, fix ? .fix : .work, t, e.at, open: false, tools: nil)) }
                let fix = fixNext.contains(l) || e.payload?["steer"] == .bool(true)
                fixNext.remove(l)
                turn[s] = (e, fix)
            case .turnEnded, .turnInterrupted, .sessionEnded:
                if let (t, fix) = turn.removeValue(forKey: s) { bars.append(bar(l, fix ? .fix : .work, t, e.at, open: false, tools: e)) }
                if e.kind == .sessionEnded, let w = wait.removeValue(forKey: s) { bars.append(bar(l, .wait, w, e.at, open: false, tools: nil)) }
                if e.kind == .turnInterrupted { marks.append(Mark(lane: l, kind: .steer, at: e.at, event: e)) }
            case .waitStarted:
                wait[s] = e
            case .waitEnded:
                if let w = wait.removeValue(forKey: s) { bars.append(bar(l, .wait, w, e.at, open: false, tools: nil)) }
            default:
                break
            }
            if let k = markKind(e) {
                marks.append(Mark(lane: l, kind: k, at: e.at, event: e))
                if k == .ciFail || (e.kind == .reviewSubmitted) { fixNext.insert(l) }
            }
        }
        for (k, (t, fix)) in turn { bars.append(bar(Int(k.split(separator: "/")[0])!, fix ? .fix : .work, t, now, open: true, tools: nil)) }
        for (k, w) in wait { bars.append(bar(Int(k.split(separator: "/")[0])!, .wait, w, now, open: true, tools: nil)) }
        bars.sort { ($0.lane, $0.start) < ($1.lane, $1.start) }
        let times = bars.flatMap { [$0.start, $0.end] } + marks.map(\.at)
        return TimelineModel(lanes: lanes, bars: bars, marks: marks, start: times.min() ?? now.addingTimeInterval(-3600), end: max(now, times.max() ?? now))
    }

    private static func bar(_ l: Int, _ k: Bar.Kind, _ s: Event, _ end: Date, open: Bool, tools: Event?) -> Bar {
        var note: String
        switch k {
        case .wait: note = "Waits for your " + (s.payload?["reason"]?.stringValue ?? "input")
        case .work, .fix:
            let n = s.payload?["turn"]?.intValue.map { "Turn \($0)" } ?? "A turn"
            let t = tools?.payload?["tools"]?.intValue.map { ", \($0) tools" } ?? ""
            let err = tools?.payload?["toolErrors"]?.intValue.flatMap { $0 > 0 ? ", \($0) tool errors" : nil } ?? ""
            note = n + t + err + (open ? ", still works" : "")
        }
        return Bar(lane: l, kind: k, start: s.at, end: max(end, s.at), open: open, note: note, ids: [s.id] + (tools.map { [$0.id] } ?? []))
    }

    static func markKind(_ e: Event) -> Mark.Kind? {
        switch e.kind {
        case .promptSubmitted: return e.payload?["steer"] == .bool(true) ? .steer : nil
        case .reviewSubmitted: return .steer
        case .questionAnswered, .reviewApproved, .itemShipped: return .decide
        case .reviewReady: return .handoff
        case .ciCompleted:
            switch e.payload?["conclusion"]?.stringValue {
            case "success": return .ciPass
            case "failure": return .ciFail
            default: return nil
            }
        case .prMerged, .gitMerge: return .merged
        case .releasePublished: return .released
        case .itemCreated: return .created
        default: return nil
        }
    }
}

/// Maps time to x. Empty time folds into a cut of fixed width: a gap over `gap` with no agent bar and no mark.
/// A wait bar does not hold time open, so a night of waiting folds.
struct TimeScale: Equatable {
    enum Segment: Equatable {
        case live(Date, Date)
        case cut(Date, Date)

        var start: Date { switch self { case .live(let a, _), .cut(let a, _): return a } }
        var end: Date { switch self { case .live(_, let b), .cut(_, let b): return b } }
        var isCut: Bool { if case .cut = self { return true }; return false }
        var length: TimeInterval { end.timeIntervalSince(start) }
    }

    static let pad: TimeInterval = 0.3 * 3600
    static let gap: TimeInterval = 1.5 * 3600
    static let cutWidth: CGFloat = 46

    let segments: [Segment]
    let width: CGFloat
    private let liveWidth: CGFloat
    private let liveTime: TimeInterval

    init(segments: [Segment], width: CGFloat) {
        self.segments = segments
        self.width = width
        let cuts = CGFloat(segments.filter(\.isCut).count)
        liveWidth = max(1, width - cuts * Self.cutWidth)
        liveTime = max(1, segments.filter { !$0.isCut }.reduce(0) { $0 + $1.length })
    }

    /// One live segment: real time.
    static func real(_ m: TimelineModel, width: CGFloat) -> TimeScale {
        TimeScale(segments: [.live(m.start.addingTimeInterval(-pad), m.end.addingTimeInterval(pad))], width: width)
    }

    static func cut(_ m: TimelineModel, width: CGFloat) -> TimeScale {
        let spans = m.bars.filter { $0.kind != .wait }.map { ($0.start, $0.end) } + m.marks.map { ($0.at, $0.at) }
        return TimeScale(segments: fold(spans, start: m.start, end: m.end), width: width)
    }

    /// The live and cut segments of the busy spans, each with `pad` on both sides.
    static func fold(_ spans: [(Date, Date)], start: Date, end: Date) -> [Segment] {
        let padded = spans.map { ($0.0.addingTimeInterval(-pad), $0.1.addingTimeInterval(pad)) }.sorted { $0.0 < $1.0 }
        guard var cur = padded.first else { return [.live(start.addingTimeInterval(-pad), end.addingTimeInterval(pad))] }
        var busy: [(Date, Date)] = []
        for s in padded.dropFirst() {
            if s.0.timeIntervalSince(cur.1) <= gap { cur.1 = max(cur.1, s.1) } else { busy.append(cur); cur = s }
        }
        busy.append(cur)
        var out: [Segment] = []
        for (i, b) in busy.enumerated() {
            if i > 0 { out.append(.cut(busy[i - 1].1, b.0)) }
            out.append(.live(b.0, b.1))
        }
        if let last = out.last, end > last.end {
            out.append(end.timeIntervalSince(last.end) > gap ? .cut(last.end, end) : .live(last.end, end))
        }
        return out
    }

    var cuts: [Segment] { segments.filter(\.isCut) }

    /// The x of a time. A time inside a cut maps inside the cut band.
    func x(_ d: Date) -> CGFloat {
        var x: CGFloat = 0
        for s in segments {
            let w = s.isCut ? Self.cutWidth : liveWidth * CGFloat(s.length / liveTime)
            if d <= s.end || s == segments.last {
                let f = s.length > 0 ? CGFloat(min(max(0, d.timeIntervalSince(s.start)), s.length) / s.length) : 0
                return x + w * f
            }
            x += w
        }
        return x
    }

    /// The x range of each segment, in order.
    func frames() -> [(Segment, ClosedRange<CGFloat>)] {
        var x: CGFloat = 0
        return segments.map { s in
            let w = s.isCut ? Self.cutWidth : liveWidth * CGFloat(s.length / liveTime)
            defer { x += w }
            return (s, x...(x + w))
        }
    }
}

/// The filters of the rows under the graph.
enum TimelineFilter: String, CaseIterable {
    case all = "All", you = "You", agents = "Agents", git = "Git", ci = "CI", system = "System"

    func matches(_ e: Event) -> Bool {
        let k = e.kind.rawValue
        switch self {
        case .all: return true
        case .you: return e.actorType == .human
        case .agents: return e.actorType == .agent
        case .git: return k.hasPrefix("git.") || k.hasPrefix("pr.") || k.hasPrefix("worktree.") || k == "release.published"
        case .ci: return k.hasPrefix("ci.")
        case .system: return (e.actorType == .system || e.actorType == .provider) && !Self.git.matches(e) && !Self.ci.matches(e)
        }
    }
}
