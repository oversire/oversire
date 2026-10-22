import Cocoa
import XCTest
import OverSireCore
import OverSireSync
import OverSireTestKit
@testable import OverSireApp

private let now = Date(timeIntervalSince1970: 2_000_000)

private func member(_ m: MachineName, _ ip: String, roles: [String] = ["serve"], seen: TimeInterval? = 0, version: String? = nil) -> GroupMember {
    GroupMember(machine: m, host: m.rawValue, addrs: [ip], port: 7690, roles: roles, joinedAt: now.addingTimeInterval(-86400),
                lastSeen: seen.map { now.addingTimeInterval(-$0) }, version: version)
}

private func group(_ members: [GroupMember], home: MachineName = "mbp") -> Group {
    Group(id: "g-1", name: "My machines", home: home, version: 2, members: members, devices: [])
}

private func info(_ m: MachineName, _ ip: String? = nil, roles: [String] = ["serve"]) -> DaemonInfo {
    DaemonInfo(machine: m, version: "0.4.0", contract: 1, roles: roles, runtimes: ["orca"], harnesses: [],
               listen: .init(loopback: "127.0.0.1:7690", tailscale: ip.map { $0 + ":7690" }))
}

private func client(_ d: FakeDaemon) -> DaemonClient { DaemonClient(base: DaemonClient.loopback, token: nil, http: d) }

// MARK: JoinFlow

@MainActor
final class JoinFlowTests: XCTestCase {
    private func flow(local: FakeDaemon, remote: [String: FakeDaemon] = [:]) -> JoinFlow {
        let f = JoinFlow(local: client(local), machines: nil, http: local, thisMachine: "mba") { host in
            let d = remote[host] ?? { let x = FakeDaemon(machine: host); x.online = false; return x }()
            return DaemonClient(base: URL(string: "http://\(host):7690")!, token: nil, http: d)
        }
        f.pollEvery = .milliseconds(20)
        return f
    }

    func testFoundPathGoesFromWaitingToJoined() async {
        let local = FakeDaemon(machine: "mba", group: group([member("mba", "100.71.4.12")], home: "mba"))
        local.asked = JoinPending(request: "r-1", confirm: "4821", expiresAt: now.addingTimeInterval(300))
        let f = flow(local: local)
        var joined = 0
        f.onJoined = { joined += 1 }
        await f.join(found: info("mbp", "100.97.81.23"))
        XCTAssertEqual(f.phase, .waiting(confirm: "4821", host: "mbp"))
        XCTAssertEqual(local.body(of: "POST /v1/group/ask")?["host"] as? String, "100.97.81.23:7690")
        f.received(JoinResultFrame(host: "mbp", request: "other", status: .approved))
        XCTAssertEqual(f.phase, .waiting(confirm: "4821", host: "mbp"), "a frame of another request does nothing")
        f.received(JoinResultFrame(host: "mbp", request: "r-1", status: .approved))
        XCTAssertEqual(f.phase, .joined(machine: "mbp"))
        XCTAssertEqual(joined, 1)
    }

    func testWithoutAFrameTheGroupTellsTheEnd() async throws {
        let local = FakeDaemon(machine: "mba", group: group([member("mba", "100.71.4.12")], home: "mba"))
        local.asked = JoinPending(request: "r-1", confirm: "4821", expiresAt: Date().addingTimeInterval(300))
        let f = flow(local: local)
        await f.join(found: info("mbp", "100.97.81.23"))
        local.group = group([member("mbp", "100.97.81.23"), member("mba", "100.71.4.12")])
        for _ in 0..<100 where f.phase != .joined(machine: "mbp") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(f.phase, .joined(machine: "mbp"))
    }

    func testDeniedAndExpiredGiveAReason() async {
        let local = FakeDaemon(machine: "mba")
        local.asked = JoinPending(request: "r-1", confirm: "4821", expiresAt: now.addingTimeInterval(300))
        let f = flow(local: local)
        await f.join(found: info("mbp"))
        f.received(JoinResultFrame(host: "mbp", request: "r-1", status: .denied))
        XCTAssertEqual(f.phase, .failed("mbp denied the request."))

        await f.join(found: info("mbp"))
        f.received(JoinResultFrame(host: "mbp", request: "r-1", status: .expired))
        guard case .failed(let why) = f.phase else { return XCTFail("\(f.phase)") }
        XCTAssertTrue(why.hasPrefix("The request expired."))
    }

