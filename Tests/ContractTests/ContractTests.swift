import XCTest
import OverSireCore
@testable import OverSireAI

/// Each file in Contract/fixtures decodes, encodes again and gives the same JSON.
final class ContractTests: XCTestCase {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Contract")

    // Fixture folder → Swift type. A new folder needs an entry here.
    static let types: [String: @Sendable (Data) throws -> Data] = [
        "provider-event": roundTrip(ProviderEvent.self),
        "subject-ref": roundTrip(SubjectRef.self),
        "item-patch": roundTrip(ItemPatch.self),
        "change-action": roundTrip(ChangeAction.self),
        "run-action": roundTrip(RunAction.self),
        "launch-request": roundTrip(LaunchRequest.self),
        "account": roundTrip(AccountConfig.self),
        "oversire-account": roundTrip(OverSireAccount.self),
        "pair-result": roundTrip(PairResult.self),
        "whoami": roundTrip(WhoAmI.self),
        "queue-lane": roundTrip(QueueLane.self),
        "queue-trigger": roundTrip(QueueTrigger.self),
        "ignored-failure": roundTrip(IgnoredFailure.self),
        "pin": roundTrip(Pin.self),
        "snooze": roundTrip(Snooze.self),
        "note": roundTrip(Note.self),
        "agent-link": roundTrip(AgentLink.self),
        "ai-task": roundTrip(AITask.self),
        "ai-result": roundTrip(AIResult.self),
        "queue-lane-state": roundTrip(QueueLaneState.self),
        "store-op": roundTrip(StoreOp.self),
        "job": roundTrip(AIJob.self),
        "job-run": roundTrip(AIJobRun.self),
        "suggestion": roundTrip(Suggestion.self),
        "work-order": roundTrip(WorkOrder.self),
        "memory-entry": roundTrip(MemoryEntry.self),
        "usage-row": roundTrip(UsageRow.self),
        "ledger-entry": roundTrip(LedgerEntry.self),
        "billing-state": roundTrip(BillingState.self),
        "runner-message": roundTrip(RunnerMessage.self),
        "runner-state": roundTrip(RunnerState.self),
        "runner-session": roundTrip(RunnerSession.self),
        "ai-endpoint": roundTrip(AIEndpoint.self),
        "ai-route": roundTrip(AIRoute.self),
        "item-relation": roundTrip(ItemRelation.self),
        "relation-patch": roundTrip(RelationPatch.self),
        "item-areas": roundTrip(ItemAreas.self),
        "planner-settings": roundTrip(PlannerSettings.self),
        "area-catalog": roundTrip(AreaCatalog.self),
        "area-claim": roundTrip(AreaClaim.self),
        "area-candidates": roundTrip(AreaCandidates.self),
        "changed-paths": roundTrip(ChangedPaths.self),
        "session-digest": roundTrip(SessionDigest.self),
        "daemon-session": roundTrip(DaemonSession.self),
        "daemon-sessions-page": roundTrip(DaemonSessionsPage.self),
        "daemon-question": roundTrip(DaemonQuestion.self),
        "daemon-questions-page": roundTrip(DaemonQuestionsPage.self),
        "daemon-answer-result": roundTrip(DaemonAnswerResult.self),
        "session-ask": roundTrip(SessionAsk.self),
        "ai-usage": roundTrip(AIUsage.self),
        "tool-spec": roundTrip(ToolSpec.self),
        "assistant-part": roundTrip(AssistantPart.self),
        "assistant-thread": roundTrip(AssistantThread.self),
        "assistant-message": roundTrip(AssistantMessage.self),
        "chat-event": roundTrip(ChatEvent.self),
        "session-ask-reply": roundTrip(SessionAskReply.self),
        "daemon-info": roundTrip(DaemonInfo.self),
        "group": roundTrip(Group.self),
        "group-invite": roundTrip(GroupInvite.self),
        "join-request": roundTrip(JoinRequest.self),
        "join-pending": roundTrip(JoinPending.self),
        "join-result": roundTrip(JoinResult.self),
        "person-detail": roundTrip(PersonDetail.self),
    ]

    // Schema file → x-oversire-schema. store.json is 2: QueueLane lost lastStarted and error.
    // jobs.json and suggestion.json are 2: the job kind and the proposal type sequence became plan.
    static let versions: [String: Int] = [
        "refs.json": 1, "provider-event.json": 1, "actions.json": 1, "ai-task.json": 1, "account.json": 1,
        "store.json": storeSchemaVersion, "jobs.json": jobsSchemaVersion, "suggestion.json": suggestionSchemaVersion, "work-order.json": workOrderSchemaVersion, "memory.json": 1,
        "billing.json": 1, "ai-endpoint.json": 1, "runner.json": 1, "session-digest.json": 1, "daemon.json": 1,
        "assistant.json": 1,
    ]

    static func roundTrip<T: Codable>(_: T.Type) -> @Sendable (Data) throws -> Data {
        { data in
            let dec = JSONDecoder()
            dec.dateDecodingStrategy = .iso8601
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return try enc.encode(dec.decode(T.self, from: data))
        }
    }

    func canonical(_ data: Data) throws -> Data {
        let obj = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        return try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }

