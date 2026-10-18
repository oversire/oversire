import OverSireCore
import XCTest

final class PlannerModelTests: XCTestCase {
    private let project = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "OVERSIRE")

    private func ref(_ n: Int) -> ItemRef {
        ItemRef(project: project, id: "i\(n)", key: "OVERSIRE-\(n)", url: URL(string: "https://app.plane.so/ocral/browse/OVERSIRE-\(n)/")!)
    }

    func testGlob() {
        let table: [(String, String, Bool)] = [
            ("Sources/OverSireCore/Store*.swift", "Sources/OverSireCore/Store.swift", true),
            ("Sources/OverSireCore/Store*.swift", "Sources/OverSireCore/StoreWrites.swift", true),
            ("Sources/OverSireCore/Store*.swift", "Sources/OverSireCore/sub/Store.swift", false),
            ("Contract/**", "Contract/schema/store.json", true),
            ("Contract/**", "Contract", false),
            ("**/README.md", "README.md", true),
            ("**/README.md", "docs/a/README.md", true),
            ("src/*.ts", "src/hub.ts", true),
            ("src/*.ts", "src/ai/prompts.ts", false),
            ("src/?ub.ts", "src/hub.ts", true),
            ("a.b", "axb", false),
        ]
        for (g, path, want) in table { XCTAssertEqual(Glob(g).matches(path), want, "\(g) ~ \(path)") }
    }

    func testCatalogAreaOf() {
        let c = AreaCatalog(project: project.storeKey, areas: [
            AreaDef(name: "graph-store", kind: .core, rules: [AreaRule(glob: "Sources/OverSireCore/**", source: .graph)]),
            AreaDef(name: "learned-store", kind: .core, rules: [AreaRule(glob: "Sources/OverSireCore/Store*.swift", source: .learned)]),
            AreaDef(name: "first", kind: .feature, rules: [AreaRule(glob: "docs/**", source: .user)]),
            AreaDef(name: "second", kind: .feature, rules: [AreaRule(glob: "docs/*.md", source: .user)]),
            AreaDef(name: "user-store", kind: .core, rules: [AreaRule(glob: "Sources/OverSireCore/StoreWrites.swift", source: .user)]),
            AreaDef(name: "new", kind: .core, rules: [AreaRule(glob: "x/**", source: .user)], proposed: true),
        ], updatedAt: Date())
        XCTAssertEqual(c.area(of: "Sources/OverSireCore/StoreWrites.swift")?.name, "user-store", "user before learned")
        XCTAssertEqual(c.area(of: "Sources/OverSireCore/Store.swift")?.name, "learned-store", "learned before graph")
        XCTAssertEqual(c.area(of: "Sources/OverSireCore/Refs.swift")?.name, "graph-store")
        XCTAssertEqual(c.area(of: "docs/planner.md")?.name, "first", "the first match wins")
        XCTAssertNil(c.area(of: "x/a.swift"), "a proposed area does not match")
        XCTAssertNil(c.area(of: "Package.swift"))
        XCTAssertEqual(c.kind(of: "first"), .feature)
        XCTAssertEqual(c.kind(of: "nope"), .core)
        XCTAssertTrue(AreaKind(rawValue: "strange").isCore)
    }

    func testOverlapsOnlyInTheSameColumn() {
        let kind: (String) -> AreaKind = { $0 == "ui" ? .feature : .core }
        let one = PlanBoard(cards: [.init(key: "A", areas: ["core"]), .init(key: "B", areas: ["core"])], slots: 2)
        XCTAssertEqual(one.overlaps(kind: kind), 3)
        XCTAssertEqual(one.clashes(kind: kind)["A"]?.other, "B")
        let two = PlanBoard(cards: [.init(key: "A", areas: ["core"]), .init(key: "B", areas: ["core"])], slots: 1)
        XCTAssertEqual(two.overlaps(kind: kind), 0)
        XCTAssertTrue(two.clashes(kind: kind).isEmpty)
        let feature = PlanBoard(cards: [.init(key: "A", areas: ["ui"]), .init(key: "B", areas: ["ui", "x"]), .init(key: "C", areas: ["x"])], slots: 3)
        XCTAssertEqual(feature.overlaps(kind: kind), 1 + 3)
        XCTAssertEqual(feature.clashes(kind: kind)["B"]?.area, "x", "a core area wins")
        let later = PlanBoard(cards: (0..<5).map { .init(key: "K\($0)", areas: ["core"]) }, slots: 2)
        XCTAssertEqual(later.cards(.later).map(\.key), ["K4"])
        XCTAssertEqual(later.overlaps(kind: kind), 6, "Later does not count")
    }

    func testRunningCardsFillNow() {
        let b = PlanBoard(cards: [.init(key: "Q", areas: []), .init(key: "R1", areas: [], running: true), .init(key: "R2", areas: [], running: true)], slots: 1)
        XCTAssertEqual(b.cards(.now).map(\.key), ["R1", "R2"])
        XCTAssertEqual(b.cards(.next).map(\.key), ["Q"])
    }

    func testPlanOrder() {
        let d = PlanDraft(order: [PlanDraft.OrderLine(item: ref(3), lane: "l", after: nil, reason: ""),
                                  PlanDraft.OrderLine(item: ref(1), lane: "l", after: ref(2), reason: ""),
                                  PlanDraft.OrderLine(item: ref(9), lane: "l", after: nil, reason: "")])
        XCTAssertEqual(d.order(["OVERSIRE-1", "OVERSIRE-2", "OVERSIRE-3"]), ["OVERSIRE-3", "OVERSIRE-2", "OVERSIRE-1"])
        let missing = PlanDraft(order: [PlanDraft.OrderLine(item: ref(1), lane: "l", after: ref(7), reason: "")])
        XCTAssertEqual(missing.order(["OVERSIRE-1", "OVERSIRE-2"]), ["OVERSIRE-1", "OVERSIRE-2"], "an unknown after keeps the place")
    }

    func testDroppingKeepsTheLineOrder() {
        let d = PlanDraft(order: [PlanDraft.OrderLine(item: ref(1), lane: "l", after: nil, reason: "o")],
                          relations: [PlanDraft.RelationLine(item: ref(2), add: [ItemRelation(kind: .blockedBy, item: ref(1))], reason: "r")],
                          areas: [PlanDraft.AreaLine(item: ref(2), add: ["a"], reason: "a")],
                          triggers: [PlannerTrigger(kind: .queued, subject: .item(ref(1)), at: Date(timeIntervalSince1970: 0))],
                          overlaps: .init(before: 3, after: 0))
        XCTAssertEqual(d.lines.map(\.reason), ["o", "r", "a"])
        XCTAssertEqual(d.dropping([]), d)
        XCTAssertEqual(d.dropping([0, 2]).lines.map(\.reason), ["r"])
        XCTAssertEqual(d.dropping([0, 2]).triggers, d.triggers)
        XCTAssertEqual(d.dropping([9]), d, "an index out of range drops nothing")
    }

    func testOrderLineEncodesNullAfter() throws {
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let json = String(decoding: try enc.encode(PlanDraft.OrderLine(item: ref(1), lane: "l", after: nil, reason: "")), as: UTF8.self)
        XCTAssertTrue(json.contains(#""after":null"#), json)
    }

    func testClaimHeld() {
        let c = AreaClaim(item: ref(1), areas: ["a"], at: Date(), grown: [ClaimArea(area: "b", at: Date()), ClaimArea(area: "a", at: Date())])
        XCTAssertEqual(c.held, ["a", "b"])
        XCTAssertEqual(c.id, ItemAreas.id(of: ref(1)))
    }
}
