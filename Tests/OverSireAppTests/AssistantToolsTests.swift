import XCTest
import OverSireCore
import OverSireSync
import OverSireAI
import OverSireAssistant
import OverSireTestKit
@testable import OverSireApp

/// The people, search and machine tools of the assistant.
final class AssistantToolsTests: XCTestCase {
    // MARK: People

    func testOnePersonInPlaneAndGitHubIsOneEntry() async throws {
        let plane: AppPeople.Source = { _ in [PersonDetail(id: "u1", name: "Ada Lovelace", email: "ada@example.com", sources: ["plane:ocral"])] }
        let github: AppPeople.Source = { _ in
            [PersonDetail(id: "9", name: "ada", login: "ada", email: "ADA@example.com", sources: ["github:acme"]),
             PersonDetail(id: "10", name: "bob", login: "bob", sources: ["github:acme"])]
        }
        let people = AppPeople(sources: [plane, github], owner: { ("Ada Lovelace", ["mbp", "mini"]) })
        let list = await people.details(for: nil)
        XCTAssertEqual(list.map(\.id), ["u1", "10"])
        XCTAssertEqual(list[0].login, "ada")
        XCTAssertEqual(list[0].sources, ["plane:ocral", "github:acme", "machines"])
        XCTAssertEqual(list[0].machines, ["mbp", "mini"])
        let byLogin = try await people.person(PersonRef(id: "", name: "", login: "bob"))
        XCTAssertEqual(byLogin.id, "10")
    }

    func testPeopleStayInTheCache() async {
        final class Count: @unchecked Sendable { var n = 0 }
        let c = Count()
        let people = AppPeople(sources: [{ _ in c.n += 1; return [] }])
        _ = await people.details(for: nil)
        _ = await people.details(for: nil)
        XCTAssertEqual(c.n, 1)
    }

    func testMachinesWithoutAMatchGiveTheOwner() async {
        let people = AppPeople(sources: [], owner: { (nil, ["mbp"]) })
        let list = await people.details(for: nil)
        XCTAssertEqual(list.map(\.name), ["You"])
        XCTAssertEqual(list[0].machines, ["mbp"])
    }

    // MARK: Search

    func testSearchFindsLocalItemsRunsAndPRs() async {
        let data = TestAppData()
        data.projectStore.seed(ProjectSnapshot(summary: ProjectSummary(ref: ProjectRef(account: AccountID(provider: "plane", id: "w"), id: "p"), identifier: "ENG",
                                                                       title: "Eng", url: "", closed: false),
                                               statusOptions: [StatusOption(id: "s", name: "Todo", color: "#000000", group: "unstarted")],
                                               items: [Item(id: "1", key: "ENG-1", title: "Fix the login page", url: "", statusOptionId: "s", fields: [:],
                                                            assignees: [], labels: [], author: "a", updatedBy: "a", updatedAt: Date(), activityAt: Date(),
                                                            commentCount: 0, lastComment: nil, mentionsMe: false, body: nil)],
                                               fetchedAt: Date(), me: "a"))
        data.grouped = [("o/a", [Run(id: "7", name: "CI", displayTitle: "Login tests", status: "completed", conclusion: "failure", headBranch: "login",
                                     headSha: "x", event: "push", url: "", updatedAt: "", createdAt: "", startedAt: "", number: 7, workflowName: "CI", actorLogin: nil)])]
        let r = await data.actions.run("search.all", ActionArgs(.object(["query": .string("login")])))
        guard case .ok(_, let d?, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(d["items"]?.array?.first?["key"]?.string, "ENG-1")
        XCTAssertEqual(d["runs"]?.array?.first?["id"]?.string, "7")
        XCTAssertEqual(d["prs"]?.array?.count, 0)
    }

    func testSearchNeedsAQuery() async {
        let r = await TestAppData().actions.run("search.all", ActionArgs(.object(["query": .string(" ")])))
        XCTAssertEqual(r, .notAllowed("The query is empty."))
    }

    // MARK: Machines

    private let now = Date()

    @MainActor
    private func machines(_ local: FakeDaemon) -> MachinesController {
        let m = MachinesController.shared
        let seen = now.addingTimeInterval(-7200)
        let members = [GroupMember(machine: "studio", host: "studio", addrs: [], port: 7690, roles: ["serve"], joinedAt: seen, lastSeen: now),
                       GroupMember(machine: "mbp", host: "mbp", addrs: [], port: 7690, roles: ["serve"], joinedAt: seen, lastSeen: seen)]
        var s = MachinesSnapshot()
        s.info = DaemonInfo(machine: "studio", version: "0.4.0", contract: 1, roles: ["serve"], runtimes: ["orca"], harnesses: [],
                            listen: .init(loopback: "127.0.0.1:7690", tailscale: nil))
        s.group = Group(id: "g", name: "My machines", home: "studio", version: 1, members: members, devices: [])
        m.use(s)
        m.local = DaemonClient(base: DaemonClient.loopback, token: nil, http: local)
        return m
    }

    @MainActor
    func testOfflineMachineGivesANotice() async {
        let saved = MachinesController.shared.snapshot
        defer { MachinesController.shared.use(saved) }
        _ = machines(FakeDaemon(machine: "studio"))
        let r = await TestAppData().actions.run("machine.sessions", ActionArgs(.object(["machine": .string("mbp")])))
        guard case .ok(let summary, _, let parts) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(summary.hasPrefix("mbp is offline. Last seen"), summary)
        XCTAssertEqual(parts.count, 1)
        let other = await TestAppData().actions.run("machine.sessions", ActionArgs(.object(["machine": .string("nope")])))
        XCTAssertEqual(other.summary, "nope is not in the group.")
    }

    @MainActor
    func testSessionsOfThisMac() async {
        let saved = MachinesController.shared.snapshot
        defer { MachinesController.shared.use(saved) }
        let d = FakeDaemon(machine: "studio")
        d.sessions = [DaemonSession(id: "cli:1", machine: "studio", runtime: "cli", harness: "claude", cwd: "/src", state: .working,
                                    stateSince: now, updatedAt: now, sources: ["hook"])]
        _ = machines(d)
        let r = await TestAppData().actions.run("machine.sessions", ActionArgs(.object(["machine": .string("studio")])))
        guard case .ok(let summary, let data?, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(summary, "1 session.")
        XCTAssertEqual(data.array?.first?["id"]?.string, "cli:1")
    }

    func testOutwardMachineToolsAsk() {
        let a = TestAppData().actions
        XCTAssertEqual(a.spec("session.ask")?.kind, .outward)
        XCTAssertEqual(a.spec("order.start")?.kind, .outward)
        XCTAssertEqual(a.spec("session.read")?.kind, .read)
        XCTAssertEqual(a.spec("people.list")?.kind, .read)
    }
}
