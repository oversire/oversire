import XCTest
import OverSireCore
import OverSireTestKit
@testable import GitHubKit
@testable import CodeHostGitHub

final class CodeHostGitHubTests: XCTestCase {
    var gh: ReplayGH!
    var host: GitHubCodeHost!
    var repo: RepoRef { host.repoRef("acme/app") }

    override func setUp() {
        gh = ReplayGH()
        host = GitHubCodeHost(owner: "acme", repos: ["acme/app"],
                              client: GitHubClient(commands: gh, http: NoHTTP(), gh: "/bin/sh"))
    }

    func testParseCLIOutput() throws {
        let a = try XCTUnwrap(GitHubClient.parse(Data(answer("304 Not Modified", "", etag: "\"e1\"").utf8)))
        XCTAssertEqual(a.status, 304)
        XCTAssertEqual(a.etag, "\"e1\"")
        XCTAssertEqual(a.budget?.remaining, 4900)
        XCTAssertNil(GitHubClient.parse(Data("To get started with GitHub CLI, please run: gh auth login".utf8)))
    }

    func testCLIErrorsBeforeAnAnswer() {
        XCTAssertEqual(GitHubClient.error(stderr: "API rate limit exceeded. Authenticated requests get a higher rate limit"),
                       .rateLimited(retryAfter: nil), "rate limit wins over auth")
        XCTAssertEqual(GitHubClient.error(stderr: "To get started with GitHub CLI, please run:  gh auth login"), .unauthorized)
        XCTAssertEqual(GitHubClient.error(stderr: "GraphQL: Could not resolve to a Repository"), .notFound)
        XCTAssertEqual(GitHubClient.hint(.unauthorized), "Not authenticated. Run: gh auth login")
    }

