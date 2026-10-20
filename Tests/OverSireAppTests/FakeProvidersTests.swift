import AppKit
import XCTest
import OverSireCore
import OverSireTestKit
import OverSireSync
@testable import OverSireApp

final class FakeProvidersTests: XCTestCase {
    private func seeded(_ caps: Set<Capability> = [.projectSettings, .relations]) async throws -> (FakeTracker, ProjectSummary) {
        let t = FakeTracker(capabilities: caps)
        _ = try await t.create(ItemDraft(title: "First fake item"), in: t.project)
        _ = try await t.create(ItemDraft(title: "Second fake item"), in: t.project)
        return (t, try await t.projects()[0])
    }

    func testSnapshotHasTheFakeItems() async throws {
        let (t, summary) = try await seeded()
        let snap = try await ProjectStore.snapshot(t, summary, limit: 50, previous: nil)
        XCTAssertEqual(Set(snap.items.map(\.title)), ["First fake item", "Second fake item"])
        XCTAssertEqual(snap.statusOptions.count, 4)
        XCTAssertNil(snap.intake, "a tracker with no intake has no intake list")
    }

    @MainActor
    func testProjectsTabShowsTheFakeItems() async throws {
        let (t, summary) = try await seeded()
        let snap = try await ProjectStore.snapshot(t, summary, limit: 50, previous: nil)
        let rows = snap.items.map { ProjectItemRow(item: $0, snap: snap, unread: false, last: nil, w: 600, expanded: false) }
        let text = rows.flatMap { texts($0) }.joined(separator: "\n")
        XCTAssertTrue(text.contains("First fake item"), text)
        XCTAssertTrue(text.contains("Second fake item"), text)

        let header = ProjectHeader(snap: snap, live: false, refreshing: false, filter: nil, updated: "now", w: 600,
                                   folded: false, canReorder: false)
        let tip = header.subviews.compactMap { ($0 as? Badge)?.toolTip }.first { $0.contains("ntake") }
        XCTAssertEqual(tip, "Intake is off for this project, or OverSire cannot read it")
    }

    func testKeysUseTheTrackerFormats() {
        let hash = KeyFormat(pattern: "#([0-9]+)\\b")
        XCTAssertEqual(WorkstreamIndex.key(in: "fix #42 now", known: [], formats: [hash]), "42")
        XCTAssertNil(WorkstreamIndex.key(in: "fix #42 now", known: [], formats: [.projectDash]))
        XCTAssertEqual(WorkstreamIndex.key(inBranch: "fake-3/fix", known: ["FAKE"], formats: [.projectDash]), "FAKE-3")
        XCTAssertNil(WorkstreamIndex.key(inBranch: "other-3/fix", known: ["FAKE"], formats: [.projectDash]))
    }

    private func texts(_ v: NSView) -> [String] {
        ((v as? NSTextField).map { [$0.stringValue] } ?? []) + v.subviews.flatMap(texts)
    }
}

final class ConfigSafetyTests: XCTestCase {
    func testNoSaveBeforeLoad() throws {
        let before = FileManager.default.contents(atPath: CONFIG_PATH)
        REPO_COLORS["config-safety-test"] = 1
        saveConfig()
        XCTAssertFalse(CONFIG_READ)
        XCTAssertEqual(FileManager.default.contents(atPath: CONFIG_PATH), before, "a test process must not write the user config")
    }
}

final class LiveSyncTests: XCTestCase {
    private func ev(_ id: String, _ kind: EventKind, _ action: String, _ subject: SubjectRef) -> ProviderEvent {
        ProviderEvent(id: id, provider: "fake", account: AccountID(provider: "fake", id: "o"), kind: kind,
                      action: action, subject: subject, at: Date())
    }

    func testPlanFromEventsOfAnyProvider() {
        let host = AccountID(provider: "fake-host", id: "o")
        let repo = RepoRef(account: host, path: "o/kept", url: URL(string: "https://host.fake/o/kept")!)
        let other = RepoRef(account: host, path: "o/other", url: URL(string: "https://host.fake/o/other")!)
        let tracker = FakeTracker(account: "ws")
        let item = ItemRef(project: tracker.project, id: "i1", key: "FAKE-1", url: URL(string: "https://tracker.fake/FAKE-1")!)
        let plan = RefreshPlan([
            ev("1", .run, "completed", .run(RunRef(account: host, repo: repo, id: "9"))),
            ev("2", .run, "in_progress", .run(RunRef(account: host, repo: repo, id: "10"))),
            ev("3", .change, "updated", .change(ChangeRef(repo: other, number: 3, url: other.url))),
            ev("4", .item, "updated", .item(item)),
        ], resyncs: [AccountID(provider: "fake-tracker", id: "ws2")], knownRepos: ["O/Kept"])
        XCTAssertEqual(plan.repos, ["O/Kept"], "unknown repos drop")
        XCTAssertEqual(plan.completedRuns.map(\.1), ["9"])
        XCTAssertTrue(plan.includePRs)
        XCTAssertEqual(plan.projects.map { "\($0.workspace)/\($0.project ?? "*")" }, ["ws2/*", "ws/p1"])
    }

    func testTheOldCloudCursorMoves() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "oversire-tests-\(UUID())"))
        defaults.set(42, forKey: "relayCursor")
        let cursors = CursorStore(url: nil)
        LiveSync.migrateCursor(into: cursors, defaults: defaults)
        XCTAssertEqual(cursors[CloudSource.cursorKey]?.rawValue, "42")
        XCTAssertNil(defaults.object(forKey: "relayCursor"))

        defaults.set(7, forKey: "relayCursor")
        LiveSync.migrateCursor(into: cursors, defaults: defaults)
        XCTAssertEqual(cursors[CloudSource.cursorKey]?.rawValue, "42", "a newer cursor stays")
    }
}
