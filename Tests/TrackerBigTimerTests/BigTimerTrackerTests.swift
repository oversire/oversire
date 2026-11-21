import XCTest
import OverSireCore
import OverSireTestKit
@testable import TrackerBigTimer

private struct OfflineHTTP: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw URLError(.notConnectedToInternet) }
}

private struct NoCommands: CommandRunner {
    func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput {
        CommandOutput(status: 127, stdout: Data(), stderr: "no \(exe)")
    }
}

private struct Secrets: SecretReader {
    let values: [String: String]
    func secret(_ key: String) -> String? { values[key] }
}

final class BigTimerTrackerTests: XCTestCase {
    static let server = URL(string: "https://bt.example.com")!
    static let account = AccountID(provider: .bigtimer, id: "bt.example.com")

    var fake: BigTimerFakeServer!
    var acme: String!

    override func setUp() {
        fake = BigTimerFakeServer()
        acme = fake.addProject(prefix: "ACME")
    }

    func tracker(_ http: (any HTTPTransport)? = nil, token: String = "good", clock: any Clock<Duration> = ContinuousClock()) -> BigTimerTracker {
        BigTimerTracker(server: Self.server, account: Self.account, token: token, http: http ?? fake, clock: clock)
    }

    var project: ProjectRef { ProjectRef(account: Self.account, id: acme, key: "ACME") }