    func testStatusMapping() async {
        gh.on("GET", "repos/acme/app/commits/abc", answer("403 Forbidden", #"{"message":"API rate limit exceeded"}"#, remaining: 0))
        do { _ = try await host.commitMessage(repo, sha: "abc"); XCTFail("no error") }
        catch { guard case ProviderError.rateLimited(let wait)? = error as? ProviderError else { return XCTFail("\(error)") }
                XCTAssertNotNil(wait) }
        gh.on("GET", "repos/acme/app/commits/abc", answer("422 Unprocessable Entity", #"{"message":"No commit found"}"#))
        do { _ = try await host.commitMessage(repo, sha: "abc"); XCTFail("no error") }
        catch { XCTAssertEqual(error as? ProviderError, .vendor(code: "422", message: "No commit found")) }
    }

    func testProbeAndCommitMessage() async throws {
        gh.on("GET", "user", answer("200 OK", #"{"login":"ada","id":42,"name":""}"#))
        let me = try await host.probe()
        XCTAssertEqual(me.person, PersonRef(id: "42", name: "ada", login: "ada"))
        gh.on("GET", "repos/acme/app/commits/abc", answer("200 OK", #"{"commit":{"message":"Fix it.\n\nBody\n"}}"#))
        let message = try await host.commitMessage(repo, sha: "abc")
        XCTAssertEqual(message, "Fix it.\n\nBody")
    }

    func testChangesPutReviewRequestsFirst() async throws {
        func pr(_ n: Int, _ title: String) -> String {
            #"{"number":\#(n),"title":"\#(title)","state":"OPEN","author":{"login":"bo"},"headRefName":"f","baseRefName":"main","url":"https://github.com/acme/app/pull/\#(n)","createdAt":"2026-10-16T10:00:00Z","updatedAt":"2026-10-16T11:00:00Z","reviewDecision":null,"additions":3,"deletions":1,"isDraft":false,"labels":{"nodes":[{"name":"bug","color":"d73a4a"}]},"body":"b"}"#
        }
        gh.on("POST", "graphql",
              answer("200 OK", #"{"data":{"search":{"nodes":[\#(pr(1, "Review me"))]}}}"#),
              answer("200 OK", #"{"data":{"search":{"nodes":[\#(pr(1, "Review me")),\#(pr(2, "Mine")),{}]}}}"#))
        let list = try await host.changes(repo, ChangeFilter(limit: 20))
        XCTAssertEqual(list.map(\.number), [1, 2])
        XCTAssertEqual(list.map(\.mine), [false, true])
        XCTAssertEqual(list[0].labels, [.init(name: "bug", color: "d73a4a")])
        let vars = gh.body(0)?["variables"] as? [String: Any]
        XCTAssertEqual(vars?["q"] as? String, "repo:acme/app is:pr is:open review-requested:@me")
        XCTAssertEqual(vars?["n"] as? Int, 20)
        XCTAssertEqual(gh.calls[0].args, ["api", "-i", "-X", "POST", "graphql", "--input", "-"], "the body goes through stdin")
    }

    func testEachChangeActionMakesOneRequest() {
        let c = ChangeRef(repo: repo, number: 7, url: URL(string: "https://github.com/acme/app/pull/7")!)
        func check(_ a: ChangeAction, _ method: String, _ path: String, _ body: NSDictionary, line: UInt = #line) {
            let r = GitHubCodeHost.request(a, on: c)
            XCTAssertEqual(r.method, method, line: line)
            XCTAssertEqual(r.path, path, line: line)
            XCTAssertEqual(r.body as NSDictionary, body, line: line)
        }
        check(.approve(nil), "POST", "repos/acme/app/pulls/7/reviews", ["event": "APPROVE"])
        check(.approve("LGTM"), "POST", "repos/acme/app/pulls/7/reviews", ["event": "APPROVE", "body": "LGTM"])
        check(.requestChanges("Fix x"), "POST", "repos/acme/app/pulls/7/reviews", ["event": "REQUEST_CHANGES", "body": "Fix x"])
        check(.comment("Hi"), "POST", "repos/acme/app/issues/7/comments", ["body": "Hi"])
        check(.merge(.squash), "PUT", "repos/acme/app/pulls/7/merge", ["merge_method": "squash"])
        check(.close, "PATCH", "repos/acme/app/pulls/7", ["state": "closed"])
    }

    func testPerformSendsTheBody() async throws {
        gh.on("PUT", "repos/acme/app/pulls/7/merge", answer("200 OK", #"{"merged":true}"#))
        try await host.perform(.merge(.rebase), on: ChangeRef(repo: repo, number: 7, url: URL(string: "https://github.com/acme/app/pull/7")!))
        XCTAssertEqual(gh.body()?["merge_method"] as? String, "rebase")
    }

    func testReposFollowPages() async throws {
        gh.on("POST", "graphql",
              answer("200 OK", #"{"data":{"repositoryOwner":{"repositories":{"nodes":[{"nameWithOwner":"acme/zed","isPrivate":true}],"pageInfo":{"hasNextPage":true,"endCursor":"c1"}}}}}"#),
              answer("200 OK", #"{"data":{"repositoryOwner":{"repositories":{"nodes":[{"nameWithOwner":"acme/app","isPrivate":false}],"pageInfo":{"hasNextPage":false}}}}}"#))
        let repos = try await host.repos()
        XCTAssertEqual(repos.map(\.ref.path), ["acme/app", "acme/zed"])
        XCTAssertEqual((gh.body(1)?["variables"] as? [String: Any])?["after"] as? String, "c1")
    }

    func testPollUsesETags() async throws {
        let path = "repos/acme/app/pulls?state=all&sort=updated&direction=desc&per_page=30"
        gh.on("GET", path, answer("200 OK", #"[{"number":1,"title":"Old","state":"open","html_url":"https://github.com/acme/app/pull/1","created_at":"2026-10-16T08:00:00Z","updated_at":"2026-10-16T10:00:00Z"}]"#, etag: "\"e1\""))
        let first = try await host.poll(since: nil)
        XCTAssertTrue(first.events.isEmpty, "the first poll sets the baseline")

        gh.on("GET", path, answer("304 Not Modified", "", etag: "\"e1\""))
        let quiet = try await host.poll(since: first.cursor)
        XCTAssertTrue(quiet.events.isEmpty)
        XCTAssertEqual(gh.calls.last?.args.suffix(2), ["-H", "If-None-Match: \"e1\""])

        gh.on("GET", path, answer("200 OK", #"[{"number":2,"title":"New","state":"open","user":{"login":"bo"},"html_url":"https://github.com/acme/app/pull/2","created_at":"2026-10-16T11:00:00Z","updated_at":"2026-10-16T11:00:00Z"},{"number":1,"title":"Old","state":"closed","merged_at":"2026-10-16T10:30:00Z","html_url":"https://github.com/acme/app/pull/1","created_at":"2026-10-16T08:00:00Z","updated_at":"2026-10-16T10:30:00Z"}]"#, etag: "\"e2\"", remaining: 100))
        let page = try await host.poll(since: quiet.cursor)
        XCTAssertEqual(page.events.map(\.action), ["merged", "opened"])
        XCTAssertEqual(page.events.last?.subject,
                       .change(ChangeRef(repo: repo, number: 2, url: URL(string: "https://github.com/acme/app/pull/2")!)))
        XCTAssertEqual(page.events.last?.summary?.actor, "bo")
        XCTAssertEqual(page.budget?.remaining, 100, "the scheduler gets the budget from the page")

        let again = try await host.poll(since: page.cursor)
        XCTAssertTrue(again.events.isEmpty, "no repeats")
    }

    func testTokenUsesHTTP() async throws {
        final class Recorder: HTTPTransport, @unchecked Sendable {
            var last: URLRequest?
            func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
                last = request
                return (Data(#"{"login":"ada","id":1}"#.utf8),
                        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let http = Recorder()
        let h = GitHubCodeHost(owner: "acme", client: GitHubClient(commands: gh, http: http, token: "t0k"))
        _ = try await h.probe()
        XCTAssertEqual(http.last?.url?.absoluteString, "https://api.github.com/user")
        XCTAssertEqual(http.last?.value(forHTTPHeaderField: "Authorization"), "Bearer t0k")
        XCTAssertTrue(gh.calls.isEmpty)
    }

    func testDescriptor() throws {
        struct Secrets: SecretReader { func secret(_ key: String) -> String? { nil } }
        let env = ProviderEnvironment(http: NoHTTP(), commands: gh, secrets: Secrets())
        let made = try GitHubCodeHost.descriptor.make(AccountConfig(account: AccountID(provider: .github, id: "acme"),
                                                                    values: ["repos": "acme/app, acme/web,"]), env)
        XCTAssertEqual((made as? GitHubCodeHost)?.repoPaths, ["acme/app", "acme/web"])
        XCTAssertEqual(made.account, AccountID(provider: .github, id: "acme"))
    }
}
