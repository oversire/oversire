import XCTest
import OverSireCore
import OverSireAI

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
        "queue-lane": roundTrip(QueueLane.self),
        "queue-trigger": roundTrip(QueueTrigger.self),
        "ignored-failure": roundTrip(IgnoredFailure.self),
        "pin": roundTrip(Pin.self),
        "snooze": roundTrip(Snooze.self),
        "note": roundTrip(Note.self),
        "agent-link": roundTrip(AgentLink.self),
        "ai-task": roundTrip(AITask.self),
        "ai-result": roundTrip(AIResult.self),
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
        XCTAssertEqual(Set(names), ["refs.json", "provider-event.json", "actions.json", "ai-task.json", "account.json", "store.json"])
        for name in names {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(name))) as? [String: Any])
            XCTAssertEqual(obj["$schema"] as? String, "https://json-schema.org/draft/2020-12/schema", name)
            XCTAssertEqual(obj["x-oversire-schema"] as? Int, ProviderEvent.schemaVersion, name)
        }
    }

    func testEventsCarryTheSchemaNumber() throws {
        let dir = Self.root.appendingPathComponent("fixtures/provider-event")
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) where name.hasSuffix(".json") {
            let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent(name))) as? [String: Any])
            XCTAssertEqual(obj["schema"] as? Int, 1, name)
        }
    }
}