    func testFixturesRoundTrip() throws {
        let fm = FileManager.default
        // claude-screens holds terminal screens for the parsers, not a wire type.
        let folders = try fm.contentsOfDirectory(atPath: Self.root.appendingPathComponent("fixtures").path)
            .filter { !$0.hasPrefix(".") && $0 != "claude-screens" }
        XCTAssertFalse(folders.isEmpty)
        var count = 0
        for folder in folders.sorted() {
            let rt = try XCTUnwrap(Self.types[folder], "no Swift type for fixtures/\(folder)")
            let dir = Self.root.appendingPathComponent("fixtures/\(folder)")
            for name in try fm.contentsOfDirectory(atPath: dir.path).filter({ $0.hasSuffix(".json") }).sorted() {
                let data = try Data(contentsOf: dir.appendingPathComponent(name))
                let back = try rt(data)
                XCTAssertEqual(String(decoding: try canonical(back), as: UTF8.self),
                               String(decoding: try canonical(data), as: UTF8.self), "\(folder)/\(name)")
                count += 1
            }
        }
        XCTAssertGreaterThan(count, 10)
    }

    func testSchemaFilesCarryTheVersion() throws {
        let dir = Self.root.appendingPathComponent("schema")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }
        XCTAssertEqual(Set(names), Set(Self.versions.keys))
        for name in names {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(name))) as? [String: Any])
            XCTAssertEqual(obj["$schema"] as? String, "https://json-schema.org/draft/2020-12/schema", name)
            XCTAssertEqual(obj["x-oversire-schema"] as? Int, Self.versions[name], name)
        }
    }

    func testEventsCarryTheSchemaNumber() throws {
        let dir = Self.root.appendingPathComponent("fixtures/provider-event")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".json") {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(name))) as? [String: Any])
            XCTAssertEqual(obj["schema"] as? Int, 1, name)
        }
    }

    func testDedupeKeyMatchesTheFixtures() throws {
        let dir = Self.root.appendingPathComponent("fixtures/suggestion")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".json") {
            let s = try dec.decode(Suggestion.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
            guard s.kind != .memoryUpkeep, s.kind != .digest else { continue }   // these keys name a topic, not a version
            XCTAssertEqual(s.dedupeKey, Suggestion.dedupeKey(subject: s.subject, kind: s.kind, version: s.subjectVersion), name)
        }
    }

    func testV1SequenceIsUnknown() throws {
        let url = Self.root.appendingPathComponent("fixtures/suggestion/v1-sequence.json")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let s = try dec.decode(Suggestion.self, from: Data(contentsOf: url))
        guard case .unknown(let type, _)? = s.proposal else { return XCTFail("v1 sequence must decode as unknown") }
        XCTAssertEqual(type, "sequence")
    }

    func testPlanFixtureLines() throws {
        let url = Self.root.appendingPathComponent("fixtures/suggestion/plan.json")
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard case .plan(let d)? = try dec.decode(Suggestion.self, from: Data(contentsOf: url)).proposal else { return XCTFail("no plan") }
        XCTAssertEqual(d.lines.count, 4)
        XCTAssertNil(d.order[0].after)
        let kept = d.dropping([1, 3])
        XCTAssertEqual(kept.order.count, 1)
        XCTAssertEqual(kept.relations.count, 1)
        XCTAssertTrue(kept.areas.isEmpty)
    }

    func testPromptFilesAreInTheApp() throws {
        let dir = Self.root.appendingPathComponent("prompts")
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".md") && $0 != "README.md" }
        XCTAssertEqual(Set(names.map { String($0.dropLast(3)) }), Set(PromptFiles.all.keys),
                       "run scripts/gen-prompts.sh")
        for name in names {
            let kind = String(name.dropLast(3))
            let text = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertEqual(PromptFiles.all[kind], text, "\(name) changed: run scripts/gen-prompts.sh")
            let t = try PromptTemplate(parsing: text)
            XCTAssertEqual(t.taskKind.rawValue, kind, name)
            // Each name in the templates is in the inputs list, and the other way round.
            let used = Set(text.matches(of: /\{\{(?:#if )?([A-Za-z]+)(?:\|trim)?\}\}/).map { String($0.1) })
            XCTAssertEqual(used, Set(t.inputs), name)
        }
        XCTAssertTrue(PromptFiles.all["draft"]!.contains("at most \(DraftSuggestion.maxTitle) characters"))
    }

    /// scripts/digest.py gives the digest of each transcript in fixtures/session-digest.
    func testDigestScriptMatchesTheFixtures() throws {
        let dir = Self.root.appendingPathComponent("fixtures/session-digest")
        let script = Self.root.deletingLastPathComponent().appendingPathComponent("scripts/digest.py")
        let cases = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("claude").path).filter { $0.hasSuffix(".jsonl") }
        XCTAssertGreaterThanOrEqual(cases.count, 5)
        for name in cases.sorted() {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", "-I", script.path, dir.appendingPathComponent("claude/\(name)").path]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            try XCTSkipIf(p.terminationStatus == 127, "no python3")
            let want = try Data(contentsOf: dir.appendingPathComponent(name.replacingOccurrences(of: ".jsonl", with: ".json")))
            XCTAssertEqual(String(decoding: try canonical(data), as: UTF8.self), String(decoding: try canonical(want), as: UTF8.self), name)
        }
    }
}