    func testCancelStopsTheWait() async {
        let local = FakeDaemon(machine: "mba")
        local.asked = JoinPending(request: "r-1", confirm: "4821", expiresAt: now.addingTimeInterval(300))
        let f = flow(local: local)
        await f.join(found: info("mbp"))
        f.cancel()
        XCTAssertEqual(f.phase, .idle)
        f.received(JoinResultFrame(host: "mbp", request: "r-1", status: .approved))
        XCTAssertEqual(f.phase, .idle, "a late frame does not join")
    }

    func testAHostThatDoesNotAnswer() async {
        let local = FakeDaemon(machine: "mba")
        let f = flow(local: local)
        await f.join(found: info("mbp"))
        guard case .failed = f.phase else { return XCTFail("\(f.phase)") }
    }

    func testCodeWithTheDaemonEntersTheGroup() async {
        let local = FakeDaemon(machine: "mba", group: group([member("mbp", "100.97.81.23"), member("mba", "100.71.4.12")]))
        local.codes = ["K7Q2-M9XD"]
        let f = flow(local: local)
        await f.join(host: "100.97.81.23", code: " k7q2-m9xd ")
        XCTAssertEqual(f.phase, .joined(machine: "mbp"))
        XCTAssertEqual(local.body(of: "POST /v1/group/enter")?["code"] as? String, "K7Q2-M9XD")
    }

    func testCodeWithoutADaemonJoinsAsAnApp() async throws {
        let local = FakeDaemon(machine: "mba")
        local.online = false
        let mbp = FakeDaemon(machine: "mbp", group: group([member("mbp", "100.97.81.23")]))
        mbp.codes = ["K7Q2-M9XD"]
        let f = flow(local: local, remote: ["mbp": mbp])
        await f.join(host: "mbp", code: "K7Q2-M9XD")
        XCTAssertEqual(f.phase, .joined(machine: "mbp"))
        let body = try XCTUnwrap(mbp.body(of: "POST /v1/group/join"))
        XCTAssertEqual(body["kind"] as? String, "app")
        XCTAssertEqual(body["machine"] as? String, "mba")
        XCTAssertGreaterThanOrEqual((body["nonce"] as? String)?.count ?? 0, 8)
    }

    func testABadCodeAndAWrongHost() async {
        let local = FakeDaemon(machine: "mba")
        local.online = false
        let mbp = FakeDaemon(machine: "mbp", group: group([member("mbp", "100.97.81.23")]))
        mbp.codes = ["K7Q2-M9XD"]
        let f = flow(local: local, remote: ["mbp": mbp])
        await f.join(host: "mbp", code: "AAAA-BBBB")
        XCTAssertEqual(f.phase, .failed("The code is not valid or was used."))
        await f.join(host: "mba-typo", code: "K7Q2-M9XD")
        guard case .failed(let why) = f.phase else { return XCTFail("\(f.phase)") }
        XCTAssertTrue(why.hasPrefix("Cannot reach mba-typo"), why)
        await f.join(host: "", code: "K7Q2-M9XD")
        XCTAssertEqual(f.phase, .failed("Enter the machine and the code."))
    }
}

// MARK: ApproveCenter

private final class RecordingNotifier: JoinNotifying {
    var posted: [(String, String)] = []
    var withdrawn: [String] = []
    func post(_ r: JoinRequestFrame, group: String) { posted.append((r.request, group)) }
    func withdraw(_ request: String) { withdrawn.append(request) }
}

@MainActor
final class ApproveCenterTests: XCTestCase {
    private let request = JoinRequestFrame(request: "r-1", machine: "mba", host: "100.71.4.12", confirm: "4821",
                                           expiresAt: Date().addingTimeInterval(300))

