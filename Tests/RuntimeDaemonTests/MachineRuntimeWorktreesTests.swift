import Foundation
import OverSireCore
import OverSireTestKit
import RuntimeDaemon
import XCTest

final class MachineRuntimeWorktreesTests: XCTestCase {
    private func fixture(_ type: String, _ name: String, file: String = #filePath) throws -> Data {
        let root = URL(fileURLWithPath: file).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try Data(contentsOf: root.appendingPathComponent("Contract/fixtures/\(type)/\(name).json"))
    }

    private func runtime(_ replies: [ScriptedHTTP.Reply]) -> (MachineRuntime, ScriptedHTTP) {
        let http = ScriptedHTTP(replies)
        return (MachineRuntime(machine: "mini", client: DaemonClient(base: URL(string: "http://mini:7690")!, token: "t", http: http)), http)
    }

    func testTheWorktreesRouteDecodesTheFixture() async throws {
        let (rt, http) = runtime([.init(body: try fixture("worktrees-page", "guess"))])
        let src: any WorktreeSource = rt
        let page = try await src.worktrees(changed: true, dir: "/Users/fritz/Projects")
        XCTAssertEqual(page.worktrees.count, 2)
        XCTAssertEqual(page.worktrees[0].guess, WorktreeGuess(key: "OVERSIRE-402", from: .prompt))
        XCTAssertNil(page.worktrees[1].guess)
        let url = try XCTUnwrap(http.requests.first?.url)
        XCTAssertEqual(url.path, "/v1/worktrees")
        XCTAssertEqual(url.query, "changed=1&dir=/Users/fritz/Projects")
    }

    func testAnOldDaemonGivesNotFound() async throws {
        let (rt, _) = runtime([.init(status: 404, body: Data(#"{"error":"not found"}"#.utf8))])
        do {
            _ = try await rt.worktrees(changed: false, dir: nil)
            XCTFail("no error")
        } catch ProviderError.notFound {}
    }
}
