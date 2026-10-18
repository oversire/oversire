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
    ]

    // Schema file → x-oversire-schema. store.json is 2: QueueLane lost lastStarted and error.
    static let versions: [String: Int] = [
        "refs.json": 1, "provider-event.json": 1, "actions.json": 1, "ai-task.json": 1, "account.json": 1,
        "store.json": storeSchemaVersion, "jobs.json": 1, "suggestion.json": 1, "work-order.json": workOrderSchemaVersion, "memory.json": 1,
        "billing.json": 1, "ai-endpoint.json": 1, "runner.json": 1,
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
        let folders = try fm.contentsOfDirectory(atPath: Self.root.appendingPathComponent("fixtures").path).filter { !$0.hasPrefix(".") }
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
}
