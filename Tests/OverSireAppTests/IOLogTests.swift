import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireApp

final class IOLogTests: XCTestCase {
    final class Lines: LogSink, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [LogEntry] = []
        var all: [LogEntry] { lock.withLock { kept } }
        func write(_ e: LogEntry) { lock.withLock { kept.append(e) } }
    }

    private func request(_ method: String, _ url: String, id: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        if let id { r.setValue(id, forHTTPHeaderField: DaemonClient.requestID) }
        return r
    }

    func testAFailureHasTheStatusTheErrorAndTheRequestID() throws {
        let l = Lines()
        IOLog(sink: l).request(request("POST", "http://mbp:7690/v1/orders?token=abc", id: "0a1b2c3d"), status: 400, ms: 14,
                               body: Data(#"{"error":"wire: order needs id, runner and suggestion"}"#.utf8))
        let e = try XCTUnwrap(l.all.first)
        XCTAssertEqual([e.level, e.area.rawValue, e.job, e.host ?? ""], [LogLevel.warn, "net", "HTTP", "mbp:7690"] as [AnyHashable])
        XCTAssertEqual(e.message, #"POST /v1/orders 400 id=0a1b2c3d: {"error":"wire: order needs id, runner and suggestion"}"#)
        XCTAssertEqual(e.ms, 14)
        XCTAssertNotEqual(e.verbose, true)
        XCTAssertFalse(e.message.contains("abc") || e.message.contains("secret"), "no query, no headers")
    }

    func testATransportErrorIsAFailure() throws {
        let l = Lines()
        IOLog(sink: l).request(request("GET", "http://127.0.0.1:7690/v1/workspaces"), status: nil, ms: 30_000, error: "The request timed out.")
        let e = try XCTUnwrap(l.all.first)
        XCTAssertEqual(e.level, .warn)
        XCTAssertEqual(e.message, "GET /v1/workspaces: The request timed out.")
    }

    func testOnlyAReadThatWorksIsVerbose() {
        let l = Lines()
        let log = IOLog(sink: l)
        log.request(request("GET", "http://127.0.0.1:7690/v1/sessions"), status: 200, ms: 3)
        log.request(request("POST", "http://127.0.0.1:7690/v1/orders"), status: 202, ms: 9)
        XCTAssertEqual(l.all.map { $0.verbose == true }, [true, false])
        XCTAssertEqual(l.all.map(\.level), [.ok, .ok])
    }

    func testALongErrorBodyIsShort() throws {
        let l = Lines()
        IOLog(sink: l).request(request("GET", "https://api.plane.so/x"), status: 502, ms: 1, body: Data(String(repeating: "a\n", count: 900).utf8))
        let e = try XCTUnwrap(l.all.first)
        XCTAssertLessThanOrEqual(e.message.count, "GET /x 502: ".count + 300)
        XCTAssertFalse(e.message.contains("\n"))
    }

    func testACommandLineShortensTheArgumentsAndKeepsTheStderrOfAFailure() throws {
        let l = Lines()
        let log = IOLog(sink: l)
        log.command("/opt/homebrew/bin/gh", ["api", String(repeating: "p", count: 200)], status: 1, ms: 120, stderr: "HTTP 404: Not Found")
        log.command("/usr/bin/git", ["status"], status: 0, ms: 5, stderr: "noise")
        let fail = try XCTUnwrap(l.all.first)
        XCTAssertEqual([fail.level, fail.area.rawValue, fail.job], [LogLevel.warn, "cmd", "gh"] as [AnyHashable])
        XCTAssertEqual(fail.message, "gh api " + String(repeating: "p", count: 77) + "…: exit 1")
        XCTAssertEqual(fail.exit, 1)
        XCTAssertEqual(fail.outputTail, "HTTP 404: Not Found")
        let ok = l.all[1]
        XCTAssertEqual(ok.verbose, true)
        XCTAssertNil(ok.outputTail)
    }

    func testAGh304IsRoutine() throws {
        let l = Lines()
        IOLog(sink: l).command("/opt/homebrew/bin/gh", ["api", "-i", "repos/o/r/actions/runs"], status: 1, ms: 80, stderr: "gh: HTTP 304\n")
        let e = try XCTUnwrap(l.all.first)
        XCTAssertEqual(e.level, .ok)
        XCTAssertEqual(e.verbose, true)
        XCTAssertEqual(e.message, "gh api -i repos/o/r/actions/runs: 304")
        XCTAssertNil(e.outputTail)
    }

    func testTheRunnerWritesALine() throws {
        let l = Lines()
        var r = ProcessRunner()
        r.log = IOLog(sink: l)
        _ = try r.runSync("/bin/sh", ["-c", "echo no >&2; exit 3"])
        XCTAssertThrowsError(try r.runSync("/no/such/exe", []))
        XCTAssertEqual(l.all.map(\.exit), [3, nil])
        XCTAssertEqual(l.all.first?.outputTail, "no")
        XCTAssertEqual(l.all.map(\.level), [.warn, .warn])
    }

    func testEachDaemonRequestHasItsOwnID() {
        let c = DaemonClient(base: DaemonClient.loopback, token: nil, http: RecordedHTTP())
        let a = c.request("/v1/sessions").value(forHTTPHeaderField: DaemonClient.requestID)
        let b = c.request("/v1/sessions").value(forHTTPHeaderField: DaemonClient.requestID)
        XCTAssertEqual(a?.count, 8)
        XCTAssertNotEqual(a, b)
    }

    func testARecordLineOpensNoProblemAndAHiddenPollPostsNothing() {
        let dir = NSTemporaryDirectory() + "oversire-logs-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let t = ProblemTracker(path: nil, now: { now })
        let s = LogStore(dir: dir, problems: t, now: { now })
        for _ in 0..<4 { s.write(LogEntry(at: now, level: .warn, area: .net, job: "HTTP", host: "mbp:7690", message: "GET /v1/sessions: timed out")) }
        let exp = expectation(forNotification: LogStore.changed, object: s)
        exp.isInverted = true
        var poll = LogEntry(at: now, level: .ok, area: .net, job: "HTTP", host: "mbp:7690", message: "GET /v1/sessions 200")
        poll.verbose = true
        s.write(poll)
        wait(for: [exp], timeout: 0.2)
        XCTAssertTrue(t.open.isEmpty)
        XCTAssertEqual(s.entries.count, 4, "the log keeps the failures, not the poll")
    }
}
