import XCTest
import OverSireCore
@testable import OverSireAI

final class GroomPromptTests: XCTestCase {
    private let block = """
        I read 142 items and the code.

        ```oversire-result
        {"proposals":[
          {"kind":"merge","keys":["OVERSIRE-402","OVERSIRE-398","OVERSIRE-329"],"keep":"OVERSIRE-402","title":"Row moves","reason":"Same cause.","confidence":"sure","description":"## Problem\\nThe row moves."},
          {"kind":"done","keys":["OVERSIRE-288"],"reason":"The ring shows.","evidence":["a41f9c2","PR #219"],"confidence":"sure"},
          {"kind":"obsolete","keys":["OVERSIRE-241"],"reason":"No remote Orca.","confidence":"maybe"},
          {"kind":"fold","keys":["OVERSIRE-371"],"parent":"OVERSIRE-285","reason":"Part of the terminal.","confidence":"sure"},
          {"kind":"relate","keys":["OVERSIRE-390"],"relation":{"kind":"blocked_by","key":"OVERSIRE-376"},"reason":"Same file.","confidence":"maybe"},
          {"kind":"vague","keys":["OVERSIRE-356"],"reason":"Only a title.","confidence":"sure"}
        ],"skipped":["OVERSIRE-311"],"findings":["11 groups."]}
        ```
        """

    func testGoodBlockWithAllKinds() throws {
        let r = try XCTUnwrap(GroomResult.parse(lastMessage: block))
        XCTAssertEqual(r.proposals.map(\.kind), GroomResult.Kind.all)
        XCTAssertEqual(r.skipped, ["OVERSIRE-311"])
        XCTAssertEqual(r.findings, ["11 groups."])
        let merge = r.proposals[0]
        XCTAssertEqual(merge.merged, ["OVERSIRE-398", "OVERSIRE-329"])
        XCTAssertEqual(merge.closes, 2)
        XCTAssertEqual(merge.description, "## Problem\nThe row moves.")
        XCTAssertEqual(merge.id, "merge:OVERSIRE-402,OVERSIRE-398,OVERSIRE-329")
        XCTAssertEqual(r.proposals[1].evidence, ["a41f9c2", "PR #219"])
        XCTAssertEqual(r.proposals[2].confidence, .maybe)
        XCTAssertEqual(r.proposals[4].relation?.relationKind, .blockedBy)
        XCTAssertTrue(r.proposals.allSatisfy(\.isApplicable))
        XCTAssertEqual(r.proposals.map(\.closes), [2, 1, 1, 0, 0, 0])
        XCTAssertEqual(r.openAfter(142, selected: Set(r.proposals.map(\.id))), 138)
        XCTAssertEqual(r.openAfter(142, selected: [r.proposals[1].id]), 141)
    }

    func testUnknownKindStaysAndCannotApply() throws {
        let r = try XCTUnwrap(GroomResult.parse(lastMessage: """
            ```oversire-result
            {"proposals":[{"kind":"split","keys":["K-1"],"reason":"two features","confidence":"maybe"},
                          {"kind":"done","keys":["K-2"],"reason":"r","confidence":"very"},
                          {"keys":["K-3"]}]}
            ```
            """))
        XCTAssertEqual(r.proposals.map(\.kind.rawValue), ["split", "done"], "a line with no kind drops")
        XCTAssertFalse(r.proposals[0].isApplicable)
        XCTAssertFalse(r.proposals[0].kind.isKnown)
        XCTAssertEqual(r.proposals[1].confidence, .maybe, "an unknown confidence is maybe")
    }

    func testTheRulesOfEachKind() {
        typealias P = GroomResult.Proposal
        XCTAssertFalse(P(kind: .merge, keys: ["K-1"], keep: "K-1", reason: "").isApplicable, "one key")
        XCTAssertFalse(P(kind: .merge, keys: ["K-1", "K-2"], keep: "K-3", reason: "").isApplicable, "keep is not in keys")
        XCTAssertTrue(P(kind: .merge, keys: ["K-1", "K-2"], keep: "k-2", reason: "").isApplicable)
        XCTAssertFalse(P(kind: .fold, keys: ["K-1"], reason: "").isApplicable, "no parent")
        XCTAssertFalse(P(kind: .fold, keys: ["K-1", "K-2"], parent: "K-3", reason: "").isApplicable)
        XCTAssertFalse(P(kind: .relate, keys: ["K-1"], relation: .init(kind: "duplicate", key: "K-2"), reason: "").isApplicable)
        XCTAssertTrue(P(kind: .relate, keys: ["K-1"], relation: .init(kind: "relates_to", key: "K-2"), reason: "").isApplicable)
        XCTAssertFalse(P(kind: .done, keys: [], reason: "").isApplicable)
    }

