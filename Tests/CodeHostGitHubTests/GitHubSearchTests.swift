import XCTest
import OverSireCore
import OverSireTestKit
@testable import GitHubKit
@testable import CodeHostGitHub

/// Search and collaborators from recorded gh outputs in Fixtures/github.
final class GitHubSearchTests: XCTestCase {
    var runner: ReplayCommandRunner!
    var host: GitHubCodeHost!
    var bin: URL!

    // The replay never runs the program. The client only checks that the file is executable.
    override func setUpWithError() throws {
        bin = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-gh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let gh = bin.appendingPathComponent("gh")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: gh)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: gh.path)
        runner = ReplayCommandRunner(dir: fixtureDir("github"), record: false)
        host = GitHubCodeHost(owner: "acme", repos: ["acme/app"], client: GitHubClient(commands: runner, http: NoHTTP(), gh: gh.path))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: bin)
    }

    func testSearchUsesTheCLI() async throws {
        let list = try await host.search("  fix   login ", limit: 5)
        XCTAssertEqual(runner.missing, [])
        XCTAssertEqual(list.map(\.number), [12, 9])
        XCTAssertEqual(list.map(\.state), ["OPEN", "MERGED"])
        XCTAssertEqual(list[0].author.login, "ada")
        XCTAssertEqual(list[0].url, "https://github.com/acme/app/pull/12")
        XCTAssertEqual(list[0].labels, [.init(name: "bug", color: "d73a4a")])
        XCTAssertTrue(list[1].isDraft == false && list[1].headRefName.isEmpty)
    }

    func testEmptySearchRunsNothing() async throws {
        let list = try await host.search(" ", limit: 5)
        XCTAssertTrue(list.isEmpty)
        XCTAssertEqual(runner.missing, [])
    }

    func testCollaboratorsSkipBots() async throws {
        let people = try await host.collaborators(host.repoRef("acme/app"))
        XCTAssertEqual(runner.missing, [])
        XCTAssertEqual(people, [PersonRef(id: "7671010", name: "ada", login: "ada"), PersonRef(id: "1001", name: "bo", login: "bo")])
    }
}
