import Cocoa
import XCTest
@testable import OverSireApp

final class NewSessionPanelTests: XCTestCase {
    private let choices = [NewSessionModel.Choice(key: "OVERSIRE", name: "OverSire", store: "ocral/o", root: "/src/o"),
                           NewSessionModel.Choice(key: "SLING", name: "Sling", store: "ocral/s", root: nil)]
    private var started: [NewSessionModel] = []
    private var closed = 0

    private func panel(last: String? = "ocral/o") -> NewSessionPanel {
        var cfg = SessionConfig()
        cfg.lastProject = last
        var a = NewSessionPanel.Actions()
        a.start = { [weak self] in self?.started.append($0) }
        a.closed = { [weak self] in self?.closed += 1 }
        return NewSessionPanel(model: NewSessionModel(choices: choices, cfg: cfg, agent: "claude"), actions: a)
    }

    private func key(_ code: UInt16, _ chars: String, _ mods: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    private func buttons(_ p: NSPanel) -> [NSButton] {
        var out: [NSButton] = []
        func walk(_ v: NSView) { if let b = v as? NSButton { out.append(b) }; v.subviews.forEach(walk) }
        p.contentView.map(walk)
        return out
    }

    func testCommandReturnStartsWithTheTypedText() {
        let p = panel()
        p.performKeyEquivalent(with: key(36, "\r", .command))
        XCTAssertTrue(started.isEmpty, "no text and no file: Start is off")
        p.promptView.string = "Fix the sync"
        XCTAssertTrue(p.performKeyEquivalent(with: key(36, "\r", .control)))
        XCTAssertEqual(started.map(\.text), ["Fix the sync"])
        XCTAssertEqual(started.first?.selected, "ocral/o")
    }

    func testEscClosesTheListFirstThenThePanel() {
        let p = panel()
        p.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(p.model.listOpen)
        p.cancelOperation(nil)
        XCTAssertFalse(p.model.listOpen)
        XCTAssertEqual(closed, 0)
        p.cancelOperation(nil)
        XCTAssertEqual(closed, 1)
    }

    func testArrowsAndReturnPickAProject() {
        let p = panel()
        let tv = NSTextView()
        p.comboField.stringValue = ""
        p.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification))
        XCTAssertTrue(p.control(p.comboField, textView: tv, doCommandBy: #selector(NSResponder.moveDown(_:))))
        XCTAssertTrue(p.control(p.comboField, textView: tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(p.model.selected, "ocral/s")
        XCTAssertFalse(p.model.listOpen)
        XCTAssertNotNil(buttons(p).first { $0.title == "Choose folder…" }, "SLING has no Orca workspace")
        XCTAssertEqual(buttons(p).first { $0.title.hasPrefix("Start claude") }?.isEnabled, false)
    }

    func testFilesShowAndRemove() {
        let p = panel()
        p.add([.init(name: "a.png", data: Data([1])), .init(name: "b.log", data: Data([2, 3]))])
        XCTAssertEqual(p.model.files.count, 2)
        let remove = buttons(p).first { $0.toolTip == "Remove b.log" }
        XCTAssertNotNil(remove)
        remove?.performClick(nil)
        XCTAssertEqual(p.model.files.map(\.name), ["a.png"])
        XCTAssertEqual(buttons(p).first { $0.title.hasPrefix("Start claude") }?.isEnabled, true, "a file alone can start")
    }

    func testHostFileErrorOffersIntake() {
        let p = panel()
        p.promptView.string = "go"
        p.add([.init(name: "a.png", data: Data([1]))])
        p.setPhase(.failed("no"), hostFiles: false)
        XCTAssertNil(buttons(p).first { $0.title == "Send with intake" })
        p.setPhase(.edit)
        (buttons(p).first { $0.title.hasPrefix("Also create an intake item") })?.performClick(nil)
        XCTAssertFalse(p.model.intake)
        p.setPhase(.failed("no"), hostFiles: true)
        let send = buttons(p).first { $0.title == "Send with intake" } as? ActionButton
        XCTAssertNotNil(send)
        send?.onClick?()
        XCTAssertEqual(started.last?.intake, true)
    }

    private func board(_ fill: (NSPasteboard) -> Void) -> NSPasteboard {
        let pb = NSPasteboard(name: .init("oversire.test.\(UUID().uuidString)"))
        pb.clearContents()
        fill(pb)
        addTeardownBlock { pb.releaseGlobally() }
        return pb
    }

    private var png: Data {
        let img = NSImage(size: NSSize(width: 4, height: 4))
        img.lockFocus(); NSColor.red.set(); NSRect(x: 0, y: 0, width: 4, height: 4).fill(); img.unlockFocus()
        return NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    func testPasteContent() {
        let shot = board { $0.setData(png, forType: .png) }
        guard case .image = PasteContent(shot) else { return XCTFail("a screenshot is an image") }
        let named = board { $0.setData(png, forType: .png); $0.setString("https://example.com/a.png", forType: .string) }
        guard case .image = PasteContent(named) else { return XCTFail("a URL next to the image keeps the image") }
        let file = board { $0.setData(png, forType: .png); $0.setString("Screenshot 2026-10-20 at 14.47.png", forType: .string) }
        guard case .image = PasteContent(file) else { return XCTFail("an image file name keeps the image") }
        let cells = board { $0.setData(png, forType: .png); $0.setString("total", forType: .string) }
        XCTAssertEqual(PasteContent(cells), .text, "a spreadsheet copy pastes its text")
        let lines = board { $0.setData(png, forType: .png); $0.setString("a\nb", forType: .string) }
        XCTAssertEqual(PasteContent(lines), .text)
        let url = URL(fileURLWithPath: "/tmp/a.log")
        XCTAssertEqual(PasteContent(board { $0.writeObjects([url as NSURL]) }), .files([url]))
        XCTAssertEqual(PasteContent(board { $0.setString("hi", forType: .string) }), .text)
    }

    func testPasteKeysAttachTheImageFromAnyField() {
        let p = panel()
        let shot = board { $0.setData(png, forType: .png) }
        p.makeFirstResponder(p.comboField)
        XCTAssertTrue(p.paste(control: false, from: shot))
        XCTAssertTrue(p.paste(control: true, from: shot))
        XCTAssertEqual(p.model.files.map(\.name), ["pasted-1.png", "pasted-2.png"])
        XCTAssertTrue(p.model.files.allSatisfy(\.isImage))
        XCTAssertFalse(p.paste(control: false, from: board { $0.setString("hi", forType: .string) }), "⌘V with text goes to Edit › Paste")
    }

    func testPasteMenuStaysOnForAnImageOnlyClipboard() {
        let types = SessionTextView().readablePasteboardTypes
        XCTAssertTrue(types.contains(.png) && types.contains(.tiff) && types.contains(.fileURL))
    }

    func testCommandDigitsSwitchModeAndHideTheSessionParts() {
        let p = panel(last: "ocral/s")
        XCTAssertNotNil(buttons(p).first { $0.title == "Choose folder…" })
        XCTAssertTrue(p.performKeyEquivalent(with: key(19, "2", .command)))
        XCTAssertEqual(p.model.mode, .intake)
        XCTAssertNil(buttons(p).first { $0.title == "Choose folder…" }, "Intake needs no Orca workspace")
        p.titleField.stringValue = "Login crashes"
        p.start()
        XCTAssertEqual(started.map(\.mode), [.intake])
        XCTAssertEqual(started.first?.itemTitle, "Login crashes")
        XCTAssertTrue(p.performKeyEquivalent(with: key(20, "3", .command)))
        XCTAssertEqual(p.model.mode, .item)
        XCTAssertEqual(buttons(p).first { $0.title.hasPrefix("Create item") }?.isEnabled, true)
    }
}
