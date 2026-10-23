import XCTest
import OverSireCore
import RuntimeDaemon

/// Read-only calls to a real daemon. Run a second daemon with OVERSIRE_DAEMON_HOME and its own serve.port, not the
/// installed service. Then run with OVERSIRE_LIVE=1 and OVERSIRE_DAEMON_URL=http://127.0.0.1:<port>.
final class DaemonLiveTests: XCTestCase {
    func testTheRuntimeReadsTheOrcaOfItsMachine() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSIRE_LIVE"] == "1", let url = env["OVERSIRE_DAEMON_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("set OVERSIRE_LIVE=1 and OVERSIRE_DAEMON_URL")
        }
        let rt = LocalMachineRuntime(machine: "live", client: DaemonClient(base: url, token: nil, http: LiveHTTP()))
        let runtimes = try await rt.refresh()
        let orca = try XCTUnwrap(runtimes.first { $0.id == "orca" }, "the daemon has no Orca")
        XCTAssertTrue(orca.reachable, orca.error ?? "")
        XCTAssertTrue(rt.capabilities.isSuperset(of: [.sessionInput, .sessionTail, .reveal, .hostFiles, .removeWorkspace]), "\(rt.capabilities)")
        let repos = try await rt.repos()
        XCTAssertFalse(repos.isEmpty)
        let workspaces = try await rt.workspaces()
        let open = try XCTUnwrap(workspaces.first { $0.liveTerminals > 0 }, "no workspace with a terminal")
        let sessions = try await rt.sessions(WorkspaceRef(account: rt.account, id: open.id))
        XCTAssertFalse(sessions.isEmpty)
        XCTAssertEqual(sessions[0].ref.workspace.account, AccountID(provider: .daemon, id: "live"))
    }
}
