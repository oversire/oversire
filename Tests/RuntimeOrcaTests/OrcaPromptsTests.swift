import XCTest
import OverSireCore
import OverSireTestKit
@testable import RuntimeOrca

/// Screens recorded from Claude Code 2.1.308 in Orca 1.4.223 on 2026-10-22.
final class OrcaPromptsTests: XCTestCase {
    typealias F = OrcaFormsTests
    static let v = "2.1.308"
    static let command = "git -C . status --short > status.txt"
    static func screen(_ name: String) -> [String] { F.screen("\(name)-\(v)") }
    static func read(lines: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": ["terminal": ["tail": lines]]])
        return String(decoding: data, as: UTF8.self)
    }
    static func read(_ name: String) -> String { read(lines: screen(name)) }
    static func ps(_ tool: String, _ input: String?) -> String {
        let i = input.map { "\"\($0)\"" } ?? "null"
        return #"{"ok":true,"result":{"worktrees":[{"worktreeId":"b07c::/w","path":"/w","agents":["#
            + #"{"paneKey":"tab2:leaf2","state":"waiting","agentType":"claude","toolName":"\#(tool)","toolInput":\#(i),"stateStartedAt":1792669871453}]}]}}"#
    }
    static let sent = #"{"ok":true,"result":{"send":{"accepted":true,"bytesWritten":1}}}"#
    static let down = FormKeys.down

    /// The screen with the cursor on choice `n`.
    static func cursor(_ lines: [String], on n: Int) -> [String] {
        lines.map { row in
            var r = row
            if let m = r.firstIndex(of: "❯"), ClaudeForm.option(r) != nil { r.replaceSubrange(m...m, with: " ") }
            if ClaudeForm.option(r)?.0 == n, let d = r.firstIndex(where: \.isNumber), r.distance(from: r.startIndex, to: d) >= 2 {
                let m = r.index(d, offsetBy: -2)
                r.replaceSubrange(m...m, with: "❯")
            }
            return r
        }
    }

    var orca: ReplayOrca!
    var files: F.Files!

