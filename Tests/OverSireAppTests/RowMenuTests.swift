import OverSireCore
import XCTest
@testable import OverSireApp

final class RowMenuTests: XCTestCase {
    private let ref = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "SLING")
    private let all: Set<Capability> = [.rerun, .rerunJob, .cancel, .logs, .changeActions, .sessionInput, .reveal]

    private var snap: ProjectSnapshot {
        ProjectSnapshot(summary: ProjectSummary(ref: ref, identifier: "SLING", title: "Sling", url: "https://plane/sling", closed: false),
                        statusOptions: [StatusOption(id: "s1", name: "Todo", color: "#000", group: "unstarted"),
                                        StatusOption(id: "s2", name: "Done", color: "#000", group: "completed")],
                        items: [], fetchedAt: Date())
    }

    private func item(assignees: [String] = []) -> Item {
        Item(id: "i1", key: "SLING-7", title: "Fix the sync", url: "https://plane/SLING-7", statusOptionId: "s1", fields: ["Priority": "High"],
             assignees: assignees, labels: [], author: nil, updatedBy: nil, updatedAt: Date(), activityAt: Date(),
             commentCount: 0, lastComment: nil, mentionsMe: false)
    }

    private func run(status: String, conclusion: String?) -> Run {
        Run(id: "99", name: "CI", displayTitle: "Fix", status: status, conclusion: conclusion, headBranch: "main", headSha: "abc123",
            event: "push", url: "https://github.com/o/r/actions/runs/99", updatedAt: "", createdAt: "", startedAt: nil,
            number: 4, workflowName: "CI", actorLogin: nil)
    }

    private func pr(mine: Bool) -> ChangeRequest {
        ChangeRequest(number: 12, title: "Fix", state: "OPEN", author: .init(login: "ada"), headRefName: "sling-7/fix", baseRefName: "main",
                      url: "https://github.com/o/r/pull/12", createdAt: "", updatedAt: "", reviewDecision: nil, additions: 1,
                      deletions: 0, isDraft: false, labels: [], body: nil, mine: mine)
    }

    func testItemMenu() {
        var local = ProjectLocalSettings()
        local.branchTemplate = "{KEY}-{slug}"
        let m = RowMenu.item(item(), snap: snap, stream: nil, local: local, caps: all)
        XCTAssertEqual(m.titles, ["Open", "Open in Plane", "Copy ID", "Copy link", "Copy ID and title", "Copy branch name",
                                  "Status", "Assign to me", "Priority", "Start session in Orca…"])
        XCTAssertEqual(m.command("Copy branch name"), .copy("SLING-7-fix-the-sync"))
        XCTAssertEqual(m.command("Copy ID and title"), .copy("SLING-7 Fix the sync"))
        guard case .submenu(_, let statuses) = m.first(where: { $0.title == "Status" }) else { return XCTFail("no status menu") }
        XCTAssertEqual(statuses.first, .action("Todo", .status(itemId: "i1", optionId: "s1"), checked: true))
        guard case .submenu(_, let prios) = m.first(where: { $0.title == "Priority" }) else { return XCTFail("no priority menu") }
        XCTAssertTrue(prios.contains(.action("High", .priority(itemId: "i1", priorityId: "high"), checked: true)))
    }

    func testItemMenuWithoutRuntimeOrForMyItem() {
        var s = snap
        s.me = "ada"
        let m = RowMenu.item(item(assignees: ["ada"]), snap: s, stream: nil, local: ProjectLocalSettings(), caps: [])
        XCTAssertFalse(m.titles.contains("Assign to me"))
        XCTAssertFalse(m.titles.contains("Start session in Orca…"))
        XCTAssertEqual(m.command("Copy branch name"), .copy("sling-7/fix-the-sync"))
    }

    func testFailedRunMenu() {
        let m = RowMenu.run(repo: "o/r", run: run(status: "completed", conclusion: "failure"), linkedKey: "SLING-7", ignored: false, caps: all)
        XCTAssertEqual(m.titles, ["Open", "Open on GitHub", "Copy link", "Copy run ID", "Copy commit SHA",
                                  "Re-run failed jobs", "Re-run all jobs", "Explain failure…", "Ignore this failure", "Open linked item"])
        XCTAssertEqual(m.command("Ignore this failure"), .ignoreFailure(repo: "o/r", runId: "99", true))
        XCTAssertEqual(m.command("Re-run failed jobs"), .run(repo: "o/r", runId: "99", .rerunFailed))
        XCTAssertEqual(m.command("Copy commit SHA"), .copy("abc123"))
        XCTAssertEqual(m.command("Explain failure…"), .explain(repo: "o/r", runId: "99", jobId: nil))
    }

    func testRunMenuFollowsCapabilities() {
        let live = RowMenu.run(repo: "o/r", run: run(status: "in_progress", conclusion: nil), linkedKey: nil, ignored: false, caps: all)
        XCTAssertTrue(live.titles.contains("Cancel run"))
        XCTAssertFalse(live.titles.contains("Re-run all jobs"))
        XCTAssertFalse(live.titles.contains("Ignore this failure"))
        let bare = RowMenu.run(repo: "o/r", run: run(status: "completed", conclusion: "failure"), linkedKey: nil, ignored: true, caps: [])
        XCTAssertEqual(bare.titles, ["Open", "Open on GitHub", "Copy link", "Copy run ID", "Copy commit SHA", "Count this failure again"])
        XCTAssertEqual(bare.command("Count this failure again"), .ignoreFailure(repo: "o/r", runId: "99", false))
        XCTAssertNotEqual(bare.last, .separator)
    }

    func testJobMenu() {
        let j = Job(id: "5", name: "build", status: "completed", conclusion: "failure", url: "https://github.com/j/5", startedAt: nil,
                    completedAt: nil, runnerName: nil, steps: nil)
        let done = run(status: "completed", conclusion: "failure")
        let m = RowMenu.job(repo: "o/r", run: done, job: j, caps: all)
        XCTAssertEqual(m.titles, ["Open job on GitHub", "Copy job log", "Copy job link", "Explain failure…", "Re-run this job"])
        XCTAssertEqual(m.command("Re-run this job"), .rerunJob(repo: "o/r", runId: "99", jobId: "5"))
        XCTAssertEqual(m.command("Explain failure…"), .explain(repo: "o/r", runId: "99", jobId: "5"))
        let ok = Job(id: "6", name: "lint", status: "completed", conclusion: "success", url: nil, startedAt: nil, completedAt: nil, runnerName: nil, steps: nil)
        XCTAssertFalse(RowMenu.job(repo: "o/r", run: done, job: ok, caps: all).titles.contains("Explain failure…"), "only a failed job")
        XCTAssertEqual(RowMenu.job(repo: "o/r", run: done, job: j, caps: []).titles, ["Open job on GitHub", "Copy job link"])
        let live = RowMenu.job(repo: "o/r", run: run(status: "in_progress", conclusion: nil), job: j, caps: all)
        XCTAssertFalse(live.titles.contains("Re-run this job"), "GitHub re-runs a job only after the run ends")
        XCTAssertNotEqual(live.last, .separator)
    }

    func testPRMenu() {
        let review = RowMenu.pr(repo: "o/r", pr: pr(mine: false), linkedKey: "SLING-7", caps: all)
        XCTAssertEqual(review.titles, ["Open on GitHub", "Copy link", "Copy branch name", "Copy checkout command", "Approve", "Merge…", "Open linked item"])
        XCTAssertEqual(review.command("Copy checkout command"), .copy("gh pr checkout 12 --repo o/r"))
        XCTAssertFalse(RowMenu.pr(repo: "o/r", pr: pr(mine: true), linkedKey: nil, caps: all).titles.contains("Approve"))
        XCTAssertFalse(RowMenu.pr(repo: "o/r", pr: pr(mine: false), linkedKey: nil, caps: []).titles.contains("Merge…"))
    }

    func testSessionMenu() {
        let card = Workspace(id: "c1", repo: "sling", path: "/w/sling", name: "sling-7", comment: nil, liveTerminals: 1, lastActivity: Date(), agents: [])
        let co = Checkout(path: "/w/.wt/sling-7", repo: "o/r", branch: "sling-7", head: "abc", key: "SLING-7", cardId: "c1")
        let m = RowMenu.session(card: card, key: "SLING-7", checkout: co, hasAgent: true, caps: all)
        XCTAssertEqual(m.titles, ["Open item", "Reveal in Orca", "Copy worktree path", "Copy branch name", "Show in Finder", "Open in Terminal", "Send input…"])
        XCTAssertEqual(m.command("Copy worktree path"), .copy("/w/.wt/sling-7"))
        let bare = RowMenu.session(card: card, key: nil, checkout: nil, hasAgent: false, caps: [])
        XCTAssertEqual(bare.titles, ["Copy worktree path", "Show in Finder", "Open in Terminal"])
    }

    func testInboxMenu() {
        let e = InboxEntry(id: "a1", source: .plane, title: "t", body: "b", at: Date(), unread: true, route: .item("SLING-7", .overview),
                           url: "https://plane/SLING-7", itemKey: "SLING-7", itemURL: "https://plane/SLING-7")
        let m = RowMenu.inbox(e, projectKey: "SLING", canTriage: true)
        XCTAssertEqual(m.titles, ["Open", "Open in Plane", "Mark as read", "Copy ID", "Copy link", "Only this project"])
        var read = e
        read.unread = false
        XCTAssertEqual(RowMenu.inbox(read, projectKey: nil, canTriage: false).command("Mark as unread"), .markRead(entryId: "a1", read: false))
    }

    func testSidebarMenu() {
        let p = ProjectSummary(ref: ref, identifier: "sling", title: "sling", url: "https://plane/sling", closed: false)
        let m = RowMenu.sidebarProject(p, hasTrackerIcon: false)
        XCTAssertEqual(m.titles, ["Open sling", "Project settings…", "Links and Orca workspace…", "Open in Plane", "Copy link",
                                  "Refresh project", "Set icon…", "Hide from sidebar"])
        XCTAssertEqual(m.command("Hide from sidebar"), .hideProject("SLING"))
        XCTAssertTrue(RowMenu.sidebarProject(p, hasTrackerIcon: true).titles.contains("Use tracker icon"))
    }

    func testTidyDropsExtraSeparators() {
        let list: [MenuEntry] = [.separator, .action("A", .copy("a")), .separator, .separator, .action("B", .copy("b")), .separator]
        XCTAssertEqual(list.tidy, [.action("A", .copy("a")), .separator, .action("B", .copy("b"))])
    }
}
