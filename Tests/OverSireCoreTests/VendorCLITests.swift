import XCTest
@testable import OverSireCore

final class VendorCLITests: XCTestCase {
    let plane = VendorCLI(binary: "plane-cli", tokenEnv: "PLANE_API_KEY", hostEnv: "PLANE_HOST", hostField: "host",
                          defaultHost: "https://api.plane.so", accountEnv: "PLANE_WORKSPACE", projectEnv: "PLANE_PROJECT",
                          managedEnv: "PLANE_MANAGED_BY", lockedFlags: ["--api-key", "-k", "--host"],
                          deniedCommands: [["auth", "login"], ["listen"], ["serve"]])
    let bigTimer = VendorCLI(binary: "big-timer-cli", tokenEnv: "BIGTIMER_TOKEN", hostEnv: "BIGTIMER_SERVER", hostField: "server",
                             lockedFlags: ["--server", "-s", "--token", "-t"], deniedCommands: [["sync", "stream"]])
    let gh = VendorCLI(binary: "gh", passEnv: ["GH_CONFIG_DIR", "SSH_AUTH_SOCK"], deniedCommands: [["auth"]])
    let base = ["PATH": "/usr/bin", "HOME": "/Users/x", "LANG": "en_US.UTF-8", "TMPDIR": "/tmp", "NO_COLOR": "1", "TERM": "dumb"]

    func testCommandWords() {
        XCTAssertEqual(VendorCLI.command(["wi", "attachment", "list", "OVERSIRE-12", "--json"]), ["wi", "attachment", "list", "OVERSIRE-12"])
        XCTAssertEqual(VendorCLI.command(["--json", "wi"]), [])
    }

    func testSummaryWordsDropIdsAndText() {
        XCTAssertEqual(VendorCLI.summaryWords(["wi", "attachment", "list", "OVERSIRE-12"]), ["wi", "attachment", "list"])
        XCTAssertEqual(VendorCLI.summaryWords(["issue", "comment", "add", "ACME-1", "fix it"]), ["issue", "comment", "add"])
        XCTAssertEqual(VendorCLI.summaryWords(["wi", "get", "ab12cd"]), ["wi", "get"])
        XCTAssertEqual(VendorCLI.summaryWords(["wi", "list", "--json"]), ["wi", "list"])
        XCTAssertEqual(VendorCLI.summaryWords(["a", "b", "c", "d"]), ["a", "b", "c"])
    }

    func testRefusesLockedFlags() {
        for flag in ["--host", "-host", "--host=x", "-k", "-k=x", "--api-key"] {
            XCTAssertEqual(plane.refusal(["wi", "list", flag], project: false), .lockedFlag(String(flag.prefix { $0 != "=" })), flag)
        }
        for flag in ["--hostname", "-kx", "--key"] { XCTAssertNil(plane.refusal(["wi", "list", flag], project: false), flag) }
        XCTAssertNil(bigTimer.refusal(["server", "version"], project: false), "a command word is no flag")
        XCTAssertNil(plane.refusal(["wi", "list", "host", "k"], project: false), "a value without a dash is no flag")
    }

    func testRefusesDeniedCommands() {
        XCTAssertEqual(plane.refusal(["auth", "login"], project: false), .deniedCommand("auth login"))
        XCTAssertNil(plane.refusal(["auth", "show"], project: false))
        XCTAssertEqual(plane.refusal(["listen", "--events", "x"], project: false), .deniedCommand("listen"))
        XCTAssertEqual(bigTimer.refusal(["sync", "stream"], project: false), .deniedCommand("sync stream"))
        XCTAssertNil(bigTimer.refusal(["sync", "pull"], project: false))
        XCTAssertEqual(gh.refusal(["auth", "token"], project: false), .deniedCommand("auth"))
        XCTAssertEqual(plane.refusal(["Auth", "Login"], project: false), .deniedCommand("auth login"))
    }

