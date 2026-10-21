import XCTest
import OverSireCore
@testable import OverSireApp

final class CleanupPlanTests: XCTestCase {
    let known: Set<String> = ["OVERSIRE"]
    let clean = CheckoutState(branch: "oversire-196", dirty: 0, ahead: 0, base: "main")

    func card(_ id: String, path: String, kind: Workspace.Kind = .worktree, agents: [AgentSession] = []) -> Workspace {
        Workspace(id: id, repo: "oversire", path: path, name: "oversire-196", comment: nil, liveTerminals: 0, lastActivity: .distantPast,
                  agents: agents, kind: kind, branch: "oversire-196")
    }

    func pr(_ n: Int, _ state: String, head: String = "oversire-196") -> ChangeRequest {
        ChangeRequest(number: n, title: "t", state: state, author: .init(login: "me"), headRefName: head, baseRefName: "main",
                      url: "https://github.com/o/r/pull/\(n)", createdAt: "", updatedAt: "", reviewDecision: nil, additions: 0, deletions: 0,
                      isDraft: false, labels: [], body: nil)
    }

    func testSafeWorktreeAndBranches() {
        var f = CleanupFacts()
        f.states["/orca/oversire-196"] = clean
        f.branches["/src/oversire"] = [GitBranch(name: "oversire-196", merged: true, checkedOut: true),
                                       GitBranch(name: "OVERSIRE-196-old", merged: true, checkedOut: false),
                                       GitBranch(name: "oversire-196-wip", merged: false, checkedOut: false),
                                       GitBranch(name: "other", merged: true, checkedOut: false)]
        f.bases["/src/oversire"] = "main"
        f.remotes["/src/oversire"] = ["oversire-196", "OVERSIRE-196-old", "main"]
        f.repos["/src/oversire"] = "o/r"
        f.pulls["o/r|oversire-196"] = [pr(9, "MERGED")]
        f.pulls["o/r|OVERSIRE-196-old"] = [pr(8, "CLOSED")]
        let w = card("c1", path: "/orca/oversire-196")
        let co = Checkout(path: "/orca/oversire-196", repo: "o/r", branch: "oversire-196", head: "a", key: "OVERSIRE-196", cardId: "c1")
        let lines = Cleaner.plan(key: "OVERSIRE-196", cards: [w], checkouts: [co], openPRs: [], facts: f, known: known)
        XCTAssertEqual(lines.map(\.kind), [.worktree, .localBranch, .remoteBranch])
        XCTAssertTrue(lines.allSatisfy(\.safe))
        XCTAssertEqual(lines[1].action, .localBranch(main: "/src/oversire", name: "OVERSIRE-196-old"))
        XCTAssertEqual(lines[2].action, .remoteBranch(repo: "o/r", name: "oversire-196", main: "/src/oversire"), "a closed PR keeps the remote branch")
    }

    func testRisksAndLookLines() {
        var f = CleanupFacts()
        f.states["/orca/a"] = CheckoutState(branch: "oversire-196", dirty: 3, ahead: 0, base: "main")
        f.remotes["/src/oversire"] = ["oversire-196"]
        f.repos["/src/oversire"] = "o/r"
        f.pulls["o/r|oversire-196"] = [pr(7, "OPEN"), pr(6, "MERGED")]
        let working = AgentSession(phase: .working, since: .distantPast, card: "c2", paneKey: "p")
        let lines = Cleaner.plan(key: "OVERSIRE-196", cards: [card("c1", path: "/orca/a"), card("c2", path: "/orca/b", agents: [working]),
                                                               card("c3", path: "/src/oversire", kind: .main)],
                                 checkouts: [], openPRs: [("o/r", pr(7, "OPEN")), ("o/r", pr(5, "OPEN", head: "x"))], facts: f, known: known)
        XCTAssertEqual(lines.map(\.kind), [.worktree, .session, .pr, .pr], "the main checkout never shows; an open PR shows once")
        XCTAssertFalse(lines[0].safe)
        XCTAssertTrue(lines[0].detail.contains("3 files with changes"))
        XCTAssertEqual(lines[1].action, .none)
        XCTAssertEqual(lines[2].url, "https://github.com/o/r/pull/7")
        XCTAssertFalse(lines.contains { $0.kind == .remoteBranch }, "an open PR keeps the remote branch")
    }

