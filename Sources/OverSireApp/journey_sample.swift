import Foundation
import OverSireCore

// A sample item journey for the tests and `--uishots` (OVERSIRE-383, OVERSIRE-384): OVERSIRE-377 and the sub-items
// 378 to 381 over five days. 378 and 381 ship in v0.14.0, 379 in cli v0.9.2, 380 waits for review round 2.
enum JourneySample {
    static let key = "OVERSIRE-377"
    static let subs = ["OVERSIRE-378", "OVERSIRE-379", "OVERSIRE-380", "OVERSIRE-381"]
    static let titles = ["Contract", "Daemon events table", "Capture", "Git watcher"]
    static var me: String { MY_EMAIL ?? "ada@example.com" }

    /// Your last look: Thu 15:05.
    static func since(now: Date) -> Date { day(3, 15, 5, now) }

    /// A time `ago` days before the day of `now`.
    static func day(_ ago: Int, _ h: Int, _ m: Int, _ now: Date) -> Date {
        let c = Calendar.current
        return c.date(byAdding: DateComponents(day: -ago, hour: h, minute: m), to: c.startOfDay(for: now))!
    }

    /// folded: an agent turn runs now, and you looked 4 min ago.
    static func rows(now: Date, folded: Bool = false) -> [Event] {
        var out: [Event] = []
        func add(_ at: Date, _ kind: Event.Kind, _ item: String, _ actor: ActorType, _ summary: String, session: String? = nil,
                 _ payload: [String: JSONValue]? = nil, isPrivate: Bool = false) {
            let who = actor == .human ? me : actor == .agent ? "claude" : actor == .provider ? "github" : "oversire"
            let d = EventDraft(id: "s\(out.count + 1)", at: at, kind: kind, item: item, parentItem: item == key ? nil : key, project: "oversire",
                               repo: kind.rawValue.hasPrefix("ci.") || kind.rawValue.hasPrefix("git.") ? "oversire/cli" : nil, machine: "mba",
                               session: session, actorType: actor, actor: who, via: actor == .human ? "app@mba" : "daemon@mba",
                               summary: summary, payload: payload, isPrivate: isPrivate)
            out.append(Event(seq: Int64(out.count + 1), seenAt: at, draft: d))
        }
        func t(_ ago: Int, _ h: Int, _ m: Int) -> Date { day(ago, h, m, now) }
        let (a, b, c, d) = (subs[0], subs[1], subs[2], subs[3])
        func turn(_ i: String, _ s: String, _ n: Int, _ from: Date, _ to: Date?, tools: Int = 20, steer: Bool = false) {
            add(from, .turnStarted, i, .agent, "Turn \(n)", session: s, ["turn": .int(n), "steer": .bool(steer)])
            if let to { add(to, .turnEnded, i, .agent, "Turn \(n) ended", session: s, ["turn": .int(n), "tools": .int(tools)]) }
        }

        // Tue: the plan, then 378 and 381.
        add(t(5, 9, 0), .itemCreated, key, .human, "Events table and item catch-up")
        turn(a, "sa", 1, t(5, 9, 30), t(5, 11, 10), tools: 34)
        turn(d, "sd", 1, t(5, 10, 0), t(5, 12, 0))
        add(t(5, 12, 10), .reviewReady, a, .agent, "Code review of 378 is ready", session: "sa", ["kind": .string("code"), "round": .int(1)])
        add(t(5, 12, 15), .reviewReady, d, .agent, "Code review of 381 is ready", session: "sd", ["kind": .string("code"), "round": .int(1)])
        add(t(5, 14, 0), .reviewApproved, a, .human, "Approved 378", ["kind": .string("code"), "round": .int(1)])
        add(t(5, 14, 5), .reviewApproved, d, .human, "Approved 381", ["kind": .string("code"), "round": .int(1)])

        // Wed: merges and v0.14.0, then 379, then a question on 380.
        add(t(4, 9, 0), .prMerged, a, .provider, "oversire#212 merged")
        add(t(4, 9, 5), .prMerged, d, .provider, "cli#88 merged")
        add(t(4, 9, 30), .releasePublished, key, .provider, "v0.14.0",
            ["tag": .string("v0.14.0"), "items": .array([.string(a), .string(d)])])
        turn(b, "sb", 1, t(4, 9, 40), t(4, 10, 40))
        add(t(4, 10, 50), .reviewReady, b, .agent, "Code review of 379 is ready", session: "sb", ["kind": .string("code"), "round": .int(1)])
        add(t(4, 13, 0), .reviewApproved, b, .human, "Approved 379", ["kind": .string("code"), "round": .int(1)])
        turn(c, "sc", 1, t(4, 15, 0), t(4, 16, 30))
        add(t(4, 16, 35), .waitStarted, c, .agent, "Keep pending comments in SQLite or in JSON?", session: "sc",
            ["reason": .string("question"), "question": .string("Keep pending comments in SQLite or in JSON?")])
        add(t(4, 17, 10), .questionAnswered, c, .human, "SQLite", session: "sc", ["question": .string("One store for the daemon.")])
        add(t(4, 17, 10), .waitEnded, c, .agent, "Answered", session: "sc")

        // Thu: 379 ships, 380 round 1, your review, a CI failure and the fix.
        add(t(3, 9, 0), .prMerged, b, .provider, "cli#90 merged")
        turn(c, "sc", 2, t(3, 10, 0), t(3, 12, 30), tools: 41)
        add(t(3, 12, 40), .reviewReady, c, .agent, "Code review of 380 is ready", session: "sc", ["kind": .string("code"), "round": .int(1)])
        add(t(3, 14, 0), .reviewSubmitted, c, .human, "Keep the comments in SQLite. Drop the JSON copy.",
            ["kind": .string("code"), "round": .int(1), "comments": .int(3)])
        turn(c, "sc", 3, t(3, 14, 10), t(3, 15, 0))
        add(t(3, 15, 5), .itemViewed, key, .human, "Opened the item page", ["page": .string("overview")])
        add(t(3, 15, 15), .gitCommit, c, .agent, "Keep pending comments in SQLite")
        add(t(3, 15, 20), .ciCompleted, c, .provider, "cli test #2243 failed: TestMergePartialFail",
            ["conclusion": .string("failure"), "failed": .array([.object(["job": .string("go test"), "step": .string("TestMergePartialFail")])])])
        turn(c, "sc", 4, t(3, 15, 30), t(3, 16, 30), steer: true)
        add(t(3, 15, 50), .gitCommit, c, .agent, "Fix a partial merge")
        add(t(3, 16, 10), .gitCommit, c, .agent, "Answer review round 1")
        add(t(3, 16, 25), .ciCompleted, c, .provider, "cli test #2244 passed", ["conclusion": .string("success")])
        add(t(3, 16, 40), .reviewReady, c, .agent, "Code review of 380 is ready, round 2", session: "sc", ["kind": .string("code"), "round": .int(2)])
        add(t(3, 17, 30), .releasePublished, key, .provider, "cli v0.9.2", ["tag": .string("cli v0.9.2"), "items": .array([.string(b)])])

        // Sat: the nightly CI run.
        add(t(1, 11, 0), .ciCompleted, c, .provider, "cli nightly #2260 passed", ["conclusion": .string("success")])

        if folded {
            add(now.addingTimeInterval(-50 * 60), .reviewSubmitted, c, .human, "Rename the table to events.", ["kind": .string("code"), "round": .int(2)])
            add(now.addingTimeInterval(-12 * 60), .turnStarted, c, .agent, "Turn 6", session: "sc", ["turn": .int(6)])
            add(now.addingTimeInterval(-4 * 60), .itemViewed, key, .human, "Opened the item page", ["page": .string("overview")])
        }
        return out
    }

    /// The AI recap of the rows after your last look.
    static func recap(rows: [Event]) -> Recap {
        func id(_ s: String) -> [String] { rows.filter { $0.summary.hasPrefix(s) }.map(\.id) }
        return Recap(lines: [CatchUp.Line(mark: "✕", text: "380: CI failed on a partial merge. The agent fixed it in 2 commits.", at: nil, ids: id("cli test #2243")),
                             CatchUp.Line(mark: "◆", text: "380 is ready for review round 2.", at: nil, ids: id("Code review of 380 is ready, round 2")),
                             CatchUp.Line(mark: "★", text: "cli v0.9.2 shipped 379.", at: nil, ids: id("cli v0.9.2"))],
                     decided: [],
                     choices: [CatchUp.Line(mark: "◆", text: "Pending comments stay in SQLite, in one table for each round.", at: nil, ids: id("Keep pending comments"))],
                     hash: "", at: Date())
    }
}
