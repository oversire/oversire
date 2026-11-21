import OverSireCore
import OverSireSync
import OverSireTestKit
import XCTest
@testable import OverSireApp

final class VendorCallsTests: XCTestCase {
    actor Outlet: EventOutlet {
        var rows: [EventDraft] = []
        func append(_ drafts: [EventDraft]) async { rows += drafts }
        func link(_ links: [ItemLink]) async {}
    }

    final class FakeRunner: VendorProcessRunning, @unchecked Sendable {
        private let lock = NSLock()
        private(set) var launches: [VendorLaunch] = []
        private var running = 0
        private(set) var peak = 0
        var exit = VendorExit(status: 0, stdout: Data("[]\n".utf8), stderr: Data(), truncated: false, timedOut: false, ms: 840)
        var delay: UInt64 = 0
        var error: (any Error)?

        func run(_ launch: VendorLaunch) async throws -> VendorExit {
            lock.withLock {
                launches.append(launch)
                running += 1
                peak = max(peak, running)
            }
            defer { lock.withLock { running -= 1 } }
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            if let error { throw error }
            return exit
        }
    }

    let plane = AccountConfig(account: AccountID(provider: "plane", id: "ocral"), values: ["workspace": "ocral"], secretKeys: ["PLANE_TOKEN_ocral"])
    let gh = AccountConfig(account: AccountID(provider: "github", id: "oversire"))
    let ghOcral = AccountConfig(account: AccountID(provider: "github", id: "ocral"))
    let actions = AccountConfig(account: AccountID(provider: "github-actions", id: "oversire"))
    let token = "plane_api_0123456789abcdef"
    let registry = AppEnvironment().registry

    func world(client: Bool = false, accounts: [AccountConfig]? = nil, token: String? = "plane_api_0123456789abcdef",
               installed: Set<String> = ["plane-cli", "gh"]) -> VendorCalls.World {
        let accounts = accounts ?? [plane, gh, actions]
        let registry = registry
        return VendorCalls.World(
            isClient: { client }, accounts: { accounts }, descriptor: { registry.descriptor($0) }, token: { _ in token },
            projects: { [(identifier: "OVERSIRE", account: AccountID(provider: "plane", id: "ocral")), (identifier: "SLING", account: AccountID(provider: "plane", id: "ocral"))] },
            find: { installed.contains($0) ? "/usr/local/bin/\($0)" : nil },
            inherited: { ["GH_CONFIG_DIR": "/cfg", "AWS_SECRET": "no"] })
    }

    func rig(_ w: VendorCalls.World? = nil, _ runner: FakeRunner = FakeRunner()) -> (VendorCalls, FakeRunner, Outlet) {
        let o = Outlet()
        let desk = EventDesk(outlet: o)
        desk.machine = { "mba" }
        let calls = VendorCalls(world: w ?? world(), runner: runner, events: desk)
        return (calls, runner, o)
    }

    func call(_ id: String = "c1", _ action: String = "vendor.run", project: String? = nil, account: String? = nil, args: [String] = ["wi", "attachment", "list", "OVERSIRE-12"],
              cwd: String? = nil, agent: String? = "claude s1") -> AppCall {
        var o: [String: JSONValue] = ["args": .array(args.map(JSONValue.string))]
        if let project { o["project"] = .string(project) }
        if let account { o["account"] = .string(account) }
        if let cwd { o["cwd"] = .string(cwd) }
        return AppCall(id: id, action: action, args: .object(o), agent: agent)
    }

