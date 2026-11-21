import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

/// A client `forward` that records the calls and answers like a home.
final class ForwardCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [MemberCallRequest] = []
    var actions: [String] { lock.withLock { seen.map(\.action) } }
    var args: [JSONValue] { lock.withLock { seen.map(\.args) } }

    var forward: @Sendable (MemberCallRequest) async throws -> AppCallResult {
        { [self] r in
            lock.withLock { seen.append(r) }
            switch r.action {
            case "intake.create":
                let intake = IntakeItem(id: "n1", workItemId: "w1", name: "x", priority: nil, createdAt: Date(timeIntervalSince1970: 0), author: nil, source: nil)
                let data: JSONValue = .object(["key": .string("FAKE-9"), "id": .string("w1"), "url": .string("https://tracker.fake/FAKE-9"), "intake": try MirrorCodec.body(intake)])
                return AppCallResult(id: "m", status: .ok, summary: "FAKE-9 is in the intake.", data: data)
            case "item.create":
                return AppCallResult(id: "m", status: .ok, summary: "FAKE-9 is made.", data: .object(["key": .string("FAKE-9"), "id": .string("w1"), "url": .string("https://tracker.fake/FAKE-9")]))
            case "item.attach":
                return AppCallResult(id: "m", status: .ok, summary: "attached", data: .object(["id": .string("a1")]))
            default:
                return AppCallResult(id: "m", status: .ok, summary: "done")
            }
        }
    }
}

final class SessionStarterTests: XCTestCase {
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

    private var rig: EpicRig!
    private var tracker: FakeTracker { rig.fake }
    private var runtime: FakeRuntime!
    private var term: Terminal!
    private var roots: [String: String] = [:]
    private var hasTerminal = true

    override func setUp() async throws {
        rig = try await EpicRig(items: 0, epics: [])
        runtime = FakeRuntime()
        term = Terminal()
        roots = [tracker.project.storeKey: "/src/fake"]
        hasTerminal = true
    }

    /// The real catalog over a project store on the fake tracker: the home path.
    private func starter(_ r: EpicRig? = nil, filing: ItemFiling? = nil) -> SessionStarter {
        let r = r ?? rig!
        let ref = r.fake.project, rt = runtime!, tm = term!, roots = self.roots, has = hasTerminal
        return SessionStarter(project: { $0 == ref.storeKey ? ref : nil }, filing: filing ?? .catalog(r.d.actions, store: r.d.projectStore),
                              terminal: { has ? tm : nil }, hostFiles: { rt }, root: { roots[$0] })
    }

    private func request(_ text: String, files: Int = 0, intake: Bool) -> SessionStarter.Request {
        let f = (0..<files).map { NewSessionModel.Attachment(name: "shot-\($0 + 1).png", data: Data("png\($0)".utf8)) }
        return SessionStarter.Request(project: tracker.project.storeKey, text: text, files: f, intake: intake)
    }