    func testAFrameNotifiesAndTheDecisionCallsLoopback() async throws {
        let d = FakeDaemon(machine: "mbp")
        d.pending = [request]
        let n = RecordingNotifier()
        let c = ApproveCenter(local: client(d), notifier: n)
        c.groupName = { "Home lab" }
        var shown: [String] = []
        c.onShow = { shown.append($0.request) }
        guard case .joinRequest(let r)? = DaemonFrame.parse(#"{"type":"joinRequest","request":"r-1","machine":"mba","host":"100.71.4.12","kind":"daemon","confirm":"4821","expiresAt":"2099-01-01T00:00:00Z"}"#) else {
            return XCTFail("frame")
        }
        c.handle(r)
        c.handle(r)
        XCTAssertEqual(n.posted.map(\.0), ["r-1"], "a second frame of the same request does not notify again")
        XCTAssertEqual(n.posted.first?.1, "Home lab")
        XCTAssertEqual(shown, ["r-1"])
        XCTAssertEqual(ApproveCenter.title(r, group: "Home lab"), "mba wants to join Home lab")

        try await c.decide("r-1", approve: true)
        XCTAssertEqual(d.calls.last, "POST /v1/group/requests/r-1/approve")
        XCTAssertEqual(d.decisions.map(\.approve), [true])
        XCTAssertEqual(n.withdrawn, ["r-1"])
        XCTAssertTrue(c.open.isEmpty)
    }

    func testDenyAndAGoneRequest() async throws {
        let d = FakeDaemon(machine: "mbp")
        d.pending = [request]
        let c = ApproveCenter(local: client(d), notifier: RecordingNotifier())
        c.handle(request)
        try await c.decide("r-1", approve: false)
        XCTAssertEqual(d.calls.last, "POST /v1/group/requests/r-1/deny")
        c.handle(JoinRequestFrame(request: "r-2", machine: "mba", host: "h", confirm: "1", expiresAt: Date().addingTimeInterval(60)))
        try await c.decide("r-2", approve: true)
        XCTAssertTrue(c.open.isEmpty, "an expired request on the daemon is not an error")
    }

    func testExpiredFramesAndSync() async {
        let d = FakeDaemon(machine: "mbp")
        let n = RecordingNotifier()
        let c = ApproveCenter(local: client(d), notifier: n)
        c.handle(JoinRequestFrame(request: "old", machine: "mba", host: "h", confirm: "1", expiresAt: Date().addingTimeInterval(-1)))
        XCTAssertTrue(c.open.isEmpty)
        d.pending = [request]
        await c.sync()
        XCTAssertEqual(c.open.map(\.request), ["r-1"])
        d.pending = []
        await c.sync()
        XCTAssertTrue(c.open.isEmpty)
        XCTAssertEqual(n.withdrawn, ["r-1"])
    }
}

// MARK: MachinesModel

final class MachinesModelTests: XCTestCase {
    func testUpdateOnlyForANewerRelease() {
        var s = snapshot()
        let v = s.info!.version
        for (latest, want) in [(nil, nil), (v, nil), ("0.0.1", nil), ("99.0.0", "99.0.0")] as [(String?, String?)] {
            s.latest = latest
            XCTAssertEqual(MachinesModel(s, config: MachinesConfig(), environments: [], now: now).update, want, "\(latest ?? "nil")")
        }
    }

    private func snapshot() -> MachinesSnapshot {
        var s = MachinesSnapshot()
        s.installed = true
        s.info = info("mbp", "100.97.81.23", roles: ["serve", "runner"])
        s.group = group([member("mbp", "100.97.81.23", roles: ["serve", "runner"]), member("mba", "100.71.4.12", seen: 20),
                         member("devbox", "100.88.20.3", roles: ["serve", "runner"], seen: 7300)])
        s.health = ["mba": .live, "devbox": .failed("no answer")]
        func session(_ id: String, _ st: DaemonSession.State) -> DaemonSession {
            DaemonSession(id: id, machine: "mbp", runtime: "orca", harness: "claude", cwd: "/", state: st, stateSince: now, updatedAt: now, sources: [])
        }
        s.sessions["mbp"] = [session("1", .working), session("2", .waiting), session("3", .working), session("4", .done)]
        s.hooks = [HarnessHooks(name: "claude", hooks: .installed), HarnessHooks(name: "codex", hooks: .untrusted),
                   HarnessHooks(name: "opencode", hooks: .missing)]
        return s
    }

