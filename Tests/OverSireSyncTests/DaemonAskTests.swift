import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

final class DaemonAskTests: XCTestCase {
    let base = "http://mbp:7690"
    let askURL = "http://mbp:7690/v1/sessions/tab-1:leaf-3/ask"

    private func client(_ http: RecordedHTTP) -> DaemonClient {
        DaemonClient(base: URL(string: base)!, token: "osd1.x", http: http)
    }

    private func body(_ r: URLRequest) -> [String: Any] {
        r.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }

    private func fixture(_ type: String, _ name: String) throws -> String {
        String(decoding: try contractFixture(type, name), as: UTF8.self)
    }

    func testAskGivesTheReply() async throws {
        let http = RecordedHTTP()
        http.on("POST", askURL, 200, try fixture("session-ask-reply", "reply"))
        let reply = try await client(http).ask(session: "tab-1:leaf-3", text: "Why did the tests stop?", timeout: 120)
        XCTAssertEqual(reply.reply, "The Claude usage limit stops me. It resets at 6:10pm. Then I run go test ./connectors/... again.")
        XCTAssertNotNil(reply.turnEndedAt)
        XCTAssertNotNil(reply.screenTail)

        let r = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(r.httpMethod, "POST")
        XCTAssertEqual(r.url?.path, "/v1/sessions/tab-1:leaf-3/ask")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer osd1.x")
        XCTAssertGreaterThan(r.timeoutInterval, 120)
        let b = body(r)
        XCTAssertEqual(b["text"] as? String, "Why did the tests stop?")
        XCTAssertEqual(b["timeoutSec"] as? Int, 120)
        XCTAssertEqual(b["readOnly"] as? Bool, true)
    }

