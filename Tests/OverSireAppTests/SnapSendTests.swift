import CoreGraphics
import ImageIO
import OverSireCore
import OverSireTestKit
import UniformTypeIdentifiers
import XCTest
@testable import OverSireApp

final class SnapSendTests: XCTestCase {
    private final class Terminal: AgentTerminal, @unchecked Sendable {
        var opened: [(path: String, title: String, command: String, prompt: String)] = []
        var agents: [AgentName] = []
        var launches: [AgentLaunch] = []
        var revealed: [SessionRef] = []

        func openTerminal(path: String, title: String, launch: AgentLaunch, prompt: String) async throws -> SessionRef {
            opened.append((path, title, launch.command ?? "", prompt))
            agents.append(AgentName(rawValue: launch.cli))
            launches.append(launch)
            return SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: "path:" + path), id: "t1")
        }

        func show(_ s: SessionRef) async throws { revealed.append(s) }
    }

    private var dir: URL!
    private var store: SnapStore!
    private var tracker: FakeTracker!
    private var term: Terminal!
    private var roots: [String: String] = ["FAKE": "/src/fake"]

    private static let png: Data = {
        let ctx = CGContext(data: nil, width: 40, height: 20, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return out as Data
    }()

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-send-\(UUID().uuidString)")
        store = SnapStore(dir: dir)
        tracker = FakeTracker()
        term = Terminal()
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func sender(tracker t: (any Tracker)? = nil, terminal: AgentTerminal? = nil) -> SnapSender {
        let tr: any Tracker = t ?? tracker
        let tm = terminal ?? term
        let ref = tracker.project
        let roots = self.roots
        return SnapSender(store: store, project: { $0 == "FAKE" ? ref : nil }, tracker: { _ in tr }, terminal: { tm }, root: { roots[$0] })
    }

    /// Two shots. The second has a small mark, so it gets a zoom file.
    private func basket() throws -> SnapBasket {
        var a = SnapShot(project: "FAKE", kind: .window, app: "Safari", windowTitle: "Jobs", pixelSize: CGSize(width: 40, height: 20), scale: 1)
        a.note = "Wrong count"
        try store.add(a, png: Self.png)
        var b = SnapShot(project: "FAKE", kind: .area, app: "", windowTitle: "", pixelSize: CGSize(width: 40, height: 20), scale: 1)
        b.marks = [SnapMark(rect: SnapRect(x: 1, y: 1, w: 2, h: 2), note: "tiny")]
        try store.add(b, png: Self.png)
        return try XCTUnwrap(store.openBaskets.first)
    }

    func testAgentModeMakesOneItemUploadsAndOpensOneTerminal() async throws {
        let b = try basket()
        let r = try await sender().send(b, agent: true)
        XCTAssertEqual(r.missing, [])
        XCTAssertEqual(tracker.uploads.map(\.file.name), ["snap-1.png", "snap-1-clean.png", "snap-2.png", "snap-2-clean.png", "snap-2-mark-1.png"])
        XCTAssertTrue(tracker.uploads.allSatisfy { $0.item == r.item })
        let made = try await tracker.intake(tracker.project)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made[0].name, "Snap basket · 2 shots · Wrong count")
        XCTAssertEqual(term.opened.count, 1)
        XCTAssertEqual(term.opened[0].path, "/src/fake")
        XCTAssertEqual(term.opened[0].title, "snap-" + r.key)
        let prompt = term.opened[0].prompt
        XCTAssertTrue(prompt.hasPrefix("Intake item \(r.key) holds a basket of screenshots (2 shots)."), prompt)
        XCTAssertTrue(prompt.contains("plane-cli wi attachment download \(r.item.id) -w fake -p FAKE --dir \(store.outDir(b.id).path)/download"), prompt)
        XCTAssertTrue(prompt.contains("plane-cli intake update \(made[0].id) "), prompt)
        XCTAssertFalse(prompt.contains("{") || prompt.contains("\n"))
        XCTAssertEqual(term.revealed.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.outDir(b.id).appendingPathComponent("snap-2-mark-1.png").path))
    }

    func testUploadFailureRetriesThenReportsMissing() async throws {
        let b = try basket()
        tracker.failUploads(of: "snap-1-clean.png", times: 2)
        tracker.failUploads(of: "snap-2.png", times: 9)
        let r = try await sender().send(b, agent: false)
        XCTAssertEqual(r.missing, ["snap-2.png"])
        XCTAssertEqual(tracker.uploads.map(\.file.name).sorted(), ["snap-1-clean.png", "snap-1.png", "snap-2-clean.png", "snap-2-mark-1.png"])
        XCTAssertTrue(term.opened.isEmpty, "the Plane mode opens no terminal")

        try store.set(b.id, .partial(key: r.key, missing: r.missing), item: r.item)
        let again = try XCTUnwrap(store.basket(b.id))
        let left = try await sender().retry(again)
        XCTAssertEqual(left, ["snap-2.png"])
        tracker.failUploads(of: "snap-2.png", times: 0)
        let none = try await sender().retry(again)
        XCTAssertEqual(none, [])
        XCTAssertEqual(tracker.uploads.last?.file.name, "snap-2.png")
    }

    func testTrackerWithoutAttachmentsGivesTheCopyFallback() async throws {
        let b = try basket()
        let plain = FakeTracker(capabilities: [.intake, .intakeCreate])
        do {
            _ = try await sender(tracker: plain).send(b, agent: true)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SnapSendError, .noAttachments)
        }
        let made = try await plain.intake(plain.project)
        XCTAssertTrue(made.isEmpty, "no half ticket")
    }

    func testMissingOrcaRootGivesTheMessage() async throws {
        let b = try basket()
        roots = [:]
        do {
            _ = try await sender().send(b, agent: true)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SnapSendError, .noRoot("FAKE"))
            XCTAssertEqual(error.localizedDescription, "Choose an Orca workspace for FAKE first: start any item of the project once.")
        }
        let made = try await tracker.intake(tracker.project)
        XCTAssertTrue(made.isEmpty)
    }

    func testCopyPutsTheTextAndTheFiles() throws {
        let b = try basket()
        let pb = NSPasteboard(name: NSPasteboard.Name("snap-test-\(UUID().uuidString)"))
        try sender().copy(b, to: pb)
        XCTAssertEqual(pb.string(forType: .string), SnapTicket.markdown(b))
        let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        XCTAssertEqual(urls.map(\.lastPathComponent), ["snap-1.png", "snap-1-clean.png", "snap-2.png", "snap-2-clean.png", "snap-2-mark-1.png"])
        pb.releaseGlobally()
    }
}
