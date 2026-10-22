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
        XCTAssertNil(lane.pick(state: started, world: world(ciPassed: false)).entry)
        XCTAssertEqual(lane.pick(state: started, world: world(ciPassed: true)).entry?.key, "OVERSIRE-2")
        XCTAssertEqual(lane.pick(state: nil, world: world(ciPassed: false)).entry?.key, "OVERSIRE-2")
    }

    func testPickSkipsBlockedEntries() {
        func entry(_ n: Int, _ c: QueueEntry.Condition = .slot) -> QueueEntry { QueueEntry(key: "OVERSIRE-\(n)", title: "\(n)", condition: c, added: Date()) }
        let started = QueueLaneState(project: lane.project, lastStarted: "OVERSIRE-1", updatedAt: Date())
        struct Case { var name: String; var entries: [QueueEntry]; var open: [String: [String]]; var start: String?; var holds: [String: QueueHold] }
        let cases = [
            Case(name: "no blockers", entries: [entry(2), entry(3)], open: [:], start: "OVERSIRE-2", holds: [:]),
            Case(name: "head blocked", entries: [entry(2), entry(3)], open: ["OVERSIRE-2": ["OVERSIRE-9"]],
                 start: "OVERSIRE-3", holds: ["OVERSIRE-2": .waits(on: ["OVERSIRE-9"])]),
            Case(name: "all blocked", entries: [entry(2), entry(3)], open: ["OVERSIRE-2": ["OVERSIRE-9"], "OVERSIRE-3": ["OVERSIRE-2", "OVERSIRE-9"]],
                 start: nil, holds: ["OVERSIRE-2": .waits(on: ["OVERSIRE-9"]), "OVERSIRE-3": .waits(on: ["OVERSIRE-2", "OVERSIRE-9"])]),
            Case(name: "blocker done", entries: [entry(2), entry(3)], open: ["OVERSIRE-2": []], start: "OVERSIRE-2", holds: [:]),
            Case(name: "condition and blocker", entries: [entry(2, .ciPassed), entry(3, .ciPassed), entry(4)], open: ["OVERSIRE-2": ["OVERSIRE-9"]],
                 start: nil, holds: ["OVERSIRE-2": .waits(on: ["OVERSIRE-9"])]),
        ]
        for c in cases {
            var w = world(ciPassed: false)
            w.blockers = { c.open[$0] ?? [] }
            let p = QueueLane(project: lane.project, identifier: "OVERSIRE", entries: c.entries).pick(state: started, world: w)
            XCTAssertEqual(p.entry?.key, c.start, c.name)
            XCTAssertEqual(p.holds, c.holds, c.name)
        }
        var w = world(ciPassed: true)
        w.blockers = { $0 == "OVERSIRE-2" ? nil : [] }
        let p = QueueLane(project: lane.project, identifier: "OVERSIRE", entries: [entry(2), entry(3)]).pick(state: started, world: w)
        XCTAssertEqual(p.holds["OVERSIRE-2"], .unknown, "relations that load hold the entry")
        XCTAssertEqual(p.entry?.key, "OVERSIRE-3")
        w.busy = { _ in 1 }
        XCTAssertNil(QueueLane(project: lane.project, identifier: "OVERSIRE", entries: [entry(3)]).pick(state: started, world: w).entry, "no free slot")
    }

    func testPickSkipsBusyAreas() {
        func entry(_ n: Int) -> QueueEntry { QueueEntry(key: "OVERSIRE-\(n)", title: "\(n)", added: Date()) }
        let areas = ["OVERSIRE-2": ["contract"], "OVERSIRE-3": ["ui", "contract"], "OVERSIRE-4": ["ui"], "OVERSIRE-5": []]
        struct Case { var name: String; var busy: [String: String]; var open: [String: [String]]; var start: String?; var holds: [String: QueueHold] }
        let cases = [
            Case(name: "no busy area", busy: [:], open: [:], start: "OVERSIRE-2", holds: [:]),
            Case(name: "head area busy", busy: ["contract": "OVERSIRE-9"], open: [:], start: "OVERSIRE-4",
                 holds: ["OVERSIRE-2": .area("contract", runs: "OVERSIRE-9"), "OVERSIRE-3": .area("contract", runs: "OVERSIRE-9")]),
            Case(name: "two areas busy", busy: ["contract": "OVERSIRE-9", "ui": "OVERSIRE-8"], open: [:], start: "OVERSIRE-5",
                 holds: ["OVERSIRE-2": .area("contract", runs: "OVERSIRE-9"), "OVERSIRE-3": .area("ui", runs: "OVERSIRE-8"),
                         "OVERSIRE-4": .area("ui", runs: "OVERSIRE-8")]),
            Case(name: "blocker before area", busy: ["contract": "OVERSIRE-9"], open: ["OVERSIRE-2": ["OVERSIRE-1"]], start: "OVERSIRE-4",
                 holds: ["OVERSIRE-2": .waits(on: ["OVERSIRE-1"]), "OVERSIRE-3": .area("contract", runs: "OVERSIRE-9")]),
            Case(name: "own area", busy: ["contract": "OVERSIRE-2"], open: [:], start: "OVERSIRE-2",
                 holds: ["OVERSIRE-3": .area("contract", runs: "OVERSIRE-2")]),
        ]
        for c in cases {
            var w = world(ciPassed: true)
            w.blockers = { c.open[$0] ?? [] }
            w.areas = { areas[$0] ?? [] }
            w.busyAreas = { _ in c.busy }
            let p = QueueLane(project: lane.project, identifier: "OVERSIRE", entries: (2...5).map(entry)).pick(state: nil, world: w)
            XCTAssertEqual(p.entry?.key, c.start, c.name)
            XCTAssertEqual(p.holds, c.holds, c.name)
        }
        XCTAssertEqual(QueueHold.area("contract", runs: "OVERSIRE-63").reason, "⊘ Area busy: contract · OVERSIRE-63 runs")
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

    func testAddByKeyAndStartNowWithoutWorkspace() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ref = ProjectRef(workspace: "ocral", id: "p1")
        let item = Item(id: "2", key: "OVERSIRE-2", title: "Two", url: "", statusOptionId: "t", fields: [:], assignees: [], labels: [],
                        author: "ada", updatedBy: "ada", updatedAt: Date(), activityAt: Date(), commentCount: 0, lastComment: nil, mentionsMe: false)
        let snap = ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "OVERSIRE", title: "OverSire", url: "", closed: false),
                                   statusOptions: [], items: [item], fetchedAt: Date(), me: "ada")
        let disk: [String: Any] = ["snapshots": [ref.storeKey: try JSONSerialization.jsonObject(with: JSONEncoder().encode(snap))],
                                   "readActivity": [], "readItems": []]
        try JSONSerialization.data(withJSONObject: disk).write(to: dir.appendingPathComponent("state.json"))

        await MainActor.run {
            let writes = StoreWrites(store: LocalStore(dir: dir))
            let projects = ProjectStore(trackers: ENV, notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                        statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
            let q = WorkQueue(writes: writes, store: projects, agents: AgentIndex(writes: writes))
            XCTAssertFalse(q.add(key: "OVERSIRE-9"), "no tracked item")
            XCTAssertTrue(q.add(key: "oversire-2"))
            XCTAssertTrue(q.contains("OVERSIRE-2"))
            q.add(key: "OVERSIRE-2")
            XCTAssertEqual(q.count, 1, "a second add does nothing")

            let saved = PROJECTS_CFG.orca.roots[ref.storeKey]
            PROJECTS_CFG.orca.roots[ref.storeKey] = nil
            defer { PROJECTS_CFG.orca.roots[ref.storeKey] = saved }
            XCTAssertNotNil(q.start("OVERSIRE-2", project: ref.storeKey))
            XCTAssertTrue(q.contains("OVERSIRE-2"), "no workspace: the entry stays")
            XCTAssertEqual(q.state(ref.storeKey)?.error, "Choose an Orca workspace for OVERSIRE: use Start now once.")
        }
    }
}