    func testRowsFromTheGroupAndHealth() {
        let m = MachinesModel(snapshot(), config: MachinesConfig(), environments: ["mbp"], now: now)
        XCTAssertEqual(m.state, .group)
        XCTAssertEqual(m.title, "My machines · 3")
        XCTAssertEqual(m.machines.map(\.name), ["mbp", "mba", "devbox"])
        let mbp = m.machines[0], mba = m.machines[1], devbox = m.machines[2]
        XCTAssertTrue(mbp.isThis && mbp.home && mbp.runner && mbp.online)
        XCTAssertEqual(mbp.host, "100.97.81.23")
        XCTAssertEqual(mbp.sessionsText, "3 sessions · 1 waiting")
        XCTAssertTrue(mba.online)
        XCTAssertEqual(mba.sessionsText, "No sessions")
        XCTAssertFalse(devbox.online)
        XCTAssertEqual(devbox.status, "Offline · 2 h ago")
        XCTAssertTrue(m.found.isEmpty)
    }

    func testOrcaAccountDefaults() {
        var cfg = MachinesConfig()
        var m = MachinesModel(snapshot(), config: cfg, environments: ["mbp"], now: now)
        XCTAssertEqual(m.machines.map(\.account), ["local", nil, nil], "this Mac: local; a machine with the name of an environment: that one")
        XCTAssertEqual(m.accounts, ["local", "mbp", nil])

        // The app on mba: mbp is the Orca environment "mbp".
        var s = snapshot()
        s.info = info("mba", "100.71.4.12")
        m = MachinesModel(s, config: cfg, environments: ["mbp"], now: now)
        XCTAssertEqual(m.machines.map(\.account), ["mbp", "local", nil])

        cfg.runtimeAccounts = ["mba": "mbp", "mbp": ""]
        m = MachinesModel(s, config: cfg, environments: ["mbp"], now: now)
        XCTAssertEqual(m.machines.map(\.account), [nil, "mbp", nil], "a stored choice wins; an empty id is none")
    }

    func testOfflineMembersAndMuted() {
        var s = snapshot()
        s.health = [:]
        let m = MachinesModel(s, config: MachinesConfig(muted: ["devbox"]), environments: [], now: now)
        XCTAssertTrue(m.machines[1].online, "seen 20 s ago")
        XCTAssertFalse(m.machines[2].online)
        XCTAssertTrue(m.machines[2].muted)
        XCTAssertEqual(MachinesModel.offline(nil, now: now), "Offline")
        XCTAssertEqual(MachinesModel.offline(now.addingTimeInterval(-300), now: now), "Offline · 5 min ago")
        XCTAssertEqual(MachinesModel.offline(now.addingTimeInterval(-86400 * 3), now: now), "Offline · 3 d ago")
    }

    func testSoloStateListsFoundPeers() {
        var s = snapshot()
        s.group = group([member("mbp", "100.97.81.23")])
        s.peers = [info("mbp"), info("mba", "100.71.4.12"), info("devbox", "100.88.20.3")]
        let m = MachinesModel(s, config: MachinesConfig(), environments: [], now: now)
        XCTAssertEqual(m.state, .solo)
        XCTAssertEqual(m.title, "My machines · this Mac only")
        XCTAssertEqual(m.found.map(\.name), ["mba", "devbox"])
        XCTAssertEqual(m.found.first?.detail, "100.71.4.12:7690 · oversire 0.4.0")
    }

    func testNoDaemonAndHooks() {
        let empty = MachinesModel(MachinesSnapshot(), config: MachinesConfig(), environments: [], now: now)
        XCTAssertEqual(empty.state, .noDaemon)
        XCTAssertTrue(empty.hooks.isEmpty)

        let m = MachinesModel(snapshot(), config: MachinesConfig(), environments: [], now: now)
        XCTAssertEqual(m.hooks.map(\.title), ["Claude Code", "Codex", "OpenCode"])
        XCTAssertEqual(m.hooks.map(\.status), ["Installed", "Needs approval in Codex", "Not installed"])
        XCTAssertEqual(m.hooks.map(\.action), [.remove, .remove, .install])
        XCTAssertEqual(m.missingHooks, ["opencode"])
    }

