import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

final class GroupJoinTests: XCTestCase {
    func testFramesParse() {
        let result = DaemonFrame.parse(#"{"type":"joinResult","host":"100.97.81.23:7690","request":"r-1","status":"denied"}"#)
        XCTAssertEqual(result, .joinResult(JoinResultFrame(host: "100.97.81.23:7690", request: "r-1", status: .denied)))
        XCTAssertNil(DaemonFrame.parse(#"{"type":"poke"}"#))
        XCTAssertNil(DaemonFrame.parse("pong"))
    }

    func testReasonUsesTheErrorOfTheBody() {
        XCTAssertEqual(DaemonClient.reason(ProviderError.vendor(code: "409", message: #"{"error":"group: this machine is in a group"}"#)),
                       "This machine is in a group")
        XCTAssertEqual(DaemonClient.reason(ProviderError.forbidden), "The code is not valid or was used.")
    }

    func testGroupRoutes() async throws {
        let mbp = MachineName("mbp"), mba = MachineName("mba")
        let d = FakeDaemon(machine: "mbp", group: Group(id: "g", name: "My machines", home: mbp, version: 1,
            members: [GroupMember(machine: mbp, host: "mbp", addrs: [], port: 7690, roles: [], joinedAt: Date()),
                      GroupMember(machine: mba, host: "mba", addrs: [], port: 7690, roles: [], joinedAt: Date())], devices: []))
        d.hooks = [HarnessHooks(name: "claude", hooks: .missing)]
        let c = DaemonClient(base: DaemonClient.loopback, token: nil, http: d)
        let invite = try await c.invite()
        XCTAssertEqual(invite.code, "K7Q2-M9XD")
        let move = try await c.setHome("mba")
        XCTAssertNil(move.warning)
        XCTAssertEqual(d.body(of: "POST /v1/group/home")?["machine"] as? String, "mba")
        try await c.remove("mba")
        XCTAssertEqual(d.calls.last, "DELETE /v1/group/members/mba")
        let added = try await c.hooks(install: ["claude"])
        XCTAssertEqual(added.first?.hooks, .installed)
        let removed = try await c.removeHooks(["claude"])
        XCTAssertEqual(removed.first?.hooks, .missing)
        XCTAssertEqual(d.body(of: "DELETE /v1/hooks/install")?["harnesses"] as? [String], ["claude"])
    }
}
