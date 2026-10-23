import OverSireCore
import OverSireSync
import XCTest
@testable import OverSireApp

/// The first start after OVERSIRE-289: the Orca accounts go, and their environment becomes the sessions machine.
final class OrcaMigrationTests: XCTestCase {
    private let plane = AccountConfig(account: AccountID(provider: .plane, id: "ocral"), values: [:])

    private func orca(_ env: String?) -> AccountConfig {
        AccountConfig(account: AccountID(provider: LegacyMigration.orca, id: env ?? "local"),
                      values: ["agent": "claude"].merging(env.map { ["environment": $0] } ?? [:]) { a, _ in a })
    }

    private func config(_ json: String) throws -> AppConfig { try JSONDecoder().decode(AppConfig.self, from: Data(json.utf8)) }

    func testTheOrcaAccountGoesAndItsEnvironmentBecomesTheSessionsMachine() throws {
        var accounts = [plane, orca("lab")]
        var machines = try JSONDecoder().decode(MachinesConfig.self, from: Data(#"{"runtimeAccounts":{"mbp":"lab"}}"#.utf8))
        XCTAssertTrue(LegacyMigration.moveOrca(&accounts, machines: &machines, environment: "lab"))
        XCTAssertEqual(accounts, [plane])
        XCTAssertEqual(machines.sessions, "mbp", "the machine that had the Orca account")
        XCTAssertFalse(LegacyMigration.moveOrca(&accounts, machines: &machines, environment: nil), "once")
    }

    func testALocalOrcaAccountKeepsThisMac() {
        var accounts = [orca(nil)]
        var machines = MachinesConfig()
        XCTAssertTrue(LegacyMigration.moveOrca(&accounts, machines: &machines, environment: nil))
        XCTAssertTrue(accounts.isEmpty)
        XCTAssertNil(machines.sessions)
    }

    func testAPickedSessionsMachineStays() {
        var accounts = [orca("lab")]
        var machines = MachinesConfig(sessions: "mini")
        XCTAssertTrue(LegacyMigration.moveOrca(&accounts, machines: &machines, environment: "lab"))
        XCTAssertEqual(machines.sessions, "mini")
    }

    func testAConfigWithoutAnAccountsListMovesTheOldEnvironment() throws {
        let c = try config(#"{"repos":[],"projects":{"orca":{"environment":"mbp","roots":{"ocral/x":"/w"}}}}"#)
        var accounts = AppEnvironment.accounts(from: c)
        XCTAssertFalse(accounts.contains { $0.account.provider == LegacyMigration.orca }, "no Orca account from the old fields")
        var machines = MachinesConfig()
        XCTAssertTrue(LegacyMigration.moveOrca(&accounts, machines: &machines, environment: c.projects?.orca.legacyEnvironment))
        XCTAssertEqual(machines.sessions, "mbp")
    }

    func testASavedConfigHasNoOrcaFields() throws {
        let c = try config(#"{"repos":[],"projects":{"orca":{"enabled":true,"cli":"/o","environment":"mbp","roots":{"ocral/x":"/w"}}}}"#)
        let p = try XCTUnwrap(c.projects)
        XCTAssertEqual(p.orca.roots, ["ocral/x": "/w"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(p)) as? [String: Any])
        XCTAssertEqual((json["orca"] as? [String: Any])?.keys.sorted(), ["roots"])
        let again = try JSONDecoder().decode(ProjectsConfig.self, from: JSONEncoder().encode(p))
        XCTAssertNil(again.orca.legacyEnvironment, "the next start does not migrate again")
    }
}
