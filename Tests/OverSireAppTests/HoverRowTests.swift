import AppKit
import OverSireCore
import XCTest
@testable import OverSireApp

final class HoverRowTests: XCTestCase {
    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    private func pr() -> ChangeRequest {
        ChangeRequest(number: 3, title: "t", state: "OPEN", author: .init(login: "me"), headRefName: "b", baseRefName: "main",
                      url: "https://github.com/o/r/pull/3", createdAt: "", updatedAt: "", reviewDecision: nil, additions: 0, deletions: 0,
                      isDraft: false, labels: [], body: nil)
    }

    private func rows(expanded: Bool = false) -> [HoverRow] {
        [RunRow(repo: "o/r", group: [Run.sample(1)], history: [], w: 400, expanded: expanded),
         PRRow(pr(), repo: "o/r", w: 400, expanded: expanded)]
    }

    func testReturnAndSpaceToggleBothRowKinds() {
        for row in rows() {
            var n = 0
            row.onToggle = { n += 1 }
            row.keyDown(with: key(36))
            row.keyDown(with: key(49))
            XCTAssertEqual(n, 2)
            row.keyDown(with: key(0))
            XCTAssertEqual(n, 2)
        }
    }

    func testExpandedRowHasTheRestingFill() {
        for row in rows(expanded: true) { XCTAssertNotNil(row.layer?.backgroundColor) }
        for row in rows(expanded: false) { XCTAssertNil(row.layer?.backgroundColor) }
    }
}

final class ClosureItemTests: XCTestCase {
    override func setUp() { _ = NSApplication.shared }

    func testTheItemRunsItsClosure() {
        var n = 0
        let menu = NSMenu()
        menu.addItem(ClosureItem("x") { n += 1 })
        menu.performActionForItem(at: 0)
        XCTAssertEqual(n, 1)
    }

    func testTheMenuKeepsTheClosureAlive() {
        var n = 0
        let menu = NSMenu()
        autoreleasepool { menu.addItem(ClosureItem("x") { n += 1 }) }
        menu.performActionForItem(at: 0)
        XCTAssertEqual(n, 1)
    }

    func testAnItemWithAClosureIsEnabled() {
        let menu = NSMenu()
        menu.autoenablesItems = true
        let item = ClosureItem("x") {}
        menu.addItem(item)
        menu.update()
        XCTAssertTrue(item.isEnabled)
    }
}

final class ProjectColorTests: XCTestCase {
    func testHexAndNames() {
        XCTAssertEqual(projectColor("#FF0000"), NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        XCTAssertEqual(projectColor("GREEN"), C_SUCCESS)
        XCTAssertEqual(projectColor("FF0000"), .secondaryLabelColor)
        XCTAssertEqual(projectColor("#12"), .secondaryLabelColor)
    }
}