    func testVersionMismatchAndBehind() {
        var s = snapshot()
        s.group = group([member("mbp", "100.97.81.23", version: "0.3.0"), member("mba", "100.71.4.12", version: "0.3.2"),
                         member("devbox", "100.88.20.3", version: nil)])
        var m = MachinesModel(s, config: MachinesConfig(), environments: [], now: now)
        XCTAssertEqual(m.machines.map(\.version), ["0.4.0", "0.3.2", nil], "this Mac: the version of its daemon")
        XCTAssertEqual(m.machines.map(\.behind), [false, true, true], "a member without a version runs a CLI before 0.2.2")
        XCTAssertEqual(m.machines[2].hostText, "100.88.20.3 · oversire before 0.2.2")
        XCTAssertEqual(m.mismatch, "Your machines run different oversire versions: mbp 0.4.0, mba 0.3.2, devbox before 0.2.2. "
                       + "Update the older ones, so that all machines speak the same API.")

        s.group = group([member("mbp", "100.97.81.23", version: "0.4.0"), member("mba", "100.71.4.12", version: "0.4.0")])
        m = MachinesModel(s, config: MachinesConfig(), environments: [], now: now)
        XCTAssertNil(m.mismatch)
        XCTAssertEqual(m.machines.map(\.behind), [false, false])

        s.latest = "0.5.0"
        m = MachinesModel(s, config: MachinesConfig(), environments: [], now: now)
        XCTAssertNil(m.mismatch, "one version, but a newer release")
        XCTAssertEqual(m.machines.map(\.behind), [true, true])
    }

    func testUpdateNote() {
        var s = snapshot()
        XCTAssertEqual(MachinesModel(s, config: MachinesConfig(), environments: [], now: now).updateNote(now: now),
                       "The daemon checks GitHub each 6 hours. No check yet.")
        s.info?.update = DaemonUpdate(checkedAt: now.addingTimeInterval(-600), latest: "0.4.0")
        XCTAssertEqual(MachinesModel(s, config: MachinesConfig(), environments: [], now: now).updateNote(now: now),
                       "The daemon checks GitHub each 6 hours. Last check 10 min ago: latest 0.4.0.")
        s.info?.update = DaemonUpdate(checkedAt: now.addingTimeInterval(-7200), latest: "0.4.1", error: "update: no write access to /usr/local/bin")
        XCTAssertEqual(MachinesModel(s, config: MachinesConfig(), environments: [], now: now).updateNote(now: now),
                       "The last update failed 2 h ago: update: no write access to /usr/local/bin")
    }

    func testSampleScenesBuildTheirState() {
        let states = ["machines-empty", "machines-found", "machines-group"].map {
            MachinesModel(MachinesSnapshot.sample($0, now: now), config: MachinesConfig(), environments: ["mbp"], now: now).state
        }
        XCTAssertEqual(states, [.noDaemon, .solo, .group])
    }
}

// MARK: Update

@MainActor
final class MachineUpdateTests: XCTestCase {
    private func controller(_ remote: FakeDaemon?) -> MachinesController {
        let c = MachinesController()
        c.frozen = true
        c.restartWait = 0
        c.changed = {}
        var s = MachinesSnapshot()
        s.info = info("mba")
        c.use(s)
        c.daemon = { name in remote.map { DaemonClient(base: URL(string: "http://\(name):7690")!, token: "t", http: $0) } }
        return c
    }