    func testRefusesFlagFirst() {
        XCTAssertEqual(plane.refusal(["-w", "ocral", "wi", "list"], project: false), .flagFirst)
        XCTAssertEqual(plane.refusal([], project: false), .noArgs)
        XCTAssertFalse(VendorRefusal.lockedFlag("--host").message.isEmpty)
    }

    func testHelpFlagFirstIsAllowed() {
        XCTAssertNil(plane.refusal(["--help"], project: false))
        XCTAssertNil(plane.refusal(["-h"], project: false))
        XCTAssertNil(plane.refusal(["help", "wi"], project: false))
        XCTAssertEqual(plane.refusal(["--help", "--host", "x"], project: false), .lockedFlag("--host"))
        XCTAssertEqual(plane.refusal(["-w", "x", "wi"], project: false), .flagFirst)
    }

    func testProjectFlagsOnlyWithProject() {
        let cli = VendorCLI(binary: "plane-cli", lockedFlags: ["--workspace", "-w"], projectFlags: ["--project", "-p"])
        XCTAssertEqual(cli.refusal(["wi", "list", "-p", "X"], project: true), .projectFlag("-p"))
        XCTAssertNil(cli.refusal(["wi", "list", "-p", "X"], project: false))
        XCTAssertEqual(cli.refusal(["wi", "list", "--project=X"], project: true), .projectFlag("--project"))
        XCTAssertNil(cli.refusal(["wi", "list", "-W"], project: true), "-W is another flag")
        XCTAssertEqual(cli.refusal(["wi", "list", "-w", "x"], project: false), .lockedFlag("-w"))
        XCTAssertEqual(VendorRefusal.projectFlag("-p").message, "OverSire sets -p from --project. Do not give it.")
    }

    func testSkillEnvironment() {
        var want = base
        want["PLANE_MANAGED_BY"] = "OverSire"
        XCTAssertEqual(plane.skillEnvironment(base: base), want)
        XCTAssertEqual(gh.skillEnvironment(base: base), base)
    }

    func testSummaryWordsOfHelpFlag() {
        XCTAssertEqual(VendorCLI.summaryWords(["--help"]), ["help"])
        XCTAssertEqual(VendorCLI.summaryWords(["-h", "wi"]), ["help"])
    }

    func testEnvironmentPlane() {
        let c = AccountConfig(account: AccountID(provider: "plane", id: "ocral"))
        let env = plane.environment(c, project: "OVERSIRE", token: "tok-123", base: base, inherited: ["GH_TOKEN": "leak", "PLANE_CONFIG": "x"])
        var want = base
        want["PLANE_API_KEY"] = "tok-123"
        want["PLANE_HOST"] = "https://api.plane.so"
        want["PLANE_WORKSPACE"] = "ocral"
        want["PLANE_PROJECT"] = "OVERSIRE"
        want["PLANE_MANAGED_BY"] = "OverSire"
        XCTAssertEqual(env, want)
        let own = AccountConfig(account: c.account, values: ["workspace": "acme", "host": " https://plane.example.com "])
        let env2 = plane.environment(own, project: nil, token: nil, base: base, inherited: [:])
        XCTAssertEqual(env2["PLANE_WORKSPACE"], "acme")
        XCTAssertEqual(env2["PLANE_HOST"], "https://plane.example.com")
        XCTAssertNil(env2["PLANE_PROJECT"])
        XCTAssertNil(env2["PLANE_API_KEY"])
        let empty = AccountConfig(account: c.account, values: ["host": "  "])
        XCTAssertEqual(plane.environment(empty, project: nil, token: nil, base: base, inherited: [:])["PLANE_HOST"], "https://api.plane.so")
    }