    func rows(_ o: Outlet, count: Int) async -> [EventDraft] {
        for _ in 0..<200 {
            let r = await o.rows
            if r.count >= count { return r }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await o.rows
    }

    func output(_ r: AppCallResult) throws -> VendorRunOutput {
        try JSONValue.decode(VendorRunOutput.self, from: XCTUnwrap(r.data))
    }

    func testRunsPlaneCLIWithKeychainToken() async throws {
        let (calls, runner, _) = rig()
        let r = await calls.handle(call(project: "OVERSIRE", cwd: NSTemporaryDirectory()))
        XCTAssertEqual(r.status, .ok)
        let l = try XCTUnwrap(runner.launches.first)
        XCTAssertEqual(l.exe, "/usr/local/bin/plane-cli")
        XCTAssertEqual(l.args, ["wi", "attachment", "list", "OVERSIRE-12"])
        XCTAssertEqual(l.environment["PLANE_API_KEY"], token)
        XCTAssertEqual(l.environment["PLANE_WORKSPACE"], "ocral")
        XCTAssertEqual(l.environment["PLANE_PROJECT"], "OVERSIRE")
        XCTAssertEqual(l.environment["PLANE_MANAGED_BY"], "OverSire")
        XCTAssertEqual(l.environment["PLANE_HOST"], "https://api.plane.so")
        XCTAssertFalse(l.args.contains { $0.contains(token) }, "the token is never in argv")
        XCTAssertEqual(l.cwd?.path, NSTemporaryDirectory().hasSuffix("/") ? String(NSTemporaryDirectory().dropLast()) : NSTemporaryDirectory())
        XCTAssertEqual(l.timeout, .seconds(45))
        XCTAssertEqual(l.logWords, ["plane-cli", "wi", "attachment", "list"])
        XCTAssertNil(l.environment["AWS_SECRET"])
        let out = try output(r)
        XCTAssertEqual(out.vendor, "plane-cli")
        XCTAssertEqual(out.account, "plane:ocral")
        XCTAssertEqual(out.stdout, "[]\n")
    }

    func testRemovesTokenFromOutput() async throws {
        let runner = FakeRunner()
        runner.exit = VendorExit(status: 1, stdout: Data("key \(token) ok".utf8), stderr: Data("bad \(token)".utf8), truncated: false, timedOut: false, ms: 5)
        let (calls, _, _) = rig(nil, runner)
        let out = try output(await calls.handle(call(project: "OVERSIRE")))
        XCTAssertFalse(out.stdout.contains(token))
        XCTAssertFalse(out.stderr.contains(token))
        XCTAssertEqual(out.stdout, "key [secret] ok")
    }

    func testCleanDropsPartialTokenAtCut() {
        let t = "abcdefghijklmnop"
        let cut = Data("text abcdefghij".utf8)
        let clean = VendorCalls.clean(cut, truncated: true, secrets: [t])
        XCTAssertFalse(clean.contains("abcde"), clean)
        XCTAssertEqual(VendorCalls.clean(cut, truncated: false, secrets: [t]), "text abcdefghij")
        XCTAssertEqual(VendorCalls.clean(Data("a \(t) b".utf8), truncated: false, secrets: [t]), "a [secret] b")
        XCTAssertEqual(VendorCalls.clean(Data("tok ghp_abcdefghijklmnopqrstuvwx".utf8), truncated: false, secrets: []), "tok [secret]")
    }

    func testResolvesAccountByProject() async throws {
        let (calls, _, _) = rig()
        let r = try await calls.resolve(VendorRunArgs(project: "oversire", args: ["wi"])).get()
        XCTAssertEqual(r.config.account.id, "ocral")
        XCTAssertEqual(r.project, "OVERSIRE")
        XCTAssertEqual(r.cli.binary, "plane-cli")
    }

    func testAccountFlagForms() async throws {
        let (calls, runner, _) = rig()
        for (name, exe, provider) in [("plane:ocral", "plane-cli", "plane"), ("PLANE:Ocral", "plane-cli", "plane"), ("ocral", "plane-cli", "plane"),
                                      ("oversire", "gh", "github"), ("github:oversire", "gh", "github")] {
            let r = try await calls.resolve(VendorRunArgs(account: name, args: ["x"])).get()
            XCTAssertEqual(r.cli.binary, exe, name)
            XCTAssertEqual(r.config.account.provider.rawValue, provider, name)
            XCTAssertNil(r.project)
        }
        let r = await calls.handle(call(account: "oversire", args: ["pr", "list"]))
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(runner.launches.last?.environment["GH_CONFIG_DIR"], "/cfg")
        XCTAssertNil(runner.launches.last?.environment["PLANE_API_KEY"])
        XCTAssertNil(runner.launches.last?.environment["AWS_SECRET"])
    }

    func testGitHubActionsAccountHasNoCLI() async {
        let (calls, _, _) = rig()
        let r = await calls.resolve(VendorRunArgs(account: "github-actions:oversire", args: ["x"]))
        guard case .failure(let e) = r else { return XCTFail("no CLI expected") }
        XCTAssertEqual(e, .noCLI("GitHub Actions"))
    }

    func testAmbiguousAccount() async {
        let (calls, runner, _) = rig(world(accounts: [plane, ghOcral]))
        let r = await calls.handle(call(account: "ocral"))
        XCTAssertEqual(r.status, .notAllowed)
        XCTAssertEqual(r.summary, "ocral is plane:ocral or github:ocral. Give --account <provider>:<id>.")
        XCTAssertTrue(runner.launches.isEmpty)
    }

    func testUnknownProject() async {
        let (calls, _, _) = rig()
        let r = await calls.handle(call(project: "NOPE"))
        XCTAssertEqual(r.status, .notAllowed)
        XCTAssertEqual(r.summary, "OverSire has no loaded project NOPE.")
        let none = await calls.handle(call())
        XCTAssertEqual(none.summary, "Give --project or --account. Run oversire vendor ls.")
        let both = await calls.handle(call(project: "OVERSIRE", account: "plane:ocral"))
        XCTAssertEqual(both.status, .notAllowed)
        let unknown = await calls.handle(call(account: "zzz"))
        XCTAssertEqual(unknown.summary, "OverSire has no account zzz.")
    }

    func testRefusalDoesNotLaunch() async {
        let (calls, runner, o) = rig()
        for args in [["auth", "login"], ["wi", "list", "--host", "evil"], ["-w", "x", "wi"], ["wi", "list", "-k=x"], ["listen"]] {
            let r = await calls.handle(call(project: "OVERSIRE", args: args))
            XCTAssertEqual(r.status, .notAllowed, "\(args)")
        }
        XCTAssertTrue(runner.launches.isEmpty)
        try? await Task.sleep(nanoseconds: 100_000_000)
        let n = await o.rows.count
        XCTAssertEqual(n, 0)
    }

    func testNotInstalled() async {
        let (calls, runner, _) = rig(world(installed: []))
        let r = await calls.handle(call(project: "OVERSIRE"))
        XCTAssertEqual(r.status, .notAllowed)
        XCTAssertEqual(r.summary, "plane-cli is not in /opt/homebrew/bin, /usr/local/bin or /usr/bin.")
        XCTAssertTrue(runner.launches.isEmpty)
    }

    func testNoToken() async {
        let (calls, runner, _) = rig(world(token: nil))
        let r = await calls.handle(call(project: "OVERSIRE"))
        XCTAssertEqual(r.status, .notAllowed)
        XCTAssertEqual(r.summary, "The Keychain has no token for plane:ocral. Add it in Settings › Providers.")
        XCTAssertTrue(runner.launches.isEmpty)
        let (c2, r2, _) = rig(world(token: nil))
        let ok = await c2.handle(call(account: "github:oversire", args: ["pr", "list"]))
        XCTAssertEqual(ok.status, .ok, "gh needs no token")
        XCTAssertEqual(r2.launches.count, 1)
    }

    func testBadFolder() async {
        let (calls, runner, _) = rig()
        for cwd in ["/nonexistent-folder-xyz", "relative/path", "/etc/hosts"] {
            let r = await calls.handle(call(project: "OVERSIRE", cwd: cwd))
            XCTAssertEqual(r.status, .notAllowed, cwd)
        }
        XCTAssertTrue(runner.launches.isEmpty)
    }

    func testClientRefuses() async {
        let (calls, runner, _) = rig(world(client: true))
        let run = await calls.handle(call(project: "OVERSIRE"))
        XCTAssertEqual(run.status, .notAllowed)
        XCTAssertEqual(run.summary, "This Mac is a client. Run the command on the home Mac.")
        let list = await calls.handle(AppCall(id: "l", action: "vendor.list"))
        XCTAssertEqual(list.status, .notAllowed)
        XCTAssertTrue(runner.launches.isEmpty)
    }

    func testWritesOneVendorCallEvent() async throws {
        let (calls, _, o) = rig()
        _ = await calls.handle(call(project: "OVERSIRE"))
        let r = await rows(o, count: 1)
        try await Task.sleep(nanoseconds: 100_000_000)
        let all = await o.rows
        XCTAssertEqual(r.count, 1)
        XCTAssertEqual(all.count, 1)
        let e = all[0]
        XCTAssertEqual(e.kind, .vendorCall)
        XCTAssertEqual(e.summary, "plane-cli wi attachment list, exit 0")
        XCTAssertEqual(e.actorType, .agent)
        XCTAssertEqual(e.actor, "claude s1")
        XCTAssertEqual(e.project, "oversire")
        XCTAssertEqual(e.payload?["command"], .string("wi attachment list"))
        XCTAssertEqual(e.payload?["exit"], .int(0))
        XCTAssertEqual(e.payload?["account"], .string("plane:ocral"))
        XCTAssertFalse(e.summary.contains("OVERSIRE-12"))
        XCTAssertFalse(String(describing: e.payload).contains("OVERSIRE-12"))
        XCTAssertEqual(EventCatalog.repo.problems(e), [])
    }

    func testNonZeroExitIsOk() async throws {
        let runner = FakeRunner()
        runner.exit = VendorExit(status: 2, stdout: Data(), stderr: Data("not found\n".utf8), truncated: false, timedOut: false, ms: 9)
        let (calls, _, o) = rig(nil, runner)
        let r = await calls.handle(call(project: "OVERSIRE"))
        XCTAssertEqual(r.status, .ok)
        let out = try output(r)
        XCTAssertEqual(out.exit, 2)
        XCTAssertEqual(out.stderr, "not found\n")
        let e = await rows(o, count: 1)
        XCTAssertEqual(e.first?.summary, "plane-cli wi attachment list, exit 2")
        XCTAssertNil(e.first?.payload?["truncated"])
    }

    func testTruncatedIsMarked() async throws {
        let runner = FakeRunner()
        runner.exit = VendorExit(status: 0, stdout: Data("a long text".utf8), stderr: Data(), truncated: true, timedOut: false, ms: 9)
        let (calls, _, o) = rig(nil, runner)
        let out = try output(await calls.handle(call(project: "OVERSIRE")))
        XCTAssertEqual(out.truncated, true)
        let e = await rows(o, count: 1)
        XCTAssertEqual(e.first?.payload?["truncated"], .bool(true))
    }

    func testTimeoutIsFailed() async throws {
        let runner = FakeRunner()
        runner.exit = VendorExit(status: 15, stdout: Data("partial".utf8), stderr: Data(), truncated: false, timedOut: true, ms: 45000)
        let (calls, _, _) = rig(nil, runner)
        let r = await calls.handle(call(project: "OVERSIRE"))
        XCTAssertEqual(r.status, .failed)
        XCTAssertEqual(r.summary, "plane-cli did not end in 45 s. The app stopped it. A change can be made already.")
        let out = try output(r)
        XCTAssertEqual(out.stdout, "partial")
        XCTAssertEqual(out.timedOut, true)
    }

    func testStartErrorIsFailed() async {
        let runner = FakeRunner()
        runner.error = CocoaError(.fileNoSuchFile)
        let (calls, _, o) = rig(nil, runner)
        let r = await calls.handle(call(project: "OVERSIRE"))
        XCTAssertEqual(r.status, .failed)
        XCTAssertTrue(r.summary.hasPrefix("OverSire could not start plane-cli"))
        let n = await o.rows.count
        XCTAssertEqual(n, 0)
    }

    func testOneCallPerAccount() async {
        let runner = FakeRunner()
        runner.delay = 80_000_000
        let (calls, _, _) = rig(nil, runner)
        await withTaskGroup(of: Void.self) { g in
            for i in 0..<3 { g.addTask { _ = await calls.handle(self.call("p\(i)", project: "OVERSIRE")) } }
        }
        XCTAssertEqual(runner.launches.count, 3)
        XCTAssertEqual(runner.peak, 1, "one running call for each account")
        let other = FakeRunner()
        other.delay = 150_000_000
        let (c2, _, _) = rig(nil, other)
        await withTaskGroup(of: Void.self) { g in
            g.addTask { _ = await c2.handle(self.call("a", project: "OVERSIRE")) }
            g.addTask { _ = await c2.handle(self.call("b", account: "github:oversire", args: ["pr", "list"])) }
        }
        XCTAssertEqual(other.peak, 2, "accounts do not wait for each other")
    }

    func testListRows() async throws {
        let (calls, _, _) = rig(world(installed: ["plane-cli"]))
        let r = await calls.handle(AppCall(id: "l", action: "vendor.list"))
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.summary, "2 vendor CLIs.")
        let rows = try JSONValue.decode([VendorCLIRow].self, from: XCTUnwrap(r.data))
        XCTAssertEqual(rows, [
            VendorCLIRow(provider: "github", vendor: "GitHub", binary: "gh", path: nil, accounts: ["github:oversire"], projects: []),
            VendorCLIRow(provider: "plane", vendor: "Plane", binary: "plane-cli", path: "/usr/local/bin/plane-cli", accounts: ["plane:ocral"], projects: ["OVERSIRE", "SLING"]),
        ])
    }

    func testBadArgsAreNotAllowed() async {
        let (calls, _, _) = rig()
        let r = await calls.handle(AppCall(id: "x", action: "vendor.run", args: .object(["project": .string("OVERSIRE")])))
        XCTAssertEqual(r.status, .notAllowed)
    }
}
