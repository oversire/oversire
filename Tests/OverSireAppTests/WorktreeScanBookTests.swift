import XCTest
import OverSireCore
import OverSireSync
import OverSireTestKit
@testable import OverSireApp

final class WorktreeScanBookTests: XCTestCase {
    private func book(_ rig: EpicRig, _ src: FakeWorktreeSource) async -> WorktreeScanBook {
        await MainActor.run {
            WorktreeScanBook(sources: { [src] }, bindings: rig.d.bindings, binder: rig.d.binder,
                             known: { [store = rig.d.projectStore] in store.item(key: $0) != nil })
        }
    }

    private func info(_ path: String, repo: String = "/w/app", uncommitted: Int = 1, guess: WorktreeGuess? = nil) -> WorktreeInfo {
        WorktreeInfo(path: path, repo: repo, branch: "quick", base: "main", uncommitted: uncommitted, guess: guess)
    }

    func testAWorktreeInsideABoundFolderIsNotUnlinked() async throws {
        let rig = try await EpicRig()
        await MainActor.run {
            rig.d.bindings.seed(WorktreeBinding(key: "X-1", machine: "mbp", root: "/w", group: ".wt/x-1"))
        }
        let src = FakeWorktreeSource(machine: "mbp", [info("/w/.wt/x-1/app"), info("/w/.claude/worktrees/quick"),
                                                      info("/w/.claude/worktrees/clean", uncommitted: 0)])
        let b = await book(rig, src)
        await b.refresh()
        let paths = await MainActor.run { b.unlinked.map(\.info.path) }
        XCTAssertEqual(paths, ["/w/.claude/worktrees/quick"])
    }

    func testAPromptGuessOfAKnownKeyBindsButABranchGuessDoesNot() async throws {
        let rig = try await EpicRig()
        let k0 = rig.items[0].key, k1 = rig.items[1].key
        let src = FakeWorktreeSource(machine: "mbp", [info("/w/.claude/worktrees/a", guess: WorktreeGuess(key: k0, from: .prompt)),
                                                      info("/w/.claude/worktrees/b", guess: WorktreeGuess(key: k1, from: .branch)),
                                                      info("/w/.claude/worktrees/c", guess: WorktreeGuess(key: "NOPE-1", from: .cwd))])
        let b = await book(rig, src)
        await b.refresh()
        let (a, other, unknown, left) = await MainActor.run {
            (rig.d.bindings.binding(k0), rig.d.bindings.binding(k1), rig.d.bindings.binding("NOPE-1"), b.unlinked.map(\.info.path))
        }
        XCTAssertEqual(a?.dir, "/w/.claude/worktrees/a")
        XCTAssertEqual(a?.source, .auto)
        XCTAssertEqual(a?.branch, "quick")
        XCTAssertNil(other)
        XCTAssertNil(unknown)
        XCTAssertEqual(left, ["/w/.claude/worktrees/b", "/w/.claude/worktrees/c"])
        let row = await rig.row(.itemWorktreeBound)
        XCTAssertEqual(row?.actorType, .system)
    }

    func testNoAutoBindWhenThisAppMayNotAct() async throws {
        let rig = try await EpicRig()
        let k0 = rig.items[0].key
        await MainActor.run { rig.d.binder.mayAct = { false } }
        let src = FakeWorktreeSource(machine: "mbp", [info("/w/.claude/worktrees/a", guess: WorktreeGuess(key: k0, from: .cwd))])
        let b = await book(rig, src)
        await b.refresh()
        let bound = await MainActor.run { rig.d.bindings.binding(k0) }
        XCTAssertNil(bound)
    }

    func testTheStateSumsTheReposOfTheGroup() async throws {
        let rig = try await EpicRig()
        let bind = WorktreeBinding(key: "X-1", machine: "mbp", root: "/w", group: ".wt/x-1")
        let src = FakeWorktreeSource(machine: "mbp", [info("/w/.wt/x-1/app", uncommitted: 2), info("/w/.wt/x-1/cli", repo: "/w/cli", uncommitted: 3)])
        let b = await book(rig, src)
        await b.refresh()
        let (s, none) = await MainActor.run {
            (b.state(of: bind), b.state(of: WorktreeBinding(key: "X-2", machine: "mbp", root: "/w", group: ".wt/x-2")))
        }
        XCTAssertEqual(s?.uncommitted, 5)
        XCTAssertEqual(s?.exists, true)
        XCTAssertEqual(none?.exists, false)
    }

    func testTheLinkFolderIsTheGroupWhenTwoReposShareTheParent() {
        let all = [info("/w/.claude/quick/app"), info("/w/.claude/quick/cli", repo: "/w/cli"),
                   info("/w/.claude/worktrees/a"), info("/w/.claude/worktrees/b")]
        XCTAssertEqual(WorktreeScanBook.groupDir(all[0], in: all), "/w/.claude/quick")
        XCTAssertEqual(WorktreeScanBook.groupDir(all[2], in: all), "/w/.claude/worktrees/a")
    }

    func testAnOldDaemonIsMarked() async throws {
        let rig = try await EpicRig()
        let src = FakeWorktreeSource(machine: "mini")
        src.failure = ProviderError.notFound
        let b = await book(rig, src)
        await b.refresh()
        let old = await MainActor.run { b.old }
        XCTAssertEqual(old, ["mini"])
    }
}
