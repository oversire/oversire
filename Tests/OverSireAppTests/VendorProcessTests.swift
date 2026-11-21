import XCTest
@testable import OverSireApp

final class VendorProcessTests: XCTestCase {
    func launch(_ script: String, env: [String: String] = [:], cwd: URL? = nil, timeout: Duration = .seconds(10), maxStdout: Int = 1 << 20) -> VendorLaunch {
        VendorLaunch(exe: "/bin/sh", args: ["-c", script], environment: env, cwd: cwd, timeout: timeout, maxStdout: maxStdout,
                     maxStderr: 1024, logWords: ["sh"])
    }

    func testCapsStdout() async throws {
        let start = Date()
        let r = try await VendorProcess().run(launch("head -c 3000000 /dev/zero", maxStdout: 1 << 20))
        XCTAssertTrue(r.truncated)
        XCTAssertEqual(r.stdout.count, 1 << 20)
        XCTAssertEqual(r.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testTimeoutStops() async throws {
        let start = Date()
        let r = try await VendorProcess().run(launch("sleep 5", timeout: .milliseconds(200)))
        XCTAssertTrue(r.timedOut)
        XCTAssertNotEqual(r.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testNoTTYAndOnlyGivenEnv() async throws {
        let r = try await VendorProcess().run(launch("[ -t 0 ] && echo tty || echo notty; cat | wc -c; echo \"$ONLY|${HOME-unset}|${SECRET_IN_APP-unset}\"",
                                                     env: ["ONLY": "1", "PATH": "/usr/bin:/bin"]))
        let lines = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines, ["notty", "0", "1|unset|unset"])
        XCTAssertFalse(r.truncated)
        XCTAssertFalse(r.timedOut)
    }

    func testRunsInCwd() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("vendor-cwd-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = try await VendorProcess().run(launch("pwd -P", env: ["PATH": "/usr/bin:/bin"], cwd: dir))
        XCTAssertEqual(String(decoding: r.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), dir.resolvingSymlinksInPath().path.replacingOccurrences(of: "/var/", with: "/private/var/", options: .anchored))
    }

    func testStartErrorThrows() async {
        let l = VendorLaunch(exe: "/nonexistent/bin", args: [], environment: [:], cwd: nil, timeout: .seconds(1), maxStdout: 10, maxStderr: 10, logWords: ["x"])
        do {
            _ = try await VendorProcess().run(l)
            XCTFail("a missing binary must throw")
        } catch {}
    }

    func testStderrIsKept() async throws {
        let r = try await VendorProcess().run(launch("echo oops >&2; exit 3"))
        XCTAssertEqual(r.status, 3)
        XCTAssertEqual(String(decoding: r.stderr, as: UTF8.self), "oops\n")
    }
}
