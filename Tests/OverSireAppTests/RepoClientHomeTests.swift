import OverSireAssistant
import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// A client reads code host data through the home (OVERSIRE-538).
final class RepoClientHomeTests: XCTestCase {
    private final class NoAccounts: RepoAccounts {
        func codeHost(owner: String) -> (any CodeHost)? { nil }
        func ci(owner: String) -> (any CIProvider)? { nil }
    }

    private final class FakeAccounts: RepoAccounts {
        let host = FakeCodeHost(), fakeCI = FakeCI()
        func codeHost(owner: String) -> (any CodeHost)? { host }
        func ci(owner: String) -> (any CIProvider)? { fakeCI }
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(what: String, args: [String: JSONValue])] = []
        var all: [(what: String, args: [String: JSONValue])] { lock.withLock { list } }
        func add(_ what: String, _ args: [String: JSONValue]) { lock.withLock { list.append((what, args)) } }
    }

    private var savedClient: RepoClient!
    private var savedRepos: [String] = []

    override func setUp() {
        savedClient = REPO_CLIENT
        savedRepos = REPOS
    }

    override func tearDown() {
        RepoClient.home = nil
        REPO_CLIENT = savedClient
        REPOS = savedRepos
    }

    private func job(_ id: String) -> Job {
        Job(id: id, name: "build", status: "completed", conclusion: "failure", url: nil, startedAt: nil, completedAt: nil, runnerName: nil, steps: nil)
    }

    private func home<T: Codable & Sendable>(_ answer: T, calls: Calls) {
        RepoClient.home = { what, args in
            calls.add(what, args)
            return try MirrorCodec.body(MirrorRows(rows: answer))
        }
    }

    func testJobsReadThroughTheHome() async {
        let calls = Calls()
        home([job("7")], calls: calls)
        let jobs = await RepoClient(accounts: NoAccounts()).jobs("o/r", runId: "9")
        XCTAssertEqual(jobs?.map(\.id), ["7"])
        XCTAssertEqual(calls.all.map(\.what), ["jobs"])
        XCTAssertEqual(calls.all.first?.args, ["repo": .string("o/r"), "runId": .string("9")])
    }

    func testCommitMessageFailuresAndLogReadThroughTheHome() async throws {
        let client = RepoClient(accounts: NoAccounts())
        let calls = Calls()
        home("Fix the thing", calls: calls)
        let message = await client.commitMessage("o/r", sha: "abc")
        XCTAssertEqual(message, "Fix the thing")
        let log = await client.rawLog("o/r", jobId: "7")
        XCTAssertEqual(log, "Fix the thing")
        home([Failure(job: "build", step: "test", messages: ["boom"])], calls: calls)
        let failures = await client.failures("o/r", runId: "9", jobs: [job("7")])
        XCTAssertEqual(failures.map(\.job), ["build"])
        XCTAssertEqual(calls.all.map(\.what), ["commitMessage", "jobLog", "failures"])
        XCTAssertEqual(calls.all[2].args["jobs"]?.array?.count, 1, "the jobs go to the home")
        XCTAssertEqual(calls.all[0].args["sha"], .string("abc"))
        XCTAssertEqual(calls.all[1].args["jobId"], .string("7"))
    }

    func testAnEmptyCommitMessageGivesNil() async {
        home("", calls: Calls())
        let message = await RepoClient(accounts: NoAccounts()).commitMessage("o/r", sha: "abc")
        XCTAssertNil(message)
        let none = await RepoClient(accounts: NoAccounts()).commitMessage("o/r", sha: "")
        XCTAssertNil(none, "no sha, no call")
    }

    func testAFailedHomeGivesNilAndEmpty() async {
        RepoClient.home = { _, _ in throw ProviderError.transport("offline") }
        let client = RepoClient(accounts: FakeAccounts())
        let jobs = await client.jobs("fake/app", runId: "1")
        XCTAssertNil(jobs, "no local read after a failed home read")
        let failures = await client.failures("fake/app", runId: "1", jobs: [])
        XCTAssertEqual(failures, [])
        let log = await client.rawLog("fake/app", jobId: "1-build")
        XCTAssertNil(log)
        let message = await client.commitMessage("fake/app", sha: "abc")
        XCTAssertNil(message)
    }

    func testWithoutAHomeTheClientReadsLocally() async {
        let jobs = await RepoClient(accounts: FakeAccounts()).jobs("fake/app", runId: "1")
        XCTAssertEqual(jobs?.map(\.id), ["1-build"])
    }

    // The home answers `mirror.read` with its own accounts.
    func testMirrorReadGivesRunDetails() async throws {
        let rig = try await EpicRig(items: 0, epics: [])
        REPO_CLIENT = RepoClient(accounts: FakeAccounts())
        REPOS = ["fake/app"]
        func read(_ args: [String: JSONValue]) async -> ActionResult {
            await rig.d.actions.run("mirror.read", ActionArgs(.object(args)))
        }
        let repo: JSONValue = .string("fake/app")
        let r = await read(["what": .string("jobs"), "repo": repo, "runId": .string("1")])
        guard case .ok(_, let data?, _) = r else { return XCTFail("\(r)") }
        let jobs = try MirrorCodec.value(MirrorRows<[Job]>.self, from: data).rows
        XCTAssertEqual(jobs.map(\.id), ["1-build"])
        let f = await read(["what": .string("failures"), "repo": repo, "runId": .string("1"), "jobs": try JSONValue.encoded(jobs)])
        guard case .ok(_, let failed?, _) = f else { return XCTFail("\(f)") }
        XCTAssertEqual(try MirrorCodec.value(MirrorRows<[Failure]>.self, from: failed).rows.map(\.job), ["build"])
        let c = await read(["what": .string("commitMessage"), "repo": repo, "sha": .string("abc1234")])
        guard case .ok(_, let message?, _) = c else { return XCTFail("\(c)") }
        XCTAssertEqual(try MirrorCodec.value(MirrorRows<String>.self, from: message).rows, "Commit abc1234")
        let l = await read(["what": .string("jobLog"), "repo": repo, "jobId": .string("1-build")])
        guard case .ok(_, let logged?, _) = l else { return XCTFail("\(l)") }
        XCTAssertTrue(try MirrorCodec.value(MirrorRows<String>.self, from: logged).rows.contains("error: the fake failed"))
    }

    func testMirrorReadRefusesARepoThatIsNotSelected() async throws {
        let rig = try await EpicRig(items: 0, epics: [])
        REPO_CLIENT = RepoClient(accounts: FakeAccounts())
        REPOS = ["fake/app"]
        for what in ["jobs", "jobLog", "commitMessage"] {
            let r = await rig.d.actions.run("mirror.read", ActionArgs(.object(["what": .string(what), "repo": .string("other/app"), "runId": .string("1"),
                                                                              "jobId": .string("1"), "sha": .string("abc")])))
            XCTAssertEqual(r, .notAllowed("other/app is not a repo of OverSire."), what)
        }
        let bad = await rig.d.actions.run("mirror.read", ActionArgs(.object(["what": .string("jobs"), "repo": .string("fake/app --flag"), "runId": .string("1")])))
        XCTAssertEqual(bad, .notAllowed("fake/app --flag is not a repo of OverSire."))
        let failures = await rig.d.actions.run("mirror.read", ActionArgs(.object(["what": .string("failures"), "repo": .string("fake/app"), "runId": .string("1")])))
        XCTAssertEqual(failures, .notAllowed("Give the jobs."))
    }

    // The home gives no answer when the run is unknown.
    func testMirrorReadFailsForAnUnknownRun() async throws {
        let rig = try await EpicRig(items: 0, epics: [])
        REPO_CLIENT = RepoClient(accounts: FakeAccounts())
        REPOS = ["fake/app"]
        let r = await rig.d.actions.run("mirror.read", ActionArgs(.object(["what": .string("jobs"), "repo": .string("fake/app"), "runId": .string("404")])))
        guard case .failed = r else { return XCTFail("\(r)") }
    }

    func testRepoCatalogRefreshRuns() async throws {
        let accounts = FakeAccounts()
        REPO_CLIENT = RepoClient(accounts: accounts)
        let d = TestAppData()
        RepoCatalogCache(user: "me", owners: [RepoOwner(login: "fake", repos: [], fetchedAt: nil)], fetchedAt: Date()).write(atPath: d.tmp + "/repo-cache.json", makeDir: true)
        let r = await d.actions.run("repo.catalogRefresh", ActionArgs(.object(["owner": .string("fake")])))
        guard case .ok = r else { return XCTFail("\(r)") }
        XCTAssertEqual(d.repoCatalog.repos(of: "fake"), ["fake/app"])
        let bad = await d.actions.run("repo.catalogRefresh", ActionArgs(.object(["owner": .string("nope")])))
        XCTAssertEqual(bad, .notAllowed("No owner nope."))
    }

    func testRepoCatalogRefreshFailureShows() async throws {
        REPO_CLIENT = RepoClient(accounts: NoAccounts())
        let d = TestAppData()
        RepoCatalogCache(user: "me", owners: [RepoOwner(login: "fake", repos: [], fetchedAt: nil)], fetchedAt: Date()).write(atPath: d.tmp + "/repo-cache.json", makeDir: true)
        let r = await d.actions.run("repo.catalogRefresh", ActionArgs(.object(["owner": .string("fake")])))
        guard case .failed(let m) = r else { return XCTFail("\(r)") }
        XCTAssertFalse(m.isEmpty)
        XCTAssertEqual(try XCTUnwrap(d.repoCatalog.mirrorRepos().owners.first).error, m)
    }
}

