import XCTest
import OverSireCore
import RuntimeOrca

/// Reads the real Orca app on this Mac. Run with OVERSIRE_LIVE=1 and Orca open.
final class OrcaLiveTests: XCTestCase {
    func testEnvironmentsAndCards() async throws {
        guard ProcessInfo.processInfo.environment["OVERSIRE_LIVE"] == "1" else { throw XCTSkip("set OVERSIRE_LIVE=1") }
        let rt = OrcaRuntime(environment: ProcessInfo.processInfo.environment["ORCA_ENV"], commands: LiveCommands())
        guard rt.installed else { throw XCTSkip("Orca is not installed") }
        _ = try await rt.version()
        let envs = try await rt.environments()
        XCTAssertEqual(envs.first, .local)
        let ws = try await rt.workspaces()
        if let w = ws.first { _ = try await rt.sessions(rt.workspaceRef(w.id)) }
        let first = try await rt.poll(since: nil)
        XCTAssertTrue(first.events.isEmpty)
    }

    /// One 2 MB random file to the local Orca, and to ORCA_ENV when it is set. ORCA_ROOT is a workspace folder of Orca.
    func testHostFiles() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSIRE_LIVE"] == "1" else { throw XCTSkip("set OVERSIRE_LIVE=1") }
        guard let root = env["ORCA_ROOT"] else { throw XCTSkip("set ORCA_ROOT to a workspace folder of Orca") }
        let data = Data((0..<2_000_000).map { _ in UInt8.random(in: 0...255) })
        var targets: [String?] = [nil]
        if let e = env["ORCA_ENV"], !e.isEmpty { targets.append(e) }
        for t in targets {
            let rt = OrcaRuntime(environment: t, commands: LiveCommands())
            guard rt.installed else { throw XCTSkip("Orca is not installed") }
            let dir = "/tmp/oversire/live-\(UUID().uuidString)"
            let paths = try await rt.writeFiles([HostFile(name: "random 2mb.bin", data: data)], workspacePath: root, dir: dir) { _, _ in }
            XCTAssertEqual(paths, [dir + "/random-2mb.bin"], t ?? "local")
        }
    }

    /// One ask/reply round. The test terminal of Orca (ORCA_TERMINAL_HANDLE) asks; OverSire answers as the coordinator.
    func testAskReplyRound() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSIRE_LIVE"] == "1" else { throw XCTSkip("set OVERSIRE_LIVE=1") }
        guard let me = env["ORCA_TERMINAL_HANDLE"] else { throw XCTSkip("run inside an Orca terminal") }
        let rt = OrcaRuntime(environment: env["ORCA_ENV"], commands: LiveCommands())
        guard rt.installed else { throw XCTSkip("Orca is not installed") }
        let coord = try await rt.coordinator()
        let body = #"{"round":1,"questions":[{"id":"q1","type":"single","text":"Live test: which store?","options":["SQLite","JSON files"]}]}"#
        var args = ["orchestration", "send", "--to", coord.address, "--from", me, "--type", "question", "--subject", "Question", "--body", body, "--json"]
        if let e = env["ORCA_ENV"], !e.isEmpty { args += ["--environment", e] }
        _ = try await LiveCommands().run(rt.exe, args, stdin: nil, timeout: .seconds(20))
        let session = rt.sessionRef(workspace: "live", handle: me)
        let q = try await rt.openQuestions(in: [session]).first { $0.items.first?.text == "Live test: which store?" }
        let open = try XCTUnwrap(q)
        let a = QuestionAnswer(question: open.id, items: [.init(id: "q1", choices: ["SQLite"])])
        let res1 = try await rt.answer(open, a)
        let res2 = try await rt.answer(open, a)
        XCTAssertEqual(res1, .sent)
        XCTAssertEqual(res2, .alreadyAnswered)
        let given = try await rt.answerGiven(open)
        XCTAssertEqual(given, a)
        let after = try await rt.openQuestions(in: [session])
        XCTAssertFalse(after.contains { $0.id == open.id })
    }

    /// Native questions of a real Claude Code session in Orca, in default permission mode.
    /// ORCA_CLAUDE_TERMINAL is its handle. ORCA_CLAUDE_DIR is its folder. The test sends prompts to it.
    func testNativeQuestions() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSIRE_LIVE"] == "1" else { throw XCTSkip("set OVERSIRE_LIVE=1") }
        guard let handle = env["ORCA_CLAUDE_TERMINAL"], let dir = env["ORCA_CLAUDE_DIR"] else {
            throw XCTSkip("set ORCA_CLAUDE_TERMINAL and ORCA_CLAUDE_DIR to a Claude Code terminal in Orca")
        }
        let rt = OrcaRuntime(environment: nil, commands: LiveCommands())
        guard rt.installed else { throw XCTSkip("Orca is not installed") }
        let s = rt.sessionRef(workspace: "live", handle: handle)
        func wait(_ via: SessionQuestion.Via, not old: QuestionID? = nil) async throws -> SessionQuestion {
            for _ in 0..<60 {
                if let q = try await rt.openQuestions(in: [s]).first(where: { $0.via == via && $0.id != old }) { return q }
                try await Task.sleep(for: .seconds(2))
            }
            throw XCTSkip("no \(via) question after 120 s")
        }
        func gone(_ id: QuestionID) async throws -> Bool {
            for _ in 0..<15 {
                if try await !rt.openQuestions(in: [s]).contains(where: { $0.id == id }) { return true }
                try await Task.sleep(for: .seconds(2))
            }
            return false
        }
        func keys(_ k: String) async throws { _ = try await LiveCommands().run(rt.exe, ["terminal", "send", "--terminal", handle, "--text", k], stdin: nil, timeout: .seconds(20)) }

        // A form with two tabs, answered in OverSire.
        try await rt.send(s, text: #"Use AskUserQuestion once with two questions. Q1 header "Store" single: "Which store?" options SQLite, JSON. "#
            + #"Q2 header "Tests" multiSelect: "Which tests?" options Unit, uishots, Live. Then reply with the answers only."#)
        // Without the transcript of this folder, OverSire reads the screen and answers one page at a time.
        let picks: [String: QuestionAnswer.Item] = ["Which store?": .init(id: "", choices: ["JSON"]),
                                                    "Which tests?": .init(id: "", choices: ["Unit"], other: "perf"),
                                                    "Ready to submit your answers?": .init(id: "", choices: ["Submit answers"])]
        var form = try await wait(.form)
        var pages: [String] = []
        while true {
            let item = try XCTUnwrap(form.items.first)
            pages.append(item.text)
            let pick = try XCTUnwrap(picks[item.text], item.text)
            let sent = try await rt.answer(form, QuestionAnswer(question: form.id, items: [.init(id: item.id, choices: pick.choices, other: pick.other)]))
            XCTAssertEqual(sent, .sent)
            guard let next = try await rt.openQuestions(in: [s]).first(where: { $0.via == .form && $0.id != form.id }) else { break }
            form = next
        }
        XCTAssertEqual(pages, ["Which store?", "Which tests?", "Ready to submit your answers?"])
        let formGone = try await gone(form.id)
        XCTAssertTrue(formGone)

        // A form answered in Orca: the card goes, and OverSire sends no key.
        try await rt.send(s, text: #"Use AskUserQuestion once with one question. Header "Color" single: "Which color?" options Red, Blue. Then reply with the answer only."#)
        let orcaForm = try await wait(.form, not: form.id)
        XCTAssertEqual(orcaForm.items.first?.text, "Which color?")
        try await keys("2")
        if try await !gone(orcaForm.id) { try await keys("1") }
        let orcaGone = try await gone(orcaForm.id)
        XCTAssertTrue(orcaGone)
        let late = try await rt.answer(orcaForm, QuestionAnswer(question: orcaForm.id, items: [.init(id: orcaForm.items[0].id, choices: ["Red"])]))
        XCTAssertEqual(late, .alreadyAnswered)

        // A permission prompt, answered Yes in OverSire. The command runs.
        let stamp = (dir as NSString).appendingPathComponent("stamp-\(Int(Date().timeIntervalSince1970)).txt")
        try await rt.send(s, text: "Run this exact Bash command and nothing else: date > \(stamp)")
        let perm = try await wait(.permission)
        XCTAssertEqual(perm.items.first?.header, "Bash")
        let yes = try await rt.answer(perm, QuestionAnswer(question: perm.id, items: [.init(id: "q1", choices: ["Yes"])]))
        XCTAssertEqual(yes, .sent)
        var ran = false
        for _ in 0..<30 where !ran {
            ran = FileManager.default.fileExists(atPath: stamp)
            if !ran { try await Task.sleep(for: .seconds(1)) }
        }
        XCTAssertTrue(ran, "the command did not run")

        // A turn that ends with a question. The answer is the next prompt.
        try await rt.send(s, text: "Reply with only this text: Do you want me to add a third line?")
        let turn = try await wait(.turn)
        XCTAssertEqual(turn.items.first?.text, "Do you want me to add a third line?")
        let reply = try await rt.answer(turn, QuestionAnswer(question: turn.id, items: [.init(id: "q1", other: "No. Reply with the word OK.")]))
        XCTAssertEqual(reply, .sent)
        let screen = try await rt.output(s, lines: 40).joined(separator: "\n")
        XCTAssertTrue(screen.contains("No. Reply with the word OK."), screen)
        let again = try await rt.answer(turn, QuestionAnswer(question: turn.id, items: [.init(id: "q1", other: "No")]))
        XCTAssertEqual(again, .alreadyAnswered)
    }
}
