import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

final class RunnerDeskTests: XCTestCase {
    let mbp = MachineLink(machine: "mbp", base: URL(string: "http://mbp.tail:7690")!, token: "osd1.APP1.secret", local: false)
    let mba = MachineLink(machine: "mba", base: DaemonClient.loopback, token: nil, local: true)

    func draft(_ env: String?) -> WorkOrderDraft {
        WorkOrderDraft(runtime: "orca", order: .start(LaunchRequest(repo: "/src/oversire", agent: .claude, prompt: "Fix it", environment: env)))
    }

    func choice(mbpLive: Bool, cloud: Bool) -> RunnerChoice {
        RunnerChoice(targets: [RunnerTarget(link: mba, live: true, runtimes: ["orca"]),
                               RunnerTarget(link: mbp, live: mbpLive, runtimes: mbpLive ? ["orca", "oversire"] : nil)],
                     cloud: cloud)
    }

    func testTheDaemonWhenLive() throws {
        XCTAssertEqual(try choice(mbpLive: true, cloud: true).route(draft("mbp")), .daemon(mbp))
        XCTAssertEqual(try choice(mbpLive: true, cloud: false).route(draft("mbp")), .daemon(mbp))
        XCTAssertEqual(try choice(mbpLive: false, cloud: false).route(draft(nil)), .daemon(mba))
    }

    func testTheHubWhenNotLive() throws {
        XCTAssertEqual(try choice(mbpLive: false, cloud: true).route(draft("mbp")), .hub)
        XCTAssertEqual(try RunnerChoice(cloud: true).route(draft("mbp")), .hub)
    }

    func testAnErrorWhenNeither() {
        XCTAssertThrowsError(try choice(mbpLive: false, cloud: false).route(draft("mbp"))) { e in
            XCTAssertEqual((e as? LocalizedError)?.errorDescription, "mbp is offline")
        }
        XCTAssertThrowsError(try RunnerChoice().route(draft("mbp"))) { e in XCTAssertEqual(e as? RunnerOffline, RunnerOffline(machine: "mbp")) }
    }

    func testTheRuntimeMustMatch() throws {
        let c = choice(mbpLive: true, cloud: false)
        let wire = WorkOrderDraft(runtime: "oversire", order: .start(LaunchRequest(repo: "/r", agent: .claude, prompt: "p")))
        XCTAssertThrowsError(try c.route(wire), "mba has no oversire runtime")
    }

    func testTheOrderOfADraftIsTheHubOrder() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let o = draft("mbp").order(suggestion: "s1", runner: "mbp", id: "wo-1", now: now)
        XCTAssertEqual(o.state, .queued)
        XCTAssertEqual(o.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(o.suggestion, "s1")
        XCTAssertTrue(WorkOrder.newID().hasPrefix("wo-"))
        XCTAssertEqual(WorkOrder.newID().count, 11)
        guard case .start(let r) = draft("mbp").order.onTarget else { return XCTFail() }
        XCTAssertNil(r.environment, "the daemon runs its own Orca")
    }

