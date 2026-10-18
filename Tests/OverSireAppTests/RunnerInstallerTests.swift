import CryptoKit
import OverSireCore
import XCTest
@testable import OverSireApp

private final class FakeHTTP: HTTPTransport, @unchecked Sendable {
    var routes: [String: (Int, Data)] = [:]
    private(set) var asked: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!.absoluteString
        asked.append(url)
        let (code, body) = routes[url] ?? (404, Data())
        return (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

private final class FakeCommands: CommandRunner, @unchecked Sendable {
    var team = "Q56WK6TB88"
    var failing: Set<String> = []
    var status = #"{"version":"0.2.0","paired":true,"device":"D1","hub":"https://hub.test","connected":true,"since":"2026-10-01T09:00:00Z","service":{"installed":true,"running":true},"runtimes":["orca"]}"#
    private(set) var calls: [(exe: String, args: [String], stdin: Data?)] = []

    func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput {
        calls.append((exe, args, stdin))
        let key = exe.hasSuffix("oversire-runner") ? args[0] : (exe as NSString).lastPathComponent
        if failing.contains(key) { return CommandOutput(status: 1, stdout: Data(), stderr: "\(key) broke\n") }
        switch key {
        case "tar":
            let dir = URL(fileURLWithPath: args[args.firstIndex(of: "-C")! + 1])
            let bin = dir.appendingPathComponent("oversire-runner")
            try Data("#!/bin/sh\n".utf8).write(to: bin)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
        case "codesign" where args[0] == "-dv":
            return CommandOutput(status: 0, stdout: Data(), stderr: "Executable=x\nTeamIdentifier=\(team)\n")
        case "status":
            return CommandOutput(status: 0, stdout: Data(status.utf8), stderr: "")
        default: break
        }
        return CommandOutput(status: 0, stdout: Data(), stderr: "")
    }
}

final class RunnerInstallerTests: XCTestCase {
    let archive = Data("archive bytes".utf8)
    fileprivate var http: FakeHTTP!
    fileprivate var commands: FakeCommands!
    var dir: URL!
    var codeAsked = 0

    override func setUpWithError() throws {
        http = FakeHTTP()
        commands = FakeCommands()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("runner-\(UUID().uuidString)")
        let base = "https://github.com/oversire/runner/releases/download/v0.2.0/"
        let release = """
        {"tag_name":"v0.2.0","assets":[
          {"name":"oversire-runner_0.2.0_darwin_arm64.tar.gz","browser_download_url":"\(base)oversire-runner_0.2.0_darwin_arm64.tar.gz"},
          {"name":"checksums.txt","browser_download_url":"\(base)checksums.txt"}]}
        """
        let sum = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        http.routes = [
            "https://api.github.com/repos/oversire/runner/releases/latest": (200, Data(release.utf8)),
            "\(base)oversire-runner_0.2.0_darwin_arm64.tar.gz": (200, archive),
            "\(base)checksums.txt": (200, Data("\(String(repeating: "0", count: 64))  oversire-runner_0.2.0_linux_amd64.tar.gz\n\(sum)  oversire-runner_0.2.0_darwin_arm64.tar.gz\n".utf8)),
        ]
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    var installer: RunnerInstaller { RunnerInstaller(http: http, commands: commands, dir: dir, arch: "arm64") }

    func install(keepAwake: Bool = false) async throws -> RunnerStatus {
        try await installer.install(hub: "https://hub.test", name: "mini", keepAwake: keepAwake) {
            self.codeAsked += 1
            return "ABCD-2345"
        }
    }

    func testInstallsChecksPairsAndStarts() async throws {
        let status = try await install(keepAwake: true)
        XCTAssertEqual(status.summary, "Online · v0.2.0")
        XCTAssertTrue(installer.isInstalled)
        let calls = commands.calls.map { c in
            [(c.exe as NSString).lastPathComponent] + c.args.map { $0.hasPrefix(dir.path) ? "<dir>" : $0 }
        }
        XCTAssertEqual(calls, [
            ["tar", "-xzf", "<dir>", "-C", "<dir>", "oversire-runner"],
            ["codesign", "--verify", "--strict", "<dir>"],
            ["codesign", "-dv", "<dir>"],
            ["oversire-runner", "pair", "-", "--hub", "https://hub.test", "--name", "mini"],
            ["oversire-runner", "install", "--keep-awake"],
            ["oversire-runner", "status", "--json"],
        ])
        XCTAssertEqual(commands.calls[3].exe, dir.appendingPathComponent("oversire-runner").path)
        let pair = try XCTUnwrap(commands.calls.first { $0.args.first == "pair" })
        XCTAssertEqual(pair.stdin, Data("ABCD-2345\n".utf8))
        XCTAssertFalse(commands.calls.contains { $0.args.contains("ABCD-2345") }, "the code never goes in argv")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["oversire-runner"], "the download folder is gone")
    }

    func testBadChecksumInstallsNothing() async throws {
        http.routes[http.routes.keys.first { $0.hasSuffix(".tar.gz") }!] = (200, Data("other bytes".utf8))
        await XCTAssertThrowsErrorAsync(try await install(), "SHA-256")
        XCTAssertTrue(commands.calls.isEmpty)
        XCTAssertEqual(codeAsked, 0, "no pairing code is made")
        XCTAssertFalse(installer.isInstalled)
    }

    func testOtherTeamInstallsNothing() async throws {
        commands.team = "ABCDE12345"
        await XCTAssertThrowsErrorAsync(try await install(), "not signed by the OverSire team")
        XCTAssertFalse(installer.isInstalled)
        XCTAssertEqual(codeAsked, 0)
    }

    func testBrokenSignatureInstallsNothing() async throws {
        commands.failing = ["codesign"]
        await XCTAssertThrowsErrorAsync(try await install(), "codesign broke")
        XCTAssertFalse(installer.isInstalled)
    }

    func testMissingAssetAndFailedPair() async throws {
        let saved = http.routes
        http.routes["https://api.github.com/repos/oversire/runner/releases/latest"] = (200, Data(#"{"tag_name":"v0.3.0","assets":[]}"#.utf8))
        await XCTAssertThrowsErrorAsync(try await install(), "has no oversire-runner_0.3.0_darwin_arm64.tar.gz")
        http.routes = saved
        commands.failing = ["pair"]
        await XCTAssertThrowsErrorAsync(try await install(), "Cannot pair oversire-runner: pair broke")
    }

    func testStatusSummary() async throws {
        let none = try await installer.status()
        XCTAssertNil(none, "no status before the install")
        _ = try await install()
        commands.status = #"{"version":"0.2.0","paired":true,"connected":false,"lastError":"401 from the hub","service":{"installed":true,"running":true}}"#
        let s = try await installer.status()
        XCTAssertEqual(s?.summary, "Offline · 401 from the hub")
        commands.status = #"{"version":"0.2.0","paired":false,"connected":false,"service":{"installed":false,"running":false}}"#
        let unpaired = try await installer.status()
        XCTAssertEqual(unpaired?.summary, "Installed, not paired")
    }

    func testChecksumLine() throws {
        XCTAssertEqual(try RunnerInstaller.checksum(of: "a.tar.gz", in: "\(String(repeating: "A", count: 64))  a.tar.gz\n"),
                       String(repeating: "a", count: 64))
        XCTAssertThrowsError(try RunnerInstaller.checksum(of: "a.tar.gz", in: "abc  a.tar.gz\n"))
    }

    func testRecordsShowTheRunners() {
        var r = CloudAIRecords()
        r.runners = [RunnerState(device: "D1", version: "0.2.0", contract: 1, runtimes: ["orca"], online: true, lastSeen: Date()),
                     RunnerState(device: "D2", version: "0.2.0", contract: 1, runtimes: [], online: false, lastSeen: Date())]
        XCTAssertEqual(r.runnerStatus, "1 of 2 runners online · No work orders")
    }
}

private func XCTAssertThrowsErrorAsync<T>(_ expr: @autoclosure () async throws -> T, _ contains: String,
                                          file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await expr()
        XCTFail("no error", file: file, line: line)
    } catch {
        XCTAssertTrue("\(error)".contains(contains), "\(error)", file: file, line: line)
    }
}
