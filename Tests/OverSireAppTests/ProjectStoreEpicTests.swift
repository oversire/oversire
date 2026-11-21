import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// A project store on a FakeTracker with one project and one epic.
final class EpicRig {
    final class Trackers: TrackerDirectory {
        let fake: FakeTracker
        init(_ fake: FakeTracker) { self.fake = fake }
        var trackerIds: [String] { [fake.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == fake.account.id ? fake : nil }
    }

    actor Outlet: EventOutlet {
        var rows: [EventDraft] = []
        func append(_ drafts: [EventDraft]) async { rows += drafts }
        func link(_ links: [ItemLink]) async {}
    }

    let fake: FakeTracker
    let d: TestAppData
    let outlet = Outlet()
    var items: [ItemRef] = []
    var epic: Epic!

    /// `items`: the number of items. `epics`: the titles. `tracking`: false skips the first snapshot.
    /// `capabilities`: the capabilities of the fake. The default is the full set.
    init(items n: Int = 3, epics titles: [String] = ["Review desk"], tracking: Bool = true, capabilities: Set<Capability>? = nil) async throws {
        fake = capabilities.map { FakeTracker(capabilities: $0) } ?? FakeTracker()
        for i in stride(from: 1, through: n, by: 1) { items.append(try await fake.create(ItemDraft(title: "Item \(i)"), in: fake.project)) }
        for t in titles {
            let e = try await fake.createEpic(EpicDraft(title: t), in: fake.project)
            epic = epic ?? e
        }
        d = TestAppData(trackers: Trackers(fake))
        d.caps = [.epics]
        let desk = EventDesk(outlet: outlet)
        desk.machine = { "mba" }
        d.projectStore.events = desk
        if tracking { try await track() }
    }

    var summary: ProjectSummary {
        get async throws { try await fake.projects()[0] }
    }

    func track() async throws {
        let s = try await summary
        await MainActor.run { d.projectStore.track([s], live: []) }
        let seen = await Wait.until { await MainActor.run { self.d.projectStore.snapshot("FAKE") != nil } }
        XCTAssertTrue(seen, "timeout: the first snapshot")
    }

    func snapshot() async -> ProjectSnapshot? { await MainActor.run { d.projectStore.snapshot("FAKE") } }

    func reload() async {
        await withCheckedContinuation { c in
            DispatchQueue.main.async { self.d.projectStore.refresh([self.fake.project.storeKey], force: true, priority: .user) { _ in c.resume() } }
        }
    }

