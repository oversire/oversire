import XCTest
import AgentBinder
import OverSireAI
@testable import AIEngineAgentBinder

final class AgentBinderEngineTests: XCTestCase {
    private func engine(_ script: String, limits: PlanLimits = PlanLimits(), timeout: Duration = .seconds(10)) async -> AgentBinderEngine {
        let rt = Runtime(options: .init(clientName: "oversire-tests", useLoginShellPath: false))
        await rt.setDriver(FakeDriver(script: script), for: .fake)
        return AgentBinderEngine(config: LocalCLIConfig(harness: "fake", timeout: timeout), runtime: rt, limits: limits)
    }

    private let prompt = AIPrompt(system: "Reply with one word.", user: "ping")

    func testAGoodAnswer() async throws {
        let e = await engine(#"""
            read -r line
            echo '{"type":"permission","id":"p1","tool":"Bash","input":"rm -rf /"}'
            read -r decision
            case "$decision" in *'"allow":false'*) ;; *) echo '{"type":"result","subtype":"success","text":"allowed"}'; exit ;; esac
            echo '{"type":"assistant","text":"po"}'
            echo '{"type":"result","subtype":"success","text":"  pong "}'
            """#)
        let reply = try await e.send(prompt)
        XCTAssertEqual(reply, "pong", "the tool request is denied; the result text wins, trimmed")
    }

    func testATimeoutGivesTheTaskAway() async throws {
        let e = await engine("read -r line; sleep 30", timeout: .seconds(1))
        do { _ = try await e.send(prompt); XCTFail("timeout") } catch {
            XCTAssertEqual(error as? AIError, .unavailable("fake did not reply in 1 s."))
        }
    }

    func testThePlanLimitPausesTheJobs() async throws {
        let limits = PlanLimits()
        await limits.set(Limits(plan: "max", windows: [LimitWindow(key: .fiveHour, minutes: 300, usedPercent: 40),
                                                       LimitWindow(key: .weekly, minutes: 10080, usedPercent: 93)]))
        let e = await engine("exit 1", limits: limits)
        do { _ = try await e.send(prompt); XCTFail("pause") } catch {
            XCTAssertEqual(error as? AIError, .unavailable("The week plan window is at 93%. Jobs pause above 90%."))
        }
        await limits.set(Limits(windows: [LimitWindow(key: .weekly, usedPercent: 93, resetsAt: Date().addingTimeInterval(-60))]))
        let pause = await limits.pause(above: 90)
        XCTAssertNil(pause, "a window that reset does not pause")
    }

    func testALimitRefusalPauses() async throws {
        let limits = PlanLimits()
        let e = await engine(#"""
            read -r line
            echo '{"type":"error","error":"Usage limit","code":"limit","end_reason":"limit"}'
            echo '{"type":"result","subtype":"error","is_error":true,"text":"Usage limit reached"}'
            """#, limits: limits)
        do { _ = try await e.send(prompt); XCTFail("limit") } catch {
            XCTAssertEqual(error as? AIError, .unavailable("fake refused the call on a plan limit."))
        }
        let pause = await limits.pause(above: 90)
        XCTAssertEqual(pause, "The CLI refused the last call on a plan limit.")
    }

    func testALoginError() async throws {
        let e = await engine(#"""
            read -r line
            echo '{"type":"error","error":"Not logged in","code":"auth","end_reason":"auth"}'
            echo '{"type":"result","subtype":"error","is_error":true,"text":""}'
            """#)
        do { _ = try await e.send(prompt); XCTFail("login") } catch {
            XCTAssertEqual(error as? AIError, .unavailable("fake is not logged in. Run fake once in a terminal."))
        }
    }

    func testAnEarlyExit() async throws {
        let e = await engine("read -r line; exit 3")
        do { _ = try await e.send(prompt); XCTFail("exit") } catch {
            guard case .unavailable = error as? AIError else { return XCTFail("\(error)") }
        }
    }
}
