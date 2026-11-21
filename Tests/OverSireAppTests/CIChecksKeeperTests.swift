import XCTest
import OverSireCore
@testable import OverSireApp

@MainActor
final class CIChecksKeeperTests: XCTestCase {
    private let reader = FakeCIReader()
    private var touched: [[String]] = []
    private var now = CITestQuota.now

    private func keeper(quota: CIQuota? = nil) -> CIChecksKeeper {
        CIChecksKeeper(reader: reader, quota: quota ?? CITestQuota.make(), clock: { [unowned self] in self.now }, touch: { [unowned self] in self.touched.append($0) })
    }

    private func pr(_ n: Int, sha: String?) -> ChangeRequest {
        var p = ChangeRequest(number: n, title: "PR", state: "OPEN", author: .init(login: "me"), headRefName: "b", baseRefName: "main",
                              url: "https://github.com/o/r/pull/\(n)", createdAt: "2026-11-20T10:00:00Z", updatedAt: "2026-11-20T10:00:00Z",
                              reviewDecision: nil, additions: 0, deletions: 0, isDraft: false, labels: [], body: nil, mine: true)
        p.headSha = sha
        return p
    }

    private func checkDoc(_ k: CIChecksKeeper, _ sha: String) -> CIChecksDoc? {
        k.docs(nil).first { $0.id == "o/r/\(sha)" }.flatMap { try? MirrorCodec.value(CIChecksDoc.self, from: $0.body!) }
    }

    func testOpenPRHeadIsFetchedWithPRNumber() async {
        reader.setChecks("o/r", sha: "aaa", [CICheck(name: "vercel", app: "vercel", kind: .checkRun, state: .success)])
        let k = keeper()
        k.observe(runs: [], prs: [("o/r", [pr(7, sha: "aaa"), pr(8, sha: nil)])])
        await settle { checkDoc(k, "aaa") != nil }
        let d = try! XCTUnwrap(checkDoc(k, "aaa"))
        XCTAssertEqual(d.prs, [7])
        XCTAssertTrue(d.final)
        XCTAssertEqual(reader.count("checks"), 1)
    }

    func testFinalDocWithSameRunStampIsNotFetchedAgain() async {
        reader.setChecks("o/r", sha: "aaa", [CICheck(name: "vercel", kind: .checkRun, state: .success)])
        let k = keeper()
        let prs = [("o/r", [pr(7, sha: "aaa")])]
        let run = Run.ci(1, updated: "2026-11-21T11:50:00Z", sha: "aaa")
        k.observe(runs: [("o/r", [run])], prs: prs)
        await settle { checkDoc(k, "aaa") != nil }
        k.observe(runs: [("o/r", [run])], prs: prs)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reader.count("checks"), 1)
        k.observe(runs: [("o/r", [Run.ci(1, updated: "2026-11-21T11:55:00Z", sha: "aaa")])], prs: prs)
        await settle { reader.count("checks") == 2 }
        XCTAssertEqual(reader.count("checks"), 2, "a new run stamp fetches again")
    }

    func testPendingDocIsFetchedAgain() async {
        reader.setChecks("o/r", sha: "aaa", [CICheck(name: "vercel", kind: .status, state: .pending)])
        let k = keeper()
        k.observe(runs: [], prs: [("o/r", [pr(7, sha: "aaa")])])
        await settle { checkDoc(k, "aaa") != nil }
        XCTAssertEqual(checkDoc(k, "aaa")?.final, false)
        reader.setChecks("o/r", sha: "aaa", [CICheck(name: "vercel", kind: .status, state: .success)])
        k.observe(runs: [], prs: [("o/r", [pr(7, sha: "aaa")])])
        await settle { checkDoc(k, "aaa")?.final == true }
        XCTAssertEqual(checkDoc(k, "aaa")?.final, true)
    }

    func testRunCommitsAreActiveOrRecent() async {
        reader.setChecks("o/r", sha: "act", [CICheck(name: "x", kind: .status, state: .success)])
        reader.setChecks("o/r", sha: "new", [CICheck(name: "x", kind: .status, state: .success)])
        reader.setChecks("o/r", sha: "old", [CICheck(name: "x", kind: .status, state: .success)])
        let k = keeper()
        k.observe(runs: [("o/r", [
            Run.ci(1, status: "in_progress", conclusion: nil, updated: "2026-11-21T08:00:00Z", sha: "act"),
            Run.ci(2, updated: "2026-11-21T11:50:00Z", sha: "new"),
            Run.ci(3, updated: "2026-11-21T08:00:00Z", sha: "old"),
        ])], prs: [])
        await settle { k.docs(nil).count == 2 }
        XCTAssertEqual(Set(k.docs(nil).map(\.id)), ["o/r/act", "o/r/new"])
    }

    func testDegradedSkipsFetches() async {
        reader.setChecks("o/r", sha: "aaa", [CICheck(name: "x", kind: .status, state: .success)])
        let k = keeper(quota: CITestQuota.make(remaining: 10))
        k.observe(runs: [], prs: [("o/r", [pr(7, sha: "aaa")])])
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(reader.count("checks"), 0)
    }

    func testAtMostTwentyCommitsForEachRepo() async {
        var list: [ChangeRequest] = []
        for i in 1...25 {
            reader.setChecks("o/r", sha: "s\(i)", [CICheck(name: "x", kind: .status, state: .success)])
            list.append(pr(i, sha: "s\(i)"))
        }
        let k = keeper()
        k.observe(runs: [], prs: [("o/r", list)])
        await settle { k.docs(nil).count == 20 }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(k.docs(nil).count, 20)
    }

    func testPruneDropsCommitsNobodyNamed() async {
        reader.setChecks("o/r", sha: "aaa", [CICheck(name: "x", kind: .status, state: .success)])
        let k = keeper()
        k.observe(runs: [], prs: [("o/r", [pr(7, sha: "aaa")])])
        await settle { checkDoc(k, "aaa") != nil }
        touched = []
        k.prune(now: now.addingTimeInterval(23 * 3600))
        XCTAssertEqual(k.docs(nil).count, 1)
        k.prune(now: now.addingTimeInterval(25 * 3600))
        XCTAssertTrue(k.docs(nil).isEmpty)
        XCTAssertEqual(touched, [["o/r"]])
    }
}