    func testEnvironmentBigTimerHasNoDefaultHost() {
        let c = AccountConfig(account: AccountID(provider: "bigtimer", id: "bt.example.com"), values: ["server": "https://bt.example.com"])
        let env = bigTimer.environment(c, project: "X", token: "btk_1", base: base, inherited: [:])
        XCTAssertEqual(env["BIGTIMER_SERVER"], "https://bt.example.com")
        XCTAssertEqual(env["BIGTIMER_TOKEN"], "btk_1")
        XCTAssertNil(env["PLANE_PROJECT"])
        let none = bigTimer.environment(AccountConfig(account: c.account), project: nil, token: nil, base: base, inherited: [:])
        XCTAssertNil(none["BIGTIMER_SERVER"])
    }

    func testEnvironmentGh() {
        let c = AccountConfig(account: AccountID(provider: "github", id: "oversire"))
        let env = gh.environment(c, project: nil, token: "ignored", base: base,
                                 inherited: ["GH_CONFIG_DIR": "/cfg", "SSH_AUTH_SOCK": "/s", "AWS_SECRET_ACCESS_KEY": "no"])
        var want = base
        want["GH_CONFIG_DIR"] = "/cfg"
        want["SSH_AUTH_SOCK"] = "/s"
        XCTAssertEqual(env, want)
    }

    func testVersionParse() {
        XCTAssertEqual(VendorVersion.find(in: "plane-cli version 0.2.2\n"), VendorVersion("0.2.2"))
        XCTAssertEqual(VendorVersion.find(in: "gh version 2.102.0 (2026-09-30)\nhttps://github.com/cli/cli/releases/tag/v2.102.0\n")?.parts, [2, 102, 0])
        XCTAssertEqual(VendorVersion.find(in: "\n  big-timer-cli version v1.0.12")?.parts, [1, 0, 12])
        XCTAssertEqual(VendorVersion("v1.0.12")?.parts, [1, 0, 12])
        XCTAssertEqual(VendorVersion("1.2.3-rc1")?.parts, [1, 2, 3])
        XCTAssertEqual(VendorVersion("1.2.3+build.4")?.parts, [1, 2, 3])
        XCTAssertEqual(VendorVersion.find(in: "x 1.2.3-rc1")?.parts, [1, 2, 3])
        XCTAssertNil(VendorVersion(""))
        XCTAssertNil(VendorVersion("dev"))
        XCTAssertNil(VendorVersion.find(in: ""))
        XCTAssertNil(VendorVersion.find(in: "plane-cli version dev"))
        XCTAssertEqual(VendorVersion("2.102.0")?.description, "2.102.0")
    }

    func testVersionOrder() throws {
        let v = { (s: String) in try XCTUnwrap(VendorVersion(s)) }
        XCTAssertGreaterThan(try v("0.2.10"), try v("0.2.9"))
        XCTAssertEqual(try v("1.0"), try v("1.0.0"))
        XCTAssertEqual(Set([try v("1.0"), try v("1.0.0")]).count, 1)
        XCTAssertLessThan(try v("1.0.11"), try v("1.0.12"))
        XCTAssertFalse(try v("1.0") < v("1.0.0"))
    }

    func testBinaryStates() {
        let floor = VendorCLI(binary: "plane-cli", minVersion: "0.2.2")
        let free = VendorCLI(binary: "gh")
        func state(_ cli: VendorCLI, _ path: String?, _ version: String?) -> VendorState {
            VendorBinary(vendor: "plane", cli: cli, path: path, version: version.flatMap(VendorVersion.init), source: path == nil ? nil : .path).state
        }
        XCTAssertEqual(state(floor, nil, nil), .missing)
        XCTAssertEqual(state(floor, "/usr/local/bin/plane-cli", "0.2.1"), .old)
        XCTAssertEqual(state(floor, "/usr/local/bin/plane-cli", nil), .old)
        XCTAssertEqual(state(floor, "/usr/local/bin/plane-cli", "0.2.2"), .ok)
        XCTAssertEqual(state(floor, "/usr/local/bin/plane-cli", "0.3"), .ok)
        XCTAssertEqual(state(free, "/opt/homebrew/bin/gh", nil), .ok)
        XCTAssertEqual(state(free, nil, nil), .missing)
    }

