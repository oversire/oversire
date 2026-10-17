import OverSireCore
import OverSireSync
import XCTest
@testable import OverSireApp

final class WorkQueueTests: XCTestCase {
    private let lane = QueueLane(project: "plane:ocral:p1", identifier: "OVERSIRE",
                                 entries: [QueueEntry(key: "OVERSIRE-2", title: "Two", condition: .ciPassed, added: Date())])

    private func world(ciPassed: Bool) -> QueueWorld {
        QueueWorld(busy: { _ in 0 }, slots: { _ in 1 }, ciPassed: { _ in ciPassed }, done: { _ in false }, now: Date())
    }

    func testDueReadsTheLaneState() {
        let started = QueueLaneState(project: lane.project, lastStarted: "OVERSIRE-1", updatedAt: Date())
        XCTAssertNil(WorkQueue.due(lane, state: started, world: world(ciPassed: false)))
        XCTAssertEqual(WorkQueue.due(lane, state: started, world: world(ciPassed: true))?.key, "OVERSIRE-2")
        XCTAssertEqual(WorkQueue.due(lane, state: nil, world: world(ciPassed: false))?.key, "OVERSIRE-2")
    }

    func testLoadsTheStateAndKeepsALaneWithAnError() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = LocalStore(dir: dir)
        try await store.put(lane)
        try await store.put(QueueLaneState(project: lane.project, error: "No workspace", updatedAt: Date()))

        await MainActor.run {
            let writes = StoreWrites(store: store)
            let projects = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                        statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
            let q = WorkQueue(writes: writes, store: projects, agents: AgentIndex(writes: writes))
            XCTAssertEqual(q.state(lane.project)?.error, "No workspace")
            q.remove("OVERSIRE-2")
            XCTAssertEqual(q.lane(lane.project)?.entries.count, 0, "the error keeps the empty lane")
            XCTAssertEqual(q.count, 0)
        }
    }
}
