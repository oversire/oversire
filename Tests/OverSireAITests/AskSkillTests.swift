import XCTest
@testable import OverSireAI

/// Runs the oversire-ask script with python3 and a fake orca that logs its arguments.
final class AskSkillTests: XCTestCase {
    var dir: URL!

    override func setUpWithError() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { throw XCTSkip("no python3") }
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ask-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AskSkill.script.write(to: dir.appendingPathComponent("oversire-ask"), atomically: true, encoding: .utf8)
        let fake = #"""
            #!/bin/bash
            D="$(dirname "$0")"
            printf '%s\n' "$*" >> "$D/log"
            case "$2" in
              run-list) cat "$D/runs.json" ;;
              send) echo '{"ok":true,"result":{"message":{"id":"msg_1"}}}' ;;
              check)
                n=$(( $(cat "$D/n" 2>/dev/null || echo 0) + 1 )); echo $n > "$D/n"
                if [ $n -lt 2 ]; then echo '{"ok":true,"result":{"messages":[{"id":"msg_1","thread_id":"msg_1","body":"x"}]}}'
                else echo '{"ok":true,"result":{"messages":[{"id":"msg_2","thread_id":"msg_1","body":"{\"round\":1,\"answers\":{\"q1\":\"SQLite\"}}"}]}}'; fi ;;
            esac
            """#
        let orca = dir.appendingPathComponent("orca")
        try fake.write(to: orca, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: orca.path)
        try runs(#"{"ok":true,"result":{"runs":[{"id":"run_old","objective":"OverSire questions","created_at":"2026-10-19T00:00:00Z"},{"id":"run_new","objective":"OverSire questions","created_at":"2026-10-21T00:00:00Z"},{"id":"run_x","objective":"Other","created_at":"2026-10-22T00:00:00Z"}]}}"#)
    }

    override func tearDownWithError() throws { if let dir { try? FileManager.default.removeItem(at: dir) } }

    func runs(_ json: String) throws { try json.write(to: dir.appendingPathComponent("runs.json"), atomically: true, encoding: .utf8) }

    func ask(_ args: [String], env: [String: String] = [:]) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [dir.appendingPathComponent("oversire-ask").path] + args
        p.environment = ["PATH": "/usr/bin:/bin", "ORCA_CLI": dir.appendingPathComponent("orca").path, "ORCA_TERMINAL_HANDLE": "term_me",
                         "OVERSIRE_ASK_EVERY": "0.01"].merging(env) { $1 }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    var log: [String] { ((try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }

    func testHelp() throws {
        let r = try ask(["--help"])
        XCTAssertEqual(r.status, 0)
        XCTAssertEqual(r.out, AskSkill.help + "\n")
        XCTAssertTrue(log.isEmpty)
    }

    func testAskWaitsForTheReplyInTheThread() throws {
        let q = #"{"round":1,"questions":[{"id":"q1","type":"single","text":"Which store? \"é\"","options":["SQLite","JSON files"]}]}"#
        let r = try ask([q])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertEqual(r.out, #"{"round":1,"answers":{"q1":"SQLite"}}"# + "\n")
        XCTAssertTrue(r.err.contains("waiting for the answer to msg_1"))
        XCTAssertEqual(log.count, 4)
        XCTAssertEqual(log[0], "orchestration run-list --json")
        XCTAssertTrue(log[1].hasPrefix("orchestration send --type question --subject Question --to run:run_new --from term_me --body {"), log[1])
        XCTAssertTrue(log[1].contains("é"))
        XCTAssertEqual(log[2], "orchestration check --terminal term_me --all --json", "the question itself is no reply")
    }

    func testResumeAndAddress() throws {
        let r = try ask(["--resume", "msg_1"])
        XCTAssertEqual(r.status, 0, r.err)
        XCTAssertFalse(log.contains { $0.contains(" send ") || $0.contains("run-list") })
        try FileManager.default.removeItem(at: dir.appendingPathComponent("n"))
        let to = try ask([#"{"questions":[{"text":"Why?"}]}"#], env: ["OVERSIRE_ASK_TO": "run:run_env"])
        XCTAssertEqual(to.status, 0, to.err)
        XCTAssertTrue(log.contains { $0.contains("--to run:run_env") })
        XCTAssertFalse(log.contains { $0.contains("run-list") })
    }

    func testErrors() throws {
        XCTAssertTrue(try ask(["not json"]).err.contains("not JSON"))
        XCTAssertTrue(try ask([#"{"questions":[]}"#]).err.contains("1 to 4 questions"))
        XCTAssertTrue(try ask([#"{"questions":[{"text":"a"},{"text":"b"},{"text":"c"},{"text":"d"},{"text":"e"}]}"#]).err.contains("1 to 4"))
        XCTAssertTrue(try ask([#"{"questions":[{"text":"a"}]}"#], env: ["ORCA_TERMINAL_HANDLE": ""]).err.contains("Orca terminal"))
        try runs(#"{"ok":true,"result":{"runs":[]}}"#)
        let none = try ask([#"{"questions":[{"text":"a"}]}"#])
        XCTAssertNotEqual(none.status, 0)
        XCTAssertTrue(none.err.contains("OverSire is not running"))
    }

    func testPromptLines() {
        XCTAssertEqual(AskSkill.path, "/tmp/oversire/bin/oversire-ask")
        XCTAssertTrue(AskSkill.promptLine.contains("python3 /tmp/oversire/bin/oversire-ask --help"))
        XCTAssertEqual(AskSkill.pythonString("a \"b\"\n"), #""a \"b\"\n""#)
    }
}