    private func settle(_ c: MachinesController) async {
        for _ in 0..<200 where !c.updating.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testRemoteUpdate() async {
        let mbp = FakeDaemon(machine: "mbp")
        mbp.update = DaemonUpdate(checkedAt: now, latest: "0.2.2", installed: "0.2.2")
        let c = controller(mbp)
        c.update("mbp")
        XCTAssertTrue(c.updating.contains("mbp"))
        await settle(c)
        XCTAssertEqual(mbp.calls, ["POST /v1/update"])
        XCTAssertNil(c.notice)
    }

    func testRemoteUpdateErrors() async {
        let mbp = FakeDaemon(machine: "mbp")
        mbp.update = DaemonUpdate(checkedAt: now, latest: "0.2.2", error: "update: no write access to /usr/local/bin")
        var c = controller(mbp)
        c.update("mbp")
        await settle(c)
        XCTAssertEqual(c.notice, "Update mbp: update: no write access to /usr/local/bin")

        mbp.update = nil
        c = controller(mbp)
        c.update("mbp")
        await settle(c)
        XCTAssertEqual(c.notice, "Update mbp: it runs a CLI before 0.2.2, which cannot update from here. "
                       + "Open OverSire on mbp and use Update in Settings › Machines.")

        c = controller(nil)
        c.update("mbp")
        XCTAssertEqual(c.notice, "Update mbp: OverSire has no link to mbp. Check that it is online.")
    }
}

// MARK: Keyboard

@MainActor
final class MachineSheetKeyboardTests: XCTestCase {
    override func tearDown() {
        MachineSheets.open?.dismiss()
        super.tearDown()
    }

    private func key(_ code: UInt16, _ chars: String) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    /// The views that Tab visits from the first key view.
    private func loop(_ w: NSWindow) -> [NSView] {
        var out: [NSView] = []
        var v = w.contentView?.nextValidKeyView ?? w.contentView?.nextKeyView
        while let x = v, !out.contains(x), out.count < 50 { out.append(x); v = x.nextKeyView }
        return out
    }

    func testApproveDialogReturnApprovesEscapeDenies() {
        let r = JoinRequestFrame(request: "r-1", machine: "mba", host: "100.71.4.12", confirm: "4821", expiresAt: Date().addingTimeInterval(300))
        var answers: [Bool] = []
        var s = MachineSheets.approve(r, group: "My machines", over: nil) { answers.append($0) }
        XCTAssertTrue(s.performKeyEquivalent(with: key(36, "\r")))
        s = MachineSheets.approve(r, group: "My machines", over: nil) { answers.append($0) }
        s.cancelOperation(nil)
        XCTAssertEqual(answers, [true, false])
        XCTAssertNil(MachineSheets.open)
    }

    func testJoinCodeTabReachesEachControl() {
        let d = FakeDaemon(machine: "mba")
        d.online = false
        let flow = JoinFlow(local: client(d), machines: nil, http: d)
        let s = MachineSheets.joinCode(over: nil, flow: flow)
        s.recalculateKeyViewLoop()
        let views = loop(s)
        let fields = views.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        XCTAssertEqual(fields.map { $0.accessibilityLabel() }, ["Machine", "Code"])
        XCTAssertNotNil(views.first { $0 === s.cancelButton })
        XCTAssertNotNil(views.first { $0 === s.primaryButton })
        XCTAssertEqual(s.cancelButton?.keyEquivalent, "\u{1b}")
        XCTAssertEqual(s.primaryButton?.keyEquivalent, "\r")
        s.cancelOperation(nil)
        XCTAssertNil(MachineSheets.open)
        XCTAssertEqual(flow.phase, .idle)
    }

    func testOneButtonSheetsCloseOnReturnAndEscape() {
        var s = MachineSheets.add(over: nil, invite: GroupInvite(code: "K7Q2-M9XD", via: "mbp", expiresAt: Date().addingTimeInterval(600)))
        XCTAssertTrue(s.performKeyEquivalent(with: key(36, "\r")))
        XCTAssertNil(MachineSheets.open)
        s = MachineSheets.waiting(over: nil, phase: .waiting(confirm: "4821", host: "mbp"), expires: Date().addingTimeInterval(60)) {}
        s.cancelOperation(nil)
        XCTAssertNil(MachineSheets.open)
        var answer: Bool?
        s = MachineSheets.consent(over: nil) { answer = $0 }
        s.cancelOperation(nil)
        XCTAssertEqual(answer, false)
    }

    func testClockText() {
        XCTAssertEqual(DialogSheet.clock(581), "9:41")
        XCTAssertEqual(DialogSheet.clock(-3), "0:00")
    }
}
