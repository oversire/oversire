import XCTest
@testable import OverSireCore

final class AutopilotModelTests: XCTestCase {
    let project = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p1", key: "OVERSIRE")
    let other = ProjectRef(account: AccountID(provider: "plane", id: "ocral"), id: "p2", key: "SLING")
    let at = Date(timeIntervalSince1970: 1_800_000_000)

    func item(_ n: Int) -> ItemRef {
        ItemRef(project: project, id: "i\(n)", key: "OVERSIRE-\(n)", url: URL(string: "https://app.plane.so/ocral/browse/OVERSIRE-\(n)/")!)
    }

    func decode<T: Decodable>(_ t: T.Type, _ json: String) throws -> T {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(T.self, from: Data(json.utf8))
    }

    func encode<T: Encodable>(_ v: T) throws -> String {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try e.encode(v), as: UTF8.self)
    }

    func testMissingMemoryKindIsAFact() throws {
        let m = try decode(MemoryEntry.self, #"{"id":"m1","scope":"user","text":"x","source":"user","updatedAt":"2026-10-01T09:00:00Z"}"#)
        XCTAssertEqual(m.kind, .fact)
        XCTAssertFalse(try encode(m).contains("kind"), "a fact keeps the short form")
        let d = try decode(MemoryDraft.self, #"{"scope":"user","text":"x"}"#)
        XCTAssertEqual(d.kind, .fact)
    }

    func testVisionPicksTheEntryOfTheProject() {
        let fact = MemoryEntry(id: "m1", scope: .project, scopeRef: .project(project), text: "a fact", updatedAt: at)
        let mine = MemoryEntry.vision("true north", of: project, updatedAt: at)
        let theirs = MemoryEntry.vision("other north", of: other, updatedAt: at)
        XCTAssertEqual(mine.id, "vision-ocral/p1")
        XCTAssertEqual(MemoryEntry.vision(for: project, in: [fact, theirs, mine])?.text, "true north")
        XCTAssertEqual(MemoryEntry.vision(for: other, in: [fact, theirs, mine])?.text, "other north")
        XCTAssertNil(MemoryEntry.vision(for: project, in: [fact, theirs]))
    }

    func testUnknownRelationKindKeepsTheRawValue() throws {
        let r = try decode(ItemRelation.self, """
            {"kind":"startsAfter","item":{"project":{"account":{"provider":"plane","id":"ocral"},"id":"p1"},"id":"i1","key":"OVERSIRE-1","url":"https://x.dev/1"}}
            """)
        XCTAssertEqual(r.kind.rawValue, "startsAfter")
        XCTAssertEqual(r.kind.inverse, r.kind)
        XCTAssertEqual(RelationKind.blocks.inverse, .blockedBy)
        XCTAssertTrue(try encode(r).contains(#""kind":"startsAfter""#))
    }

    func testUnknownProposalRoundTrips() throws {
        let json = #"{"future":{"a":[1,2],"b":"x"},"type":"futureThing"}"#
        let p = try decode(Proposal.self, json)
        guard case .unknown(let type, _) = p else { return XCTFail("\(p)") }
        XCTAssertEqual(type, "futureThing")
        XCTAssertEqual(try encode(p), json)
    }

    func testUnknownWorkOrderStateKeepsTheRawValue() throws {
        let s = try decode(WorkOrder.State.self, #""paused""#)
        XCTAssertEqual(s.rawValue, "paused")
        XCTAssertEqual(try encode(s), #""paused""#)
        XCTAssertEqual(try decode(WorkOrder.State.self, #""held""#), .held)
    }

    func testAreaClean() {
        XCTAssertEqual(ItemAreas.clean(["Queue UI", "queue-ui", "a_b", "", String(repeating: "x", count: 33), "api"]), ["queue-ui", "api"])
        XCTAssertEqual(ItemAreas.clean((1...9).map { "a\($0)" }).count, 6)
        XCTAssertEqual(ItemAreas(item: item(4), areas: [], updatedAt: at).id, "ocral/p1/i4")
    }
}
