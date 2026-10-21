import OverSireAI
import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class AskScriptsTests: XCTestCase {
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 0) }

    func testWritesOnceForEachHostThenAgainAfterItsLife() async {
        let clock = Clock()
        let asks = AskScripts(life: 60, now: { clock.t })
        let rt = FakeRuntime()
        let first = await asks.prompt("Go", host: rt, workspacePath: "/w")
        XCTAssertEqual(first, "Go\n\n" + AskSkill.promptLine)
        XCTAssertEqual(rt.hostFiles[AskSkill.path], AskSkill.file.data)
        XCTAssertEqual(rt.hostFileWrites, 1)
        _ = await asks.prompt("Go", host: rt, workspacePath: "/w")
        XCTAssertEqual(rt.hostFileWrites, 1, "fresh")
        clock.t = clock.t.addingTimeInterval(61)
        _ = await asks.prompt("Go", host: rt, workspacePath: "/w")
        XCTAssertEqual(rt.hostFileWrites, 2)
    }

    func testNoLineWithoutTheScript() async {
        let asks = AskScripts()
        let none = await asks.prompt("Go", host: nil, workspacePath: "/w")
        XCTAssertEqual(none, "Go")
        let rt = FakeRuntime(capabilities: [.sessionInput])
        let unsupported = await asks.prompt("Go", host: rt, workspacePath: "/w")
        XCTAssertEqual(unsupported, "Go", "the write failed")
    }
}