    /// The first row of the kind. It waits for the row.
    func row(_ kind: Event.Kind) async -> EventDraft? {
        for _ in 0..<200 {
            if let r = await outlet.rows.first(where: { $0.kind == kind }) { return r }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return nil
    }

    func rows(count: Int) async -> [EventDraft] {
        for _ in 0..<200 {
            let r = await outlet.rows
            if r.count >= count { return r }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await outlet.rows
    }
}

final class ProjectStoreEpicTests: XCTestCase {
    func testSnapshotLoadsEpicsBeforeItems() async throws {
        let rig = try await EpicRig(tracking: false)
        try await rig.fake.setEpic(rig.epic.id, for: rig.items[0])
        let s = try await ProjectStore.snapshot(rig.fake, rig.summary, limit: 50, previous: nil)
        XCTAssertEqual(s.epics?.map(\.title), ["Review desk"])
        XCTAssertEqual(s.items.first { $0.id == rig.items[0].id }?.epicId, rig.epic.id)
        XCTAssertNil(s.items.first { $0.id == rig.items[1].id }?.epicId)
    }

    func testSnapshotWithoutCapabilityHasNilEpics() async throws {
        let fake = FakeTracker(capabilities: [])
        _ = try await fake.create(ItemDraft(title: "One"), in: fake.project)
        let s = try await ProjectStore.snapshot(fake, fake.projects()[0], limit: 50, previous: nil)
        XCTAssertNil(s.epics)
        XCTAssertEqual(s.items.count, 1)
    }

    func testDigestChangesOnEpicsOnly() async throws {
        let rig = try await EpicRig(tracking: false)
        let s = try await ProjectStore.snapshot(rig.fake, rig.summary, limit: 50, previous: nil)
        var renamed = s
        renamed.epics = s.epics?.map { var e = $0; e.title = "Other"; return e }
        XCTAssertNotEqual(ProjectStore.digest(s), ProjectStore.digest(renamed))
        XCTAssertEqual(ProjectStore.digest(s), ProjectStore.digest(s))
    }

    func testWithItemsKeepsEpics() async throws {
        let rig = try await EpicRig(tracking: false)
        let s = try await ProjectStore.snapshot(rig.fake, rig.summary, limit: 50, previous: nil)
        XCTAssertEqual(ProjectStore.withItems(s, []).epics, s.epics)
        XCTAssertNotNil(s.epics)
    }

    func testSetEpicRefreshesAndMarksMine() async throws {
        let rig = try await EpicRig()
        let item = rig.items[0]
        let before = await rig.rows(count: 1)
        XCTAssertEqual(before.map(\.kind), [.epicCreated], "the first snapshot writes the backfill")
        let ok: Bool = await withCheckedContinuation { c in
            DispatchQueue.main.async {
                rig.d.projectStore.setEpic(rig.epic.id, itemId: item.id) { c.resume(returning: $0) }
            }
        }
        XCTAssertTrue(ok)
        let rows = await rig.rows(count: 2)
        XCTAssertEqual(rows.map(\.kind), [.epicCreated, .epicItemAdded])
        XCTAssertEqual(rows[1].actorType, .human)
        XCTAssertEqual(rows[1].item, item.key)
        XCTAssertEqual(rows[1].parentItem, rig.epic.eventKey)
        await until("the mark ends") { await MainActor.run { rig.d.projectStore.writeActors.isEmpty } }
        let snap = await rig.snapshot()
        XCTAssertEqual(snap?.epicId(of: item.id), rig.epic.id)
    }

    func testSetEpicShowsAtOnceAndTheReadWritesOneRow() async throws {
        let rig = try await EpicRig()
        let item = rig.items[0]
        let agent = EventActor(type: .agent, name: "codex")
        _ = await rig.rows(count: 1)
        rig.fake.freezeList()
        let ok: Bool = await withCheckedContinuation { c in
            DispatchQueue.main.async { rig.d.projectStore.setEpic(rig.epic.id, itemId: item.id, by: agent) { c.resume(returning: $0) } }
        }
        XCTAssertTrue(ok)
        await until("the view shows the epic") { await rig.snapshot()?.epicId(of: item.id) == rig.epic.id }
        rig.fake.thawList()
        await rig.reload()
        let rows = await rig.rows(count: 2)
        XCTAssertEqual(rows.map(\.kind), [.epicCreated, .epicItemAdded])
        XCTAssertEqual(rows[1].actorType, .agent)
        XCTAssertEqual(rows[1].actor, "codex")
        await until("the mark ends") { await MainActor.run { rig.d.projectStore.writeActors.isEmpty } }
    }

    func testAFailedSetEpicClearsTheMark() async throws {
        let rig = try await EpicRig()
        let ok: Bool = await withCheckedContinuation { c in
            DispatchQueue.main.async { rig.d.projectStore.setEpic("nope", itemId: rig.items[0].id) { c.resume(returning: $0) } }
        }
        XCTAssertFalse(ok)
        await until("the mark ends") { await MainActor.run { rig.d.projectStore.writeActors.isEmpty } }
    }

    func testCreateAndUpdateEpic() async throws {
        let rig = try await EpicRig()
        let made: Result<Epic, ProviderError> = await withCheckedContinuation { c in
            DispatchQueue.main.async {
                rig.d.projectStore.createEpic(EpicDraft(title: "Billing"), projectKey: rig.fake.project.storeKey) { c.resume(returning: $0) }
            }
        }
        let e = try made.get()
        var snap = await rig.snapshot()
        XCTAssertEqual(snap?.epics?.map(\.title), ["Review desk", "Billing"])
        let ok: Bool = await withCheckedContinuation { c in
            DispatchQueue.main.async { rig.d.projectStore.updateEpic(e, EpicPatch(state: .active)) { c.resume(returning: $0) } }
        }
        XCTAssertTrue(ok)
        snap = await rig.snapshot()
        XCTAssertEqual(snap?.epic(e.id)?.state, .active)
        let found = await MainActor.run { rig.d.projectStore.epic("FAKE", e.id)?.epic.title }
        XCTAssertEqual(found, "Billing")
        let all = await MainActor.run { rig.d.projectStore.allEpics.map(\.epic.title) }
        XCTAssertEqual(all, ["Review desk", "Billing"])
    }
}
