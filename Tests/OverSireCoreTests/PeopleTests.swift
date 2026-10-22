import XCTest
@testable import OverSireCore

final class PeopleTests: XCTestCase {
    func testOnePersonInPlaneAndGitHubWithTheSameEmailIsOneEntry() {
        let plane = [PersonDetail(id: "u1", name: "Ada", login: "ada.l", email: "Ada@Example.com", sources: ["plane:ocral"])]
        let github = [PersonDetail(id: "42", name: "ada", login: "ada-gh", email: "ada@example.com", sources: ["github:acme"]),
                      PersonDetail(id: "43", name: "bo", login: "bo", sources: ["github:acme"])]
        let out = PersonDetail.merge([plane, github])
        XCTAssertEqual(out, [PersonDetail(id: "u1", name: "Ada", login: "ada.l", email: "Ada@Example.com", sources: ["plane:ocral", "github:acme"]),
                             PersonDetail(id: "43", name: "bo", login: "bo", sources: ["github:acme"])])
    }

    func testTheLoginJoinsWhenAnEmailIsMissing() {
        let plane = [PersonDetail(id: "u1", name: "flarco", login: "flarco", email: "f@x.dev", sources: ["plane:ocral"])]
        let github = [PersonDetail(PersonRef(id: "7", name: "flarco", login: "FLARCO"), sources: ["github:acme"])]
        let machines = [PersonDetail(id: "m", name: "Fritz", login: "flarco", machines: ["studio", "air"]),
                        PersonDetail(id: "m2", name: "Fritz", login: "flarco", machines: ["air", "mini"])]
        let out = PersonDetail.merge([plane, github, machines])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].id, "u1", "the first entry gives the id")
        XCTAssertEqual(out[0].sources, ["plane:ocral", "github:acme"])
        XCTAssertEqual(out[0].machines, ["studio", "air", "mini"])
    }

    func testTwoEmailsKeepTwoPeopleWithOneLogin() {
        let out = PersonDetail.merge([[PersonDetail(id: "a", name: "sam", login: "sam", email: "sam@a.dev")],
                                      [PersonDetail(id: "b", name: "sam", login: "sam", email: "sam@b.dev")],
                                      [PersonDetail(id: "c", name: "sam", login: "sam")]])
        XCTAssertEqual(out.map(\.id), ["a", "b"])
        XCTAssertEqual(out.map(\.ref), [PersonRef(id: "a", name: "sam", login: "sam"), PersonRef(id: "b", name: "sam", login: "sam")])
    }

    func testAPersonCanJoinTwoEntries() {
        let out = PersonDetail.merge([[PersonDetail(id: "a", name: "Ada", email: "ada@x.dev", sources: ["plane:w"])],
                                      [PersonDetail(id: "b", name: "ada", login: "ada", sources: ["github:o"])],
                                      [PersonDetail(id: "c", name: "Ada", login: "ada", email: "ada@x.dev", machines: ["mac"])]])
        XCTAssertEqual(out, [PersonDetail(id: "a", name: "Ada", login: "ada", email: "ada@x.dev", sources: ["plane:w", "github:o"],
                                          machines: ["mac"])])
    }

    func testEmptyListsStayOutOfTheJSON() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let json = String(decoding: try enc.encode(PersonDetail(id: "1", name: "Ada")), as: UTF8.self)
        XCTAssertEqual(json, #"{"id":"1","name":"Ada"}"#)
        let back = try JSONDecoder().decode(PersonDetail.self, from: Data(json.utf8))
        XCTAssertEqual(back.sources, [])
    }
}
