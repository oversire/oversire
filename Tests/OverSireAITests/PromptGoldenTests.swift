import XCTest
import OverSireCore
@testable import OverSireAI

/// Each prompt renders the same text as the Swift prompt code before the move to Contract/prompts.
/// Golden/prompts.json holds that text. OVERSIRE_WRITE_GOLDEN=1 writes the file again.
final class PromptGoldenTests: XCTestCase {
    static let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Golden/prompts.json")

    struct Rendered: Codable, Equatable {
        var system: String
        var user: String
        var maxTokens: Int?
    }

    static let size = ProjectField(id: "FS", name: "Size", options: [StatusOption(id: "o1", name: "S", color: "GRAY"),
                                                                     StatusOption(id: "o2", name: "L", color: "GRAY")])

    static let cases: [(String, AITaskKind, AIInput)] = [
        ("ping", .ping, AIInput(text: "ping")),
        ("draft-full", .draft, DraftContext(projects: [("acme/1", "Board"), ("ocral/w1", "Fritz Tasks")], fields: [size])
            .input(body: "the note\nwith two lines", extra: "  Be brief.\n")),
        ("draft-bare", .draft, DraftContext().input(body: "n", extra: "")),
        ("draft-fields", .draft, DraftContext(fields: [size]).input(body: "n", extra: "   ")),
        ("draft-projects", .draft, DraftContext(projects: [("acme/1", "Board")]).input(body: "n", extra: "x")),
        ("tidy", .tidy, AIInput(text: "fix the  thing\n- a", context: ["extra": ""])),
        ("tidy-extra", .tidy, AIInput(text: "body", context: ["extra": "Use British English."])),
        ("check", .check, AgentPrompts.checkInput(key: "A-1", title: "T", quietMinutes: 12, phase: "working", ticking: true, ci: "none",
                                                  prOpen: true, status: "unknown", message: "Built the app.",
                                                  turn: (1...80).map { "l\($0)" }.joined(separator: "\n"))),
        ("check-no-pr", .check, AgentPrompts.checkInput(key: "B-2", title: "Fix {it}", quietMinutes: 3, phase: "waiting", ticking: false,
                                                        ci: "failed", prOpen: false, status: "In Progress", message: "", turn: "")),
        ("session-end", .sessionEnd, AgentPrompts.sessionEndInput(key: "C-3", title: "Ship", status: "In Progress",
                                                                  message: "I can't do the check. Tell me the result.", turn: "⏺ Done.\nTell me.")),
        ("session-end-no-message", .sessionEnd, AgentPrompts.sessionEndInput(key: "C-4", title: "T", status: "Done", message: "", turn: "ok")),
        ("order", .order, AgentPrompts.orderInput([QueueEntry(key: "P-1", title: "One", added: .distantPast),
                                                   QueueEntry(key: "P-2", title: "Two", added: .distantPast)],
                                                  bodies: ["P-1": String(repeating: "b", count: 700)])),
        ("order-vision", .order, AgentPrompts.orderInput([QueueEntry(key: "P-1", title: "One", added: .distantPast),
                                                          QueueEntry(key: "P-2", title: "Two", added: .distantPast)],
                                                         bodies: ["P-2": "body"], vision: "Small and native.", blockers: ["P-1": ["P-2"]])),
        ("session-summary", .sessionSummary, AgentPrompts.sessionInput(key: "K-1", title: "Title", transcript: "> hi\nok")),
        ("item-summary", .itemSummary, AgentPrompts.summaryInput(key: "K-1", title: "Title", body: "Line one.\n\n- a")),
        ("item-summary-long", .itemSummary, AgentPrompts.summaryInput(key: "K-2", title: "T", body: String(repeating: "x", count: 24_010))),
        ("question", .question, AgentPrompts.questionInput(transcript: "t", question: "Why?")),
        ("triage", .triage, AgentPrompts.triageInput(template: "Plan {KEY} ({key}): {title}\n{url}\n\n{body}\n{KEY}", key: "TREBI-9",
                                                     title: "T", url: "https://x/TREBI-9", body: "line one\nline two")),
        ("triage-vision", .triage, AgentPrompts.triageInput(template: "Plan {KEY}\n\n{vision}\n\n{body}", key: "TREBI-9",
                                                            title: "T", url: "u", body: "b", vision: "Small and native.")),
        ("triage-empty-body", .triage, AgentPrompts.triageInput(template: "{KEY} {key} {title} {url} {body}", key: "TREBI-9",
                                                                title: "T", url: "u", body: "")),
        ("triage-long-body", .triage, AgentPrompts.triageInput(template: "{body}", key: "K-1", title: "T", url: "u",
                                                               body: String(repeating: "x", count: 6100))),
        ("failure-reason", .failureReason, CIPrompts.failureInput(workflow: "CI", number: 9, branch: "main", sha: "abcdef12345",
                                                                  commit: "Fix", job: "build", files: ["a.swift", "b.swift"],
                                                                  errors: ["error: x"], tail: ["a", "b"])),
        ("failure-reason-no-files", .failureReason, CIPrompts.failureInput(workflow: "Release", number: 1, branch: "v1", sha: "12",
                                                                           commit: "Tag", job: "sign", files: [], errors: [], tail: [])),
        ("digest", .digest, CIPrompts.digestInput(facts: ["2 PRs wait for review", "CI on main is green"])),
    ]

    func testPromptsMatchTheGolden() throws {
        var got: [String: Rendered] = [:]
        for (name, kind, input) in Self.cases {
            let p = try kind.prompt(input)
            got[name] = Rendered(system: p.system, user: p.user, maxTokens: p.maxTokens)
        }
        if ProcessInfo.processInfo.environment["OVERSIRE_WRITE_GOLDEN"] == "1" {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            try enc.encode(got).write(to: Self.file)
            return
        }
        let want = try JSONDecoder().decode([String: Rendered].self, from: Data(contentsOf: Self.file))
        XCTAssertEqual(Set(got.keys), Set(want.keys))
        for (name, w) in want.sorted(by: { $0.key < $1.key }) {
            XCTAssertEqual(got[name]?.system, w.system, "\(name) system")
            XCTAssertEqual(got[name]?.user, w.user, "\(name) user")
            XCTAssertEqual(got[name]?.maxTokens, w.maxTokens, "\(name) maxTokens")
        }
    }
}
