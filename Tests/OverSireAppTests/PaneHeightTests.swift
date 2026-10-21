import AppKit
import XCTest
@testable import OverSireApp

final class PaneHeightTests: XCTestCase {
    private let text = String(repeating: "A long note that wraps to more lines in a narrow pane. ", count: 12)

    func testPaneFitsItsBodyAfterOneTurn() {
        let label = NSTextField.text(text, size: 12.5, lines: 0)
        let body = NSStackView(v: [], spacing: 10)
        body.addFull(label)
        let pane = SidePane(side: NSView(), body: body, sideWidth: 200, keep: "test")
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView!.addSubview(pane)
        NSLayoutConstraint.activate([pane.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
                                     pane.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
                                     pane.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
                                     pane.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor)])
        w.contentView!.layoutSubtreeIfNeeded()
        pane.settle()
        XCTAssertEqual(label.preferredMaxLayoutWidth, label.frame.width)
        let doc = pane.pane.documentView!
        XCTAssertEqual(doc.frame.height, body.fittingSize.height + 16, accuracy: 1)
        XCTAssertGreaterThan(label.frame.height, 40, "the label shows all its lines")
    }

    func testWrapAsksForTheNewHeightWhenTheWidthChanges() {
        let chips = (0..<12).map { Chiplet("chip \($0)") as NSView }
        let wrap = Wrap(chips)
        wrap.setFrameSize(NSSize(width: 2000, height: 20))
        let one = wrap.intrinsicContentSize.height
        wrap.setFrameSize(NSSize(width: 160, height: 20))
        XCTAssertGreaterThan(wrap.intrinsicContentSize.height, one)
    }
}