    func query(_ r: URLRequest) -> [String: String] {
        Dictionary((URLComponents(url: r.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { a, _ in a })
    }

    func ref(_ t: BigTimerTracker, _ id: String) async throws -> ItemRef {
        let item = try await t.items(project, since: nil, limit: 50).first { $0.id == id }
        return try XCTUnwrap(item?.ref(in: project))
    }

    // MARK: Conformance

    func testProviderConformance() async {
        let fake = fake!
        let r = await ProviderConformance.run { s in
            BigTimerTracker(server: Self.server, account: Self.account, token: s == .unauthorized ? "bad" : "good", http: fake)
        }
        XCTAssertTrue(r.passed, r.description)
    }

    func testTrackerConformance() async {
        let fake = fake!
        let r = await TrackerConformance.run {
            BigTimerTracker(server: Self.server, account: Self.account, token: "good", http: fake)
        }
        XCTAssertTrue(r.passed, r.description)
    }

    // MARK: Descriptor

    func testDescriptorPassesTheStreaming() async throws {
        let env = ProviderEnvironment(http: OfflineHTTP(), streaming: fake, commands: NoCommands(),
                                      secrets: Secrets(values: ["BIGTIMER_TOKEN_bt.example.com": "good"]))
        let config = AccountConfig(account: Self.account, values: ["server": "https://bt.example.com"], secretKeys: ["BIGTIMER_TOKEN_bt.example.com"])
        let p = try BigTimerTracker.descriptor.make(config, env)
        XCTAssertTrue(fake.requests.isEmpty, "make does no I/O")
        let feed = try XCTUnwrap(p as? any LiveFeeding)
        let stream = try await feed.liveFeed(lastEventID: nil)
        XCTAssertEqual(fake.paths(), ["/v1/stream"])
        XCTAssertEqual(fake.openStreams, 1)
        withExtendedLifetime(stream) {}
    }

    func testDescriptorMakesNoIO() throws {
        let env = ProviderEnvironment(http: OfflineHTTP(), commands: NoCommands(), secrets: Secrets(values: ["BIGTIMER_TOKEN_bt.example.com": "btk_x"]))
        let config = AccountConfig(account: Self.account, values: ["server": "https://BT.Example.com/"], secretKeys: ["BIGTIMER_TOKEN_bt.example.com"])
        let p = try BigTimerTracker.descriptor.make(config, env)
        XCTAssertEqual(p.account, Self.account)
        XCTAssertEqual(BigTimerTracker.descriptor.layer, .tracker)
        XCTAssertEqual(BigTimerTracker.descriptor.displayName, "Big Timer")
    }

    func testDescriptorIgnoresTheAccountOfTheForm() throws {
        let env = ProviderEnvironment(http: OfflineHTTP(), commands: NoCommands(), secrets: Secrets(values: ["K": "btk_x"]))
        let config = AccountConfig(account: AccountID(provider: .bigtimer, id: "typed"), values: ["server": "http://localhost:8080"], secretKeys: ["K"])
        XCTAssertEqual(try BigTimerTracker.descriptor.make(config, env).account.id, "localhost:8080")
    }

    func testAccountIdIsHost() {
        XCTAssertEqual(BigTimerTracker.account(forServer: "https://BT.Example.com/"), "bt.example.com")
        XCTAssertEqual(BigTimerTracker.account(forServer: "http://localhost:8080"), "localhost:8080")
        XCTAssertNil(BigTimerTracker.account(forServer: "notaurl"))
    }

    func testHttpOnlyForLocalHosts() throws {
        func make(_ url: String) throws -> any Provider {
            let env = ProviderEnvironment(http: OfflineHTTP(), commands: NoCommands(), secrets: Secrets(values: ["K": "btk_x"]))
            return try BigTimerTracker.descriptor.make(AccountConfig(account: Self.account, values: ["server": url], secretKeys: ["K"]), env)
        }
        for ok in ["http://localhost:8080", "http://127.0.0.1:8080", "http://bt.local"] { XCTAssertNoThrow(try make(ok), ok) }
        for bad in ["http://bt.example.com", "", "notaurl", "ftp://bt.example.com"] {
            XCTAssertThrowsError(try make(bad), bad) {
                guard case .vendor(let code, _)? = $0 as? ProviderError else { return XCTFail("\($0)") }
                XCTAssertEqual(code, "bad_server_url")
            }
        }
    }

    func testMissingTokenIsUnauthorized() {
        let env = ProviderEnvironment(http: OfflineHTTP(), commands: NoCommands(), secrets: Secrets(values: ["K": ""]))
        let config = AccountConfig(account: Self.account, values: ["server": "https://bt.example.com"], secretKeys: ["K"])
        XCTAssertThrowsError(try BigTimerTracker.descriptor.make(config, env)) { XCTAssertEqual($0 as? ProviderError, .unauthorized) }
    }

    // MARK: Statuses and errors

    func testStatusMap() async throws {
        let options = try await tracker().statuses(project)
        XCTAssertEqual(options.map(\.id), ["open", "in_progress", "blocked", "client_reviewing", "done", "cancelled"])
        XCTAssertEqual(options.map(\.category), [.todo, .progress, .blocked, .review, .done, .done])
        XCTAssertEqual(options.last?.group, "cancelled")
        XCTAssertTrue(fake.requests.isEmpty, "the statuses need no call")
    }

    func testErrorMap() async {
        let url = "https://bt.example.com/v1/me"
        func error(_ status: Int, headers: [String: String] = [:], _ body: String = "") async -> ProviderError? {
            let http = RecordedHTTP()
            http.on("GET", url, status, headers: headers, body)
            do { _ = try await tracker(http).probe() } catch { return error as? ProviderError }
            return nil
        }
        let e401 = await error(401), e403 = await error(403), e404 = await error(404)
        XCTAssertEqual(e401, .unauthorized)
        XCTAssertEqual(e403, .forbidden)
        XCTAssertEqual(e404, .notFound)
        let e429 = await error(429, headers: ["Retry-After": "30"]), e429b = await error(429)
        XCTAssertEqual(e429, .rateLimited(retryAfter: .seconds(30)))
        XCTAssertEqual(e429b, .rateLimited(retryAfter: nil))
        let e400 = await error(400, #"{"code":"validation","detail":"Bad title."}"#)
        XCTAssertEqual(e400, .vendor(code: "validation", message: "Bad title."))
        let e500 = await error(500)
        guard case .vendor(let code, _)? = e500 else { return XCTFail("\(String(describing: e500))") }
        XCTAssertEqual(code, "500")
        do { _ = try await tracker(OfflineHTTP()).probe(); XCTFail("no throw") } catch {
            guard case .transport? = error as? ProviderError else { return XCTFail("\(error)") }
        }
    }

    func testBadBodyIsDecodingError() async {
        let http = RecordedHTTP()
        http.on("GET", "https://bt.example.com/v1/me", 200, "{}")
        do { _ = try await tracker(http).probe(); XCTFail("no throw") } catch {
            guard case .decoding? = error as? ProviderError else { return XCTFail("\(error)") }
        }
    }

    func testAuthLatch() async throws {
        let clock = ManualClock()
        let t = tracker(token: "bad", clock: clock)
        do { _ = try await t.probe(); XCTFail("no throw") } catch { XCTAssertEqual(error as? ProviderError, .unauthorized) }
        XCTAssertEqual(fake.requests.count, 1)
        do { _ = try await t.projects(); XCTFail("no throw") } catch { XCTAssertEqual(error as? ProviderError, .unauthorized) }
        XCTAssertEqual(fake.requests.count, 1, "the latch sends no request")
        clock.advance(by: .seconds(901))
        do { _ = try await t.projects(); XCTFail("no throw") } catch { XCTAssertEqual(error as? ProviderError, .unauthorized) }
        XCTAssertEqual(fake.requests.count, 2, "the latch ends after 15 minutes")
    }

    func testRequestHeaders() async throws {
        _ = try await tracker().probe()
        let r = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer good")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testProbeNeedsWrite() async throws {
        fake.scopes = ["read"]
        do { _ = try await tracker().probe(); XCTFail("no throw") } catch { XCTAssertEqual(error as? ProviderError, .forbidden) }
        fake.scopes = ["admin"]
        let me = try await tracker().probe()
        XCTAssertEqual(me.person.name, "Ada Lovelace")
        XCTAssertEqual(me.scopes, ["admin"])
    }

    // MARK: Projects and items

    func testProjectsFollowCursor() async throws {
        _ = fake.addProject(prefix: "BETA")
        _ = fake.addProject(prefix: "GAMMA")
        fake.pageSize = 2
        let list = try await tracker().projects()
        XCTAssertEqual(list.map(\.identifier), ["ACME", "BETA", "GAMMA"])
        XCTAssertEqual(list.map(\.url), ["bigtimer://issues?project=ACME", "bigtimer://issues?project=BETA", "bigtimer://issues?project=GAMMA"])
        XCTAssertEqual(fake.paths().filter { $0 == "/v1/projects" }.count, 2)
    }

    func testItemsOpenOverLimit() async throws {
        for n in 1...5 { fake.addIssue(project: acme, title: "Open \(n)") }
        for n in 1...5 { fake.addIssue(project: acme, title: "Done \(n)", status: "done") }
        let items = try await tracker().items(project, since: nil, limit: 2)
        XCTAssertEqual(items.filter { $0.statusOptionId == "open" }.count, 5)
        XCTAssertEqual(items.filter { $0.statusOptionId == "done" }.count, 2)
        XCTAssertEqual(items.map(\.activityAt), items.map(\.activityAt).sorted(by: >))
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }

    func testItemsSinceSendsUpdatedSince() async throws {
        fake.addIssue(project: acme, title: "One")
        _ = try await tracker().items(project, since: Date(timeIntervalSince1970: 1_790_000_000), limit: 5)
        XCTAssertEqual(fake.requests.map { query($0)["updated_since"] }.compactMap { $0 }, ["2026-09-21T14:13:20Z", "2026-09-21T14:13:20Z"])
    }

    func testItemFields() async throws {
        let ada = fake.meUUID
        let full = fake.addIssue(project: acme, title: "Full", assignee: ada, size: "M", due: "2026-12-01", start: "2026-11-20")
        let bare = fake.addIssue(project: acme, title: "Bare")
        let items = try await tracker().items(project, since: nil, limit: 10)
        let a = try XCTUnwrap(items.first { $0.id == full })
        XCTAssertEqual(a.fields, [Item.estimateField: "M", Item.dueField: "2026-12-01", Item.startField: "2026-11-20"])
        XCTAssertEqual([a.estimate, a.dueDate, a.startDate], ["M", "2026-12-01", "2026-11-20"])
        XCTAssertEqual(a.createdAt, fake.issue(full)?.createdAt)
        XCTAssertNotNil(a.createdAt)
        XCTAssertEqual(a.assignees, ["Ada Lovelace"])
        XCTAssertEqual(a.author, "Ada Lovelace")
        XCTAssertEqual(try XCTUnwrap(items.first { $0.id == bare }).fields, [:])
        XCTAssertNil(a.fields["Priority"])
    }

    func testItemURL() async throws {
        let id = fake.addIssue(project: acme, title: "Link")
        let items = try await tracker().items(project, since: nil, limit: 10)
        let item = try XCTUnwrap(items.first { $0.id == id })
        XCTAssertEqual(item.url, "bigtimer://issue/ACME-1")
        XCTAssertNotNil(item.ref(in: project))
    }

    func testCommentsAndActivity() async throws {
        let id = fake.addIssue(project: acme, title: "Talk")
        fake.addComment(issue: id, body: "First")
        fake.addComment(issue: id, body: "Second")
        let t = tracker()
        let items = try await t.items(project, since: nil, limit: 10)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.commentCount, 2)
        XCTAssertGreaterThan(item.activityAt, item.updatedAt)
        let d = try await t.detail(try XCTUnwrap(item.ref(in: project)))
        XCTAssertEqual(d.comments.compactMap(\.body), ["First", "Second"])
        XCTAssertEqual(d.comments.first?.author, "Ada Lovelace")
        XCTAssertEqual(d.comments.first?.url, "bigtimer://issue/ACME-1")
    }

    // MARK: Writes

    func testUpdateMapsPatch() async throws {
        let id = fake.addIssue(project: acme, title: "Old")
        let who = fake.addMember(name: "Grace Hopper")
        let t = tracker()
        let r = try await ref(t, id)
        let before = fake.requests.count

        try await t.update(r, ItemPatch(title: "New", status: "done", bodyMarkdown: "Body"))
        let patches = fake.requests.dropFirst(before).filter { $0.httpMethod == "PATCH" }
        XCTAssertEqual(patches.count, 1)
        XCTAssertEqual(Set(fake.body(patches[0]).keys), ["title", "details", "status"])
        XCTAssertEqual(fake.issue(id)?.status, "done")

        try await t.update(r, ItemPatch(assignees: [who]))
        XCTAssertEqual(fake.body(try XCTUnwrap(fake.requests.last))["member"] as? String, who)
        try await t.update(r, ItemPatch(assignees: []))
        XCTAssertTrue(fake.body(try XCTUnwrap(fake.requests.last))["member"] is NSNull)
        XCTAssertNil(fake.issue(id)?.assignee)

        let mark = fake.requests.count
        try await t.update(r, ItemPatch(title: "Both", assignees: [who]))
        XCTAssertEqual(fake.requests.dropFirst(mark).map { "\($0.httpMethod!) \($0.url!.lastPathComponent)" }, ["PATCH \(id)", "POST assign"])

        try await t.update(r, ItemPatch(startDate: "2026-11-02", dueDate: "2026-11-30", estimate: "xl"))
        var patch = try XCTUnwrap(fake.requests.last { $0.httpMethod == "PATCH" })
        XCTAssertEqual(fake.body(patch) as NSDictionary, ["start_date": "2026-11-02", "due_date": "2026-11-30", "size": "XL"] as NSDictionary)
        try await t.update(r, ItemPatch(startDate: "", dueDate: "", estimate: ""))
        patch = try XCTUnwrap(fake.requests.last { $0.httpMethod == "PATCH" })
        XCTAssertEqual(fake.body(patch) as NSDictionary, ["start_date": NSNull(), "due_date": NSNull(), "size": NSNull()] as NSDictionary)
        XCTAssertNil(fake.issue(id)?.due)
        XCTAssertNil(fake.issue(id)?.size)

        let quiet = fake.requests.count
        try await t.update(r, ItemPatch())
        XCTAssertEqual(fake.requests.count, quiet, "an empty patch sends nothing")
        for (patch, cap) in [(ItemPatch(priority: "high"), Capability.priority), (ItemPatch(labels: ["x"]), .labels)] {
            do { try await t.update(r, patch); XCTFail("no throw") } catch { XCTAssertEqual(error as? ProviderError, .unsupported(cap)) }
        }
        XCTAssertEqual(fake.requests.count, quiet, "a refused patch sends nothing")
    }

    func testUpdateRefusesBadSize() async throws {
        let id = fake.addIssue(project: acme, title: "Old")
        let t = tracker()
        let r = try await ref(t, id)
        let quiet = fake.requests.count
        do { try await t.update(r, ItemPatch(estimate: "huge")); XCTFail("no throw") } catch {
            XCTAssertEqual(error as? ProviderError, .vendor(code: "validation", message: "Big Timer sizes: S, M, L, XL."))
        }
        do { _ = try await t.create(ItemDraft(title: "x", estimate: "3"), in: project); XCTFail("no throw") } catch {
            XCTAssertEqual(error as? ProviderError, .vendor(code: "validation", message: "Big Timer sizes: S, M, L, XL."))
        }
        XCTAssertEqual(fake.requests.count, quiet, "a bad size sends nothing")
    }

    func testCreateSendsDates() async throws {
        let t = tracker()
        XCTAssertTrue([Capability.dates, .estimate, .timeline].allSatisfy(t.capabilities.contains))
        let made = try await t.create(ItemDraft(title: "Dated", startDate: "2026-11-02", dueDate: "2026-11-30", estimate: "l"), in: project)
        let post = try XCTUnwrap(fake.requests.last { $0.httpMethod == "POST" })
        XCTAssertEqual(fake.body(post)["start_date"] as? String, "2026-11-02")
        XCTAssertEqual(fake.body(post)["due_date"] as? String, "2026-11-30")
        XCTAssertEqual(fake.body(post)["size"] as? String, "L")
        XCTAssertEqual(fake.issue(made.id)?.due, "2026-11-30")
        _ = try await t.create(ItemDraft(title: "Plain"), in: project)
        let plain = fake.body(try XCTUnwrap(fake.requests.last { $0.httpMethod == "POST" }))
        XCTAssertNil(plain["start_date"])
        XCTAssertNil(plain["size"])
    }

    func testCreateRefusesPriority() async throws {
        let t = tracker()
        do { _ = try await t.create(ItemDraft(title: "x", priority: "high"), in: project); XCTFail("no throw") } catch {
            XCTAssertEqual(error as? ProviderError, .unsupported(.priority))
        }
        do { _ = try await t.create(ItemDraft(title: "x", labels: ["a"]), in: project); XCTFail("no throw") } catch {
            XCTAssertEqual(error as? ProviderError, .unsupported(.labels))
        }
        XCTAssertTrue(fake.requests.isEmpty)
        let made = try await t.create(ItemDraft(title: "Made", bodyMarkdown: "Body", status: "in_progress"), in: project)
        XCTAssertEqual(made.key, "ACME-1")
        XCTAssertEqual(made.url.absoluteString, "bigtimer://issue/ACME-1")
        XCTAssertEqual(fake.issue(made.id)?.status, "in_progress")
    }

    func testCreateSendsParent() async throws {
        let parent = fake.addIssue(project: acme, title: "Parent")
        let t = tracker()
        XCTAssertTrue(t.capabilities.contains(.subItems))
        let made = try await t.create(ItemDraft(title: "Child", parent: parent), in: project)
        let post = try XCTUnwrap(fake.requests.last { $0.httpMethod == "POST" })
        XCTAssertEqual(fake.body(post)["parent_uuid"] as? String, parent)
        XCTAssertEqual(fake.issue(made.id)?.parent, parent)
        let plain = try await t.create(ItemDraft(title: "Top"), in: project)
        XCTAssertNil(fake.body(try XCTUnwrap(fake.requests.last { $0.httpMethod == "POST" }))["parent_uuid"], "no parent, no key")
        XCTAssertNil(fake.issue(plain.id)?.parent)
    }

    func testUpdateSetsAndClearsParent() async throws {
        let parent = fake.addIssue(project: acme, title: "Parent")
        let id = fake.addIssue(project: acme, title: "Child")
        let t = tracker()
        let r = try await ref(t, id)

        try await t.update(r, ItemPatch(parent: parent))
        var patch = try XCTUnwrap(fake.requests.last { $0.httpMethod == "PATCH" })
        XCTAssertEqual(Array(fake.body(patch).keys), ["parent_uuid"])
        XCTAssertEqual(fake.body(patch)["parent_uuid"] as? String, parent)
        XCTAssertEqual(fake.issue(id)?.parent, parent)

        try await t.update(r, ItemPatch(parent: ""))
        patch = try XCTUnwrap(fake.requests.last { $0.httpMethod == "PATCH" })
        XCTAssertEqual(fake.body(patch)["parent_uuid"] as? String, "", "an empty string clears the parent")
        XCTAssertNil(fake.issue(id)?.parent)

        try await t.update(r, ItemPatch(title: "Renamed"))
        patch = try XCTUnwrap(fake.requests.last { $0.httpMethod == "PATCH" })
        XCTAssertNil(fake.body(patch)["parent_uuid"], "a nil parent is not sent")
    }

    func testItemsMapParentId() async throws {
        let parent = fake.addIssue(project: acme, title: "Parent")
        let child = fake.addIssue(project: acme, title: "Child", parent: parent)
        let t = tracker()
        let items = try await t.items(project, since: nil, limit: 10)
        XCTAssertEqual(items.first { $0.id == child }?.parentId, parent)
        XCTAssertNil(items.first { $0.id == parent }?.parentId)
        let one = try await t.item(try await ref(t, child))
        XCTAssertEqual(one.parentId, parent)
        let found = try await t.search("Child", in: nil, limit: 5)
        XCTAssertEqual(found.first?.parentId, parent)
    }

    func testOldServerHasNoParent() throws {
        let json = #"""
        {"uuid":"u","version":1,"project_uuid":"p","number":1,"key":"ACME-1","title":"T","status":"open",
         "created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}
        """#
        let row = try BigTimerAPI.decode(BTIssue.self, from: Data(json.utf8))
        XCTAssertNil(row.parent_uuid)
    }

    func testParentRuleErrorMessage() async throws {
        let top = fake.addIssue(project: acme, title: "Top")
        let kid = fake.addIssue(project: acme, title: "Kid", parent: top)
        let other = fake.addProject(prefix: "OTH")
        let foreign = fake.addIssue(project: other, title: "Foreign")
        let t = tracker()
        let kidRef = try await ref(t, kid)
        let topRef = try await ref(t, top)

        func message(_ work: () async throws -> Void) async -> String? {
            do { try await work() } catch { return (error as? ProviderError)?.errorDescription }
            return nil
        }
        let deep = await message { _ = try await t.create(ItemDraft(title: "Deep", parent: kid), in: project) }
        XCTAssertEqual(deep, "Big Timer: a sub-item cannot have sub-items.")
        let parentOfKids = await message { try await t.update(topRef, ItemPatch(parent: foreign)) }
        XCTAssertEqual(parentOfKids, "Big Timer: a sub-item must be in the project of its parent.")
        let lonely = fake.addIssue(project: acme, title: "Lonely")
        let hasKids = await message { try await t.update(topRef, ItemPatch(parent: lonely)) }
        XCTAssertEqual(hasKids, "Big Timer: an item with sub-items cannot become a sub-item.")
        let itself = await message { try await t.update(kidRef, ItemPatch(parent: kid)) }
        XCTAssertEqual(itself, "Big Timer: an item cannot be its own parent.")
        let unknown = await message { try await t.update(kidRef, ItemPatch(parent: "nope")) }
        XCTAssertEqual(unknown, "Big Timer: the parent is not valid (does not name a live record).")
        XCTAssertEqual(fake.issue(kid)?.parent, top, "a refused patch keeps the parent")
    }

    func testAssignMeSendsMe() async throws {
        let id = fake.addIssue(project: acme, title: "Mine")
        let t = tracker()
        try await t.assignMe(try await ref(t, id))
        XCTAssertEqual(fake.issue(id)?.assignee, fake.meUUID)
        XCTAssertEqual(fake.body(try XCTUnwrap(fake.requests.last))["member"] as? String, "me")
    }

    func testMemberNamesAreActiveMembers() async {
        _ = fake.addMember(name: "Gone Person", status: "deactivated")
        _ = fake.addMember(name: "New Person", status: "invited")
        let names = await tracker().memberNames()
        XCTAssertEqual(Set(names.values), ["Ada Lovelace"])
    }

    // MARK: Search

    func testSearchByKeyThenText() async throws {
        let id = fake.addIssue(project: acme, title: "Login bug")
        let t = tracker()
        let hits = try await t.search("ACME-1", in: nil, limit: 5)
        XCTAssertEqual(fake.requests.first?.url?.path, "/v1/issues/ACME-1")
        XCTAssertEqual(hits.map(\.id), [id], "the key hit and the text hit are one item")
        let before = fake.requests.count
        let text = try await t.search("login bug", in: [project], limit: 5)
        XCTAssertEqual(text.map(\.id), [id])
        let r = try XCTUnwrap(fake.requests.dropFirst(before).first)
        XCTAssertTrue(r.url!.absoluteString.contains("q=login%20bug"), r.url!.absoluteString)
        XCTAssertEqual(query(r)["order"], "activity")
        XCTAssertEqual(query(r)["project"], acme)
        let empty = try await t.search("  ", in: nil, limit: 5)
        XCTAssertTrue(empty.isEmpty)
        let unknown = try await t.search("ACME-99", in: nil, limit: 5)
        XCTAssertTrue(unknown.isEmpty, "a missing key goes on to the text search")
    }

    func testSearchFiltersManyProjects() async throws {
        let beta = fake.addProject(prefix: "BETA")
        fake.addIssue(project: acme, title: "Shared word")
        fake.addIssue(project: beta, title: "Shared word")
        let both = try await tracker().search("shared", in: [project, ProjectRef(account: Self.account, id: beta)], limit: 10)
        XCTAssertEqual(both.count, 2)
        XCTAssertNil(query(try XCTUnwrap(fake.requests.last))["project"])
        let one = try await tracker().search("shared", in: [project, ProjectRef(account: Self.account, id: "other")], limit: 10)
        XCTAssertEqual(one.count, 1)
    }

    // MARK: Poll

    func testPollBaseline() async throws {
        fake.addIssue(project: acme, title: "Old")
        let page = try await tracker().poll(since: nil)
        XCTAssertTrue(page.events.isEmpty)
        XCTAssertEqual(page.cursor.rawValue, String(fake.head))
        let r = try XCTUnwrap(fake.requests.first)
        XCTAssertEqual(query(r)["entity"], "issue,issue_comment")
        XCTAssertEqual(query(r)["limit"], "1")
        XCTAssertFalse(page.busy)
        XCTAssertTrue(page.baseline)
    }

    func testPollEvents() async throws {
        let t = tracker()
        let first = try await t.poll(since: nil)
        let id = fake.addIssue(project: acme, title: "Fresh")
        fake.addComment(issue: id, body: "Hello")
        let page = try await t.poll(since: first.cursor)
        XCTAssertEqual(page.events.map(\.kind), [.item, .comment])
        XCTAssertEqual(page.events.map(\.action), ["created", "created"])
        XCTAssertEqual(page.events.first?.summary?.title, "Fresh")
        for e in page.events {
            guard case .item(let r) = e.subject else { return XCTFail("subject") }
            XCTAssertEqual(r.key, "ACME-1")
            XCTAssertEqual(r.id, id)
            XCTAssertEqual(r.url.absoluteString, "bigtimer://issue/ACME-1")
        }
        XCTAssertEqual(page.cursor.rawValue, String(fake.head))
        XCTAssertFalse(page.baseline)
        XCTAssertTrue(first.baseline)
        let again = try await t.poll(since: first.cursor)
        XCTAssertEqual(again.events.map(\.id), page.events.map(\.id), "a repeated page gives the same ids")
        let quiet = try await t.poll(since: page.cursor)
        XCTAssertTrue(quiet.events.isEmpty)
    }

    func testPollUpdateAndDelete() async throws {
        let id = fake.addIssue(project: acme, title: "Start")
        let comment = fake.addComment(issue: id, body: "Gone soon")
        let t = tracker()
        let base = try await t.poll(since: nil)
        // The caches know the issue and the comment after one read.
        _ = try await ref(t, id)
        _ = try await t.comments(try await ref(t, id))
        try await t.update(try await ref(t, id), ItemPatch(title: "Next"))
        fake.deleteComment(comment)
        let page = try await t.poll(since: base.cursor)
        XCTAssertEqual(page.events.map(\.action), ["updated", "deleted"])
        XCTAssertEqual(page.events.map(\.kind), [.item, .comment])
    }

    func testPoll410Baseline() async throws {
        fake.addIssue(project: acme, title: "Old")
        fake.override = { r in
            r.url?.query?.contains("since=99") == true ? (410, [:], #"{"code":"cursor_expired","detail":"The cursor is too old."}"#) : nil
        }
        let page = try await tracker().poll(since: Cursor(rawValue: "99"))
        XCTAssertTrue(page.events.isEmpty)
        XCTAssertEqual(page.cursor.rawValue, String(fake.head))
        XCTAssertTrue(page.baseline, "an expired cursor asks the caller to read all data again")
    }

    func testPollUnknownProjectRefreshesOnce() async throws {
        let t = tracker()
        let base = try await t.poll(since: nil)
        fake.addIssue(project: "ghost", title: "Lost one")
        fake.addIssue(project: "ghost", title: "Lost two")
        let page = try await t.poll(since: base.cursor)
        XCTAssertTrue(page.events.isEmpty, "an issue of an unknown project is skipped")
        XCTAssertEqual(fake.paths().filter { $0 == "/v1/projects" }.count, 1)
        XCTAssertEqual(page.cursor.rawValue, String(fake.head))
    }

    func testPollCommentOfUnseenIssueReadsIssue() async throws {
        let id = fake.addIssue(project: acme, title: "Quiet")
        let t = tracker()
        let base = try await t.poll(since: nil)
        fake.addComment(issue: id, body: "Late")
        let page = try await t.poll(since: base.cursor)
        XCTAssertEqual(page.events.map(\.kind), [.comment])
        XCTAssertTrue(fake.paths("GET").contains("/v1/issues/\(id)"))
    }

    // MARK: Contract fixtures

    func testFixturesDecode() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let issues = try BigTimerAPI.decode(BTIssuePage.self, from: Data(contentsOf: dir.appendingPathComponent("issue_page.json")))
        XCTAssertEqual(issues.items.map(\.key), ["ACME-142", "ACME-143", "ACME-140"])
        XCTAssertEqual(issues.items.map { $0.comment_count }, [2, 0, 1])
        XCTAssertNotNil(issues.items[0].last_comment_at)
        XCTAssertNil(issues.items[1].last_comment_at)
        XCTAssertNil(issues.items[0].parent_uuid)
        XCTAssertEqual(issues.items[1].parent_uuid, issues.items[0].uuid)
        XCTAssertGreaterThan(try XCTUnwrap(issues.items[0].activity_at), issues.items[0].updated_at)
        let epic = issues.items[2]
        XCTAssertEqual(epic.kind, "epic")
        XCTAssertEqual(epic.health, "at_risk")
        XCTAssertEqual(epic.item_count, 2)
        XCTAssertEqual(epic.start_date, "2026-10-19")
        XCTAssertEqual(issues.items[0].epic_uuid, epic.uuid)
        XCTAssertNil(issues.items[1].epic_uuid)
        XCTAssertEqual(issues.items[1].epic_key, "ACME-140")
        let feed = try BigTimerAPI.decode(BTChangesPage.self, from: Data(contentsOf: dir.appendingPathComponent("changes_page.json")))
        XCTAssertEqual(feed.head, 9814)
        XCTAssertEqual(feed.changes.map(\.entity), ["issue", "entry", "issue_comment", "issue_source"])
        guard case .issue(let r)? = feed.changes[0].record else { return XCTFail("no issue record") }
        XCTAssertEqual(r.number, 142)
        XCTAssertNil(r.parent_uuid)
        XCTAssertEqual(r.kind, "issue")
        XCTAssertNil(r.epic_uuid)
        XCTAssertNil(feed.changes[1].record)
        XCTAssertEqual(feed.changes[2].uuid, "019a1b2c-3d4e-7f80-9a1b-2c3d4e5f6073")
        XCTAssertEqual(feed.changes[2].version, 3)
    }

    func testHistoryFixtureDecodes() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let h = try BigTimerAPI.decode(BTIssueHistory.self, from: Data(contentsOf: dir.appendingPathComponent("issue_history.json")))
        XCTAssertEqual(h.transitions.map(\.to_status), ["open", "in_progress"])
        XCTAssertNil(h.transitions[0].from_status)
        XCTAssertEqual(h.changes.count, 4)
        XCTAssertEqual(h.changes.filter { $0.channel == "mcp" }.count, 1)
        XCTAssertEqual(h.changes[0].field, "assignee_uuid")
        XCTAssertNil(h.changes[0].old)
        XCTAssertEqual(BigTimerTracker.jsonText(h.changes[0].new), "019a0000-0000-7000-8000-000000000002")
        XCTAssertNil(BigTimerTracker.jsonText("null"))
        XCTAssertEqual(BigTimerTracker.jsonText("\"2026-12-01\""), "2026-12-01")
    }

    func testTimelineMapsHistory() async throws {
        let grace = fake.addMember(name: "Grace Hopper")
        let id = fake.addIssue(project: acme, title: "Old")
        let t = tracker()
        let r = try await ref(t, id)
        try await t.update(r, ItemPatch(title: "New", status: "in_progress", dueDate: "2026-12-01", estimate: "M"))
        try await t.update(r, ItemPatch(assignees: [grace]))
        try await t.update(r, ItemPatch(assignees: []))
        try await t.update(r, ItemPatch(dueDate: ""))
        try await t.comment(r, markdown: "Done soon")

        let list = try await t.timeline(r)
        XCTAssertEqual(list.map(\.at), list.map(\.at).sorted(), "oldest first")
        XCTAssertTrue(fake.paths("GET").contains("/v1/issues/\(id)/history"))
        let changes = list.map(\.change)
        XCTAssertTrue(changes.contains(.status(from: nil, to: "Open")))
        XCTAssertTrue(changes.contains(.status(from: "Open", to: "In progress")))
        XCTAssertEqual(changes.filter { if case .status = $0 { return true }; return false }.count, 2, "the status audit rows are skipped")
        XCTAssertTrue(changes.contains(.field(name: "Title", from: "Old", to: "New")))
        XCTAssertTrue(changes.contains(.field(name: "Due", from: nil, to: "2026-12-01")))
        XCTAssertTrue(changes.contains(.field(name: "Due", from: "2026-12-01", to: nil)))
        XCTAssertTrue(changes.contains(.field(name: "Estimate", from: nil, to: "M")))
        XCTAssertTrue(changes.contains(.assigned("Grace Hopper")))
        XCTAssertTrue(changes.contains(.unassigned("Grace Hopper")))
        XCTAssertEqual(changes.filter { if case .field(let n, _, _) = $0 { return n == "Title" }; return false }.count, 1, "the creation row is skipped")
        let assigned = try XCTUnwrap(list.first { $0.change == .assigned("Grace Hopper") })
        XCTAssertEqual(assigned.actor, "Ada Lovelace", "the actor is the member name")
        guard case .comments(_, let last)? = list.last?.change else { return XCTFail("the comment is last") }
        XCTAssertEqual(last.body, "Done soon")
        XCTAssertEqual(list.last?.actor, "Ada Lovelace")
    }

    func testTimelineNotFound() async throws {
        let t = tracker()
        let r = ItemRef(project: project, id: "00000000-0000-7000-8000-999999999999", key: "ACME-9", url: URL(string: "bigtimer://issue/ACME-9")!)
        do { _ = try await t.timeline(r); XCTFail("no throw") } catch { XCTAssertEqual(error as? ProviderError, .notFound) }
    }

    func testDescriptorHasVendorCLI() throws {
        let cli = try XCTUnwrap(BigTimerTracker.descriptor.cli)
        XCTAssertEqual(cli.binary, "big-timer-cli")
        XCTAssertEqual(cli.minVersion, "1.0.12")
        XCTAssertEqual(cli.tokenEnv, "BIGTIMER_TOKEN")
        XCTAssertEqual(cli.hostEnv, "BIGTIMER_SERVER")
        XCTAssertTrue(BigTimerTracker.descriptor.fields.contains { $0.key == cli.hostField })
        XCTAssertNil(cli.refusal(["server", "version"]), "a command word is no flag")
        XCTAssertNotNil(cli.refusal(["issue", "list", "--token", "x"]))
        XCTAssertNotNil(cli.refusal(["sync", "stream"]))
    }

    // MARK: Epics

    func epicRef(_ id: String, key: String = "ACME-1") -> Epic {
        Epic(id: EpicID(rawValue: id), key: key, title: "E", state: .planned, url: "bigtimer://issue/\(key)", project: project)
    }

    func firstEpic(_ t: BigTimerTracker) async throws -> Epic {
        let list = try await t.epics(in: project)
        return try XCTUnwrap(list.first)
    }

    func health(_ t: BigTimerTracker) async throws -> EpicHealth? { try await t.epics(in: project).first?.health }

    func patches() -> [URLRequest] { fake.requests.filter { $0.httpMethod == "PATCH" } }

    func testItemsSkipEpics() async throws {
        let epic = fake.addEpic(project: acme, title: "Epic")
        let issue = fake.addIssue(project: acme, title: "Issue", epic: epic)
        let t = tracker()
        let items = try await t.items(project, since: nil, limit: 10)
        XCTAssertEqual(items.map(\.id), [issue])
        XCTAssertTrue(fake.requests.filter { $0.url?.path == "/v1/issues" }.allSatisfy { query($0)["kind"] == "issue" })
        let found = try await t.search("Epic", in: nil, limit: 5)
        XCTAssertTrue(found.isEmpty)
        let byKey = try await t.search("ACME-1", in: nil, limit: 5)
        XCTAssertTrue(byKey.isEmpty, "the exact key of an epic gives no item")
        XCTAssertEqual(query(try XCTUnwrap(fake.requests.last))["kind"], "issue")
    }

    func testEpicsMapIssueView() async throws {
        let ada = fake.meUUID
        let epic = fake.addEpic(project: acme, title: "Invoicing", status: "in_progress", due: "2026-12-15", start: "2026-10-19")
        let a = fake.addIssue(project: acme, title: "A", status: "done", size: "M", epic: epic)
        fake.addIssue(project: acme, title: "B", status: "blocked", size: "L", epic: epic)
        fake.addIssue(project: acme, title: "Sub", status: "in_progress", size: "S", parent: a)
        fake.addComment(issue: epic, body: "Slow", health: "at_risk")
        let t = tracker()
        _ = try await t.update(try await ref(t, a), ItemPatch(assignees: [ada]))
        let epics = try await t.epics(in: project)
        XCTAssertEqual(epics.count, 1)
        let e = try XCTUnwrap(epics.first)
        XCTAssertEqual(e.id.rawValue, epic)
        XCTAssertEqual(e.key, "ACME-1")
        XCTAssertEqual(e.title, "Invoicing")
        XCTAssertEqual(e.state, .active)
        XCTAssertEqual(e.nativeState, "in_progress")
        XCTAssertEqual(e.health, .atRisk)
        XCTAssertEqual(e.counts, EpicCounts(total: 3, done: 1, inProgress: 1, blocked: 1, estimateMinutes: 60 + 240 + 30))
        XCTAssertEqual(e.url, "bigtimer://issue/ACME-1")
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: try XCTUnwrap(e.targetDate)), DateComponents(year: 2026, month: 12, day: 15))
        XCTAssertEqual(Calendar.current.dateComponents([.year, .month, .day], from: try XCTUnwrap(e.startDate)), DateComponents(year: 2026, month: 10, day: 19))
        XCTAssertNil(e.lead)
        let r = try XCTUnwrap(fake.requests.first { query($0)["kind"] == "epic" })
        XCTAssertEqual(query(r)["project"], acme)
    }

    func testEpicsGiveClosedEpicsAndFollowCursor() async throws {
        for n in 1...3 { fake.addEpic(project: acme, title: "E\(n)", status: n == 3 ? "cancelled" : "done") }
        fake.pageSize = 2
        let epics = try await tracker().epics(in: project)
        XCTAssertEqual(epics.count, 3)
        XCTAssertEqual(Set(epics.map(\.state)), [.done, .canceled])
        XCTAssertEqual(fake.paths().filter { $0 == "/v1/issues" }.count, 2)
    }

    func testItemEpicIdFromEpicUUID() async throws {
        let epic = fake.addEpic(project: acme, title: "E")
        let id = fake.addIssue(project: acme, title: "In", epic: epic)
        let plain = fake.addIssue(project: acme, title: "Out")
        let t = tracker()
        let items = try await t.items(project, since: nil, limit: 10)
        XCTAssertEqual(items.first { $0.id == id }?.epicId?.rawValue, epic)
        XCTAssertNil(items.first { $0.id == plain }?.epicId)
        XCTAssertNil(items.first { $0.id == id }?.otherEpicIds)
        let one = try await t.item(try await ref(t, id))
        XCTAssertEqual(one.epicId?.rawValue, epic)
    }

    func testSubItemUsesParentEpic() async throws {
        let epic = fake.addEpic(project: acme, title: "E")
        let parent = fake.addIssue(project: acme, title: "Parent", epic: epic)
        let kid = fake.addIssue(project: acme, title: "Kid", parent: parent)
        let t = tracker()
        let before = try await t.items(project, since: nil, limit: 10)
        XCTAssertNil(before.first { $0.id == kid }?.epicId, "the key is not known before the epics load")
        _ = try await t.epics(in: project)
        let items = try await t.items(project, since: nil, limit: 10)
        XCTAssertEqual(items.first { $0.id == kid }?.epicId?.rawValue, epic)
        XCTAssertEqual(items.first { $0.id == kid }?.parentId, parent)
    }

    func testCreateEpicSendsKind() async throws {
        let ada = fake.meUUID
        let t = tracker()
        let day = { (y: Int, m: Int, d: Int) in Calendar.current.date(from: DateComponents(year: y, month: m, day: d))! }
        let made = try await t.createEpic(EpicDraft(title: "Big", goal: "Ship it.", state: .active, lead: ada, startDate: day(2026, 11, 1), targetDate: day(2026, 12, 31)), in: project)
        let post = try XCTUnwrap(fake.requests.first { $0.httpMethod == "POST" && $0.url?.path == "/v1/issues" })
        let b = fake.body(post)
        XCTAssertEqual(b["kind"] as? String, "epic")
        XCTAssertEqual(b["title"] as? String, "Big")
        XCTAssertEqual(b["details"] as? String, "Ship it.")
        XCTAssertEqual(b["status"] as? String, "in_progress")
        XCTAssertEqual(b["start_date"] as? String, "2026-11-01")
        XCTAssertEqual(b["due_date"] as? String, "2026-12-31")
        XCTAssertEqual(b["project_uuid"] as? String, acme)
        XCTAssertEqual(fake.paths("POST").last, "/v1/issues/\(made.id.rawValue)/assign")
        XCTAssertEqual(made.lead, ada)
        XCTAssertEqual(made.state, .active)
        XCTAssertEqual(fake.issue(made.id.rawValue)?.kind, "epic")
        let plain = try await t.createEpic(EpicDraft(title: "Bare"), in: project)
        let bare = fake.body(try XCTUnwrap(fake.requests.last { $0.httpMethod == "POST" }))
        XCTAssertEqual(Set(bare.keys), ["project_uuid", "title", "kind", "status"], "no lead, no assign call")
        XCTAssertEqual(plain.state, .planned)
    }

    func testUpdateEpicClearsDates() async throws {
        let ada = fake.meUUID
        let id = fake.addEpic(project: acme, title: "E", due: "2026-12-01", start: "2026-11-01")
        let t = tracker()
        let e = try await firstEpic(t)
        XCTAssertEqual(e.id.rawValue, id)
        let mark = fake.requests.count
        let out = try await t.updateEpic(e, EpicPatch(title: "Renamed", state: .paused, lead: ada, clear: [.targetDate, .startDate, .goal]))
        let patch = try XCTUnwrap(patches().last)
        let b = fake.body(patch)
        XCTAssertEqual(b["title"] as? String, "Renamed")
        XCTAssertEqual(b["status"] as? String, "blocked")
        XCTAssertTrue(b["due_date"] is NSNull)
        XCTAssertTrue(b["start_date"] is NSNull)
        XCTAssertTrue(b["details"] is NSNull)
        XCTAssertEqual(fake.requests.dropFirst(mark).map { "\($0.httpMethod!) \($0.url!.path)" },
                       ["PATCH /v1/issues/\(id)", "POST /v1/issues/\(id)/assign", "GET /v1/issues/\(id)"])
        XCTAssertNil(out.targetDate)
        XCTAssertNil(out.startDate)
        XCTAssertEqual(out.state, .paused)
        XCTAssertEqual(out.lead, ada)
        _ = try await t.updateEpic(out, EpicPatch(clear: [.lead]))
        XCTAssertTrue(fake.body(try XCTUnwrap(fake.requests.last { $0.url?.lastPathComponent == "assign" }))["member"] is NSNull)
        XCTAssertNil(fake.issue(id)?.assignee)
        let quiet = fake.requests.count
        _ = try await t.updateEpic(out, EpicPatch())
        XCTAssertEqual(fake.requests.dropFirst(quiet).map { $0.httpMethod! }, ["GET"], "an empty patch sends no write")
    }

    func testSetEpicPatchesEpicUUID() async throws {
        let epic = fake.addEpic(project: acme, title: "E")
        let id = fake.addIssue(project: acme, title: "Item")
        let t = tracker()
        let r = try await ref(t, id)
        try await t.setEpic(EpicID(rawValue: epic), for: r)
        XCTAssertEqual(fake.body(try XCTUnwrap(patches().last))["epic_uuid"] as? String, epic)
        XCTAssertEqual(fake.issue(id)?.epic, epic)
        try await t.setEpic(nil, for: r)
        let b = fake.body(try XCTUnwrap(patches().last))
        XCTAssertEqual(Array(b.keys), ["epic_uuid"])
        XCTAssertTrue(b["epic_uuid"] is NSNull)
        XCTAssertNil(fake.issue(id)?.epic)
    }

    func testSetEpicOnSubItemGivesMessage() async throws {
        let epic = fake.addEpic(project: acme, title: "E")
        let parent = fake.addIssue(project: acme, title: "Parent")
        let kid = fake.addIssue(project: acme, title: "Kid", parent: parent)
        let t = tracker()
        do { try await t.setEpic(EpicID(rawValue: epic), for: try await ref(t, kid)); XCTFail("no throw") } catch {
            XCTAssertEqual(error as? ProviderError, .vendor(code: "validation", message: "Big Timer: a sub-item uses the epic of its parent."))
        }
        let plain = fake.addIssue(project: acme, title: "Plain")
        do { try await t.setEpic(EpicID(rawValue: plain), for: try await ref(t, parent)); XCTFail("no throw") } catch {
            XCTAssertEqual(error as? ProviderError, .vendor(code: "validation", message: "Big Timer: the item is not an epic."))
        }
        XCTAssertNil(fake.issue(kid)?.epic)
    }

    func testEpicStateMapping() {
        let pairs: [(String, EpicState)] = [("open", .planned), ("in_progress", .active), ("client_reviewing", .active), ("blocked", .paused),
                                            ("done", .done), ("cancelled", .canceled), ("future", .planned)]
        for (status, state) in pairs { XCTAssertEqual(BigTimerTracker.epicState(status), state, status) }
        XCTAssertEqual(EpicState.allCases.map(BigTimerTracker.status), ["open", "in_progress", "blocked", "done", "cancelled"])
        for s in EpicState.allCases { XCTAssertEqual(BigTimerTracker.epicState(BigTimerTracker.status(s)), s) }
    }

    func testPostUpdateSendsHealth() async throws {
        let id = fake.addEpic(project: acme, title: "E", due: "2026-12-01")
        let t = tracker()
        XCTAssertTrue(t.capabilities.contains(.epicHealth))
        let e = try await firstEpic(t)
        try await t.postUpdate(e, health: .offTrack, markdown: "Late.")
        let b = fake.body(try XCTUnwrap(fake.requests.last))
        XCTAssertEqual(fake.requests.last?.url?.path, "/v1/issues/\(id)/comments")
        XCTAssertEqual(b["body"] as? String, "Late.")
        XCTAssertEqual(b["health"] as? String, "off_track")
        let first = try await health(t)
        XCTAssertEqual(first, .offTrack)
        try await t.postUpdate(e, health: nil, markdown: "Note only.")
        XCTAssertEqual(Array(fake.body(try XCTUnwrap(fake.requests.last)).keys), ["body"], "no health, no key")
        let kept = try await health(t)
        XCTAssertEqual(kept, .offTrack, "a note keeps the health of the last update")
        let plain = fake.addIssue(project: acme, title: "Plain")
        do { try await t.postUpdate(epicRef(plain), health: .atRisk, markdown: "x"); XCTFail("no throw") } catch {
            XCTAssertEqual(error as? ProviderError, .vendor(code: "validation", message: "Big Timer: only an update on an epic has a health."))
        }
        let comments = try await t.comments(try await ref(t, plain))
        XCTAssertTrue(comments.isEmpty)
    }

    func testHealthNilWithoutDueDate() async throws {
        let id = fake.addEpic(project: acme, title: "E")
        let t = tracker()
        let e = try await firstEpic(t)
        try await t.postUpdate(e, health: .atRisk, markdown: "Slow.")
        let none = try await health(t)
        XCTAssertNil(none)
        _ = try await t.updateEpic(e, EpicPatch(targetDate: Calendar.current.date(from: DateComponents(year: 2026, month: 12, day: 1))))
        let later = try await health(t)
        XCTAssertEqual(later, .atRisk)
        XCTAssertEqual(fake.issue(id)?.due, "2026-12-01")
    }

    func testChangeOfEpicGivesNoItemEvent() async throws {
        let t = tracker()
        let base = try await t.poll(since: nil)
        let epic = fake.addEpic(project: acme, title: "E", due: "2026-12-01")
        let page = try await t.poll(since: base.cursor)
        XCTAssertTrue(page.events.isEmpty, "an epic is not an item")
        XCTAssertEqual(page.cursor.rawValue, String(fake.head))
        fake.addComment(issue: epic, body: "Update", health: "on_track")
        let comment = try await t.poll(since: page.cursor)
        XCTAssertTrue(comment.events.isEmpty, "an update on an epic gives no comment row")
        let item = fake.addIssue(project: acme, title: "Real", epic: epic)
        let rows = try await t.poll(since: comment.cursor)
        XCTAssertEqual(rows.events.map(\.kind), [.item])
        XCTAssertEqual(rows.events.first?.summary?.title, "Real")
        _ = item
    }

    func testEpicDeleteGivesNoItemEvent() async throws {
        let epic = fake.addEpic(project: acme, title: "E")
        let t = tracker()
        _ = try await t.epics(in: project)
        let base = try await t.poll(since: nil)
        fake.deleteIssue(epic)
        let page = try await t.poll(since: base.cursor)
        XCTAssertTrue(page.events.isEmpty)
    }

    func testEpicErrorMessages() {
        XCTAssertEqual(BigTimerAPI.epicMessage("kind", "cannot change after create"), "Big Timer: the kind of an item is fixed after create.")
        XCTAssertEqual(BigTimerAPI.epicMessage("health", "must be on_track, at_risk, or off_track"), "Big Timer: the health must be on_track, at_risk or off_track.")
        XCTAssertEqual(BigTimerAPI.epicMessage("epic_uuid", "an epic cannot be in an epic"), "Big Timer: an epic cannot be in an epic.")
        XCTAssertEqual(BigTimerAPI.epicMessage("epic_uuid", "belongs to another project"), "Big Timer: an epic must be in the project of its items.")
        XCTAssertEqual(BigTimerAPI.epicMessage("epic_uuid", "odd"), "Big Timer: the epic is not valid (odd).")
    }

    func testPatchEncodesClearAsNull() throws {
        var p = BTIssuePatch(title: nil, details: nil, status: nil, parent_uuid: nil, due_date: "2026-12-01")
        p.clear = ["start_date", "due_date"]
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        XCTAssertEqual(json["due_date"] as? String, "2026-12-01", "a value wins over clear")
        XCTAssertTrue(json["start_date"] is NSNull)
        XCTAssertEqual(json.count, 2)
        XCTAssertFalse(p.isEmpty)
        XCTAssertTrue(BTIssuePatch(title: nil, details: nil, status: nil, parent_uuid: nil).isEmpty)
        var c = BTIssuePatch(title: nil, details: nil, status: nil, parent_uuid: nil)
        c.clear = ["epic_uuid"]
        XCTAssertFalse(c.isEmpty)
    }
}
