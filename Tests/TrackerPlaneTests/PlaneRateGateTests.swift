import XCTest
import OverSireCore
@testable import TrackerPlane

/// Plane answers 429 to the first request and 200 to the others (OVERSIRE-428).
final class LimitedPlane: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var statuses: [Int] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let status = lock.withLock { () -> Int in
            let s = statuses.isEmpty ? 429 : 200
            statuses.append(s)
            return s
        }
        let headers = status == 429 ? ["Retry-After": "20"] : [:]
        return (Data(#"{"id":"u1"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }
}

final class PlaneRateGateTests: XCTestCase {
    final class Clock: @unchecked Sendable {
        let lock = NSLock()
        var at = Date(timeIntervalSince1970: 1_800_000_000)
        var gate: RateGate.Clock {
            RateGate.Clock(now: { self.lock.withLock { self.at } },
                           sleep: { s in self.lock.withLock { self.at = self.at.addingTimeInterval(s) }; await Task.yield() })
        }
    }

    final class Lines: LogSink, @unchecked Sendable {
        let lock = NSLock()
        var all: [LogEntry] = []
        func write(_ e: LogEntry) { lock.withLock { all.append(e) } }
    }

    func testOne429PausesAllCalls() async throws {
        let http = LimitedPlane(), clock = Clock(), log = Lines()
        let gate = RateGate(perMinute: { 40 }, clock: clock.gate)
        let plane = PlaneTracker(workspace: PlaneWorkspace(slug: "acme"), token: "tok",
                                 http: GatedTransport(http, gate: gate, log: log, host: "acme"))
        let start = clock.at
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<10 { g.addTask { _ = try await plane.api.send("GET", "/api/v1/users/me/") } }
            try await g.waitForAll()
        }
        XCTAssertEqual(http.statuses.filter { $0 == 429 }.count, 1)
        XCTAssertEqual(http.statuses.count, 11, "the 429 call tries again after the pause")
        XCTAssertGreaterThanOrEqual(clock.lock.withLock { clock.at }.timeIntervalSince(start), 20, "Retry-After holds all calls")
        XCTAssertEqual(log.all.count, 1, "one log line for the pause")
        XCTAssertEqual(log.all.first?.message, "HTTP 429: all requests wait 20 s")
    }
}
