import XCTest
import OverSireCore
import OverSireTestKit
@testable import RuntimeOrca

/// Each screen in Contract/fixtures/claude-screens gives the form and the prompt of its .expect.json.
/// The Go parsers of the daemon check the same files. Set OVERSIRE_RECORD_SCREENS=1 to write the files again.
final class ClaudeScreensTests: XCTestCase {
    typealias F = OrcaFormsTests
    static let record = ProcessInfo.processInfo.environment["OVERSIRE_RECORD_SCREENS"] == "1"

    static func object<T: Encodable>(_ v: T) -> Any {
        try! JSONSerialization.jsonObject(with: JSONEncoder().encode(v))
    }

    static func expect(_ screen: [String]) -> [String: Any] {
        var d: [String: Any] = ["form": NSNull(), "prompt": NSNull()]
        if let f = ClaudeForm.parse(screen) {
            var form: [String: Any] = ["headers": f.headers, "items": object(f.items), "review": f.review]
            if let c = f.cursor, !c.isEmpty { form["cursor"] = c }
            if !f.boxes.isEmpty { form["boxes"] = Dictionary(uniqueKeysWithValues: f.boxes.map { (String($0.key), $0.value) }) }
            d["form"] = form
        }
        if let p = ClaudePrompt.parse(screen) {
            var prompt: [String: Any] = ["kind": p.kind == .plan ? "plan" : "permission", "title": p.title, "body": p.body,
                                         "question": p.question, "options": p.options.map { ["n": $0.n, "label": $0.label] },
                                         "amending": p.amending]
            if let c = p.cursor, !c.isEmpty { prompt["cursor"] = c }
            if let t = p.typed { prompt["typed"] = t }
            d["prompt"] = prompt
        }
        return d
    }

    static func json(_ obj: Any) -> Data {
        try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) + Data("\n".utf8)
    }

    func testScreensMatchTheExpectFiles() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: F.dir.path).filter { $0.hasSuffix(".txt") }.sorted()
        XCTAssertGreaterThan(names.count, 30)
        for name in names {
            let base = String(name.dropLast(".txt".count))
            let got = Self.expect(F.screen(base))
            let url = F.dir.appendingPathComponent(base + ".expect.json")
            if Self.record { try Self.json(got).write(to: url) }
            let want = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
            XCTAssertEqual(NSDictionary(dictionary: got), want as? NSDictionary, base)
        }
        for name in ["no-form-answered", "false-footer"] {
            XCTAssertTrue(Self.expect(F.screen(name))["form"] is NSNull, name)
        }
    }

    /// The answer and the keys of the flow files.
    struct Keys: Codable {
        struct Page: Codable {
            let first: Int
            let last: Int
            let answer: [QuestionAnswer.Item]
            let sends: [String]
        }
        let transcript: String
        let answer: [QuestionAnswer.Item]
        let sends: [String]
        let pages: [Page]
    }

    static func keys() throws -> Keys {
        try JSONDecoder().decode(Keys.self, from: Data(contentsOf: F.dir.appendingPathComponent("flow-\(F.v).keys.json")))
    }

    func testTheKeysFileHoldsTheRecordedFlow() throws {
        let k = try Self.keys()
        XCTAssertEqual(k.transcript, "ask-flow-open.jsonl")
        let down = FormKeys.down
        XCTAssertEqual(k.sends, ["2", "1", "4", down, down, down, "perf", down, "\r", "1"])
        XCTAssertEqual(k.pages.map(\.sends), [["2"], ["1", "4", down, down, down, "perf", down, "\r"], ["1"]])
    }
}
