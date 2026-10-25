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

    // A filling page: the side pane takes all the free height, at each window height and after each rebuild.
    // 28: the bottom inset of the column. 16: the space before the empty rest view.
    func testSidePaneFillsThePageAfterRebuildAndResize() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        let scroll = PageScroll()
        w.contentView!.addSubview(scroll)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: w.contentView!.leadingAnchor),
                                     scroll.trailingAnchor.constraint(equalTo: w.contentView!.trailingAnchor),
                                     scroll.topAnchor.constraint(equalTo: w.contentView!.topAnchor),
                                     scroll.bottomAnchor.constraint(equalTo: w.contentView!.bottomAnchor)])
        var pane: SidePane!
        func build() {
            scroll.rebuild(fills: true) { col in
                col.addFull(PageHeader("Settings", caption: "A caption."))
                let side = NSStackView(v: (0..<4).map { _ in Row([NSTextField.text("Nav")], height: 32) as NSView }, spacing: 0)
                let body = NSStackView(v: [NSTextField.text(self.text, size: 12.5, lines: 0)], spacing: 10)
                pane = SidePane(side: side, body: body, sideWidth: 200, keep: "test")
                col.addFull(pane)
            }
        }
        for h: CGFloat in [500, 900, 640] {
            w.setContentSize(NSSize(width: 900, height: h))
            build()
            w.contentView!.layoutSubtreeIfNeeded()
            let bottom = pane.convert(pane.bounds, to: scroll.documentView).maxY
            XCTAssertEqual(bottom, scroll.contentView.bounds.height - 28 - 16, accuracy: 1, "rebuild at \(h)")
            XCTAssertFalse(pane.hasAmbiguousLayout)
        }
        w.setContentSize(NSSize(width: 900, height: 1000))
        w.contentView!.layoutSubtreeIfNeeded()
        XCTAssertEqual(pane.convert(pane.bounds, to: scroll.documentView).maxY, scroll.contentView.bounds.height - 28 - 16, accuracy: 1, "after a resize")
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