/// A client picks repos from the catalog of the home (OVERSIRE-538).
final class RepoCatalogClientTests: XCTestCase {
    private func client(_ repos: CatalogRepos?) -> RepoCatalog {
        let c = RepoCatalog(path: NSTemporaryDirectory() + "repo-cache-\(UUID().uuidString).json")
        c.mirrored = repos
        return c
    }

    private let sample = CatalogRepos(user: "me", owners: [
        CatalogRepoOwner(login: "me", repos: ["me/a", "me/b"], fetchedAt: Date(timeIntervalSince1970: 100)),
        CatalogRepoOwner(login: "acme", repos: ["acme/x"], fetchedAt: Date(timeIntervalSince1970: 200), error: "Rate limit"),
    ])

    func testClientOwnersComeFromTheMirror() {
        let c = client(sample)
        XCTAssertEqual(c.owners.map(\.login), ["me", "acme"])
        XCTAssertEqual(c.user, "me")
        XCTAssertTrue(c.authChecked)
        XCTAssertEqual(c.repos(of: "ACME"), ["acme/x"])
        XCTAssertEqual(c.fetchedAt, Date(timeIntervalSince1970: 200))
        XCTAssertEqual(c.resolve(picked: [], orgs: ["acme"]), ["acme/x"])
        guard case .failed("Rate limit") = c.fetch("acme") else { return XCTFail("a mirrored error shows") }
        XCTAssertTrue(c.fetch("me").isIdle)
    }

