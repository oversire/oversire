import Cocoa
import XCTest
import SwiftTerm
import OverSireCore
import OverSireSync
@testable import OverSireApp

private struct NoSockets: WebSocketConnecting {
    func connect(_ request: URLRequest) async throws -> any WebSocketConnection {
        try await Task.sleep(for: .seconds(3600))
        throw CancellationError()
    }
}

@MainActor
final class LiveTerminalCardTests: XCTestCase {
    private func card(writable: Bool = true) -> (LiveTerminalCard, NSWindow, NSView) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        let stream = SessionStream(request: URLRequest(url: URL(string: "ws://127.0.0.1:1/v1/sessions/s/stream")!), view: .terminal, socket: NoSockets())
        let c = LiveTerminalCard(sessionID: "s", stream: stream, runtime: "Orca", place: "this Mac", trailing: [])
        c.frame = w.contentView!.bounds
        w.contentView!.addSubview(c)
        c.handle(.attached(StreamAttached(source: .stream, cols: 80, rows: 24, writable: writable, resizable: true)))
        let term = Self.find(c)!
        return (c, w, term)
    }

    private static func find(_ v: NSView) -> TerminalView? {
        if let t = v as? TerminalView { return t }
        return v.subviews.lazy.compactMap { find($0) }.first
    }

    /// The focus observer runs on the next turn of the main queue.
    private func settle() async {
        for _ in 0..<5 { await Task.yield(); RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    func testFocusTakesTheSizeAndLeavingGivesItBack() async {
        let (c, w, term) = card()
        w.makeFirstResponder(term)
        await settle()
        XCTAssertTrue(c.controlling, "focus fits Orca to the view")

        w.makeFirstResponder(nil)
        await settle()
        XCTAssertFalse(c.controlling, "leaving the terminal gives the size back")
    }

    func testGiveBackPausesUntilTheFocusLeaves() async {
        let (c, w, term) = card()
        w.makeFirstResponder(term)
        await settle()
        c.giveBack()
        term.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: w.windowNumber,
                                                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        XCTAssertFalse(c.controlling, "a click after Give back keeps the size of Orca")

        w.makeFirstResponder(nil)
        await settle()
        w.makeFirstResponder(term)
        await settle()
        XCTAssertTrue(c.controlling)
    }

    func testTakeControlStaysWhenTheFocusLeaves() async {
        let (c, w, _) = card()
        c.takeControl(auto: false)
        await settle()
        w.makeFirstResponder(nil)
        await settle()
        XCTAssertTrue(c.controlling)
    }

    func testViewOnlyDoesNotTake() async {
        let (c, w, term) = card(writable: false)
        w.makeFirstResponder(term)
        await settle()
        XCTAssertFalse(c.controlling)
    }
}
