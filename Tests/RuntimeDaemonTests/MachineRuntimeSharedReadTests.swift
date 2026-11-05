import XCTest
import OverSireCore
import OverSireTestKit
@testable import RuntimeDaemon

final class MachineRuntimeSharedReadTests: XCTestCase {
    /// Counts the workspace reads of a FakeDaemon and makes each one slow.
    final class SlowReads: HTTPTransport, @unchecked Sendable {
        let daemon = FakeDaemon()
        private let lock = NSLock()
        private var n = 0
        var reads: Int { lock.withLock { n } }

        func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
            if request.url?.path == "/v1/workspaces" {
                lock.withLock { n += 1 }
                try await Task.sleep(for: .milliseconds(200))
            }
            return try await daemon.send(request)
        }
    }

    func testParallelReadsShareOneCall() async throws {
        let t = SlowReads()
        let rt = MachineRuntime(machine: "mbp", client: DaemonClient(base: DaemonClient.loopback, token: nil, http: t))
        try await withThrowingTaskGroup(of: Void.self) { g in
            for _ in 0..<5 { g.addTask { _ = try await rt.workspaces() } }
            try await g.waitForAll()
        }
        XCTAssertEqual(t.reads, 1)
        _ = try await rt.workspaces()
        XCTAssertEqual(t.reads, 2, "a read after the end of the shared one asks the daemon again")
    }
}
