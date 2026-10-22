import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class SessionStarterTests: XCTestCase {
    private final class Terminal: AgentTerminal, @unchecked Sendable {
        var opened: [(path: String, title: String, command: String, prompt: String)] = []
        var revealed: [SessionRef] = []

        func openTerminal(path: String, title: String, command: String, prompt: String) async throws -> SessionRef {
            opened.append((path, title, command, prompt))
            return SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: "path:" + path), id: "t1")
        }

        func reveal(_ s: SessionRef) async throws { revealed.append(s) }
    }

    private var tracker: FakeTracker!
    private var runtime: FakeRuntime!
    private var term: Terminal!
    private var roots: [String: String] = [:]
    private var hasTerminal = true

    override func setUp() {
        tracker = FakeTracker()
        runtime = FakeRuntime()
        term = Terminal()
        roots = [tracker.project.storeKey: "/src/fake"]
        hasTerminal = true
    }

    private func starter(tracker t: (any OverSireCore.Tracker)? = nil) -> SessionStarter {
        let tr: any OverSireCore.Tracker = t ?? tracker
        let ref = tracker.project, rt = runtime!, tm = term!, roots = self.roots, has = hasTerminal
        return SessionStarter(project: { $0 == ref.storeKey ? ref : nil }, tracker: { _ in tr }, terminal: { has ? tm : nil },
                              hostFiles: { rt }, root: { roots[$0] })
    }

    private func request(_ text: String, files: Int = 0, intake: Bool) -> SessionStarter.Request {
        let f = (0..<files).map { NewSessionModel.Attachment(name: "shot-\($0 + 1).png", data: Data("png\($0)".utf8)) }
        return SessionStarter.Request(project: tracker.project.storeKey, text: text, files: f, intake: intake)
    }

    private func start(_ r: SessionStarter.Request, tracker t: (any OverSireCore.Tracker)? = nil) async throws -> (SessionStarter.Result, [String]) {
        var steps: [String] = []
        let res = try await starter(tracker: t).start(r) { steps.append($0) }
        return (res, steps)
    }

    func testCreateItemModeOpensNoTerminal() async throws {
        var r = request("The token exchange fails.\nRetry it.", files: 1, intake: false)
        r.title = "Add a retry"
        r.state = "s-todo"
        var steps: [String] = []
        let made = try await starter().create(r, intake: false) { steps.append($0) }
        let items = try await tracker.items(tracker.project, since: nil, limit: 10)
        XCTAssertEqual(items.map(\.title), ["Add a retry"])
        XCTAssertEqual(items.first?.statusOptionId, "s-todo")
        XCTAssertEqual(items.first?.body, "The token exchange fails.\nRetry it.")
        let intake = try await tracker.intake(tracker.project)
        XCTAssertTrue(intake.isEmpty, "Item mode skips triage")
        XCTAssertEqual(tracker.uploads.map(\.item), [made.item])
        XCTAssertEqual(made.missing, [])
        XCTAssertEqual(steps, ["Creating item…", "Sending 1 file…"])
        XCTAssertTrue(term.opened.isEmpty)
        XCTAssertEqual(made.detail(files: 1), "It holds 1 file. No session started.")
    }

    func testCreateIntakeModeTitleFallsBackToTheFirstLine() async throws {
        hasTerminal = false
        roots = [:]
        let made = try await starter().create(request("Why is the sync slow?\nIt takes 2 min.", intake: true), intake: true) { _ in }
        let intake = try await tracker.intake(tracker.project)
        XCTAssertEqual(intake.map(\.name), ["Why is the sync slow?"], "no runtime and no Orca folder are needed")
        XCTAssertEqual(made.detail(files: 0), "No session started.")
    }

    func testCreateChecksFilesBeforeAnyChange() async throws {
        let t = FakeTracker(capabilities: [.intake, .intakeCreate])
        do {
            _ = try await starter(tracker: t).create(request("x", files: 1, intake: false), intake: false) { _ in }
            XCTFail("a tracker with no attachments cannot take files")
        } catch let e as SessionStartError {
            XCTAssertEqual(e, .noCreate("FAKE"))
        }
        let items = try await t.items(t.project, since: nil, limit: 10)
        XCTAssertTrue(items.isEmpty)
    }

    func testIntakeWithNoFiles() async throws {
        let (r, steps) = try await start(request("Why is the sync slow?\nIt takes 2 min.", intake: true))
        let made = try await tracker.intake(tracker.project)
        XCTAssertEqual(made.count, 1)
        XCTAssertEqual(made[0].name, "Why is the sync slow?")
        XCTAssertTrue(tracker.uploads.isEmpty)
        let key = try XCTUnwrap(r.item?.key)
        XCTAssertEqual(term.opened.count, 1)
        XCTAssertEqual(term.opened[0].path, "/src/fake")
        XCTAssertEqual(term.opened[0].title, "claude-why-is-the")
        let prompt = term.opened[0].prompt
        XCTAssertTrue(prompt.hasPrefix("Why is the sync slow?\nIt takes 2 min.\n\nThis request is intake item \(key). It is not a ticket yet."))
        XCTAssertTrue(prompt.hasSuffix("Do not make a new ticket."), "no files: the files line drops")
        XCTAssertEqual(steps, ["Creating item…", "Opening terminal…"])
        XCTAssertEqual(term.revealed, [r.session])
    }

    func testIntakeWithTwoFiles() async throws {
        let (r, steps) = try await start(request("Look at {key} these", files: 2, intake: true))
        let item = try XCTUnwrap(r.item)
        XCTAssertEqual(tracker.uploads.map(\.file.name), ["shot-1.png", "shot-2.png"])
        XCTAssertEqual(tracker.uploads.map(\.file.mimeType), ["image/png", "image/png"])
        XCTAssertTrue(tracker.uploads.allSatisfy { $0.item == item })
        let p = term.opened[0].prompt
        XCTAssertTrue(p.hasPrefix("Look at {key} these\n\n"), "the user text keeps its braces: \(p)")
        XCTAssertTrue(p.contains("plane-cli wi attachment download \(item.id) -w fake -p FAKE --dir .oversire/\(item.key)"), p)
        XCTAssertEqual(steps, ["Creating item…", "Sending 2 files…", "Opening terminal…"])
        XCTAssertTrue(runtime.hostFiles.isEmpty)
    }

    func testFailedUploadListsMissingAndStillOpens() async throws {
        tracker.failUploads(of: "shot-2.png", times: 9)
        let (r, _) = try await start(request("go", files: 2, intake: true))
        XCTAssertEqual(r.missing, ["shot-2.png"])
        XCTAssertEqual(term.opened.count, 1)
    }

    func testDirectWithTwoFiles() async throws {
        let (r, steps) = try await start(request("Read the images", files: 2, intake: false))
        XCTAssertNil(r.item)
        XCTAssertEqual(r.paths.count, 2)
        XCTAssertTrue(r.paths.allSatisfy { $0.hasPrefix("/tmp/oversire/") })
        XCTAssertEqual(Set(runtime.hostFiles.keys), Set(r.paths))
        XCTAssertEqual(term.opened[0].prompt, "Read the images\n\nAttached files:\n" + r.paths.joined(separator: "\n"))
        let made = try await tracker.intake(tracker.project)
        XCTAssertTrue(made.isEmpty, "no tracker call")
        XCTAssertEqual(steps, ["Sending 2 files…", "Opening terminal…"])
    }

    func testDirectWithNoFilesSendsTheText() async throws {
        let (r, _) = try await start(request("Explain {paths} here\n\nplease", intake: false))
        XCTAssertEqual(term.opened[0].prompt, "Explain {paths} here\n\nplease")
        XCTAssertTrue(r.paths.isEmpty)
        XCTAssertTrue(runtime.hostFiles.isEmpty)
    }

    func testChecksComeBeforeAnyChange() async throws {
        func expect(_ e: SessionStartError, _ r: SessionStarter.Request, tracker t: (any OverSireCore.Tracker)? = nil,
                    line: UInt = #line) async throws {
            do {
                _ = try await start(r, tracker: t)
                XCTFail("expected \(e)", line: line)
            } catch {
                XCTAssertEqual(error as? SessionStartError, e, line: line)
            }
            let made = try await tracker.intake(tracker.project)
            XCTAssertTrue(made.isEmpty, line: line)
            XCTAssertTrue(term.opened.isEmpty, line: line)
        }
        var bad = request("go", intake: true)
        bad.project = "nope"
        try await expect(.noProject("nope"), bad)
        roots = [:]
        try await expect(.noRoot("FAKE"), request("go", intake: true))
        roots = [tracker.project.storeKey: "/src/fake"]
        hasTerminal = false
        try await expect(.noRuntime, request("go", intake: true))
        hasTerminal = true
        try await expect(.noIntake("FAKE"), request("go", intake: true), tracker: FakeTracker(capabilities: [.intake]))
        try await expect(.noIntake("FAKE"), request("go", files: 1, intake: true), tracker: FakeTracker(capabilities: [.intake, .intakeCreate]))
        runtime.base.capabilities = [.sessionInput]
        try await expect(.hostFiles("the runtime cannot take files."), request("go", files: 1, intake: false))
    }

    func testHostFileErrorOpensNoTerminal() async throws {
        runtime.base.fail(.vendor(code: "checksum", message: "a.png did not arrive whole on the Orca host."))
        do {
            _ = try await start(request("go", files: 1, intake: false))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SessionStartError, .hostFiles("a.png did not arrive whole on the Orca host."))
        }
        XCTAssertTrue(term.opened.isEmpty)
    }

    func testPromptResolveIsOnePass() {
        XCTAssertEqual(SessionPrompt.resolve("{text} {key} {nope}", ["text": "{key}", "key": "K-1"]), "{key} K-1 {nope}")
        XCTAssertEqual(SessionPrompt.intake(SessionPrompt.intakeOld, values: ["text": "hi", "key": "K-1", "item": "i1", "workspace": "w", "project": "K"],
                                            files: true),
                       SessionPrompt.intakeOld.replacingOccurrences(of: "{text}", with: "hi").replacingOccurrences(of: "{key}", with: "K-1")
                           .replacingOccurrences(of: "{item}", with: "i1").replacingOccurrences(of: "{workspace}", with: "w")
                           .replacingOccurrences(of: "{project}", with: "K"))
    }

    func testToastDetail() {
        let s = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: "orca", id: "local"), id: "path:/x"), id: "t1")
        let item = ItemRef(project: tracker.project, id: "i1", key: "FAKE-9", url: URL(string: "https://x")!)
        var r = SessionStarter.Result(session: s, item: item, paths: [], missing: [], terminal: "claude-go")
        XCTAssertEqual(r.detail(files: 2), "Intake FAKE-9 holds 2 files. The prompt names it.")
        XCTAssertEqual(r.detail(files: 0), "Intake FAKE-9 tracks this work. The prompt names it.")
        r.missing = ["b.png"]
        XCTAssertEqual(r.detail(files: 2), "1 of 2 files did not upload to FAKE-9: b.png.")
        r = SessionStarter.Result(session: s, item: nil, paths: ["/tmp/a"], missing: [], terminal: "claude-go")
        XCTAssertEqual(r.detail(files: 1), "1 file copied to the Orca host. The prompt has their paths.")
        r.paths = []
        XCTAssertEqual(r.detail(files: 0), "The prompt went as typed.")
    }
}
