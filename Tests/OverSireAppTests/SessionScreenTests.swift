import OverSireCore
import XCTest
@testable import OverSireApp

// Recorded Orca screens of real sessions (trimmed). `expect` is the state that a person gave each one.
final class SessionScreenTests: XCTestCase {
    struct Case: Decodable {
        let state: String
        let message: String
        let screen: [String]
        let expect: String
        let shells: Int
    }

    private func load(_ name: String) throws -> Case {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/sessions/\(name).json")
        return try JSONDecoder().decode(Case.self, from: Data(contentsOf: url))
    }

    private let all = ["oversire-109", "oversire-121", "oversire-91", "oversire-137", "trebi-422", "towertail-61", "background"]

    func testTheLastTurnHasNoHarnessUI() throws {
        for name in all {
            let s = HarnessScreen(try load(name).screen)
            let turn = s.lastTurn()
            for ui in ["Opus 5.5 (1M context) |", "⏵⏵", "new task? /clear", "(disable recaps in /config)", "Tip:"] {
                XCTAssertFalse(turn.contains(ui), "\(name): the turn holds \"\(ui)\"")
            }
            XCTAssertFalse(turn.components(separatedBy: "\n").contains { $0.trimmingCharacters(in: .whitespaces) == "❯" }, name)
            XCTAssertFalse(turn.contains("─────"), name)
        }
    }

    func testTheLastTurnStartsAfterTheLastUserPrompt() throws {
        let turn = HarnessScreen(try load("oversire-109").screen).lastTurn()
        XCTAssertTrue(turn.hasPrefix("  Ran 3 shell commands\n⏺ No, OVERSIRE-109 is not done."), turn)
        XCTAssertFalse(turn.contains("is ticket done?"))
        XCTAssertTrue(turn.contains("※ recap: Snap Basket (OVERSIRE-109) is released in v1.3.9"))
        XCTAssertEqual(HarnessScreen(try load("oversire-109").screen).lastTurn(limit: 50).count, 50)
    }

    func testShellsAndRecap() throws {
        for name in all {
            let c = try load(name)
            XCTAssertEqual(HarnessScreen(c.screen).shells, c.shells, name)
        }
        let r = HarnessScreen(try load("oversire-109").screen).recap
        XCTAssertEqual(r, "Snap Basket (OVERSIRE-109) is released in v1.3.9, but the ticket stays In Progress because the manual Mac check "
                          + "in OVERSIRE-117 is still open. Next, you run that check, especially a real send to Plane and Orca, and tell me the result.")
    }

    func testTheFingerprintIgnoresTheSpinnerAndTheStatusLine() throws {
        let lines = try load("oversire-137").screen
        let a = HarnessScreen(lines)
        XCTAssertEqual(a.counter, "5m 56s · ↓ 15.6k tokens")
        let ticked = lines.map {
            $0.replacingOccurrences(of: "✽ Puttering… (5m 56s · ↓ 15.6k tokens)", with: "✶ Puttering… (6m 12s · ↓ 16.1k tokens)")
                .replacingOccurrences(of: "6.6 min", with: "7.0 min")
        }
        XCTAssertNotEqual(ticked, lines)
        let b = HarnessScreen(ticked)
        XCTAssertEqual(a.fingerprint, b.fingerprint)
        XCTAssertEqual(b.counter, "6m 12s · ↓ 16.1k tokens")
        XCTAssertNotEqual(a.fingerprint, HarnessScreen(Array(lines.dropFirst())).fingerprint)

        var w = SessionWatch(at: Date(timeIntervalSince1970: 0))
        w.observe(a, at: Date(timeIntervalSince1970: 60))
        XCTAssertFalse(w.ticking)
        w.observe(b, at: Date(timeIntervalSince1970: 120))
        XCTAssertTrue(w.ticking, "only the counter moved")
        XCTAssertEqual(w.changedAt, Date(timeIntervalSince1970: 60))
        w.observe(HarnessScreen(Array(lines.dropFirst())), at: Date(timeIntervalSince1970: 180))
        XCTAssertFalse(w.ticking)
        XCTAssertEqual(w.changedAt, Date(timeIntervalSince1970: 180))
    }

    func testTheEndCheckFindsTheBlockedSessions() throws {
        for name in all {
            let c = try load(name)
            guard c.state == "done" else { continue }
            let s = HarnessScreen(c.screen)
            let r = SessionEnd.read(message: c.message, turn: s.lastTurn(), recap: s.recap, status: .progress)
            XCTAssertEqual(r != nil, c.expect == "blocked", "\(name): \(String(describing: r))")
        }
    }

    func testTheStepsOfTheBlockedSessions() throws {
        let m = try load("oversire-109")
        let a = try XCTUnwrap(SessionEnd.read(message: m.message, turn: "", recap: nil, status: .progress))
        XCTAssertEqual(a.steps.count, 7)
        XCTAssertEqual(a.steps.first?.text, "turning on the Screen Recording permission")
        XCTAssertEqual(a.steps.first?.kind, "manual-check")

        let r = try XCTUnwrap(SessionEnd.read(message: try load("oversire-121").message, turn: "", recap: nil, status: .progress))
        XCTAssertEqual(r.steps.map(\.text), ["Connect, repair and disconnect with the real cloud.", "The AI Test button with a real key.",
                                             "The menu bar gear opens Settings in the window."])

        let t = try XCTUnwrap(SessionEnd.read(message: try load("towertail-61").message, turn: "", recap: nil, status: .progress))
        XCTAssertEqual(t.steps.first?.kind, "secret")
        XCTAssertEqual(t.blockedBy, ["TOWERTAIL-76"])
    }

    func testTheEndCheckWithoutAMessageReadsTheTurn() throws {
        let c = try load("towertail-61")
        let s = HarnessScreen(c.screen)
        XCTAssertNotNil(SessionEnd.read(message: "", turn: s.lastTurn(), recap: s.recap, status: .progress))
        XCTAssertNil(SessionEnd.read(message: "", turn: HarnessScreen(try load("trebi-422").screen).lastTurn(), recap: nil, status: .done))
    }

    func testABackgroundShellHoldsTheSlot() throws {
        let s = HarnessScreen(try load("background").screen)
        let f = SessionFacts(phase: .done, shells: s.shells)
        XCTAssertEqual(f.state(quietAfter: 600), .background)
        XCTAssertTrue(f.state(quietAfter: 600).holdsSlot)
    }

    func testTheReportOfTheChecklist() {
        var e = SessionEnd(id: "1", key: "A-1", message: "m", verdict: .blocked,
                           steps: [.init(text: "one", kind: "manual-check"), .init(text: "two", kind: "secret")],
                           followUpAt: nil, blockedBy: [], at: Date())
        e.steps[1].ticked = true
        XCTAssertEqual(e.report, "Manual check: 1 of 2 pass.\n- [ ] one\n- [x] two")
    }

    func testTheEndReplyParse() throws {
        let p = try XCTUnwrap(SessionEnd.parse(#"{"state":"blocked","steps":[{"text":"Set the token","kind":"secret"}],"followUpAt":"2026-11-02","blockedBy":["a-1"]}"#))
        XCTAssertEqual(p.0, .blocked)
        XCTAssertEqual(p.1.first?.kind, "secret")
        XCTAssertNotNil(p.2)
        XCTAssertEqual(p.3, ["A-1"])
        XCTAssertNil(SessionEnd.parse("no"))
    }
}
