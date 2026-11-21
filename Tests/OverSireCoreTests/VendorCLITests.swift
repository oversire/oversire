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
            XCTAssertEqual(plane.refusal(["wi", "list", flag]), .lockedFlag(String(flag.prefix { $0 != "=" })), flag)
        }
        for flag in ["--hostname", "-kx", "--key"] { XCTAssertNil(plane.refusal(["wi", "list", flag]), flag) }
        XCTAssertNil(bigTimer.refusal(["server", "version"]), "a command word is no flag")
        XCTAssertNil(plane.refusal(["wi", "list", "host", "k"]), "a value without a dash is no flag")
    }

    func testRefusesDeniedCommands() {
        XCTAssertEqual(plane.refusal(["auth", "login"]), .deniedCommand("auth login"))
        XCTAssertNil(plane.refusal(["auth", "show"]))
        XCTAssertEqual(plane.refusal(["listen", "--events", "x"]), .deniedCommand("listen"))
        XCTAssertEqual(bigTimer.refusal(["sync", "stream"]), .deniedCommand("sync stream"))
        XCTAssertNil(bigTimer.refusal(["sync", "pull"]))
        XCTAssertEqual(gh.refusal(["auth", "token"]), .deniedCommand("auth"))
        XCTAssertEqual(plane.refusal(["Auth", "Login"]), .deniedCommand("auth login"))
    }

    func testRefusesFlagFirst() {
        XCTAssertEqual(plane.refusal(["-w", "ocral", "wi", "list"]), .flagFirst)
        XCTAssertEqual(plane.refusal([]), .noArgs)
        XCTAssertFalse(VendorRefusal.lockedFlag("--host").message.isEmpty)
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
}
