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
               installed: Set<String> = ["plane-cli", "gh"],
               versions: [String: String] = ["plane-cli": "0.2.2", "gh": "2.102.0", "big-timer-cli": "1.0.12"],
               projects: [(identifier: String, account: AccountID)]? = nil) -> VendorCalls.World {
        let accounts = accounts ?? [plane, gh, actions]
        let projects = projects ?? [(identifier: "OVERSIRE", account: AccountID(provider: "plane", id: "ocral")),
                                    (identifier: "SLING", account: AccountID(provider: "plane", id: "ocral"))]
        let registry = registry
        return VendorCalls.World(
            isClient: { client }, accounts: { accounts }, descriptor: { registry.descriptor($0) }, token: { _ in token },
            projects: { projects },
            find: { installed.contains($0) ? "/usr/local/bin/\($0)" : nil },
            inherited: { ["GH_CONFIG_DIR": "/cfg", "AWS_SECRET": "no"] },
            vendors: { VendorCalls.vendors(in: registry) },
            version: { _, cli in versions[cli.binary].flatMap(VendorVersion.init) })
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
        XCTAssertEqual(r.summary, "plane-cli is not installed. Run `oversire vendor install plane`.")
        XCTAssertTrue(runner.launches.isEmpty)
    }

    func testRunRefusesOldBinary() async {
        let (calls, runner, o) = rig(world(versions: ["plane-cli": "0.2.1"]))
        let r = await calls.handle(call(project: "OVERSIRE"))
        XCTAssertEqual(r.status, .notAllowed)
        XCTAssertEqual(r.summary, "plane-cli 0.2.1 is older than 0.2.2. Run `oversire vendor install plane`.")
        XCTAssertTrue(runner.launches.isEmpty)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let n = await o.rows.count
        XCTAssertEqual(n, 0, "a refusal writes no row")
    }

    func testRunRefusesBinaryWithNoVersion() async {
        let (calls, runner, _) = rig(world(versions: [:]))
        let r = await calls.handle(call(project: "OVERSIRE"))
        XCTAssertEqual(r.status, .notAllowed)
        XCTAssertTrue(r.summary.contains("gives no version"), r.summary)
        XCTAssertTrue(runner.launches.isEmpty)
    }

    func testGhHasNoFloor() async {
        let (calls, runner, _) = rig(world(versions: [:]))
        let r = await calls.handle(call(account: "github:oversire", args: ["pr", "list"]))
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(runner.launches.first?.exe, "/usr/local/bin/gh")
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
            VendorCLIRow(provider: "github", vendor: "GitHub", binary: "gh", path: nil, state: .missing, accounts: ["github:oversire"], projects: []),
            VendorCLIRow(provider: "plane", vendor: "Plane", binary: "plane-cli", path: "/usr/local/bin/plane-cli", version: "0.2.2",
                         minVersion: "0.2.2", source: .path, state: .ok, accounts: ["plane:ocral"], projects: ["OVERSIRE", "SLING"]),
        ])
        let (all, _, _) = rig()
        let both = await all.list()
        XCTAssertEqual(both.first { $0.provider == "github" }?.version, "2.102.0")
        XCTAssertEqual(both.first { $0.provider == "github" }?.state, .ok)
        XCTAssertNil(both.first { $0.provider == "github" }?.minVersion)
    }

    func testListOldAndMissing() async {
        let (calls, _, _) = rig(world(installed: ["plane-cli"], versions: ["plane-cli": "0.2.1"]))
        let rows = await calls.list()
        XCTAssertEqual(rows.map(\.provider), ["github", "plane"])
        XCTAssertEqual(rows.map(\.state), [.missing, .old])
        XCTAssertEqual(rows.last?.version, "0.2.1")
        XCTAssertNil(rows.first?.source)
    }

    func testBinarySeam() async throws {
        let (calls, _, _) = rig()
        let found = await calls.binary("plane")
        let b = try XCTUnwrap(found)
        XCTAssertEqual(b.path, "/usr/local/bin/plane-cli")
        XCTAssertEqual(b.version, VendorVersion("0.2.2"))
        XCTAssertEqual(b.source, .path)
        XCTAssertEqual(b.state, .ok)
        let none = await calls.binary("github-actions")
        XCTAssertNil(none)
    }

    func testVendorNamed() {
        let (calls, _, _) = rig()
        XCTAssertEqual(try calls.vendor(named: "Plane").get(), "plane")
        guard case .failure(let e) = calls.vendor(named: "linear") else { return XCTFail("linear is no vendor") }
        XCTAssertEqual(e, .unknownVendor("linear", known: ["bigtimer", "github", "plane"]))
        XCTAssertEqual(e.message, "OverSire has no vendor linear. Give bigtimer, github or plane.")
    }

    // MARK: vendor.skill

    static let planeHeader = """
        # Plane (plane): plane-cli through OverSire

        The OverSire app on this Mac runs plane-cli for you. Do not run plane-cli directly: it has no token outside OverSire.

        - Run: `oversire vendor run --project <PROJECT> -- <command> [flags]`, or `oversire vendor run --account <ACCOUNT> -- <command> [flags]`.
        - Put the command first, then its flags. Help: `oversire vendor run --project <PROJECT> -- help <command>`, or `-- <command> --help`.
        - The app sets: PLANE_API_KEY (the token of the account), PLANE_HOST (the host), PLANE_WORKSPACE (the workspace), PLANE_PROJECT (the project of --project), PLANE_MANAGED_BY=OverSire.
        - The app refuses these flags: --api-key, -k, --host, --workspace, -w. With --project, also: --project, -p.
        - The app refuses these commands: auth login, auth logout, auth workspace add, auth workspace remove, config set, listen, serve.
        - Accounts: plane:ocral. Projects: OVERSIRE, SLING.
        - plane-cli 0.2.2: PATH copy at /usr/local/bin/plane-cli.
        - The app sends no stdin and gives no TTY. The output has at most 1 MB. The command has 45 s.

        """

    func skillCall(_ vendor: String) -> AppCall {
        AppCall(id: "s1", action: "vendor.skill", args: .object(["vendor": .string(vendor)]), agent: "claude s1")
    }

    func skillOutput(_ r: AppCallResult) throws -> VendorSkillOutput {
        try JSONValue.decode(VendorSkillOutput.self, from: XCTUnwrap(r.data))
    }

    func testSkillPlaneHeaderAndText() async throws {
        let runner = FakeRunner()
        runner.exit = VendorExit(status: 0, stdout: Data("# plane-cli\nUse wi list.\n".utf8), stderr: Data(), truncated: false, timedOut: false, ms: 20)
        let (calls, _, o) = rig(nil, runner)
        let r = await calls.handle(skillCall("plane"))
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.summary, "The skill of plane-cli.")
        let out = try skillOutput(r)
        XCTAssertEqual(out.reference, .skill)
        XCTAssertEqual(out.path, "/usr/local/bin/plane-cli")
        XCTAssertEqual(out.markdown, Self.planeHeader + "\n## plane-cli reference\n\n# plane-cli\nUse wi list.\n")
        XCTAssertEqual(runner.launches.count, 1)
        let l = try XCTUnwrap(runner.launches.first)
        XCTAssertEqual(l.args, ["skill"])
        var env = VendorCalls.base
        env["PLANE_MANAGED_BY"] = "OverSire"
        XCTAssertEqual(l.environment, env)
        XCTAssertNil(l.environment["PLANE_API_KEY"])
        XCTAssertNil(l.cwd)
        XCTAssertEqual(l.timeout, .seconds(45))
        XCTAssertEqual(l.logWords, ["plane-cli", "skill"])
        try await Task.sleep(nanoseconds: 100_000_000)
        let n = await o.rows.count
        XCTAssertEqual(n, 0, "a read writes no row")
    }

    func testSkillBigTimerHeader() async throws {
        let bt = AccountConfig(account: AccountID(provider: "bigtimer", id: "bt.example.com"), values: ["server": "https://bt.example.com"])
        let w = world(accounts: [bt], installed: ["big-timer-cli"],
                      projects: [(identifier: "ACME", account: AccountID(provider: "bigtimer", id: "bt.example.com"))])
        let (calls, _, _) = rig(w)
        let page = try await calls.skill(VendorSkillArgs(vendor: "bigtimer")).get()
        XCTAssertEqual(page.header, """
            # Big Timer (bigtimer): big-timer-cli through OverSire

            The OverSire app on this Mac runs big-timer-cli for you. Do not run big-timer-cli directly: it has no token outside OverSire.

            - Run: `oversire vendor run --project <PROJECT> -- <command> [flags]`, or `oversire vendor run --account <ACCOUNT> -- <command> [flags]`.
            - Put the command first, then its flags. Help: `oversire vendor run --project <PROJECT> -- help <command>`, or `-- <command> --help`.
            - The app sets: BIGTIMER_TOKEN (the token of the account), BIGTIMER_SERVER (the host), BIGTIMER_MANAGED_BY=OverSire.
            - The app refuses these flags: --server, -s, --token, -t.
            - The app refuses these commands: auth login, auth logout, auth join, auth rotate, token create, sync stream.
            - Accounts: bigtimer:bt.example.com. Projects: ACME.
            - big-timer-cli 1.0.12: PATH copy at /usr/local/bin/big-timer-cli.
            - The app sends no stdin and gives no TTY. The output has at most 1 MB. The command has 45 s.

            """)
    }

    func testSkillGitHubUsesHelpWithoutRun() async throws {
        let (calls, runner, _) = rig()
        let r = await calls.handle(skillCall("github"))
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.summary, "gh has no skill text. Read its help.")
        XCTAssertTrue(runner.launches.isEmpty)
        let out = try skillOutput(r)
        XCTAssertEqual(out.reference, .help)
        XCTAssertEqual(out.markdown, """
            # GitHub (github): gh through OverSire

            The OverSire app on this Mac runs gh for you.

            - Run: `oversire vendor run --account <ACCOUNT> -- <command> [flags]`.
            - Put the command first, then its flags. Help: `oversire vendor run --account <ACCOUNT> -- help <command>`, or `-- <command> --help`.
            - gh keeps its own login. OverSire has no token for it.
            - The app refuses these flags: --watch.
            - The app refuses these commands: auth, config set, extension, alias set, run watch, codespace ssh, skill.
            - Accounts: github:oversire. Projects: none.
            - gh 2.102.0: PATH copy at /usr/local/bin/gh.
            - The app sends no stdin and gives no TTY. The output has at most 1 MB. The command has 45 s.

            ## gh reference

            gh has no skill text for OverSire. Read the help: `oversire vendor run --account <ACCOUNT> -- help <command>`, or `-- <command> --help`.

            """)
    }

    func testSkillOldBinaryFallsBack() async throws {
        let cases: [(VendorExit?, (any Error)?)] = [
            (VendorExit(status: 3, stdout: Data("No help topic for 'skill'".utf8), stderr: Data(), truncated: false, timedOut: false, ms: 5), nil),
            (nil, CocoaError(.fileNoSuchFile)),
            (VendorExit(status: 0, stdout: Data("part".utf8), stderr: Data(), truncated: false, timedOut: true, ms: 45000), nil),
            (VendorExit(status: 0, stdout: Data("part".utf8), stderr: Data(), truncated: true, timedOut: false, ms: 5), nil),
            (VendorExit(status: 0, stdout: Data(" \n".utf8), stderr: Data(), truncated: false, timedOut: false, ms: 5), nil),
        ]
        for (i, c) in cases.enumerated() {
            let runner = FakeRunner()
            if let e = c.0 { runner.exit = e }
            runner.error = c.1
            let (calls, _, _) = rig(world(versions: ["plane-cli": "0.2.1"]), runner)
            let r = await calls.handle(skillCall("plane"))
            XCTAssertEqual(r.status, .ok, "\(i)")
            XCTAssertEqual(r.summary, "plane-cli gave no skill text. Read its help.", "\(i)")
            let out = try skillOutput(r)
            XCTAssertEqual(out.reference, .help, "\(i)")
            XCTAssertTrue(out.markdown.contains("plane-cli gave no skill text. It can be an old version."), "\(i)")
            XCTAssertTrue(out.markdown.contains("- plane-cli 0.2.1: old, OverSire needs 0.2.2. PATH copy at /usr/local/bin/plane-cli.\n"), "\(i)")
            XCTAssertEqual(runner.launches.count, 1, "\(i)")
        }
    }

    func testSkillNotInstalled() async throws {
        let (calls, runner, _) = rig(world(installed: []))
        let r = await calls.handle(skillCall("plane"))
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(r.summary, "plane-cli is not installed.")
        XCTAssertTrue(runner.launches.isEmpty)
        let out = try skillOutput(r)
        XCTAssertEqual(out.reference, .notInstalled)
        XCTAssertNil(out.path)
        XCTAssertTrue(out.markdown.contains("\n- plane-cli: not installed.\n"), out.markdown)
        XCTAssertTrue(out.markdown.hasSuffix("Run `oversire vendor install plane`.\n"), out.markdown)
    }

    func testSkillVendorNames() async {
        let (calls, _, _) = rig()
        let upper = await calls.handle(skillCall("PLANE"))
        XCTAssertEqual(upper.status, .ok)
        for name in ["plane-cli", "github-actions", ""] {
            let r = await calls.handle(skillCall(name))
            XCTAssertEqual(r.status, .notAllowed, name)
            XCTAssertEqual(r.summary, VendorCallError.unknownVendor(name, known: ["bigtimer", "github", "plane"]).message, name)
        }
        let bad = await calls.handle(AppCall(id: "x", action: "vendor.skill", args: .object([:])))
        XCTAssertEqual(bad.summary, VendorCallError.unknownVendor("", known: ["bigtimer", "github", "plane"]).message)
    }

    func testSkillNoAccount() async throws {
        let (calls, _, _) = rig(world(accounts: []))
        let r = await calls.handle(skillCall("plane"))
        XCTAssertEqual(r.status, .ok)
        XCTAssertTrue(try skillOutput(r).markdown.contains("- Accounts: none. Add one in Settings › Providers. Projects: OVERSIRE, SLING.\n"))
    }

    func testSkillClientRefuses() async {
        let (calls, runner, _) = rig(world(client: true))
        let r = await calls.handle(skillCall("plane"))
        XCTAssertEqual(r.status, .notAllowed)
        XCTAssertEqual(r.summary, VendorCallError.client.message)
        XCTAssertTrue(runner.launches.isEmpty)
    }

    func testRunAllowsHelpFirst() async throws {
        let (calls, runner, o) = rig()
        let r = await calls.handle(call(project: "OVERSIRE", args: ["--help"]))
        XCTAssertEqual(r.status, .ok)
        XCTAssertEqual(runner.launches.first?.args, ["--help"])
        let e = await rows(o, count: 1)
        XCTAssertEqual(e.first?.summary, "plane-cli help, exit 0")
    }

    func testRunPlaneWorkspaceAndProjectFlags() async {
        let (calls, runner, _) = rig()
        let p = await calls.handle(call(project: "OVERSIRE", args: ["wi", "list", "-p", "SLING"]))
        XCTAssertEqual(p.status, .notAllowed)
        XCTAssertEqual(p.summary, "OverSire sets -p from --project. Do not give it.")
        XCTAssertTrue(runner.launches.isEmpty)
        let a = await calls.handle(call(account: "plane:ocral", args: ["wi", "list", "-p", "SLING"]))
        XCTAssertEqual(a.status, .ok)
        XCTAssertEqual(runner.launches.count, 1)
        let w = await calls.handle(call(account: "plane:ocral", args: ["wi", "list", "-w", "x"]))
        XCTAssertEqual(w.status, .notAllowed)
        XCTAssertEqual(w.summary, "OverSire sets -w. Do not give it.")
    }

    func testDescriptorSkillCommands() {
        XCTAssertEqual(registry.descriptor("plane")?.cli?.skillCommand, ["skill"])
        XCTAssertEqual(registry.descriptor("bigtimer")?.cli?.skillCommand, ["skill"])
        XCTAssertNotNil(registry.descriptor("github")?.cli)
        XCTAssertNil(registry.descriptor("github")?.cli?.skillCommand)
    }

    func testBadArgsAreNotAllowed() async {
        let (calls, _, _) = rig()
        let r = await calls.handle(AppCall(id: "x", action: "vendor.run", args: .object(["project": .string("OVERSIRE")])))
        XCTAssertEqual(r.status, .notAllowed)
    }
}
