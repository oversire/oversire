import XCTest
@testable import OverSireCore

final class LaunchCommandTests: XCTestCase {
    func testDefaults() throws {
        XCTAssertEqual(LaunchCommand.defaultFor(.claude).template, "claude -n {name}")
        XCTAssertEqual(LaunchCommand.defaultFor(.codex).template, "codex")
        XCTAssertEqual(try LaunchCommand.defaultFor(.claude).resolve(name: "FRITZ-7", key: "FRITZ-7", title: "x"), "claude -n FRITZ-7")
        XCTAssertEqual(try LaunchCommand.intakeDefault.resolve(name: "Fix the S3 retry", key: "", title: ""),
                       "claude -n 'Fix the S3 retry' --permission-mode plan")
        XCTAssertEqual(LaunchCommand.intakeDefault.program, "claude")
    }

    func testResolve() throws {
        let c = LaunchCommand("  claude -n {name} --append '{KEY}' {key} {title} ")
        XCTAssertEqual(try c.resolve(name: "ENG-4", key: "ENG-4", title: "Don't; break | it\nnow"),
                       "claude -n ENG-4 --append 'ENG-4' eng-4 'Dont  break   it now'")
        XCTAssertEqual(LaunchCommand.quote(""), "''")
        XCTAssertEqual(LaunchCommand.quote("a/b:c.d_e-f"), "a/b:c.d_e-f")
        XCTAssertEqual(LaunchCommand.quote("$(rm -rf ~)"), "' rm -rf ~)'")
        XCTAssertFalse(try c.resolve(name: "x", key: "x", title: "$(x) `y` a&b <c>").contains("$("))
    }

    func testValidate() {
        func problem(_ t: String) -> LaunchCommand.Problem? {
            do { try LaunchCommand(t).validate(); return nil } catch { return error as? LaunchCommand.Problem }
        }
        XCTAssertNil(problem("claude -n {name} --model opus"))
        XCTAssertNil(problem("/opt/bin/codex --full-auto"))
        XCTAssertNil(problem("claude --append-system-prompt \"be brief\""))
        XCTAssertEqual(problem("   "), .empty)
        XCTAssertEqual(problem("{name} claude"), .noProgram)
        XCTAssertEqual(problem("claude -n {item}"), .unknownKey("item"))
        XCTAssertEqual(problem("claude -n 'x"), .openQuote)
        XCTAssertEqual(problem("claude -n \"x"), .openQuote)
        for op in LaunchCommand.shellOperators {
            XCTAssertEqual(problem("claude -n {name} \(op) echo"), .shellOperator(op), op)
        }
        XCTAssertEqual(LaunchCommand.Problem.shellOperator("\n").description, "Remove the shell operator newline.")
        XCTAssertThrowsError(try LaunchCommand("claude; rm").resolve(name: "a", key: "a", title: "a"))
    }

    func testSkipsPermissions() {
        XCTAssertTrue(LaunchCommand("claude -n {name} --dangerously-skip-permissions").skipsPermissions)
        XCTAssertTrue(LaunchCommand("claude  --permission-mode   bypassPermissions").skipsPermissions)
        XCTAssertTrue(LaunchCommand("codex --dangerously-bypass-approvals-and-sandbox").skipsPermissions)
        XCTAssertFalse(LaunchCommand("claude --permission-mode plan").skipsPermissions)
        XCTAssertFalse(LaunchCommand("claude --dangerously-skip-permissionsx").skipsPermissions)
    }

    func testCodable() throws {
        let c = LaunchCommand("codex --full-auto")
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(c), as: UTF8.self), #""codex --full-auto""#)
        XCTAssertEqual(try JSONDecoder().decode(LaunchCommand.self, from: JSONEncoder().encode(c)), c)
    }
}
