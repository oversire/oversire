import AppKit
import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// The read of the description on the intake detail page (OVERSIRE-462).
@MainActor
final class IntakeDetailReadTests: XCTestCase {
    private final class Trackers: TrackerDirectory {
        let fake: FakeTracker
        init(_ fake: FakeTracker) { self.fake = fake }
        var trackerIds: [String] { [fake.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == fake.account.id ? fake : nil }
    }

    private let fake = FakeTracker()
    private var pk = ""
    private var item: IntakeItem!
    private var page: IntakeDetailPage!

    override func setUp() async throws {
        item = try await fake.createIntake(ItemDraft(title: "Labels drop", bodyMarkdown: "label sync is broken"), in: fake.project).intake
        let summary = try await fake.projects()[0]
        pk = summary.ref.storeKey
        let d = TestAppData()
        d.projectStore = ProjectStore(trackers: Trackers(fake), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                      statePath: d.tmp + "/s.json", activityPath: d.tmp + "/a.jsonl")
        d.projectStore.seed(ProjectSnapshot(summary: summary, statusOptions: [], items: [], fetchedAt: Date(), intake: [item]))
        page = IntakeDetailPage(.intakeItem("FAKE", item.id), data: d, router: Router())
    }

    private func texts(_ v: NSView) -> [String] { (v as? NSTextField).map { [$0.stringValue] } ?? v.subviews.flatMap(texts) }
    private func buttons(_ v: NSView) -> [NSButton] { (v as? NSButton).map { [$0] } ?? v.subviews.flatMap(buttons) }

    /// The rows of the description card, built.
    private func description() throws -> NSView {
        let secs = page.sections() ?? []
        return try XCTUnwrap(PageSection.flatten(secs).first { $0.id.hasSuffix("/description") }).make()
    }

    func testAFailedDescriptionDoesNotReadInALoop() async throws {
        fake.failIntakeDetail = .transport("Plane did not answer.")
        page.reload()
        await page.read(item, pk: pk).settled()
        XCTAssertEqual(fake.intakeDetailReads, 1)
        for _ in 0..<3 {
            page.reload()
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        await page.read(item, pk: pk).settled()
        XCTAssertEqual(fake.intakeDetailReads, 1, "one failure gives one read, not a loop")
        XCTAssertEqual(page.parts.first?.state, .failed("Plane did not answer."))
    }

    func testAFailedDescriptionShowsTheNoteAndTryAgainReadsAgain() async throws {
        fake.failIntakeDetail = .transport("Plane did not answer.")
        page.reload()
        await page.read(item, pk: pk).settled()
        let card = try description()
        XCTAssertTrue(texts(card).contains("OverSire cannot read the description."))
        XCTAssertTrue(texts(card).contains("Plane did not answer."))
        XCTAssertFalse(texts(card).contains { $0.contains("OverSire cannot read the description:") })
        fake.failIntakeDetail = nil
        let again = try XCTUnwrap(buttons(card).first { $0.title == "Try again" })
        again.performClick(nil)
        await page.read(item, pk: pk).settled()
        XCTAssertEqual(fake.intakeDetailReads, 2)
        guard case .fresh = page.parts.first?.state else { return XCTFail("the state is fresh") }
        XCTAssertFalse(texts(try description()).contains("OverSire cannot read the description."))
    }

    func testTheRetryPlanReadsAgainByItself() async throws {
        fake.failIntakeDetail = .transport("Plane did not answer.")
        page.reload()
        let r = page.read(item, pk: pk)
        await r.settled()
        XCTAssertEqual(r.last.retry(now: Date())?.k, 1)
        XCTAssertEqual(page.parts.map(\.id), ["description", "plane"])
    }
}
