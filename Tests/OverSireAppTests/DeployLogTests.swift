import Foundation
import OverSireCore
import XCTest
@testable import OverSireApp

final class DeployLogTests: XCTestCase {
    private var path = ""

    override func setUp() {
        path = NSTemporaryDirectory() + "deploys-\(UUID().uuidString)/deploys.jsonl"
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent)
    }

    private func record(_ n: Int, _ conclusion: String = "success") -> DeployRecord {
        DeployRecord(repo: "o/r", workflow: "Deploy", title: "t\(n)", branch: "main", event: "push", conclusion: conclusion, actor: "ada",
                     url: "https://x/runs/\(n)", number: n, startedAt: nil, completedAt: "2026-11-01T10:00:00Z", durationSec: 5,
                     loggedAt: "2026-11-01T10:00:05Z")
    }

    private func run(_ n: Int) -> Run {
        Run(id: "\(n)", name: "Deploy", displayTitle: "t\(n)", status: "completed", conclusion: "success", headBranch: "main", headSha: "abc",
            event: "push", url: "https://x/runs/\(n)", updatedAt: "2026-11-01T10:00:05Z", createdAt: "2026-11-01T10:00:00Z",
            startedAt: "2026-11-01T10:00:00Z", number: n, workflowName: "Deploy", actorLogin: "ada")
    }

    private func write(_ records: [DeployRecord]) throws {
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        let text = try records.map { String(decoding: try enc.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
        try text.write(toFile: path, atomically: true, encoding: .utf8)
    }

    func testAllHasTheFileRecordsAndTheNewOnes() throws {
        try write([record(1), record(2)])
        let log = DeployLog(path: path)
        XCTAssertEqual(log.all().map(\.number), [1, 2])
        log.record([("o/r", [run(2), run(3)])])
        XCTAssertEqual(log.all().map(\.number), [1, 2, 3], "run 2 is known, run 3 is new and last")
        try FileManager.default.removeItem(atPath: path)
        XCTAssertEqual(log.all().map(\.number), [1, 2, 3], "no read of the file after the first call")
    }

    func testARecordAfterALoadKeepsTheFileAndMemoryTheSame() throws {
        let log = DeployLog(path: path)
        XCTAssertTrue(log.all().isEmpty)
        log.record([("o/r", [run(1), run(2)])])
        let inMemory = log.all()
        XCTAssertEqual(inMemory.map(\.number), [1, 2])
        let onDisk = DeployLog.parse(try String(contentsOfFile: path, encoding: .utf8))
        XCTAssertEqual(onDisk, inMemory)
    }
}
