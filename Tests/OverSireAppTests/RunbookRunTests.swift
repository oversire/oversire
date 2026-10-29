import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class RunbookRunTests: XCTestCase {
    private let summary = ProjectSummary(ref: ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE"),
                                         identifier: "OVERSIRE", title: "OverSire", url: "https://app.plane.so/ocral/projects/p1", closed: false)
    private let item = Item(id: "i341", key: "OVERSIRE-341", title: "Retry a failed sync", url: "https://app.plane.so/ocral/browse/OVERSIRE-341/",
                            statusOptionId: nil, fields: [:], assignees: [], labels: [], author: nil, updatedBy: nil, updatedAt: Date(),
                            activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)

    private func starter(_ rt: FakeRuntime?, cfg: ProjectsConfig = ProjectsConfig(), root: String? = "/src/oversire-workspace") -> RunbookStarter {
        var s = RunbookStarter()
        s.runtime = { rt }
        s.root = { _ in root }
        s.cfg = { cfg }
        return s
    }

    private func config() -> ProjectsConfig {
        var cfg = ProjectsConfig()
        cfg.runtime.add("claude-max", cli: "claude")
        cfg.runtime.profiles["claude-max"]?.model = "claude-opus-5-5"
        cfg.runtime.runbooks = cfg.runtime.defaultRunbooks
        return cfg
    }

    // MARK: Starter

    func testTheStartResolvesEachAgentOfTheSteps() throws {
        let cfg = config()
        let full = try XCTUnwrap(cfg.runtime.runbook("full"))
        let s = try starter(nil, cfg: cfg).request(full, item: item, in: summary)
        XCTAssertEqual(s.repo, "/src/oversire-workspace")
        XCTAssertEqual(s.item.key, "OVERSIRE-341")
        XCTAssertEqual(s.item.url.absoluteString, item.url)
        XCTAssertEqual(s.title, item.title)
        XCTAssertNil(s.startAt)
        XCTAssertEqual(Set(s.agents.keys), ["claude", "claude-max"])
        XCTAssertEqual(s.agents["claude-max"]?.model, "claude-opus-5-5")
        XCTAssertEqual(s.agents["claude-max"]?.profile, "claude-max")
        XCTAssertEqual(s.agents["claude"]?.command, "claude -n OVERSIRE-341", "the command name is the item key")
        XCTAssertEqual(s.runbook, full)
    }

    func testTheStartRefusesABadRunbookAndNoRoot() throws {
        let cfg = config()
        var book = try XCTUnwrap(cfg.runtime.runbook("small"))
        book.steps[0].agent = "gone"
        XCTAssertThrowsError(try starter(nil, cfg: cfg).request(book, item: item, in: summary)) { e in
            XCTAssertEqual((e as? RunbookRefusal)?.problems.map(\.text), ["Implement: there is no agent gone."])
        }
        XCTAssertThrowsError(try starter(nil, cfg: cfg, root: nil).request(cfg.runtime.runbooks[0], item: item, in: summary)) { e in
            XCTAssertEqual(e as? SessionStartError, .noRoot("OVERSIRE"))
        }
    }

    func testTheStartNeedsADaemonWithRunbooks() async throws {
        let cfg = config()
        let book = cfg.runtime.runbooks[0]
        do {
            _ = try await starter(nil, cfg: cfg).start(book, item: item, in: summary)
            XCTFail("a start with no runtime")
        } catch { XCTAssertEqual(error as? SessionStartError, .noRuntime) }
        do {
            _ = try await starter(FakeRuntime(capabilities: [.sessionInput]), cfg: cfg).start(book, item: item, in: summary)
            XCTFail("a start on an old daemon")
        } catch { XCTAssertEqual(error as? SessionStartError, .noRunbooks) }
    }

    func testAStartAtAStepSkipsTheStepsBefore() async throws {
        let cfg = config()
        let rt = FakeRuntime()
        let run = try await starter(rt, cfg: cfg).start(try XCTUnwrap(cfg.runtime.runbook("full")), item: item, in: summary, at: "implement")
        XCTAssertEqual(run.current, "implement")
        XCTAssertEqual(run.state, .running, "a start at a step that pauses before does not wait at the gate")
        XCTAssertEqual(run.steps.prefix(3).map(\.state), [.skipped, .skipped, .skipped])
        let shown = await MainActor.run { RUNBOOKS.run(for: "OVERSIRE-341") }
        XCTAssertEqual(shown?.id, run.id, "the start shows in the book at once")
    }

    // MARK: Book

    func testTheBookKeepsTheNewestRunOfEachItem() async throws {
        let rt = FakeRuntime()
        let clock = Ticks()
        rt.runbooks.now = { clock.next() }
        let cfg = config()
        let book = RunbookBook(runtime: { rt })
        let s = try starter(rt, cfg: cfg).request(cfg.runtime.runbooks[1], item: item, in: summary)
        let first = try rt.runbooks.start(s)
        await book.refresh()
        XCTAssertEqual(book.run(for: "OVERSIRE-341"), first)
        XCTAssertEqual(book.open.map(\.id), [first.id])
        XCTAssertTrue(book.waiting.isEmpty)

        let paused = try rt.runbooks.act(.pause, on: first.id)
        let changed = expectation(forNotification: RunbookBook.changed, object: book)
        book.apply(paused)
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(book.waiting.map(\.id), [first.id])
        book.apply(first)
        XCTAssertEqual(book.run(for: "OVERSIRE-341")?.state, .paused, "an older copy of the run does not win")

        let stopped = try rt.runbooks.act(.stop, on: first.id)
        book.apply(stopped)
        var later = try rt.runbooks.start(s)
        later.started = stopped.started.addingTimeInterval(60)
        book.apply(later)
        book.apply(stopped)
        XCTAssertEqual(book.run(for: "OVERSIRE-341")?.id, later.id, "a newer run of the item wins")
    }

    func testTheBookReadsNothingWithoutRunbooks() async throws {
        let rt = FakeRuntime(capabilities: [.sessionInput])
        let book = RunbookBook(runtime: { rt })
        let cfg = config()
        _ = try rt.runbooks.start(try starter(rt, cfg: cfg).request(cfg.runtime.runbooks[1], item: item, in: summary))
        await book.refresh()
        XCTAssertTrue(book.open.isEmpty)
    }

    /// A time that moves 1 s on each read.
    private final class Ticks: @unchecked Sendable {
        private let lock = NSLock()
        private var t = Date(timeIntervalSince1970: 1_792_400_000)
        func next() -> Date { lock.withLock { t += 1; return t } }
    }
}
