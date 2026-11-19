import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireApp

final class ProjectSnapshotPriorityTests: XCTestCase {
    private func snapshot(_ t: FakeTracker) async throws -> ProjectSnapshot {
        let summary = try await t.projects()[0]
        return try await ProjectStore.snapshot(t, summary, limit: 50, previous: nil)
    }

    func testSnapshotHidesPriority() async throws {
        let with = try await snapshot(FakeTracker())
        XCTAssertTrue(with.hasPriority)
        XCTAssertNotNil(with.fields.first { $0.id == ProjectSnapshot.priorityFieldId })
        let without = try await snapshot(FakeTracker(capabilities: [.epics]))
        XCTAssertFalse(without.hasPriority)
        XCTAssertNil(without.fields.first { $0.id == ProjectSnapshot.priorityFieldId })
        XCTAssertNotNil(without.fields.first { $0.id == ProjectSnapshot.statusFieldId })
    }
}
