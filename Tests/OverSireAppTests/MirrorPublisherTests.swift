import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireApp

/// A home daemon that serves the index and takes puts.
private final class FakeMirrorHome: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    var epoch = "E1"
    var index: [MirrorIndex.Entry] = []
    private var _puts: [MirrorPut] = []
    private var _raw: [Data] = []
    private var _indexReads = 0
    /// The status and the body of the next puts. An empty list means 200.
    var putFailures: [(Int, String)] = []

    var puts: [MirrorPut] { lock.withLock { _puts } }
    var raw: [Data] { lock.withLock { _raw } }
    var indexReads: Int { lock.withLock { _indexReads } }

    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        func reply(_ code: Int, _ data: Data) -> (Data, HTTPURLResponse) {
            (data, HTTPURLResponse(url: r.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        switch (r.httpMethod ?? "GET", r.url!.path) {
        case ("GET", "/v1/mirror/index"):
            return lock.withLock {
                _indexReads += 1
                return reply(200, try! enc.encode(MirrorIndex(epoch: epoch, head: 0, docs: index)))
            }
        case ("PUT", "/v1/mirror/docs"):
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let put = try dec.decode(MirrorPut.self, from: r.httpBody ?? Data())
            return lock.withLock {
                if !putFailures.isEmpty {
                    let f = putFailures.removeFirst()
                    return reply(f.0, Data(f.1.utf8))
                }
                guard put.epoch == epoch else { return reply(409, Data(#"{"error":"The mirror changed. Send all again.","epoch":"\#(epoch)"}"#.utf8)) }
                _puts.append(put)
                _raw.append(r.httpBody ?? Data())
                let head = MirrorHead(epoch: epoch, head: Int64(_puts.count), floor: 0, ready: put.ready == true)
                return reply(200, try! enc.encode(MirrorPutResult(head: head, applied: put.docs.count, same: 0)))
            }
        default:
            return reply(404, Data(#"{"error":"not found"}"#.utf8))
        }
    }
}

private struct Body: Codable, Equatable {
    var n: Int
    var name = ""
}

/// Docs that the test sets.
@MainActor
private final class FakeDocs: MirrorDocSource {
    var projects: [MirrorDoc] = []
    var runs: [MirrorDoc] = []
    var prs: [MirrorDoc] = []
    var activity: [MirrorDoc] = []
    var catalog = MirrorDoc.make(.catalog, id: "home", Body(n: 0))!
    var settings = MirrorDoc.make(.settings, id: "home", Body(n: 0))!

    func projectDocs(_ keys: [String]?) -> [MirrorDoc] {
        projects.filter { d in
            guard let keys else { return true }
            return keys.contains { d.id == $0 || d.id.hasPrefix($0 + "/") }
        }
    }
    func runDocs(_ repos: [String]?) -> [MirrorDoc] { runs.filter { repos?.contains($0.id) ?? true } }
    func prDocs(_ repos: [String]?) -> [MirrorDoc] { prs.filter { repos?.contains($0.id) ?? true } }
    func activityDocs(since: Date?) -> [MirrorDoc] { activity }
    func catalogDoc() -> MirrorDoc { catalog }
    func settingsDoc() -> MirrorDoc { settings }
}

@MainActor
final class MirrorPublisherTests: XCTestCase {
    private func client(_ h: FakeMirrorHome, _ host: String = "mbp.test") -> DaemonClient {
        DaemonClient(base: URL(string: "http://\(host):7690")!, token: nil, http: h)
    }

    private func doc(_ kind: MirrorKind, _ id: String, _ n: Int = 0) -> MirrorDoc { MirrorDoc.make(kind, id: id, Body(n: n))! }

    private func publisher(_ docs: FakeDocs, bus: ChangeBus = ChangeBus(delay: 0, schedule: { _, f in f() }),
                           home: @escaping () async -> DaemonClient?, rehome: @escaping () async -> Void = {}) -> MirrorPublisher {
        MirrorPublisher(home: home, rehome: rehome, docs: docs, bus: bus, appVersion: "1.0", source: "app-1", sourceName: "mbp",
                        clock: { Date(timeIntervalSince1970: 1_000_000) }, debounce: 3600)
    }

    private func started(_ docs: FakeDocs, _ h: FakeMirrorHome, bus: ChangeBus = ChangeBus(delay: 0, schedule: { _, f in f() })) async throws -> MirrorPublisher {
        let c = client(h)
        let p = publisher(docs, bus: bus, home: { c })
        p.start()
        try await p.flush()
        return p
    }

    func testFirstSyncSendsAllThenReady() async throws {
        let docs = FakeDocs()
        docs.projects = [doc(.project, "ocral/p1"), doc(.item, "ocral/p1/i1"), doc(.item, "ocral/p1/i2")]
        docs.runs = [doc(.runs, "o/r")]
        let h = FakeMirrorHome()
        _ = try await started(docs, h)
        XCTAssertEqual(h.puts.count, 1)
        XCTAssertEqual(h.puts[0].docs.count, 6, "4 docs, the catalog and the settings")
        XCTAssertEqual(h.puts[0].ready, true)
        XCTAssertEqual(h.puts[0].epoch, "E1")
        XCTAssertEqual(h.puts[0].source, "app-1")
        XCTAssertTrue(h.puts[0].docs.allSatisfy { $0.hash.isEmpty && $0.seq == 0 && $0.v == 1 })
    }

    func testUnchangedDocSendsNothing() async throws {
        let docs = FakeDocs()
        docs.runs = [doc(.runs, "o/r", 1)]
        let h = FakeMirrorHome()
        let p = try await started(docs, h)
        let before = h.puts.count
        p.touched(.runs, ids: nil)
        docs.runs = [doc(.runs, "o/r", 1)]
        try await p.flush()
        XCTAssertEqual(h.puts.count, before)
        docs.runs = [doc(.runs, "o/r", 2)]
        p.touched(.runs, ids: ["o/r"])
        try await p.flush()
        XCTAssertEqual(h.puts.count, before + 1)
        XCTAssertNil(h.puts.last?.ready, "only the first full send sets ready")
    }

    func testRemovedItemSendsTombstone() async throws {
        let docs = FakeDocs()
        docs.projects = [doc(.project, "ocral/p1"), doc(.item, "ocral/p1/i1"), doc(.item, "ocral/p1/i2"), doc(.project, "ocral/p2"), doc(.item, "ocral/p2/i9")]
        let h = FakeMirrorHome()
        let p = try await started(docs, h)
        docs.projects.removeAll { $0.id == "ocral/p1/i2" }
        p.touched(.project, ids: ["ocral/p1"])
        try await p.flush()
        let last = try XCTUnwrap(h.puts.last)
        XCTAssertEqual(last.docs.map(\.id), ["ocral/p1/i2"])
        XCTAssertEqual(last.docs.first?.deleted, true)
        XCTAssertNil(last.docs.first?.body)
        // A project that leaves takes its items.
        docs.projects.removeAll { $0.id.hasPrefix("ocral/p2") }
        p.touched(.project, ids: ["ocral/p2"])
        try await p.flush()
        XCTAssertEqual(Set(h.puts.last?.docs.map(\.id) ?? []), ["ocral/p2", "ocral/p2/i9"])
    }

    func testDiffAgainstIndex() async throws {
        let docs = FakeDocs()
        let a = doc(.runs, "o/a", 1), b = doc(.runs, "o/b", 1), c = doc(.runs, "o/c", 1)
        docs.runs = [a, b, c]
        let h = FakeMirrorHome()
        h.index = [a, b, docs.catalog, docs.settings].map { MirrorIndex.Entry(kind: $0.kind, id: $0.id, hash: $0.hash) }
        h.index.append(MirrorIndex.Entry(kind: .runs, id: "o/c", hash: "old"))
        _ = try await started(docs, h)
        XCTAssertEqual(h.puts.count, 1)
        XCTAssertEqual(h.puts[0].docs.map(\.id), ["o/c"])
        XCTAssertEqual(h.puts[0].ready, true)
    }

    func testIndexEntryWithNoDocGivesTombstone() async throws {
        let docs = FakeDocs()
        let h = FakeMirrorHome()
        h.index = [MirrorIndex.Entry(kind: .runs, id: "o/gone", hash: "x")]
        _ = try await started(docs, h)
        XCTAssertEqual(h.puts[0].docs.filter { $0.deleted == true }.map(\.id), ["o/gone"])
    }

    func testFullSyncWithNothingToSendStillSetsReady() async throws {
        let docs = FakeDocs()
        let h = FakeMirrorHome()
        h.index = [MirrorIndex.Entry(kind: .catalog, id: "home", hash: docs.catalog.hash),
                   MirrorIndex.Entry(kind: .settings, id: "home", hash: docs.settings.hash)]
        _ = try await started(docs, h)
        XCTAssertEqual(h.puts.count, 1)
        XCTAssertTrue(h.puts[0].docs.isEmpty)
        XCTAssertEqual(h.puts[0].ready, true)
    }

    func testBatchesAt500Docs() async throws {
        let docs = FakeDocs()
        docs.projects = (0..<1199).map { doc(.item, "ocral/p1/i\($0)", $0) }
        let h = FakeMirrorHome()
        _ = try await started(docs, h)
        XCTAssertEqual(h.puts.map(\.docs.count), [500, 500, 201], "1,199 items, the catalog and the settings")
        XCTAssertEqual(h.puts.map(\.ready), [nil, nil, true])
    }

    func testEpochConflictResends() async throws {
        let docs = FakeDocs()
        docs.runs = [doc(.runs, "o/a")]
        let h = FakeMirrorHome()
        let p = try await started(docs, h)
        XCTAssertEqual(h.indexReads, 1)
        // The daemon starts a new epoch with no docs.
        h.epoch = "E2"
        docs.runs = [doc(.runs, "o/a", 5)]
        p.touched(.runs, ids: nil)
        try await p.flush()
        XCTAssertEqual(h.indexReads, 2, "the 409 makes a new index read")
        let last = try XCTUnwrap(h.puts.last)
        XCTAssertEqual(last.epoch, "E2")
        XCTAssertEqual(Set(last.docs.map(\.id)), ["o/a", "home"], "a full diff, not only the touched doc")
        XCTAssertEqual(last.ready, true)
    }

    func testNotHomeRereadsTheGroup() async throws {
        let docs = FakeDocs()
        docs.runs = [doc(.runs, "o/a")]
        let mbp = FakeMirrorHome(), box = FakeMirrorHome()
        mbp.putFailures = [(409, #"{"error":"mbp is not home","home":"box"}"#)]
        var current = client(mbp, "mbp.test")
        var rehomed = 0
        let boxClient = client(box, "box.test")
        let p = publisher(docs, home: { current }, rehome: { rehomed += 1; current = boxClient })
        p.start()
        try await p.flush()
        XCTAssertEqual(rehomed, 1)
        XCTAssertTrue(mbp.puts.isEmpty)
        XCTAssertEqual(box.indexReads, 1, "the new home gets its own full diff")
        XCTAssertEqual(box.puts.count, 1)
        XCTAssertEqual(box.puts[0].ready, true)
        XCTAssertEqual(Set(box.puts[0].docs.map(\.id)), ["o/a", "home"])
    }

    func testStopsWhenLeaseLost() async throws {
        let docs = FakeDocs()
        let h = FakeMirrorHome()
        let p = try await started(docs, h)
        let before = h.puts.count
        p.stop()
        docs.runs = [doc(.runs, "o/a")]
        p.touched(.runs, ids: nil)
        try await p.flush()
        XCTAssertEqual(h.puts.count, before)
        XCTAssertFalse(p.isRunning)
    }

    func testNoHomeThrowsAndKeepsThePending() async throws {
        let docs = FakeDocs()
        let h = FakeMirrorHome()
        var offline = false
        let c = client(h)
        let p = publisher(docs, home: { offline ? nil : c })
        p.start()
        try await p.flush()
        docs.runs = [doc(.runs, "o/a")]
        p.touched(.runs, ids: nil)
        offline = true
        do { try await p.flush(); XCTFail("no home") } catch {}
        offline = false
        try await p.flush()
        XCTAssertEqual(h.puts.last?.docs.map(\.id), ["o/a"])
    }

    func testBusChangeTouchesTheProject() async throws {
        let docs = FakeDocs()
        docs.projects = [doc(.project, "ocral/p1"), doc(.project, "ocral/p2")]
        let bus = ChangeBus(delay: 0, schedule: { _, f in f() })
        let h = FakeMirrorHome()
        let p = try await started(docs, h, bus: bus)
        let before = h.puts.count
        docs.projects = [doc(.project, "ocral/p1", 1), doc(.project, "ocral/p2", 1)]
        bus.post(DataChange(.projects, projects: ["ocral/p1"]))
        try await p.flush()
        XCTAssertEqual(h.puts.count, before + 1)
        XCTAssertEqual(h.puts.last?.docs.map(\.id), ["ocral/p1"])
    }

    func testBusChangeOfRunsTouchesTheRepos() async throws {
        let docs = FakeDocs()
        docs.runs = [doc(.runs, "o/a"), doc(.runs, "o/b")]
        docs.prs = [doc(.prs, "o/a")]
        let bus = ChangeBus(delay: 0, schedule: { _, f in f() })
        let h = FakeMirrorHome()
        let p = try await started(docs, h, bus: bus)
        docs.runs = [doc(.runs, "o/a", 1), doc(.runs, "o/b", 1)]
        docs.prs = [doc(.prs, "o/a", 1)]
        bus.post(DataChange(.runs, repos: ["o/b"]))
        try await p.flush()
        XCTAssertEqual(h.puts.last?.docs.map(\.id), ["o/b"])
        bus.post(DataChange(.prs))
        try await p.flush()
        XCTAssertEqual(h.puts.last?.docs.map(\.id), ["o/a"])
        XCTAssertEqual(h.puts.last?.docs.first?.kind, .prs)
    }

    func testPutBodyBytesAreTheHashedBytes() async throws {
        let docs = FakeDocs()
        let d = MirrorDoc.make(.runs, id: "o/a", ["z": 1, "b": 2, "m/n": 3])!
        docs.runs = [d]
        let h = FakeMirrorHome()
        _ = try await started(docs, h)
        let bytes = MirrorCodec.bytes(try XCTUnwrap(d.body))
        XCTAssertNotNil(h.raw[0].range(of: bytes), "the daemon hashes these bytes")
        XCTAssertEqual(d.hash, MirrorHash.hex(bytes))
    }

    func testOversizeDocIsSkipped() async throws {
        let docs = FakeDocs()
        docs.runs = [MirrorDoc.make(.runs, id: "o/big", Body(n: 1, name: String(repeating: "x", count: MirrorPublisher.maxDocBytes + 1)))!, doc(.runs, "o/a")]
        let h = FakeMirrorHome()
        _ = try await started(docs, h)
        XCTAssertEqual(Set(h.puts[0].docs.map(\.id)), ["o/a", "home"])
    }

    // MARK: The docs of the app

    private final class Trackers: TrackerDirectory {
        let t: any Tracker
        init(_ t: any Tracker) { self.t = t }
        var trackerIds: [String] { [t.account.id] }
        func tracker(_ id: String) -> (any Tracker)? { id == t.account.id ? t : nil }
    }

    private func item(_ id: String, key: String) -> Item {
        Item(id: id, key: key, title: "Title of \(key)", url: "https://x/\(key)", statusOptionId: nil, fields: [:], assignees: [], labels: ["a"],
             author: nil, updatedBy: nil, updatedAt: Date(timeIntervalSince1970: 1_000_000.123), activityAt: Date(timeIntervalSince1970: 1_000_000),
             commentCount: 0, lastComment: nil, mentionsMe: false)
    }

    private func appDocs(caps: Set<Capability> = [.links, .priority], catalog: ProjectCatalog? = nil) throws -> (AppMirrorDocs, ProjectStore, ProjectSummary) {
        let t = FakeTracker(account: "ws", capabilities: caps)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProjectStore(trackers: Trackers(t), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                 statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        let summary = ProjectSummary(ref: t.project, identifier: "FAKE", title: "Fake", url: "https://x/FAKE", closed: false)
        store.track([summary], live: [])
        let docs = AppMirrorDocs(store: store, runs: { [("o/r", [])] }, prs: { [] }, projects: { [summary] },
                                 layers: { $0 == .tracker ? caps : $0 == .ci ? [.rerun] : [] }, trackers: { ["ws"] },
                                 workspaces: { catalog?.mirrorWorkspaces() ?? [] })
        return (docs, store, summary)
    }

    func testProjectDocHasNoItems() throws {
        let (docs, store, summary) = try appDocs()
        store.absorb(ProjectSnapshot(summary: summary, statusOptions: [], items: [item("u1", key: "FAKE-1"), item("u2", key: "FAKE-2")], fetchedAt: Date()))
        let out = docs.projectDocs(nil)
        let project = try XCTUnwrap(out.first { $0.kind == .project })
        XCTAssertEqual(project.id, summary.ref.storeKey)
        XCTAssertEqual(project.body?["items"], .array([]))
        XCTAssertEqual(project.v, 1)
        let items = out.filter { $0.kind == .item }
        XCTAssertEqual(Set(items.map(\.id)), ["\(summary.ref.storeKey)/u1", "\(summary.ref.storeKey)/u2"])
        // The reader gets the same types back.
        let back: Item = try MirrorCodec.value(from: try XCTUnwrap(items.first { $0.id.hasSuffix("/u1") }?.body))
        XCTAssertEqual(back.key, "FAKE-1")
        XCTAssertEqual(back.updatedAt.timeIntervalSince1970, 1_000_000.123, accuracy: 0.001)
        let snap: ProjectSnapshot = try MirrorCodec.value(from: try XCTUnwrap(project.body))
        XCTAssertEqual(snap.summary.identifier, "FAKE")
        XCTAssertEqual(MirrorCodec.projectKey(ofItemDoc: items[0].id), summary.ref.storeKey)
    }

    func testItemDocIsKeptWhenTheItemDoesNotChange() throws {
        let (docs, store, summary) = try appDocs()
        store.absorb(ProjectSnapshot(summary: summary, statusOptions: [], items: [item("u1", key: "FAKE-1")], fetchedAt: Date()))
        let a = docs.projectDocs(nil).first { $0.kind == .item }
        let b = docs.projectDocs([summary.ref.storeKey]).first { $0.kind == .item }
        XCTAssertEqual(a?.hash, b?.hash)
        XCTAssertEqual(docs.projectDocs(["other/p"]).count, 0)
    }

    func testRunAndPRDocsHaveAnObjectBody() throws {
        let (docs, _, _) = try appDocs()
        let r = docs.runDocs(nil)
        XCTAssertEqual(r.map(\.id), ["o/r"])
        XCTAssertEqual(r.first?.body?["runs"], .array([]))
        XCTAssertEqual(docs.runDocs(["x/y"]).count, 0)
    }

    func testActivityDocsCarryNoLocalReadState() throws {
        let (docs, store, summary) = try appDocs()
        let before = ProjectSnapshot(summary: summary, statusOptions: [], items: [item("u1", key: "FAKE-1")], fetchedAt: Date() - 60)
        store.absorb(before)
        store.absorb(ProjectSnapshot(summary: summary, statusOptions: [], items: [item("u1", key: "FAKE-1"), item("u2", key: "FAKE-2")], fetchedAt: Date()))
        let out = docs.activityDocs(since: Date() - 86400)
        XCTAssertFalse(out.isEmpty)
        for d in out {
            XCTAssertEqual(d.kind, .activity)
            let e: ActivityEntry = try MirrorCodec.value(from: try XCTUnwrap(d.body))
            XCTAssertEqual(e.id, d.id)
            XCTAssertTrue(e.unread)
        }
        XCTAssertTrue(docs.activityDocs(since: Date() + 60).isEmpty, "an entry older than since stays out")
    }

    /// A fake tracker with an intake page, like Plane.
    private final class PagedTracker: IntakePage {
        let t: FakeTracker
        init(_ t: FakeTracker) { self.t = t }
        var id: ProviderID { t.id }
        var account: AccountID { t.account }
        var capabilities: Set<Capability> { t.capabilities }
        var pollPolicy: PollPolicy { t.pollPolicy }
        var keyFormat: KeyFormat { t.keyFormat }
        func probe() async throws -> Identity { try await t.probe() }
        func poll(since: Cursor?) async throws -> EventPage { try await t.poll(since: since) }
        func projects() async throws -> [ProjectSummary] { try await t.projects() }
        func statuses(_ p: ProjectRef) async throws -> [StatusOption] { try await t.statuses(p) }
        func items(_ p: ProjectRef, since: Date?, limit: Int) async throws -> [Item] { try await t.items(p, since: since, limit: limit) }
        func detail(_ i: ItemRef) async throws -> ItemDetail { try await t.detail(i) }
        func comments(_ i: ItemRef) async throws -> [Comment] { try await t.comments(i) }
        func create(_ d: ItemDraft, in p: ProjectRef) async throws -> ItemRef { try await t.create(d, in: p) }
        func update(_ i: ItemRef, _ patch: ItemPatch) async throws { try await t.update(i, patch) }
        func comment(_ i: ItemRef, markdown: String) async throws { try await t.comment(i, markdown: markdown) }
        func intakeURL(_ p: ProjectRef) -> String { "https://plane.test/\(p.id)/intake" }
    }

    func testCatalogDocHasIntakeURL() throws {
        let t = PagedTracker(FakeTracker(account: "ws"))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-docs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = ProjectStore(trackers: Trackers(t), notifier: ProjectNotifier(post: { _, _, _, _ in }),
                                 statePath: dir.path + "/state.json", activityPath: dir.path + "/activity.jsonl")
        let summary = ProjectSummary(ref: t.t.project, identifier: "FAKE", title: "Fake", url: "https://x/FAKE", closed: false)
        store.track([summary], live: [])
        let docs = AppMirrorDocs(store: store, runs: { [] }, prs: { [] }, projects: { [summary] },
                                 layers: { _ in [] }, trackers: { ["ws"] }, workspaces: { [] })
        let c: ClientCatalog = try MirrorCodec.value(from: try XCTUnwrap(docs.catalogDoc().body))
        XCTAssertEqual(c.projects.first?.intakeURL, "https://plane.test/\(summary.ref.id)/intake")
        let (plain, _, _) = try appDocs()
        let p: ClientCatalog = try MirrorCodec.value(from: try XCTUnwrap(plain.catalogDoc().body))
        XCTAssertNil(p.projects.first?.intakeURL, "a tracker with no intake page has none")
    }

    func testCatalogDocHasCapabilities() throws {
        let (docs, _, summary) = try appDocs(caps: [.links, .priority])
        let d = docs.catalogDoc()
        XCTAssertEqual(d.kind, .catalog)
        XCTAssertEqual(d.id, "home")
        let c: ClientCatalog = try MirrorCodec.value(from: try XCTUnwrap(d.body))
        XCTAssertEqual(c.projects.map(\.summary.ref.storeKey), [summary.ref.storeKey])
        XCTAssertEqual(c.projects.first?.capabilities, [.links, .priority], "the capabilities of its tracker, sorted")
        XCTAssertEqual(c.capabilities["tracker"], [.links, .priority])
        XCTAssertEqual(c.capabilities["ci"], [.rerun])
        XCTAssertEqual(c.capabilities["codeHost"], [])
        XCTAssertEqual(c.trackers, ["ws"])
    }

    // OVERSIRE-534
    func testCatalogDocHasWorkspaceProjects() throws {
        let ref = ProjectRef(account: AccountID(provider: "plane", id: "w1"), id: "p1", key: "ONE")
        let open = ProjectSummary(ref: ref, identifier: "ONE", title: "One", url: "", closed: false)
        let closed = ProjectSummary(ref: ProjectRef(account: ref.account, id: "p2", key: "TWO"), identifier: "TWO", title: "Two", url: "", closed: true)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("plane-cache-\(UUID().uuidString).json").path
        let fetched = Date(timeIntervalSince1970: 1_000_000)
        ProjectCatalogCache(workspaces: [.init(slug: "w1", projects: [open, closed], fetchedAt: fetched)]).write(atPath: path)
        let catalog = ProjectCatalog(trackers: Trackers(FakeTracker(account: "w1")), path: path)
        let (docs, _, _) = try appDocs(catalog: catalog)
        let c: ClientCatalog = try MirrorCodec.value(from: try XCTUnwrap(docs.catalogDoc().body))
        XCTAssertEqual(c.workspaces?.map(\.id), ["w1"])
        XCTAssertEqual(c.workspaces?.first?.projects.map(\.identifier), ["ONE"], "only the open projects")
        XCTAssertEqual(c.workspaces?.first?.fetchedAt?.timeIntervalSince1970 ?? 0, 1_000_000, accuracy: 1)
        XCTAssertNil(c.workspaces?.first?.error)
    }

    func testTouchedSettingsSendsOnlyTheSettingsDoc() async throws {
        let docs = FakeDocs()
        let h = FakeMirrorHome()
        let p = try await started(docs, h)
        let before = h.puts.count
        p.touched(.settings, ids: nil)
        try await p.flush()
        XCTAssertEqual(h.puts.count, before, "the same body sends nothing")
        docs.settings = doc(.settings, "home", 1)
        p.touched(.settings, ids: nil)
        try await p.flush()
        XCTAssertEqual(h.puts.count, before + 1)
        XCTAssertEqual(h.puts.last?.docs.map(\.kind), [.settings])
    }

    func testTouchedCatalogChecksTheSettingsDocToo() async throws {
        let docs = FakeDocs()
        let h = FakeMirrorHome()
        let p = try await started(docs, h)
        docs.settings = doc(.settings, "home", 2)
        p.touched(.catalog, ids: nil)
        try await p.flush()
        XCTAssertEqual(h.puts.last?.docs.map(\.kind), [.settings])
    }

    func testSettingsDocHasTheHomeSettings() throws {
        let (docs, _, _) = try appDocs()
        let d = docs.settingsDoc()
        XCTAssertEqual(d.kind, .settings)
        XCTAssertEqual(d.id, "home")
        let h: HomeSettings = try MirrorCodec.value(from: try XCTUnwrap(d.body))
        XCTAssertEqual(h.v, HomeSettings.version)
        XCTAssertEqual(h.hashes.count, SettingsSection.allCases.count)
    }

    func testBodyEncodingIsStable() throws {
        let a = try MirrorCodec.body(["b": 1, "a": 2])
        XCTAssertEqual(String(decoding: MirrorCodec.bytes(a), as: UTF8.self), #"{"a":2,"b":1}"#)
        XCTAssertThrowsError(try MirrorCodec.body([1, 2]), "a body is an object")
    }
}
