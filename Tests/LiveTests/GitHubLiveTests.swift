import XCTest
import OverSireCore
import GitHubKit
import CodeHostGitHub

/// Calls the real GitHub API through the gh CLI. Run with OVERSIRE_LIVE=1.
final class GitHubLiveTests: XCTestCase {
    func testListOpenPRs() async throws {
        guard ProcessInfo.processInfo.environment["OVERSIRE_LIVE"] == "1" else { throw XCTSkip("set OVERSIRE_LIVE=1") }
        let host = GitHubCodeHost(owner: "oversire", repos: ["oversire/oversire"],
                                  client: GitHubClient(commands: LiveCommands(), http: LiveHTTP()))
        let me = try await host.probe()
        XCTAssertNotNil(me.person.login)
        _ = try await host.changes(host.repoRef("oversire/oversire"), ChangeFilter())
        let repos = try await host.repos()
        XCTAssertTrue(repos.contains { $0.ref.path == "oversire/oversire" })
        let first = try await host.poll(since: nil)
        let second = try await host.poll(since: first.cursor)
        XCTAssertTrue(second.events.isEmpty)
    }
}

struct LiveCommands: CommandRunner {
    func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.environment = GitHubClient.environment
        let out = Pipe(), err = Pipe(), input = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = input
        try p.run()
        if let stdin { input.fileHandleForWriting.write(stdin) }
        try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return CommandOutput(status: p.terminationStatus, stdout: data, stderr: e)
    }
}