    func testAHomeWithNoLoginGivesNoUser() {
        let c = client(CatalogRepos(user: nil, owners: []))
        XCTAssertNil(c.user)
        XCTAssertTrue(c.authChecked, "the home was asked")
        XCTAssertTrue(c.owners.isEmpty)
    }

    func testANewMirroredCatalogNotifies() {
        let c = client(nil)
        let seen = expectation(description: "changed")
        let token = NotificationCenter.default.addObserver(forName: RepoCatalog.changed, object: c, queue: nil) { _ in seen.fulfill() }
        defer { NotificationCenter.default.removeObserver(token) }
        c.mirrored = sample
        wait(for: [seen], timeout: 1)
    }

    func testClientRefreshForwards() {
        let c = client(sample)
        var asked: [String?] = []
        var finish: ((String?) -> Void)?
        c.forwardRefresh = { owner, done in
            asked.append(owner)
            finish = done
        }
        c.refresh(owner: "me")
        XCTAssertEqual(asked, ["me"])
        guard case .loading = c.fetch("me") else { return XCTFail("the refresh runs") }
        XCTAssertTrue(c.refreshing)
        finish?("Offline")
        guard case .failed("Offline") = c.fetch("me") else { return XCTFail("the failure shows") }
        XCTAssertFalse(c.refreshing)
        c.refresh(owner: "me")
        finish?(nil)
        XCTAssertTrue(c.fetch("me").isIdle)
    }

    func testClientRefreshAllForwardsOnceAndDoesNotRefreshByAge() {
        let c = client(sample)
        var asked: [String?] = []
        var finish: ((String?) -> Void)?
        c.forwardRefresh = { owner, done in
            asked.append(owner)
            finish = done
        }
        c.refreshIfStale()
        XCTAssertEqual(asked, [], "the home refreshes by age")
        c.refreshAll()
        c.refreshAll()
        XCTAssertEqual(asked, [nil], "a running refresh blocks the next")
        XCTAssertTrue(c.refreshing)
        finish?(nil)
        XCTAssertFalse(c.refreshing)
    }

    func testAnOldRefreshAnswerDoesNotOverrideANewerOne() {
        let c = client(sample)
        var finish: [(String?) -> Void] = []
        c.forwardRefresh = { _, done in finish.append(done) }
        c.refresh(owner: "me")
        c.refresh(owner: "acme")
        finish[0]("old")
        guard case .loading = c.fetch("acme") else { return XCTFail("the other refresh still runs") }
        finish[1](nil)
        XCTAssertFalse(c.refreshing)
    }

    func testTheHomeMirrorsItsOwners() {
        let path = NSTemporaryDirectory() + "repo-cache-\(UUID().uuidString).json"
        RepoCatalogCache(user: "me", owners: [RepoOwner(login: "me", repos: ["me/a"], fetchedAt: Date(timeIntervalSince1970: 5))], fetchedAt: Date()).write(atPath: path, makeDir: true)
        let c = RepoCatalog(path: path)
        XCTAssertEqual(c.mirrorRepos(), CatalogRepos(user: "me", owners: [CatalogRepoOwner(login: "me", repos: ["me/a"], fetchedAt: Date(timeIntervalSince1970: 5))]))
    }
}
