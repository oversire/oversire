import XCTest
@testable import OverSireCore

final class RefsTests: XCTestCase {
    let plane = AccountID(provider: "plane", id: "ocral")
    let github = AccountID(provider: "github", id: "oversire")

    func roundTrip<T: Codable & Equatable>(_ v: T, file: StaticString = #filePath, line: UInt = #line) throws {
        let back = try JSONDecoder().decode(T.self, from: JSONEncoder().encode(v))
        XCTAssertEqual(back, v, file: file, line: line)
    }

    var subjects: [SubjectRef] {
        let project = ProjectRef(account: plane, id: "p1", key: "OVERSIRE")
        let item = ItemRef(project: project, id: "i1", key: "OVERSIRE-12", url: URL(string: "https://app.plane.so/ocral/browse/OVERSIRE-12/")!)
        let repo = RepoRef(account: github, path: "oversire/oversire", url: URL(string: "https://github.com/oversire/oversire")!)
        let change = ChangeRef(repo: repo, number: 12, url: URL(string: "https://github.com/oversire/oversire/pull/12")!)
        let run = RunRef(account: github, repo: repo, id: "123", attempt: 2)
        let job = JobRef(run: run, id: "456")
        let ws = WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: "card-1")
        let session = SessionRef(workspace: ws, id: "t1:l1")
        return [.project(project), .item(item), .repo(repo), .change(change), .run(run), .job(job), .workspace(ws), .session(session)]
    }

    func testEachRefRoundTrips() throws {
        for s in subjects {
            try roundTrip(s)
            switch s {
            case .project(let r): try roundTrip(r)
            case .item(let r): try roundTrip(r)
            case .repo(let r): try roundTrip(r)
            case .change(let r): try roundTrip(r)
            case .run(let r): try roundTrip(r)
            case .job(let r): try roundTrip(r)
            case .workspace(let r): try roundTrip(r)
            case .session(let r): try roundTrip(r)
            }
        }
        XCTAssertEqual(Set(subjects.map(\.kind)), Set(SubjectRef.Kind.allCases))
        try roundTrip(PersonRef(id: "u1", name: "Ada", login: "ada"))
        try roundTrip(RunRef(account: AccountID(provider: "buildkite", id: "acme"), repo: nil, id: "9"))
    }

    func testSubjectJSONShape() throws {
        let data = try JSONEncoder().encode(SubjectRef.workspace(WorkspaceRef(account: plane, id: "w")))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(obj?["kind"] as? String, "workspace")
        let ref = obj?["ref"] as? [String: Any]
        XCTAssertEqual((ref?["account"] as? [String: Any])?["provider"] as? String, "plane")
    }

    func testOpenIDsEncodeAsStrings() throws {
        XCTAssertEqual(String(data: try JSONEncoder().encode(ProviderID(rawValue: "github-actions")), encoding: .utf8), #""github-actions""#)
        XCTAssertEqual(String(data: try JSONEncoder().encode(AgentName.codex), encoding: .utf8), #""codex""#)
        XCTAssertEqual(try JSONDecoder().decode(AgentName.self, from: Data(#""claude""#.utf8)), .claude)
    }

    func testProjectRefKeyIsALabel() {
        let a = ProjectRef(account: plane, id: "p1", key: "OVERSIRE")
        let b = ProjectRef(account: plane, id: "p1")
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set([a, b]).count, 1)
        XCTAssertEqual(a.storeKey, "ocral/p1")
    }

    func testProjectRefDecodesTheCatEyeShape() throws {
        let old = #"{"workspace":"ocral","id":"p1","key":"ocral/p1"}"#
        let r = try JSONDecoder().decode(ProjectRef.self, from: Data(old.utf8))
        XCTAssertEqual(r.account, plane)
        XCTAssertNil(r.key)
        XCTAssertEqual(r.storeKey, "ocral/p1")
    }
}