    override func setUp() {
        orca = ReplayOrca()
        files = F.Files()
        orca.on("terminal list", F.terminals)
        orca.on("orchestration run-current", OrcaAskFixtures.bound)
        orca.on("orchestration inbox", #"{"ok":true,"result":{"messages":[]}}"#)
        orca.on("terminal send", Self.sent)
    }

    func runtime() -> OrcaRuntime {
        let rt = OrcaRuntime(exe: "/bin/sh", environment: nil, commands: orca, transcripts: files)
        rt.formWait = .zero
        return rt
    }

    func open(_ rt: OrcaRuntime) async throws -> SessionQuestion {
        let qs = try await rt.openQuestions(in: [rt.sessionRef(workspace: "b07c::/w", handle: "term_bash")])
        return try XCTUnwrap(qs.first)
    }

    func testPermissionScreens() throws {
        let bash = try XCTUnwrap(ClaudePrompt.parse(Self.screen("permission-bash")))
        XCTAssertEqual(bash.kind, .permission)
        XCTAssertEqual(bash.title, "Bash command")
        XCTAssertEqual(bash.question, "Do you want to proceed?")
        XCTAssertEqual(bash.options.map(\.n), [1, 2, 3, 4])
        XCTAssertEqual(bash.options[1].label, "Yes, and always allow access to "
            + "/private/tmp/claude-501/-Users-fritz-Projects-oversire-workspace/d5fcef0c-7455-4f95-b07e-34552b4e76b4/scratchpad/formlab from this project",
            "a row that fills the width wraps in a word")
        XCTAssertEqual(bash.options[3].label, "No")
        XCTAssertEqual(bash.cursor, "1. Yes")
        XCTAssertEqual(bash.typed, 4)
        XCTAssertFalse(bash.amending)
        XCTAssertTrue(bash.body.contains(Self.command))

        let git = try XCTUnwrap(ClaudePrompt.parse(Self.screen("permission-bash-git")))
        XCTAssertEqual(git.options[1].label, "Yes, and don’t ask again for: git *")

        let typing = try XCTUnwrap(ClaudePrompt.parse(Self.screen("permission-amend-typing")))
        XCTAssertTrue(typing.amending)
        XCTAssertEqual(typing.cursor, "4. No, use git status without a file")
        XCTAssertEqual(typing.key, bash.key, "the same prompt while the text goes in")

        for (name, title, question) in [("permission-write", "Create file", "Do you want to create notes.md?"),
                                        ("permission-edit", "Edit file", "Do you want to make this edit to notes.md?"),
                                        ("permission-read", "Read file", "Do you want to proceed?")] {
            let p = try XCTUnwrap(ClaudePrompt.parse(Self.screen(name)), name)
            XCTAssertEqual(p.title, title)
            XCTAssertEqual(p.question, question)
            XCTAssertEqual(p.options.count, 3, name)
            XCTAssertEqual(p.typed, 3, name)
        }
    }

    func testPlanScreens() throws {
        let plan = try XCTUnwrap(ClaudePrompt.parse(Self.screen("plan-approval")))
        XCTAssertEqual(plan.kind, .plan)
        XCTAssertEqual(plan.title, "Ready to code?")
        XCTAssertEqual(plan.question, "Claude has written up a plan and is ready to execute. Would you like to proceed?")
        XCTAssertEqual(plan.options.map(\.label), ["Yes, clear context (6% used) and use auto mode", "Yes, and use auto mode",
                                                   "Yes, manually approve edits", "Tell Claude what to change"], "the hint row is no label")
        XCTAssertEqual(plan.typed, 4)
        XCTAssertTrue(plan.body.contains("Plan: Append \"world\" to notes.md"))
        XCTAssertEqual(ClaudePrompt.parse(Self.screen("plan-feedback-typing"))?.cursor, "4. use one step only")
    }

    func testNoPrompt() {
        let others = ["form-local", "form-multi", "form-review", "false-footer", "no-form-answered"].map(F.screen)
            + ["form-single", "form-other-typing", "form-review2", "form-submitted", "turn-question"].map(Self.screen)
            + (0...10).map { F.screen(String(format: "flow-\(Self.v)-%02d", $0)) }
        for (i, s) in others.enumerated() { XCTAssertNil(ClaudePrompt.parse(s), "screen \(i)") }
    }

    func testItems() throws {
        let bash = try XCTUnwrap(ClaudePrompt.parse(Self.screen("permission-bash"))).item(tool: "Bash", input: Self.command)
        XCTAssertEqual(bash.header, "Bash")
        XCTAssertEqual(bash.text, Self.command)
        XCTAssertEqual(bash.why, "Do you want to proceed?")
        XCTAssertEqual(bash.kind, .single)
        XCTAssertEqual(bash.options.count, 4)
        XCTAssertTrue(bash.allowsOther, "No takes a text")

        let write = try XCTUnwrap(ClaudePrompt.parse(Self.screen("permission-write"))).item(tool: "Write", input: "/private/tmp/formlab/notes.md")
        XCTAssertEqual([write.header, write.text], ["Write", "notes.md"])

        let plan = try XCTUnwrap(ClaudePrompt.parse(Self.screen("plan-approval"))).item(tool: "ExitPlanMode", input: nil)
        XCTAssertEqual([plan.header, plan.text], ["Plan", "Append \"world\" to notes.md"])
    }

    func testOpenTool() {
        let jsonl = """
            {"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}
            {"message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]}}
            {"message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{}}]}}
            """
        XCTAssertEqual(ClaudePrompt.openTool("Bash", in: Data(jsonl.utf8)), "t2")
        XCTAssertNil(ClaudePrompt.openTool("Bash", in: Data(jsonl.utf8).prefix(160)), "the call has a result")
        XCTAssertNil(ClaudePrompt.openTool("Edit", in: Data(jsonl.utf8)))
        XCTAssertNil(ClaudePrompt.openTool("Bash", input: "rm -rf build", in: Data(jsonl.utf8)), "the open call has another command")
    }

    func testPermissionQuestion() async throws {
        orca.on("worktree ps", Self.ps("Bash", Self.command))
        orca.on("terminal read", Self.read("permission-bash"))
        let rt = runtime()
        let q = try await open(rt)
        XCTAssertEqual(q.via, .permission)
        XCTAssertTrue(q.answerable)
        XCTAssertTrue(q.id.rawValue.hasPrefix("orca:local:form:term_bash:"), q.id.rawValue)
        XCTAssertEqual(q.items.first?.header, "Bash")

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-\(UUID().uuidString).jsonl")
        try Data(#"{"message":{"content":[{"type":"tool_use","id":"toolu_bash","name":"Bash","input":{"command":"\#(Self.command)"}}]}}"#.utf8).write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        files.file = dir.path
        let named = try await open(rt)
        XCTAssertEqual(named.id.rawValue, "orca:local:form:toolu_bash", "the transcript gives the call")
    }

    func testChoiceSendsTheNumber() async throws {
        orca.on("worktree ps", Self.ps("Bash", Self.command))
        orca.on("terminal read", Self.read("permission-bash"))
        let rt = runtime()
        let q = try await open(rt)
        orca.on("terminal read", Self.read("permission-bash"), Self.read("permission-bash"), Self.read("permission-edit"))
        let r = try await rt.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: ["Yes"])]))
        XCTAssertEqual(r, .sent, "the next prompt shows")
        XCTAssertEqual(orca.args("terminal send").map { $0[5] }, ["1"])
    }

    func testTextForAPermission() async throws {
        orca.on("worktree ps", Self.ps("Bash", Self.command))
        orca.on("terminal read", Self.read("permission-bash"))
        let rt = runtime()
        let q = try await open(rt)
        let bash = Self.screen("permission-bash")
        orca.on("terminal read", list: [Self.read(lines: bash), Self.read(lines: bash)] + (2...4).map { Self.read(lines: Self.cursor(bash, on: $0)) }
            + [Self.read("permission-amend-typing"), Self.read("permission-amend-typing"), Self.read("turn-question")])
        let r = try await rt.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "q1", other: "use git status without a file")]))
        XCTAssertEqual(r, .sent)
        XCTAssertEqual(orca.args("terminal send").map { $0[5] }, [Self.down, Self.down, Self.down, "\t", "use git status without a file", "\r"])
    }

    func testTextForAPlan() async throws {
        orca.on("worktree ps", Self.ps("ExitPlanMode", nil))
        orca.on("terminal read", Self.read("plan-approval"))
        let rt = runtime()
        let q = try await open(rt)
        XCTAssertEqual(q.items.first?.header, "Plan")
        let plan = Self.screen("plan-approval")
        orca.on("terminal read", Self.read(lines: plan), Self.read(lines: plan), Self.read(lines: Self.cursor(plan, on: 4)), Self.read("plan-feedback-typing"),
                Self.read("turn-question"))
        let r = try await rt.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "q1", other: "use one step only")]))
        XCTAssertEqual(r, .sent)
        XCTAssertEqual(orca.args("terminal send").map { $0[5] }, ["4", "use one step only", "\r"])
    }

    func testPromptAnsweredInOrcaSendsNoKey() async throws {
        orca.on("worktree ps", Self.ps("Bash", Self.command))
        orca.on("terminal read", Self.read("permission-bash"))
        let rt = runtime()
        let q = try await open(rt)
        let a = QuestionAnswer(question: q.id, items: [.init(id: "q1", choices: ["Yes"])])
        for after in ["turn-question", "permission-edit"] {
            orca.on("terminal read", Self.read(after))
            let r = try await rt.answer(q, a)
            XCTAssertEqual(r, .alreadyAnswered, after)
        }
        XCTAssertTrue(orca.args("terminal send").isEmpty)
    }

    func testPromptThatMovesStopsTheKeys() async throws {
        orca.on("worktree ps", Self.ps("Bash", Self.command))
        orca.on("terminal read", Self.read("permission-bash"))
        let rt = runtime()
        let q = try await open(rt)
        let bash = Self.screen("permission-bash")
        orca.on("terminal read", Self.read(lines: bash), Self.read(lines: bash), Self.read(lines: Self.cursor(bash, on: 3)))
        do {
            _ = try await rt.answer(q, QuestionAnswer(question: q.id, items: [.init(id: "q1", other: "no")]))
            XCTFail("no error")
        } catch ProviderError.vendor(let code, _) {
            XCTAssertEqual(code, "form_changed")
        }
        XCTAssertEqual(orca.args("terminal send").map { $0[5] }, [Self.down], "the user moved the cursor")
    }
}