    func testAKeyThatIsNotInTheInput() throws {
        let r = try XCTUnwrap(GroomResult.parse(lastMessage: block))
        let input: Set<String> = ["OVERSIRE-402", "OVERSIRE-398", "OVERSIRE-288"]
        XCTAssertFalse(r.proposals[0].isApplicable(in: input), "OVERSIRE-329 is not in the input")
        XCTAssertTrue(r.proposals[1].isApplicable(in: input))
        XCTAssertEqual(r.proposals.count, 6, "the line stays in the result")
    }

    func testNoBlockReadsTheLastJSONObject() throws {
        let text = #"Here: {"note":"x"} and then {"proposals":[{"kind":"vague","keys":["K-1"],"reason":"short","confidence":"sure"}]} done."#
        let r = try XCTUnwrap(GroomResult.parse(lastMessage: text))
        XCTAssertEqual(r.proposals.map(\.keys), [["K-1"]])
        XCTAssertNil(GroomResult.parse(lastMessage: #"{"verdict":"clear","description":"d"}"#), "an Enhance result is not a Groom result")
    }

    func testAClippedMessageIsNil() {
        let clipped = String(block.prefix(block.count / 2))
        XCTAssertNil(GroomResult.parse(lastMessage: clipped))
        XCTAssertNil(GroomResult.parse(lastMessage: "I read the items."))
    }

    func testPromptRenders() {
        let input = GroomPrompt.input(project: "OVERSIRE", file: "/tmp/oversire/x/groom.jsonl", scope: .all, staleDays: 14,
                                      vision: "Small and native.", note: "142 items.")
        let text = GroomPrompt.render(GroomPrompt.template, input)
        XCTAssertTrue(text.hasPrefix("You groom the open items of project OVERSIRE. Do not change files."), text)
        XCTAssertTrue(text.contains("The file /tmp/oversire/x/groom.jsonl holds the open items of the intake and the backlog,"))
        XCTAssertTrue(text.contains("older than 14 days"))
        XCTAssertTrue(text.contains("```oversire-result\n"))
        XCTAssertTrue(text.contains("Project vision (the true north of the project):\nSmall and native."))
        XCTAssertTrue(text.hasSuffix("142 items."), text)

        let bare = GroomPrompt.render("", GroomPrompt.input(project: "K", file: "f", scope: .intake, staleDays: 7))
        XCTAssertFalse(bare.contains("Project vision"))
        XCTAssertFalse(bare.contains("{{"))
        XCTAssertTrue(bare.contains("open items of the intake, one JSON object"))
        XCTAssertTrue(bare.hasSuffix("Use simple English."), bare)
    }

    func testInputClipsTheBodyAndDropsTheOverSireBlock() throws {
        let markers = [("OverSire block ▾ (OverSire updates this part)", "OverSire block ▴")]
        let body = "Steps here.\n\nOverSire block ▾ (OverSire updates this part)\n- Session: done\nOverSire block ▴\n\nMore text."
        let i = GroomItem(key: "K-1", title: "T", body: body, state: "Todo", updated: Date(timeIntervalSince1970: 0), markers: markers)
        XCTAssertEqual(i.body, "Steps here.\n\n\n\nMore text.")
        let long = GroomItem(key: "K-2", title: "T", body: String(repeating: "x", count: 900), state: "Todo", updated: Date())
        XCTAssertEqual(long.body.count, GroomItem.bodyLimit + 1)
        XCTAssertTrue(long.body.hasSuffix("…"))

        let data = try GroomInput.jsonLines([i, long])
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix(#"{"areas":[],"body":"Steps here."#), String(lines[0]))
        XCTAssertTrue(lines[0].contains(#""updated":"1970-01-01T00:00:00Z""#))
    }

    func testInputHoldsAtMost200Items() {
        let items = (0...GroomInput.limit).map { GroomItem(key: "K-\($0)", title: "T", body: "", state: "Todo", updated: Date()) }
        XCTAssertThrowsError(try GroomInput.jsonLines(items)) { e in
            XCTAssertEqual(e as? GroomInput.TooMany, GroomInput.TooMany(count: 201))
            XCTAssertTrue("\(e)".contains("The scope has 201"))
        }
        XCTAssertNoThrow(try GroomInput.jsonLines(Array(items.prefix(200))))
    }
}
