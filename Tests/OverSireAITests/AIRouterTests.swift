import XCTest
import OverSireCore
import OverSireSync
import OverSireTestKit
@testable import OverSireAI

final class AIRouterTests: XCTestCase {
    let task = AITask(id: "digest:2026-10-16", kind: .digest, input: CIPrompts.digestInput(facts: ["3 runs failed."]))

    func testFirstAvailableEngineRuns() async throws {
        let off = FakeAIEngine(id: "off", available: false)
        let a = FakeAIEngine(id: "a")
        let b = FakeAIEngine(id: "b")
        a.on(.digest, .success("All good."))
        let r = try await AIRouter(engines: [off, a, b]).run(task)
        XCTAssertEqual(r.engine, "a")
        XCTAssertEqual(r.text, "All good.")
        XCTAssertEqual(r.task, task.id)
        XCTAssertTrue(off.tasks.isEmpty)
        XCTAssertTrue(b.tasks.isEmpty)
    }

    func testUnavailableFallsToTheNextEngine() async throws {
        let a = FakeAIEngine(id: "a")
        let b = FakeAIEngine(id: "b")
        a.on(.digest, .failure(.unavailable("no credit")))
        let r = try await AIRouter(engines: [a, b]).run(task)
        XCTAssertEqual(r.engine, "b")

        b.on(.digest, .failure(.unavailable("offline")))
        do { _ = try await AIRouter(engines: [a, b]).run(task); XCTFail("no engine") } catch {
            XCTAssertEqual(error as? AIError, .unavailable("offline"))
        }
    }

    func testOtherErrorsStop() async throws {
        let a = FakeAIEngine(id: "a")
        let b = FakeAIEngine(id: "b")
        a.on(.digest, .failure(.http(401, "bad key")))
        do { _ = try await AIRouter(engines: [a, b]).run(task); XCTFail("401") } catch {
            XCTAssertEqual(error as? AIError, .http(401, "bad key"))
        }
        XCTAssertTrue(b.tasks.isEmpty, "a real error does not go to the next engine")
        do { _ = try await AIRouter(engines: []).run(task); XCTFail("none") } catch {
            XCTAssertEqual(error as? AIError, .notConfigured)
        }
    }

    func testResultsGoToTheStore() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-ai-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalStore(dir: dir)
        let clock = Clock()
        let router = AIRouter(engines: [FakeAIEngine()], store: store, now: { clock.tick() })
        for i in 0..<(AIRouter.keep + 2) {
            _ = try await router.run(AITask(id: "t\(i)", kind: .tidy, input: AIInput(text: "x")))
        }
        _ = try await router.run(AITask(kind: .ping, input: AIInput(text: "ping")))
        let all = try await store.all(AIResult.self)
        XCTAssertEqual(all.count, AIRouter.keep, "the oldest results drop, a ping is not kept")
        let first = try await store.get(AIResult.self, id: "t0")
        XCTAssertNil(first)
        let last = try await store.get(AIResult.self, id: "t\(AIRouter.keep + 1)")
        XCTAssertEqual(last?.engine, "fake")
    }

    func testEveryKnownKindHasAPrompt() throws {
        for kind: AITaskKind in [.ping, .draft, .tidy, .check, .order, .sessionSummary, .question, .triage, .failureReason, .digest] {
            XCTAssertNoThrow(try kind.prompt(AIInput(text: "x")), "\(kind)")
        }
        XCTAssertThrowsError(try AITaskKind("unknown").prompt(AIInput(text: "x"))) {
            XCTAssertEqual($0 as? AIError, .unsupported("unknown"))
        }
    }
}

/// One second more on each call.
final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_800_000_000)
    func tick() -> Date { lock.withLock { t.addTimeInterval(1); return t } }
}
