import XCTest
import OverSireCore
@testable import OverSireAI

final class PromptTests: XCTestCase {
    let size = ProjectField(id: "FS", name: "Size", options: [StatusOption(id: "o1", name: "S", color: "GRAY"),
                                                              StatusOption(id: "o2", name: "L", color: "GRAY")])

    func testDraftSuggestionParse() {
        let ctx = DraftContext(projects: [("ocral/w1", "Fritz Tasks"), ("acme/1", "Board")], fields: [size])
        let reply = """
        Sure! Here it is:
        ```json
        {"title": "  \(String(repeating: "x", count: 80)).", "alternatives": ["Other", "Third"],
         "fields": {"size": "l", "Priority": "P0", "Size2": "S"}, "project": "OCRAL/w1", "reason": "personal"}
        ```
        """
        let sug = DraftSuggestion.parse(reply, ctx: ctx)
        XCTAssertEqual(sug?.title.count, 70)
        XCTAssertEqual(sug?.alternatives, ["Other", "Third"])
        XCTAssertEqual(sug?.fields, ["Size": "L"], "unknown fields and options drop")
        XCTAssertEqual(sug?.project, "ocral/w1", "the project key is normalized")
        XCTAssertEqual(sug?.reason, "personal")
        XCTAssertNil(DraftSuggestion.parse(#"{"title":"Fix it","project":"nope/1"}"#, ctx: ctx)?.project, "unknown project drops")
        XCTAssertNil(DraftSuggestion.parse("no json here", ctx: ctx))
    }

    func testDraftPrompt() throws {
        let ctx = DraftContext(projects: [("acme/1", "Board")], fields: [size])
        let p = try AITaskKind.draft.prompt(ctx.input(body: "the note", extra: ""))
        XCTAssertTrue(p.system.contains("\"project\"") && p.system.contains("\"fields\""))
        XCTAssertEqual(p.user, "Projects:\n- acme/1: Board\n\nFields:\n- Size: S, L\n\nNote:\nthe note")
        XCTAssertNil(p.maxTokens, "the draft uses the limit of the settings")
        let bare = try AITaskKind.draft.prompt(DraftContext().input(body: "n", extra: "Be brief."))
        XCTAssertFalse(bare.system.contains("\"project\""))
        XCTAssertTrue(bare.system.hasSuffix("Extra instructions from the user:\nBe brief."))
        XCTAssertEqual(bare.user, "Note:\nn")
    }

    func testUnfenced() {
        XCTAssertEqual(unfenced("```markdown\n## Context\nText\n```"), "## Context\nText")
        XCTAssertEqual(unfenced("  plain  "), "plain")
        XCTAssertEqual(unfenced("```a b\nx```"), "a b\nx", "a first line with a space is text")
        XCTAssertEqual(replyObject("Here:\n```json\n{\"a\":1}\n```")?["a"] as? Int, 1)
        XCTAssertNil(replyObject("} {"))
    }

    func testParseOrder() {
        let keys = ["FRITZ-2", "FRITZ-3"]
        XCTAssertEqual(AgentPrompts.parseOrder(#"{"order":["fritz-3","FRITZ-2"],"reason":"3 first"}"#, keys: keys)?.order, ["FRITZ-3", "FRITZ-2"])
        XCTAssertNil(AgentPrompts.parseOrder(#"{"order":["FRITZ-2","FRITZ-3"]}"#, keys: keys), "the same order is no suggestion")
        XCTAssertNil(AgentPrompts.parseOrder(#"{"order":["FRITZ-2"]}"#, keys: keys), "a missing key is refused")
    }

    func testCheckAndFailurePrompts() throws {
        let check = try AITaskKind.check.prompt(AgentPrompts.checkInput(key: "A-1", title: "T", quietMinutes: 12, phase: "working", ci: "none",
                                                                        prOpen: true, status: "unknown", tail: (1...80).map { "l\($0)" }))
        XCTAssertTrue(check.user.hasPrefix("Item A-1: T\nQuiet for 12 min. Agent state: working.\nCI: none. PR open: yes. Plane status: unknown.\n"))
        XCTAssertTrue(check.user.hasSuffix("l21\n" + (22...80).map { "l\($0)" }.joined(separator: "\n")), "the last 60 lines")
        let fail = try AITaskKind.failureReason.prompt(CIPrompts.failureInput(
            workflow: "CI", number: 9, branch: "main", sha: "abcdef12345", commit: "Fix", job: "build", files: [],
            errors: ["error: x"], tail: ["a", "b"]))
        XCTAssertTrue(fail.user.hasPrefix("Workflow: CI #9 on main (abcdef1)\nCommit: Fix\nJob: build\nChanged files: unknown\n\nLog:\nerror: x\n--- last lines ---\na\nb"))
    }

    func testTriagePrompt() throws {
        let p = try AITaskKind.triage.prompt(AgentPrompts.triageInput(template: "{KEY} {key} {title} {url} {body}", key: "TREBI-9",
                                                                       title: "T", url: "u", body: ""))
        XCTAssertEqual(p.user, "TREBI-9 trebi-9 T u (no description)")
    }

    func testTemplateSyntax() {
        let v = { (n: String) in ["a": " x ", "b": "", "c": "{{a}}", "text": "T"][n] ?? "" }
        XCTAssertEqual(PromptTemplate.fill("[{{a}}][{{a|trim}}][{{nope}}]", v), "[ x ][x][]")
        XCTAssertEqual(PromptTemplate.fill("{{#if a}}A{{a|trim}}{{/if}}{{#if b}}B{{/if}}-{{text}}", v), "Ax-T")
        XCTAssertEqual(PromptTemplate.fill("{{c}} {\"json\": 1}", v), "{{a}} {\"json\": 1}", "a value is not a template")
    }

    func testTemplateParse() throws {
        let t = try PromptTemplate(parsing: "---\ntaskKind: x\nversion: 2\ninputs: text\n---\n\n<!-- user -->\nHi {{text}}\n\n")
        XCTAssertEqual(t.version, 2)
        XCTAssertNil(t.maxTokens)
        XCTAssertEqual(t.render(AIInput(text: "you")), AIPrompt(system: "", user: "Hi you"))
        XCTAssertThrowsError(try PromptTemplate(parsing: "no front matter"))
        XCTAssertThrowsError(try PromptTemplate(parsing: "---\ntaskKind: x\nversion: 1\n---\n<!-- system -->\nonly system\n"))
    }
}
