import XCTest
import OverSireCore
import GitHubKit
import CIGitHubActions

/// Reads real runs, jobs and a log tail through the gh login. Run with OVERSIRE_LIVE=1.
final class ActionsLiveTests: XCTestCase {
    func testRunsJobsAndLog() async throws {
        guard ProcessInfo.processInfo.environment["OVERSIRE_LIVE"] == "1" else { throw XCTSkip("set OVERSIRE_LIVE=1") }
        let path = "slingdata-io/sling-cli"
        let ci = ActionsCI(owner: "slingdata-io", repos: [path],
                           client: GitHubClient(commands: LiveCommands(), http: NoRedirectHTTP()))
        let runs = try await ci.runs(RunQuery(repo: ci.repoRef(path), limit: 10))
        let done = try XCTUnwrap(runs.first { $0.phase == .completed })
        let ref = ci.runRef(path, id: done.id, attempt: done.attempt)
        let jobs = try await ci.jobs(ref)
        let job = try XCTUnwrap(jobs.first { $0.status == "completed" })
        let lines = try await ci.log(JobRef(run: ref, id: job.id), lines: 20)
        XCTAssertFalse(lines.isEmpty)
        let first = try await ci.poll(since: nil)
        let second = try await ci.poll(since: first.cursor)
        XCTAssertNotNil(second.budget)
    }
}

/// The app transport: the caller sees each redirect.
struct NoRedirectHTTP: HTTPTransport {
    final class Stop: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? { nil }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await URLSession.shared.data(for: request, delegate: Stop())
        return (data, resp as! HTTPURLResponse)
    }
}