    func testWritesWithNoBodyAreJSON() async throws {
        let http = RecordedHTTP()
        http.on("POST", "\(base)/v1/runtimes/orca/retry", 200, #"{"id":"orca","name":"Orca","installed":true,"reachable":true,"capabilities":[]}"#)
        http.on("POST", "\(base)/v1/workers/w-1/stop", 200, "{}")
        let c = client(http)
        _ = try await c.retryRuntime("orca")
        try await c.stopWorker(id: "w-1")
        XCTAssertEqual(http.requests.count, 2)
        for r in http.requests {
            XCTAssertEqual(r.value(forHTTPHeaderField: "Content-Type"), "application/json", r.url?.path ?? "")
            XCTAssertNil(r.httpBody)
        }
    }

    func testAskSendsTheDefaultsAndClampsTheTimeout() async throws {
        let http = RecordedHTTP()
        http.on("POST", askURL, 200, try fixture("session-ask-reply", "reply"))
        let c = client(http)
        _ = try await c.ask(session: "tab-1:leaf-3", text: "Status?")
        _ = try await c.ask(session: "tab-1:leaf-3", text: "Fix it", timeout: 3600, readOnly: false)

        let first = http.requests[0], second = http.requests[1]
        XCTAssertEqual(body(first)["timeoutSec"] as? Int, 180)
        XCTAssertEqual(body(first)["readOnly"] as? Bool, true)
        XCTAssertGreaterThan(first.timeoutInterval, 180)
        XCTAssertEqual(body(second)["timeoutSec"] as? Int, 600)
        XCTAssertEqual(body(second)["readOnly"] as? Bool, false)
        XCTAssertGreaterThan(second.timeoutInterval, 600)
    }

    func testAskBusyIs409() async throws {
        let http = RecordedHTTP()
        http.on("POST", askURL, 409,
                #"{"error":"busy","message":"The agent is in a turn. Ask again when the turn ends.","screenTail":"✶ Thinking…"}"#)
        do {
            _ = try await client(http).ask(session: "tab-1:leaf-3", text: "Status?")
            XCTFail("no error")
        } catch let e as SessionAskError {
            XCTAssertEqual(e.status, 409)
            XCTAssertEqual(e.code, SessionAskError.busy)
            XCTAssertEqual(e.message, "The agent is in a turn. Ask again when the turn ends.")
            XCTAssertEqual(e.screenTail, "✶ Thinking…")
            XCTAssertEqual(e.localizedDescription, e.message)
        }
    }

    func testAskTimeoutIs504WithTheScreenTail() async throws {
        let http = RecordedHTTP()
        http.on("POST", askURL, 504, try fixture("session-ask-reply", "timeout"))
        do {
            _ = try await client(http).ask(session: "tab-1:leaf-3", text: "Status?")
            XCTFail("no error")
        } catch let e as SessionAskError {
            XCTAssertEqual(e.status, 504)
            XCTAssertEqual(e.code, SessionAskError.timeout)
            XCTAssertEqual(e.message, "The agent did not end its turn in 180 s.")
            XCTAssertEqual(e.screenTail, "⏺ Running go test ./connectors/...\n  ✶ Thinking…")
        }
    }

    func testAskUnknownSessionIsNotFound() async throws {
        let http = RecordedHTTP()
        http.on("POST", "http://mbp:7690/v1/sessions/gone/ask", 404,
                #"{"error":"noSession","message":"The daemon has no session gone."}"#)
        do {
            _ = try await client(http).ask(session: "gone", text: "Status?")
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .notFound)
        }
    }

    func testAskOtherErrorWithNoReplyBodyIsVendor() async throws {
        let http = RecordedHTTP()
        http.on("POST", askURL, 500, "boom")
        do {
            _ = try await client(http).ask(session: "tab-1:leaf-3", text: "Status?")
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .vendor(code: "500", message: "boom"))
        }
    }

    func testSessionByID() async throws {
        let http = RecordedHTTP()
        http.on("GET", "http://mbp:7690/v1/sessions/tab-1:leaf-3", 200, try fixture("daemon-session", "orca-monitoring"))
        let s = try await client(http).session(id: "tab-1:leaf-3")
        XCTAssertEqual(s.id, "tab-1:leaf-3")
        XCTAssertEqual(s.machine, "mba")
        XCTAssertEqual(http.requests.first?.httpMethod, "GET")
        XCTAssertEqual(http.requests.first?.url?.path, "/v1/sessions/tab-1:leaf-3")
    }

    func testSessionUnknownIsNotFound() async throws {
        let http = RecordedHTTP()
        http.on("GET", "http://mbp:7690/v1/sessions/nope", 404, #"{"error":"no session"}"#)
        do {
            _ = try await client(http).session(id: "nope")
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error as? ProviderError, .notFound)
        }
    }

    func testOrderByID() async throws {
        let http = RecordedHTTP()
        http.on("GET", "http://mbp:7690/v1/orders/wo-1", 200, #"{"state":"done","result":{"lines":["ok","PASS"]}}"#)
        http.on("GET", "http://mbp:7690/v1/orders/wo-2", 200, #"{"state":"acked"}"#)
        let c = client(http)
        let done = try await c.order(id: "wo-1")
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(done.result?.lines, ["ok", "PASS"])
        let acked = try await c.order(id: "wo-2")
        XCTAssertEqual(acked, DaemonOrderState(state: .acked))
        XCTAssertEqual(http.requests.map(\.httpMethod), ["GET", "GET"])
        XCTAssertEqual(http.requests.map { $0.url?.path }, ["/v1/orders/wo-1", "/v1/orders/wo-2"])
    }

    func testRuntimeRoutesWaitLongerThanTheDefault() async throws {
        let http = RecordedHTTP()
        http.on("GET", "http://mbp:7690/v1/workspaces", 200, try fixture("daemon-workspaces-page", "two"))
        http.on("GET", "http://mbp:7690/v1/repos", 200, try fixture("daemon-repos-page", "two"))
        http.on("GET", "http://mbp:7690/v1/runtimes", 200, try fixture("daemon-runtimes-page", "orca-and-oversire"))
        let c = client(http)
        let page = try await c.workspaces()
        _ = try await c.repos()
        _ = try await c.runtimes()
        XCTAssertEqual(page.workspaces.count, 2)
        XCTAssertEqual(http.requests.map { $0.url?.path }, ["/v1/workspaces", "/v1/repos", "/v1/runtimes"])
        XCTAssertEqual(http.requests.map(\.timeoutInterval), [30, 30, 30])
    }
}
