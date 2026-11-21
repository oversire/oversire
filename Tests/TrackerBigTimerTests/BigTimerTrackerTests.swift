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
        let full = fake.addIssue(project: acme, title: "Full", assignee: ada, size: "M", due: "2026-12-01")
        let bare = fake.addIssue(project: acme, title: "Bare")
        let items = try await tracker().items(project, since: nil, limit: 10)
        let a = try XCTUnwrap(items.first { $0.id == full })
        XCTAssertEqual(a.fields, ["Size": "M", "Due": "2026-12-01"])
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

        let quiet = fake.requests.count
        try await t.update(r, ItemPatch())
        XCTAssertEqual(fake.requests.count, quiet, "an empty patch sends nothing")
        for (patch, cap) in [(ItemPatch(priority: "high"), Capability.priority), (ItemPatch(labels: ["x"]), .labels)] {
            do { try await t.update(r, patch); XCTFail("no throw") } catch { XCTAssertEqual(error as? ProviderError, .unsupported(cap)) }
        }
        XCTAssertEqual(fake.requests.count, quiet, "a refused patch sends nothing")
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
        XCTAssertEqual(issues.items.map(\.key), ["ACME-142", "ACME-143"])
        XCTAssertEqual(issues.items.map { $0.comment_count }, [2, 0])
        XCTAssertNotNil(issues.items[0].last_comment_at)
        XCTAssertNil(issues.items[1].last_comment_at)
        XCTAssertNil(issues.items[0].parent_uuid)
        XCTAssertEqual(issues.items[1].parent_uuid, issues.items[0].uuid)
        XCTAssertGreaterThan(try XCTUnwrap(issues.items[0].activity_at), issues.items[0].updated_at)
        let feed = try BigTimerAPI.decode(BTChangesPage.self, from: Data(contentsOf: dir.appendingPathComponent("changes_page.json")))
        XCTAssertEqual(feed.head, 9813)
        XCTAssertEqual(feed.changes.map(\.entity), ["issue", "entry", "issue_comment"])
        guard case .issue(let r)? = feed.changes[0].record else { return XCTFail("no issue record") }
        XCTAssertEqual(r.number, 142)
        XCTAssertEqual(r.parent_uuid, "019a1b2c-3d4e-7f80-9a1b-2c3d4e5f6070")
        XCTAssertNil(feed.changes[1].record)
        XCTAssertEqual(feed.changes[2].uuid, "019a1b2c-3d4e-7f80-9a1b-2c3d4e5f6073")
        XCTAssertEqual(feed.changes[2].version, 3)
    }

    func testDescriptorHasVendorCLI() throws {
        let cli = try XCTUnwrap(BigTimerTracker.descriptor.cli)
        XCTAssertEqual(cli.binary, "big-timer-cli")
        XCTAssertEqual(cli.tokenEnv, "BIGTIMER_TOKEN")
        XCTAssertEqual(cli.hostEnv, "BIGTIMER_SERVER")
        XCTAssertTrue(BigTimerTracker.descriptor.fields.contains { $0.key == cli.hostField })
        XCTAssertNil(cli.refusal(["server", "version"]), "a command word is no flag")
        XCTAssertNotNil(cli.refusal(["issue", "list", "--token", "x"]))
        XCTAssertNotNil(cli.refusal(["sync", "stream"]))
    }
}
