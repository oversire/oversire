import XCTest
import OverSireCore
import RuntimeOrca

/// Reads the real Orca app on this Mac. Run with OVERSIRE_LIVE=1 and Orca open.
final class OrcaLiveTests: XCTestCase {
    func testEnvironmentsAndCards() async throws {
        guard ProcessInfo.processInfo.environment["OVERSIRE_LIVE"] == "1" else { throw XCTSkip("set OVERSIRE_LIVE=1") }
        let rt = OrcaRuntime(environment: ProcessInfo.processInfo.environment["ORCA_ENV"], commands: LiveCommands())
        guard rt.installed else { throw XCTSkip("Orca is not installed") }
        _ = try await rt.version()
        let envs = try await rt.environments()
        XCTAssertEqual(envs.first, .local)
        let ws = try await rt.workspaces()
        if let w = ws.first { _ = try await rt.sessions(rt.workspaceRef(w.id)) }
        let first = try await rt.poll(since: nil)
        XCTAssertTrue(first.events.isEmpty)
    }
}