    private func start(_ r: SessionStarter.Request, rig other: EpicRig? = nil) async throws -> (SessionStarter.Result, [String]) {
        var steps: [String] = []
        let res = try await starter(other).start(r) { steps.append($0) }
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
        let plain = try await EpicRig(items: 0, epics: [], capabilities: [.intake, .intakeCreate])
        let t = plain.fake
        do {
            _ = try await starter(plain).create(request("x", files: 1, intake: false), intake: false) { _ in }
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
        XCTAssertTrue(prompt.hasPrefix("Why is the sync slow?\nIt takes 2 min.\n\nThis request is intake item \(key). It is not a ticket yet. Plan it."))
        XCTAssertFalse(prompt.contains("Its files:"), "no files: the files line drops")
        XCTAssertTrue(prompt.contains("oversire review ready --key \(key) --kind plan"))
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
        XCTAssertTrue(p.contains("oversire vendor run --project FAKE -- wi attachment download \(item.id) --dir .oversire/\(item.key)"), p)
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

    func testAPickedAgentSendsItsCLIModelAndEffort() async throws {
        let saved = PROJECTS_CFG.runtime
        defer { PROJECTS_CFG.runtime = saved }
        PROJECTS_CFG.runtime.add("claude-max", cli: "claude")
        PROJECTS_CFG.runtime.setProfile("claude-max", AgentProfile(cli: "claude", model: "claude-opus-5-5", effort: "max"))
        var r = request("Fix the sync", intake: false)
        r.agent = "claude-max"
        _ = try await start(r)
        XCTAssertEqual(term.launches, [AgentLaunch(profile: "claude-max", cli: "claude", model: "claude-opus-5-5", effort: "max",
                                                   command: term.launches.first?.command)])
        XCTAssertEqual(term.opened[0].title, "claude-max-fix-the-sync")
        XCTAssertEqual(term.agents, [.claude])
    }

    func testDirectWithNoFilesSendsTheText() async throws {
        let (r, _) = try await start(request("Explain {paths} here\n\nplease", intake: false))
        XCTAssertEqual(term.opened[0].prompt, "Explain {paths} here\n\nplease")
        XCTAssertTrue(r.paths.isEmpty)
        XCTAssertTrue(runtime.hostFiles.isEmpty)
    }

    func testChecksComeBeforeAnyChange() async throws {
        func expect(_ e: SessionStartError, _ r: SessionStarter.Request, rig other: EpicRig? = nil,
                    line: UInt = #line) async throws {
            do {
                _ = try await start(r, rig: other)
                XCTFail("expected \(e)", line: line)
            } catch {
                XCTAssertEqual(error as? SessionStartError, e, line: line)
            }
            let fake = (other ?? rig).fake
            let made = try await fake.intake(fake.project)
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
        let noCreate = try await EpicRig(items: 0, epics: [], capabilities: [.intake])
        try await expect(.noIntake("FAKE"), request("go", intake: true), rig: noCreate)
        let noFiles = try await EpicRig(items: 0, epics: [], capabilities: [.intake, .intakeCreate])
        try await expect(.noIntake("FAKE"), request("go", files: 1, intake: true), rig: noFiles)
        runtime.base.capabilities = [.sessionInput]
        try await expect(.hostFiles("the runtime cannot take files."), request("go", files: 1, intake: false))
    }

    func testHostFileErrorOpensNoTerminal() async throws {
        runtime.base.fail(.vendor(code: "checksum", message: "a.png did not arrive whole on the sessions machine."))
        do {
            _ = try await start(request("go", files: 1, intake: false))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? SessionStartError, .hostFiles("a.png did not arrive whole on the sessions machine."))
        }
        XCTAssertTrue(term.opened.isEmpty)
    }

    // OVERSIRE-536
    func testClientCreateWithFilesUsesFiling() async throws {
        let calls = ForwardCalls()
        rig.d.actions.forward = calls.forward
        let (r, steps) = try await start(request("Look at these", files: 2, intake: true))
        XCTAssertEqual(calls.actions, ["intake.create", "item.attach", "item.attach"])
        XCTAssertEqual(calls.args[0]["project"], .string(tracker.project.storeKey))
        XCTAssertEqual(calls.args[1]["id"], .string("w1"))
        XCTAssertEqual(calls.args[1]["name"], .string("shot-1.png"))
        XCTAssertEqual(calls.args[1]["data"], .string(Data("png0".utf8).base64EncodedString()))
        XCTAssertEqual(r.item?.key, "FAKE-9")
        XCTAssertEqual(r.missing, [])
        XCTAssertEqual(steps, ["Creating item…", "Sending 2 files…", "Opening terminal…"])
        XCTAssertTrue(tracker.uploads.isEmpty, "the client path reaches no tracker")
    }

    // OVERSIRE-536
    func testEnableIntakeRunsUpdateSettings() async throws {
        let calls = ForwardCalls()
        rig.d.actions.forward = calls.forward
        try await starter().enableIntake(tracker.project.storeKey)
        XCTAssertEqual(calls.actions, ["project.updateSettings"])
        XCTAssertEqual(calls.args[0]["patch"], try MirrorCodec.body(ProjectSettingsPatch(features: [.intake: true])))
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
        XCTAssertEqual(r.detail(files: 1), "1 file copied to the sessions machine. The prompt has their paths.")
        r.paths = []
        XCTAssertEqual(r.detail(files: 0), "The prompt went as typed.")
    }
}
