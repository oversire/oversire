import XCTest
import OverSireCore
import OverSireTestKit
@testable import GitHubKit
@testable import CIGitHubActions

final class CIGitHubActionsTests: XCTestCase {
    var gh: ReplayGH!
    var ci: ActionsCI!
    var ref: RunRef { ci.runRef("acme/app", id: "77") }

    static let runJSON = #"""
        {"id":77,"name":"CI","display_title":"Fix the build","status":"completed","conclusion":"timed_out","head_branch":"main",
         "head_sha":"abc","event":"push","html_url":"https://github.com/acme/app/actions/runs/77","updated_at":"2026-10-16T10:05:00Z",
         "created_at":"2026-10-16T10:00:00Z","run_started_at":"2026-10-16T10:00:05Z","run_number":12,"run_attempt":2,"actor":{"login":"ada"}}
        """#

    override func setUp() {
        gh = ReplayGH()
        ci = ActionsCI(owner: "acme", repos: ["acme/app"], client: GitHubClient(commands: gh, http: NoHTTP(), gh: "/bin/sh"))
    }

    func testRunMapping() async throws {
        gh.on("GET", "repos/acme/app/actions/runs?per_page=5&branch=feat%2Fx", answer("200 OK", #"{"workflow_runs":["# + Self.runJSON + "]}"))
        let runs = try await ci.runs(RunQuery(repo: ci.repoRef("acme/app"), branch: "feat/x", limit: 5))
        let r = try XCTUnwrap(runs.first)
        XCTAssertEqual(r.id, "77")
        XCTAssertEqual(r.displayTitle, "Fix the build")
        XCTAssertEqual(r.workflowName, "CI")
        XCTAssertEqual(r.actorLogin, "ada")
        XCTAssertEqual(r.attempt, 2)
        XCTAssertEqual(r.startedAt, "2026-10-16T10:00:05Z")
        XCTAssertEqual(r.phase, .completed)
        XCTAssertEqual(r.outcome, .timedOut)

        gh.on("GET", "repos/acme/app/actions/runs/77", answer("200 OK", Self.runJSON))
        let one = try await ci.run(ref)
        XCTAssertEqual(one.number, 12)
    }

    func testStatusEnums() {
        func run(_ status: String, _ conclusion: String?) -> Run {
            Run(id: "1", name: "n", displayTitle: "t", status: status, conclusion: conclusion, headBranch: "", headSha: "", event: "",
                url: "", updatedAt: "", createdAt: "", startedAt: nil, number: 1, workflowName: nil, actorLogin: nil)
        }
        XCTAssertEqual(run("in_progress", nil).phase, .running)
        XCTAssertEqual(run("waiting", nil).phase, .queued, "other GitHub states count as queued")
        XCTAssertNil(run("in_progress", nil).outcome)
        XCTAssertEqual(run("completed", "startup_failure").outcome, .startupFailure)
    }

    func testJobsAndFailures() async throws {
        gh.on("GET", "repos/acme/app/actions/runs/77/jobs?per_page=100", answer("200 OK", #"""
            {"jobs":[{"id":9,"name":"test","status":"completed","conclusion":"failure","html_url":"https://github.com/acme/app/actions/runs/77/job/9",
              "runner_name":"r1","steps":[{"name":"Checkout","status":"completed","conclusion":"success"},
                                          {"name":"Run tests","status":"completed","conclusion":"failure"}]},
                     {"id":10,"name":"lint","status":"completed","conclusion":"success","steps":[]}]}
            """#))
        gh.on("GET", "repos/acme/app/check-runs/9/annotations", answer("200 OK", #"""
            [{"message":"expected 1, got 2","path":"pkg/a_test.go","start_line":14,"annotation_level":"failure"},
             {"message":"Node 16 is old","path":".github","annotation_level":"warning"},
             {"message":"Process completed with exit code 1.","path":".github","start_line":1,"annotation_level":"failure"}]
            """#))
        let jobs = try await ci.jobs(ref)
        XCTAssertEqual(jobs.map(\.id), ["9", "10"])
        XCTAssertEqual(jobs[0].runnerName, "r1")
        XCTAssertEqual(jobs[0].steps?.count, 2)

        let f = try await ci.failures(ref)
        XCTAssertEqual(f, [Failure(job: "test", step: "Run tests",
                                   messages: ["pkg/a_test.go:14\nexpected 1, got 2", "Process completed with exit code 1."])])
    }

    func testPerform() async throws {
        XCTAssertEqual(try ActionsCI.request(.rerun, on: ref).path, "repos/acme/app/actions/runs/77/rerun")
        XCTAssertEqual(try ActionsCI.request(.rerunFailed, on: ref).path, "repos/acme/app/actions/runs/77/rerun-failed-jobs")
        XCTAssertEqual(try ActionsCI.request(.cancel, on: ref).path, "repos/acme/app/actions/runs/77/cancel")
        XCTAssertThrowsError(try ActionsCI.request(.rerun, on: RunRef(account: ci.account, repo: nil, id: "1")))

        gh.on("POST", "repos/acme/app/actions/runs/77/cancel", answer("202 Accepted", "{}"))
        try await ci.perform(.cancel, on: ref)
        XCTAssertEqual(gh.calls.last?.args.prefix(5), ["api", "-i", "-X", "POST", "repos/acme/app/actions/runs/77/cancel"])
    }

    func testPoll() async throws {
        let path = "repos/acme/app/actions/runs?per_page=20"
        func runs(_ status: String, _ updated: String) -> String {
            #"{"workflow_runs":[{"id":77,"name":"CI","status":""# + status + #"","run_attempt":1,"updated_at":""# + updated + #""}]}"#
        }
        gh.on("GET", path, answer("200 OK", runs("in_progress", "2026-10-16T10:00:00Z"), etag: "\"e1\""))
        let first = try await ci.poll(since: nil)
        XCTAssertTrue(first.events.isEmpty, "the first poll sets the baseline")
        XCTAssertTrue(first.busy)

        gh.on("GET", path, answer("304 Not Modified", "", etag: "\"e1\""))
        let quiet = try await ci.poll(since: first.cursor)
        XCTAssertTrue(quiet.busy, "a 304 keeps the busy state")
        XCTAssertEqual(quiet.budget?.remaining, 4900)

        gh.on("GET", path, answer("200 OK", runs("completed", "2026-10-16T10:04:00Z"), etag: "\"e2\""))
        let page = try await ci.poll(since: quiet.cursor)
        XCTAssertFalse(page.busy)
        XCTAssertEqual(page.events.map(\.action), ["completed"])
        XCTAssertEqual(page.events.first?.subject, .run(ref))
        XCTAssertEqual(page.events.first?.kind, .run)

        let again = try await ci.poll(since: page.cursor)
        XCTAssertTrue(again.events.isEmpty, "no repeats")
    }

    func testLogTailKeepsTheTokenOnTheAPIHost() async throws {
        let http = RecordedHTTP()
        let blob = "https://results.example.net/logs/9.txt"
        http.on("GET", "https://api.github.com/repos/acme/app/actions/jobs/9/logs", 302, headers: ["Location": blob])
        http.on("HEAD", blob, 200, headers: ["Content-Length": "40000"])
        http.on("GET", blob, 206, "art of a line\n2026-10-16T10:00:00.1Z ##[group]Run x\n2026-10-16T10:00:01.2Z FAIL pkg\n" +
                "2026-10-16T10:00:01.3Z ##[error]Process completed with exit code 1.\n")
        let c = ActionsCI(owner: "acme", client: GitHubClient(commands: gh, http: http, token: "t0k"))
        let lines = try await c.log(JobRef(run: c.runRef("acme/app", id: "77"), id: "9"), lines: 5)
        XCTAssertEqual(lines, ["FAIL pkg", "##[error]Process completed with exit code 1."])

        XCTAssertEqual(http.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        for r in http.requests.dropFirst() {
            XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"), "no token for \(r.url!)")
        }
        XCTAssertEqual(http.requests.last?.value(forHTTPHeaderField: "Range"), "bytes=\(40000 - ActionsCI.tailBytes)-")
    }

    func testRedirectStaysOnTheAPIHost() async throws {
        let http = RecordedHTTP()
        http.on("GET", "https://api.github.com/repos/old/app", 301, headers: ["Location": "https://api.github.com/repositories/5"])
        http.on("GET", "https://api.github.com/repositories/5", 200, #"{"id":5}"#)
        http.on("GET", "https://api.github.com/repos/evil/app", 301, headers: ["Location": "https://evil.example.com/x"])
        let client = GitHubClient(commands: gh, http: http, token: "t0k")
        let moved = try await client.json("GET", "repos/old/app") as? [String: Any]
        XCTAssertEqual(moved?["id"] as? Int, 5)
        do {
            _ = try await client.api("GET", "repos/evil/app")
            XCTFail("an other host must not get the request")
        } catch {}
        XCTAssertFalse(http.requests.contains { $0.url?.host == "evil.example.com" })
    }

    func testLogHelpers() {
        let log = "2026-10-01T23:14:09.48Z FAIL\tpkg\t300s\n2026-10-01T23:14:11.29Z ##[error]Process completed with exit code 1.\n" +
            "2026-10-01T23:14:11.32Z Post job cleanup.\n"
        XCTAssertEqual(ActionsCI.errorSnippet(log), "FAIL\tpkg\t300s\n##[error]Process completed with exit code 1.", "the snippet ends at the error")
        XCTAssertEqual(ActionsCI.clean("2026-10-01T23:14:09.48Z \u{1B}[32mok\u{1B}[0m pkg\n##[group]Run x\n\n[90m12:00[0m INF done\n"),
                       ["ok pkg", "12:00 INF done"])
        XCTAssertTrue(ActionsCI.isError("##[error]boom") && ActionsCI.isError("--- FAIL: TestX") && ActionsCI.isError("panic: nil map"))
        XCTAssertFalse(ActionsCI.isError("ok  pkg 0.3s") || ActionsCI.isError("errors are fine"))
        let long = (1...40).map { "line \($0)" }.joined(separator: "\n")
        XCTAssertEqual(ActionsCI.errorSnippet(long).split(separator: "\n").count, ActionsCI.snippetLines, "no marker gives the last lines")
    }

    func testDescriptor() throws {
        struct Secrets: SecretReader { func secret(_ key: String) -> String? { nil } }
        let env = ProviderEnvironment(http: NoHTTP(), commands: gh, secrets: Secrets())
        let made = try ActionsCI.descriptor.make(AccountConfig(account: AccountID(provider: .githubActions, id: "acme"),
                                                               values: ["repos": "acme/app, acme/web"]), env)
        XCTAssertEqual((made as? ActionsCI)?.repoPaths, ["acme/app", "acme/web"])
        XCTAssertEqual(ActionsCI.descriptor.layer, .ci)
    }
}
