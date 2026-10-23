import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// An accepted workOrder proposal: the daemon when live, the hub when not, a failed suggestion when neither.
final class DirectOrderTests: XCTestCase {
    let mbp = MachineLink(machine: "mbp", base: URL(string: "http://mbp.tail:7690")!, token: "osd1.APP1.secret", local: false)

    final class Hub: RunnerAnswerSending, @unchecked Sendable {
        func send(session: String, answer: RunnerAnswer) async throws -> AnswerResult { .sent }
        func send(session: String, permission: PermissionAnswer) async throws -> AnswerResult { .sent }
    }

    private func book(_ choice: RunnerChoice, http: RecordedHTTP = RecordedHTTP()) -> SuggestionBook {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
        let desk = RunnerDesk(store: MemoryStore(), hub: Hub(), http: http)
        desk.update(choice)
        let b = SuggestionBook(writes: StoreWrites(store: LocalStore(dir: dir)), desk: desk)
        let draft = WorkOrderDraft(runtime: "orca", order: .start(LaunchRequest(repo: "/src/r", agent: .claude, prompt: "p", environment: "mbp")))
        b.seed(Suggestion(id: "s1", subject: .repo(RepoRef(account: AccountID(provider: "github", id: "o"), path: "o/r", url: URL(string: "https://github.com/o/r")!)),
                          kind: "triage", title: "Fix", body: "", proposal: .workOrder(draft), subjectVersion: "1",
                          createdAt: Date(), expiresAt: Date().addingTimeInterval(600)))
        return b
    }

    private func target(live: Bool) -> RunnerTarget { RunnerTarget(link: mbp, live: live, runtimes: nil) }

    func testLiveDaemonRunsTheOrder() {
        let http = RecordedHTTP()
        http.on("POST", "http://mbp.tail:7690/v1/orders", 202, #"{"order":{}}"#)
        let b = book(RunnerChoice(targets: [target(live: true)], cloud: true), http: http)
        b.accept("s1", drop: [], by: "dev")
        XCTAssertEqual(b.all[0].state, .accepted)
        let done = expectation(description: "done")
        let o = NotificationCenter.default.addObserver(forName: SuggestionBook.changed, object: b, queue: .main) { _ in
            if b.all[0].state == .done { done.fulfill() }
        }
        wait(for: [done], timeout: 2)
        NotificationCenter.default.removeObserver(o)
        XCTAssertEqual(http.requests.map { $0.url?.path }, ["/v1/orders"])
    }

    func testTheHubWhenTheMachineIsNotLive() {
        let b = book(RunnerChoice(targets: [target(live: false)], cloud: true))
        b.accept("s1", drop: [], by: "dev")
        XCTAssertEqual(b.all[0].state, .accepted, "the hub makes the order")
    }

    func testAFailureWhenNeither() {
        let b = book(RunnerChoice(targets: [target(live: false)], cloud: false))
        b.accept("s1", drop: [], by: "dev")
        XCTAssertEqual(b.all[0].state, .failed)
        XCTAssertEqual(b.all[0].error, "mbp is offline")
    }
}
