import Cocoa
import XCTest
import OverSireAI
import OverSireAssistant
@testable import OverSireApp

@MainActor
final class AssistantPanelTests: XCTestCase {
    private var boards: [NSPasteboard] = []

    override func tearDown() {
        boards.forEach { $0.releaseGlobally() }
        boards = []
        super.tearDown()
    }

    private func board() -> NSPasteboard {
        let pb = NSPasteboard(name: .init("oversire-test-\(UUID().uuidString)"))
        pb.clearContents()
        boards.append(pb)
        return pb
    }

    private func png() -> Data {
        let img = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { r in
            NSColor.systemBlue.setFill()
            r.fill()
            return true
        }
        return NSBitmapImageRep(data: img.tiffRepresentation!)!.representation(using: .png, properties: [:])!
    }

    // MARK: Composer

    func testComposerTakesAPastedImage() {
        let c = AssistantComposer()
        let pb = board()
        pb.setData(png(), forType: .png)
        XCTAssertTrue(c.take(pb))
        XCTAssertEqual(c.attachments.count, 1)
        guard case .image(let d)? = c.attachments.first?.kind else { return XCTFail("no image") }
        XCTAssertNotNil(NSImage(data: d))
    }

    func testComposerTakesAFileURL() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("assistant-\(UUID().uuidString).log")
        try Data("line one\nline two\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let c = AssistantComposer()
        let pb = board()
        pb.writeObjects([url as NSURL])
        XCTAssertTrue(c.take(pb))
        guard case .file(let name, let data)? = c.attachments.first?.kind else { return XCTFail("no file") }
        XCTAssertEqual(name, url.lastPathComponent)
        XCTAssertEqual(data, Data("line one\nline two\n".utf8))
    }

    func testComposerLeavesTextToTheTextView() {
        let c = AssistantComposer()
        let pb = board()
        pb.setString("Why is the CI red?", forType: .string)
        XCTAssertFalse(c.take(pb))
        XCTAssertTrue(c.attachments.isEmpty)
    }

    func testComposerSendsTheTextAndTheAttachmentsThenClears() {
        let c = AssistantComposer()
        var sent: [(String, Int)] = []
        c.onSend = { sent.append(($0, $1.count)) }
        c.textView.string = "Look at this"
        c.add(AssistantAttachment(kind: .image(png())))
        c.submit()
        XCTAssertEqual(sent.map(\.0), ["Look at this"])
        XCTAssertEqual(sent.map(\.1), [1])
        XCTAssertEqual(c.textView.string, "")
        XCTAssertTrue(c.attachments.isEmpty)
    }

    // MARK: Approval card

    private func card(_ kind: ActionKind) -> (ApprovalCard, () -> [ApprovalAnswer]) {
        var got: [ApprovalAnswer] = []
        let c = ApprovalCard(ToolCall(id: "c1", tool: "pr_merge", args: .object(["number": .int(212)]), kind: kind),
                             title: "Merge the PR", note: nil) { got.append($0) }
        return (c, { got })
    }

    func testApproveButtonAnswersApprove() {
        let (c, got) = card(.outward)
        XCTAssertNil(c.allowBox)
        c.approveButton.performClick(nil)
        XCTAssertEqual(got(), [.approve])
        XCTAssertEqual(c.answered, .approve)
        // A second answer does nothing.
        c.denyButton.performClick(nil)
        XCTAssertEqual(got(), [.approve])
    }

    func testDenyButtonAnswersDeny() {
        let (c, got) = card(.outward)
        c.denyButton.performClick(nil)
        XCTAssertEqual(got(), [.deny])
        XCTAssertFalse(c.approveButton.isEnabled)
    }

    func testAllowForTheChatOnAChangeAction() {
        let (c, got) = card(.change)
        XCTAssertNotNil(c.allowBox)
        c.allowBox?.state = .on
        c.approve()
        XCTAssertEqual(got(), [.approveForChat])
    }

    // MARK: Stream helpers

    func testQuickRepliesComeFromTheLastLine() {
        let (body, replies) = QuickReplies.split("CI is green.\n\nReplies: Merge it | Wait")
        XCTAssertEqual(body, "CI is green.")
        XCTAssertEqual(replies, ["Merge it", "Wait"])
        XCTAssertEqual(QuickReplies.split("No replies here.").1, [])
    }

    func testChatGroups() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let day: TimeInterval = 86_400
        let threads = [
            AssistantThread(title: "Pinned one", createdAt: now - 9 * day, engine: .apiKey, pinned: true),
            AssistantThread(title: "Today one", createdAt: now - 60, engine: .apiKey),
            AssistantThread(title: "Yesterday one", createdAt: now - day, engine: .apiKey),
            AssistantThread(title: "Old one", createdAt: now - 9 * day, engine: .apiKey),
        ]
        let groups = AssistantChats.groups(threads, query: "", now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.0), ["Pinned", "Today", "Yesterday", "Earlier"])
        XCTAssertEqual(AssistantChats.groups(threads, query: "old", now: now, calendar: cal).map { $0.1.map(\.title) }, [["Old one"]])
    }
}