    func testRunSendsTheOrderAndReadsTheFrames() async throws {
        let http = RecordedHTTP()
        http.on("POST", "http://mbp.tail:7690/v1/orders", 202, #"{"order":{}}"#)
        let store = MemoryStore()
        let desk = RunnerDesk(store: store, hub: Hub(), http: http)
        desk.update(choice(mbpLive: true, cloud: false))
        let s = Suggestion(id: "s1", subject: .repo(RepoRef(account: AccountID(provider: "github", id: "o"), path: "o/r", url: URL(string: "https://github.com/o/r")!)), kind: "triage",
                           title: "t", body: "", proposal: .workOrder(draft("mbp")), state: .accepted, subjectVersion: "1",
                           createdAt: Date(), expiresAt: Date().addingTimeInterval(60))
        let done = await desk.run(s, draft: draft("mbp"), on: mbp)
        XCTAssertEqual(done.state, .done)
        XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer osd1.APP1.secret")
        let sent = try JSONDecoder.iso.decode(WorkOrder.self, from: XCTUnwrap(http.requests.first?.httpBody))
        XCTAssertEqual(sent.runner, "mbp")
        let orders = try await store.all(WorkOrder.self)
        XCTAssertEqual(orders.map(\.id), [sent.id])

        desk.received(#"{"type":"ack","order":"\#(sent.id)"}"#, from: "mbp")
        await eventually("acked") { (try? await store.get(WorkOrder.self, id: sent.id))?.state == .acked }
        desk.received(#"{"type":"result","order":"\#(sent.id)","state":"done","result":{"session":{"workspace":{"account":{"provider":"orca","id":"local"},"id":"w1"},"id":"t1"}}}"#, from: "mbp")
        await eventually("done") { (try? await store.get(WorkOrder.self, id: sent.id))?.state == .done }
    }

    func testRunFailsWhenTheDaemonRefuses() async {
        let http = RecordedHTTP()
        http.on("POST", "http://mbp.tail:7690/v1/orders", 403, #"{"error":"only an app gives orders"}"#)
        let desk = RunnerDesk(store: MemoryStore(), hub: Hub(), http: http)
        let s = Suggestion(id: "s1", subject: .repo(RepoRef(account: AccountID(provider: "github", id: "o"), path: "o/r", url: URL(string: "https://github.com/o/r")!)), kind: "triage",
                           title: "t", body: "", state: .accepted, subjectVersion: "1", createdAt: Date(), expiresAt: Date())
        let r = await desk.run(s, draft: draft("mbp"), on: mbp)
        XCTAssertEqual(r.state, .failed)
        XCTAssertNotNil(r.error)
    }

    func testAnswersTakeThePathOfTheSession() async throws {
        let http = RecordedHTTP()
        http.on("POST", "http://mbp.tail:7690/v1/runner-sessions/s-1/answer", 200, "{}")
        http.on("POST", "http://mbp.tail:7690/v1/runner-sessions/s-1/permission", 409, #"{"error":"no such prompt is pending"}"#)
        let hub = Hub()
        let store = MemoryStore()
        let desk = RunnerDesk(store: store, hub: hub, http: http)
        desk.update(choice(mbpLive: true, cloud: true))
        let answer = RunnerAnswer(id: "q1", items: [])

        // A session that no daemon sent goes to the hub.
        let viaHub = try await desk.send(session: "s-1", answer: answer)
        XCTAssertEqual(viaHub, .sent)
        XCTAssertEqual(hub.calls.get(), ["s-1"])

        _ = desk.transport(mbp)
        let now = "2026-10-22T10:00:00Z"
        desk.received(#"{"type":"session","session":{"id":"s-1","runner":"D1","session":{"workspace":{"account":{"provider":"oversire","id":"D1"},"id":"w"},"id":"s-1"},"order":"wo-1","agent":"claude","repo":"/r","state":"waitingInput","startedAt":"\#(now)","updatedAt":"\#(now)"}}"#, from: "mbp")
        await eventually("session") { (try? await store.get(RunnerSession.self, id: "s-1")) != nil }
        let viaDaemon = try await desk.send(session: "s-1", answer: answer)
        XCTAssertEqual(viaDaemon, .sent)
        XCTAssertEqual(http.requests.last?.url?.path, "/v1/runner-sessions/s-1/answer")
        let permission = try await desk.send(session: "s-1", permission: PermissionAnswer(id: "p1", allow: true))
        XCTAssertEqual(permission, .alreadyAnswered)
        XCTAssertEqual(hub.calls.get(), ["s-1"])

        // The machine goes offline: the hub again.
        desk.update(choice(mbpLive: false, cloud: true))
        _ = try await desk.send(session: "s-1", answer: answer)
        XCTAssertEqual(hub.calls.get(), ["s-1", "s-1"])
    }

    final class Hub: RunnerAnswerSending, @unchecked Sendable {
        let calls = Locked<[String]>([])
        func send(session: String, answer: RunnerAnswer) async throws -> AnswerResult { calls.with { $0.append(session) }; return .sent }
        func send(session: String, permission: PermissionAnswer) async throws -> AnswerResult { calls.with { $0.append(session) }; return .sent }
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
