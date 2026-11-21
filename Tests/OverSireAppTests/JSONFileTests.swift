import XCTest
@testable import OverSireApp

final class JSONFileTests: XCTestCase {
    private let tmp = NSTemporaryDirectory() + "oversire-json-" + UUID().uuidString

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tmp)
    }

    private func make() -> String {
        try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
        return tmp
    }

    func testRoundTrip() {
        let path = make() + "/a.json"
        let value = ["x": Date(timeIntervalSince1970: 1_700_000_000), "y": Date(timeIntervalSince1970: 5)]
        value.write(atPath: path)
        XCTAssertEqual([String: Date].read(atPath: path), value)
    }

    func testBytesMatchTheDefaultEncoder() throws {
        let path = make() + "/a.json"
        let value = ["x": Date(timeIntervalSince1970: 1_700_000_000)]
        value.write(atPath: path)
        XCTAssertEqual(FileManager.default.contents(atPath: path), try JSONEncoder().encode(value))
    }

    func testMissingFileGivesNil() throws {
        let dir = make()
        XCTAssertNil([String: Date].read(atPath: dir + "/none.json"))
        try Data("not json".utf8).write(to: URL(fileURLWithPath: dir + "/bad.json"))
        XCTAssertNil([String: Date].read(atPath: dir + "/bad.json"))
    }

    func testMakeDirMakesTheParent() {
        let dir = make()
        let value = ["x": 1]
        value.write(atPath: dir + "/a/b.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/a"))
        value.write(atPath: dir + "/a/b.json", makeDir: true)
        XCTAssertEqual([String: Int].read(atPath: dir + "/a/b.json"), value)
    }
}
