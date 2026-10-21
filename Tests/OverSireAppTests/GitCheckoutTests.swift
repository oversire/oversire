import XCTest
import OverSireCore
@testable import OverSireApp

/// GitCheckout against a real git repo in a temp folder.
final class GitCheckoutTests: XCTestCase {
    var root: URL!
    let runner = ProcessRunner()

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitcheckout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await sh("init", "-q", "-b", "main")
        try await sh("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "base")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func sh(_ args: String..., in dir: URL? = nil) async throws -> String {
        // A global reference-transaction hook can fail in a repo that git init makes.
        let out = try await runner.run(GitCheckout.git, ["-C", (dir ?? root).path, "-c", "core.hooksPath=/dev/null"] + args, stdin: nil, timeout: .seconds(20))
        XCTAssertEqual(out.status, 0, out.stderr)
        return String(decoding: out.stdout, as: UTF8.self)
    }

    func testStateBranchesAndRemove() async throws {
        let wt = root.appendingPathComponent("wt-a")
        try await sh("worktree", "add", "-q", "-b", "a", wt.path)
        try await sh("branch", "merged-b")
        try await sh("branch", "open-c")
        try await sh("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "c", in: nil)
        try await sh("checkout", "-q", "open-c")
        try await sh("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "own")
        try await sh("checkout", "-q", "main")

        let g = GitCheckout(path: wt.path, commands: runner)
        var s = try await g.state()
        XCTAssertEqual(s.branch, "a")
        XCTAssertEqual(s.base, "main")
        XCTAssertTrue(s.clean)
        try Data("x".utf8).write(to: wt.appendingPathComponent("f.txt"))
        s = try await g.state()
        XCTAssertEqual(s.dirty, 1)
        XCTAssertEqual(s.risk, "1 file with changes")
        let mainPath = try await g.mainCheckout()
        XCTAssertEqual(URL(fileURLWithPath: mainPath).resolvingSymlinksInPath().path, root.resolvingSymlinksInPath().path)

        let main = GitCheckout(path: root.path, commands: runner)
        let bs = Dictionary(uniqueKeysWithValues: try await main.branches(base: "main").map { ($0.name, $0) })
        XCTAssertEqual(bs["merged-b"]?.merged, true)
        XCTAssertEqual(bs["open-c"]?.merged, false)
        XCTAssertEqual(bs["a"]?.checkedOut, true)
        XCTAssertEqual(bs["merged-b"]?.checkedOut, false)

        do {
            try await main.removeWorktree(wt.path, force: false)
            XCTFail("git must refuse a worktree with changes")
        } catch {}
        try await main.removeWorktree(wt.path, force: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt.path))
        try await main.deleteBranch("merged-b")
        do {
            try await main.deleteBranch("open-c")
            XCTFail("git must refuse a branch that is not merged")
        } catch {}
    }
}
