import AppKit
import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireApp

final class FakeProvidersTests: XCTestCase {
    private func seeded() async throws -> (FakeTracker, ProjectSummary) {
        let t = FakeTracker()
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

    func testIntakeTabNeedsTheCapability() {
        XCTAssertFalse(Route.InboxTab.visible { _ in false }.contains(.intake))
        XCTAssertTrue(Route.InboxTab.visible { $0 == .intake }.contains(.intake))
        XCTAssertEqual(Route.InboxTab.visible { _ in false }.count, Route.InboxTab.allCases.count - 1)
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