    func testFolderCardAndGroup() {
        var f = CleanupFacts()
        f.states["/ws/.wt/oversire-196/oversire"] = clean
        f.states["/ws/.wt/oversire-196/cloud"] = CheckoutState(branch: "oversire-196", dirty: 0, ahead: 2, base: "main")
        let folder = card("r::/ws::workspace:u", path: "/ws", kind: .folder)
        let cos = ["oversire", "cloud"].map { Checkout(path: "/ws/.wt/oversire-196/\($0)", repo: "", branch: "oversire-196", head: "a",
                                                       key: "OVERSIRE-196", cardId: folder.id) }
        let lines = Cleaner.plan(key: "OVERSIRE-196", cards: [folder], checkouts: cos, openPRs: [], facts: f, known: known)
        XCTAssertEqual(lines.map(\.kind), [.card, .group])
        XCTAssertTrue(lines[0].safe)
        XCTAssertEqual(lines[1].action, .group(path: "/ws/.wt/oversire-196", worktrees: ["/ws/.wt/oversire-196/cloud", "/ws/.wt/oversire-196/oversire"]))
        XCTAssertFalse(lines[1].safe)
        XCTAssertTrue(lines[1].detail.contains("cloud: 2 commits not in main"))

        f.states["/ws/.wt/oversire-196/cloud"] = clean
        let ok = Cleaner.plan(key: "OVERSIRE-196", cards: [folder], checkouts: cos, openPRs: [], facts: f, known: known)
        XCTAssertTrue(ok[1].safe)
        XCTAssertFalse(Cleaner.plan(key: "OVERSIRE-196", cards: [folder], checkouts: Array(cos.prefix(1)), openPRs: [], facts: CleanupFacts(),
                                    known: known)[1].safe, "a group that git did not check is not safe")
    }

    func testRemoveGroupKeepsFilesAndRemovesLinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("group-\(UUID().uuidString)")
        let group = root.appendingPathComponent(".wt/t")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("docs")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: target.appendingPathComponent("a.md"))
        try FileManager.default.createSymbolicLink(at: group.appendingPathComponent("docs"), withDestinationURL: target)
        try Data("x".utf8).write(to: group.appendingPathComponent("notes.txt"))
        defer { try? FileManager.default.removeItem(at: root) }

        do {
            try await Cleaner.removeGroup(group.path, worktrees: [], force: false, facts: CleanupFacts(), commands: ProcessRunner())
            XCTFail("a folder with a file must stay")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: group.appendingPathComponent("notes.txt").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.md").path), "the link target stays")
        try FileManager.default.removeItem(at: group.appendingPathComponent("notes.txt"))
        try await Cleaner.removeGroup(group.path, worktrees: [], force: false, facts: CleanupFacts(), commands: ProcessRunner())
        XCTAssertFalse(FileManager.default.fileExists(atPath: group.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("a.md").path))
    }

    func testConfigDefaults() throws {
        let c = try JSONDecoder().decode(CleanupConfig.self, from: Data("{}".utf8))
        XCTAssertEqual(c, CleanupConfig())
        XCTAssertFalse(c.auto)
        XCTAssertEqual(c.waitMinutes, 60)
        XCTAssertTrue(c.onlyOurs)
        XCTAssertFalse(c.runHooks)
        XCTAssertEqual(CleanupConfig.waits.map(CleanupConfig.waitText), ["15 minutes", "1 hour", "1 day", "1 week"])
    }
}
