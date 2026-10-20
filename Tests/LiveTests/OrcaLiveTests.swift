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

    /// One 2 MB random file to the local Orca, and to ORCA_ENV when it is set. ORCA_ROOT is a workspace folder of Orca.
    func testHostFiles() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["OVERSIRE_LIVE"] == "1" else { throw XCTSkip("set OVERSIRE_LIVE=1") }
        guard let root = env["ORCA_ROOT"] else { throw XCTSkip("set ORCA_ROOT to a workspace folder of Orca") }
        let data = Data((0..<2_000_000).map { _ in UInt8.random(in: 0...255) })
        var targets: [String?] = [nil]
        if let e = env["ORCA_ENV"], !e.isEmpty { targets.append(e) }
        for t in targets {
            let rt = OrcaRuntime(environment: t, commands: LiveCommands())
            guard rt.installed else { throw XCTSkip("Orca is not installed") }
            let dir = "/tmp/oversire/live-\(UUID().uuidString)"
            let paths = try await rt.writeFiles([HostFile(name: "random 2mb.bin", data: data)], workspacePath: root, dir: dir) { _, _ in }
            XCTAssertEqual(paths, [dir + "/random-2mb.bin"], t ?? "local")
        }
    }
}
