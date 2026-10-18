import AppKit
import XCTest
@testable import OverSireApp

final class SnapCaptureTests: XCTestCase {
    private let guess = SnapProjectGuess([
        .init(key: "OVERSIRE", names: ["OVERSIRE", "OverSire", "oversire", "cloud", "oversire-workspace"]),
        .init(key: "SLING", names: ["SLING", "Sling Platform", "sling-cli", "sling-workspace"]),
        .init(key: "UI", names: ["UI", "User interface"]),
    ])

    func testGuessFromWindowTitles() {
        XCTAssertEqual(guess.guess(app: "Safari", title: "Sling Platform – Jobs"), "SLING")
        XCTAssertEqual(guess.guess(app: "Terminal", title: "fritz@mac: ~/Projects/sling-workspace/sling-cli"), "SLING")
        XCTAssertEqual(guess.guess(app: "Code", title: "snap_store.swift — oversire-workspace"), "OVERSIRE")
        XCTAssertEqual(guess.guess(app: "OverSire", title: ""), "OVERSIRE")
        XCTAssertNil(guess.guess(app: "Finder", title: "Downloads"))
        XCTAssertNil(guess.guess(app: "Notes", title: "UI ideas"), "a name needs 3 letters")
        XCTAssertNil(guess.guess(app: "Mail", title: "Slingshot"), "only whole words match")
    }

    func testGuessPrefersTheLongestName() {
        let g = SnapProjectGuess([.init(key: "A", names: ["cloud"]), .init(key: "B", names: ["cloud console"])])
        XCTAssertEqual(g.guess(app: "Chrome", title: "Cloud Console – logs"), "B")
    }

    func testPointsBecomePixelsAtScale2() {
        let main = CGRect(x: 0, y: 0, width: 1440, height: 900)
        // 100 pt from the left, 50 pt from the top.
        let r = CGRect(x: 100, y: 900 - 50 - 200, width: 300, height: 200)
        XCTAssertEqual(SnapGeometry.pixels(r, display: main, scale: 2), SnapRect(x: 200, y: 100, w: 600, h: 400))
    }

    func testSecondDisplayWithOffsetOrigin() {
        // Left of the main screen and higher up.
        let second = CGRect(x: -1920, y: 300, width: 1920, height: 1080)
        let r = CGRect(x: -1900, y: 300 + 1080 - 30 - 100, width: 400, height: 100)
        XCTAssertEqual(SnapGeometry.pixels(r, display: second, scale: 1), SnapRect(x: 20, y: 30, w: 400, h: 100))
        XCTAssertEqual(SnapGeometry.pixels(r, display: second, scale: 2), SnapRect(x: 40, y: 60, w: 800, h: 200))
    }

    func testSelectionIsCutAtTheDisplayEdge() {
        let main = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(SnapGeometry.pixels(CGRect(x: 900, y: 700, width: 300, height: 300), display: main, scale: 2),
                       SnapRect(x: 1800, y: 0, w: 200, h: 200))
    }

    func testDisplayWithTheCenter() {
        let frames = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 1000, height: 800)]
        XCTAssertEqual(SnapGeometry.display(for: CGRect(x: 900, y: 100, width: 400, height: 100), in: frames), 1)
        XCTAssertEqual(SnapGeometry.display(for: CGRect(x: 700, y: 100, width: 400, height: 100), in: frames), 0)
        XCTAssertNil(SnapGeometry.display(for: CGRect(x: 5000, y: 0, width: 10, height: 10), in: frames))
    }

    func testWindowListRectBecomesCocoa() {
        XCTAssertEqual(SnapGeometry.cocoa(CGRect(x: 10, y: 20, width: 100, height: 50), mainHeight: 900),
                       CGRect(x: 10, y: 830, width: 100, height: 50))
    }
}

/// Real captures. Needs OVERSIRE_LIVE=1 and the Screen Recording permission for the terminal.
final class SnapCaptureLiveTests: XCTestCase {
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OVERSIRE_LIVE"] == "1", "set OVERSIRE_LIVE=1")
        try XCTSkipUnless(SnapCapturer.hasPermission, "no Screen Recording permission")
    }

    private func capturer() -> SnapCapturer { SnapCapturer(guess: { SnapProjectGuess([]) }, onShot: { _, _, _ in }) }

    func testWindowAndAreaGiveTheRightPixelSize() async throws {
        let w = try XCTUnwrap(SnapWindow.onScreen().first)
        let scr = try XCTUnwrap(NSScreen.screens.first { $0.frame.contains(CGPoint(x: w.frame.midX, y: w.frame.midY)) })
        let (shot, png) = try await capturer().captureWindow(w)
        XCTAssertEqual(shot.pixelSize, CGSize(width: (w.frame.width * scr.backingScaleFactor).rounded(),
                                              height: (w.frame.height * scr.backingScaleFactor).rounded()))
        XCTAssertEqual(NSBitmapImageRep(data: png)?.pixelsWide, Int(shot.pixelSize.width))

        let main = NSScreen.screens[0]
        let r = CGRect(x: main.frame.minX + 40, y: main.frame.minY + 60, width: 300, height: 200)
        let (area, data) = try await capturer().captureArea(r, under: nil)
        XCTAssertEqual(area.pixelSize, CGSize(width: 300 * main.backingScaleFactor, height: 200 * main.backingScaleFactor))
        XCTAssertEqual(area.kind, .area)
        XCTAssertEqual(NSBitmapImageRep(data: data)?.pixelsHigh, Int(area.pixelSize.height))
    }
}