    func testBinaryProblemTexts() {
        let cli = VendorCLI(binary: "plane-cli", minVersion: "0.2.2")
        let path = "/usr/local/bin/plane-cli"
        XCTAssertEqual(VendorBinary(vendor: "plane", cli: cli, path: nil, version: nil, source: nil).problem,
                       "plane-cli is not installed. Run `oversire vendor install plane`.")
        XCTAssertEqual(VendorBinary(vendor: "plane", cli: cli, path: path, version: VendorVersion("0.2.1"), source: .path).problem,
                       "plane-cli 0.2.1 is older than 0.2.2. Run `oversire vendor install plane`.")
        XCTAssertEqual(VendorBinary(vendor: "plane", cli: cli, path: path, version: nil, source: .path).problem,
                       "plane-cli at /usr/local/bin/plane-cli gives no version. OverSire needs 0.2.2 or newer. Run `oversire vendor install plane`.")
        XCTAssertNil(VendorBinary(vendor: "plane", cli: cli, path: path, version: VendorVersion("0.2.2"), source: .path).problem)
        XCTAssertEqual(VendorBinary(vendor: "plane", cli: cli, path: nil, version: nil, source: nil).installHint, "Run `oversire vendor install plane`.")
    }

    // MARK: prefer

    let floor = VendorCLI(binary: "plane-cli", minVersion: "0.2.2", release: .trebiCatalog(entry: "plane"))
    let ownPath = "/Users/x/.config/oversire/vendors/plane/0.2.2/plane-cli"

    func own(_ v: String?) -> VendorBinary {
        VendorBinary(vendor: "plane", cli: floor, path: v == nil ? nil : ownPath, version: v.flatMap(VendorVersion.init), source: v == nil ? nil : .oversire)
    }

    func onPath(_ v: String?) -> VendorBinary {
        VendorBinary(vendor: "plane", cli: floor, path: v == nil ? nil : "/usr/local/bin/plane-cli", version: v.flatMap(VendorVersion.init), source: v == nil ? nil : .path)
    }

    func testPreferOwnOk() {
        let b = VendorBinary.prefer(own: own("0.2.2"), path: onPath("0.2.3"))
        XCTAssertEqual(b.source, .oversire)
        XCTAssertEqual(b.path, ownPath)
        XCTAssertEqual(b.ownVersion, VendorVersion("0.2.2"))
        XCTAssertEqual(b.release, .trebiCatalog(entry: "plane"))
    }

    func testPathOkWinsOverOldOwn() {
        let b = VendorBinary.prefer(own: own("0.2.1"), path: onPath("0.2.2"))
        XCTAssertEqual(b.source, .path)
        XCTAssertEqual(b.state, .ok)
        XCTAssertEqual(b.ownVersion, VendorVersion("0.2.1"))
    }

    func testOldOwnBeforeOldPath() {
        let b = VendorBinary.prefer(own: own("0.2.1"), path: onPath("0.2.0"))
        XCTAssertEqual(b.source, .oversire)
        XCTAssertEqual(b.state, .old)
        XCTAssertEqual(VendorBinary.prefer(own: own(nil), path: onPath("0.2.0")).source, .path)
        XCTAssertNil(VendorBinary.prefer(own: own(nil), path: onPath("0.2.0")).ownVersion)
    }

    func testMissing() {
        let b = VendorBinary.prefer(own: own(nil), path: onPath(nil))
        XCTAssertEqual(b.state, .missing)
        XCTAssertNil(b.path)
        XCTAssertNil(b.source)
        XCTAssertNil(b.ownVersion)
    }

    func testHomebrewHint() {
        let gh = VendorCLI(binary: "gh", release: .homebrew(formula: "gh"))
        let b = VendorBinary(vendor: "github", cli: gh, path: nil, version: nil, source: nil)
        XCTAssertEqual(b.installHint, "Install gh with Homebrew: `brew install gh`.")
        XCTAssertEqual(b.problem, "gh is not installed. Install gh with Homebrew: `brew install gh`.")
    }
}
