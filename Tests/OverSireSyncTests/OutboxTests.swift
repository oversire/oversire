import XCTest
import OverSireCore
@testable import OverSireSync

final class OutboxTests: XCTestCase {
    var dir: URL!

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("outbox-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func file(_ name: String) -> URL { dir.appendingPathComponent(name) }

    func op(_ id: String, _ n: Int) -> StoreOp {
        StoreOp(collection: "pins", id: id, op: .delete, hlc: String(format: "%015d-000000-app", n), device: "app")
    }

    func testABatchGivesTheSameOpsAsSingleAdds() throws {
        let batch = Outbox(url: file("a.json")), single = Outbox(url: file("b.json"))
        let a1 = op("a", 1), b = op("b", 2), a2 = op("a", 3)
        batch.add(contentsOf: [a1, b, a2])
        [a1, b, a2].forEach(single.add)
        XCTAssertEqual(batch.pending, [b, a2])
        XCTAssertEqual(batch.pending, single.pending)
        let saved = { try JSONDecoder().decode([StoreOp].self, from: Data(contentsOf: self.file($0))) }
        XCTAssertEqual(try saved("a.json"), [b, a2])
        XCTAssertEqual(try saved("a.json"), try saved("b.json"))
    }

    func testABatchReplacesAWaitingOp() {
        let box = Outbox(url: nil)
        box.add(op("a", 1))
        let a2 = op("a", 2)
        box.add(contentsOf: [a2])
        XCTAssertEqual(box.pending, [a2])
    }

    func testAnEmptyBatchWritesNothing() {
        let box = Outbox(url: file("none.json"))
        box.add(contentsOf: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: file("none.json").path))
    }

    func testABatchSurvivesARestart() {
        let ops = [op("a", 1), op("b", 2), op("c", 3)]
        Outbox(url: file("o.json")).add(contentsOf: ops)
        XCTAssertEqual(Outbox(url: file("o.json")).pending, ops)
    }
}
