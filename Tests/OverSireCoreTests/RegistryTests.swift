import XCTest
@testable import OverSireCore

private struct NoHTTP: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw ProviderError.transport("offline") }
}

private struct NoCommands: CommandRunner {
    func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput {
        CommandOutput(status: 127, stdout: Data(), stderr: "no \(exe)")
    }
}

private struct Secrets: SecretReader {
    let values: [String: String]
    func secret(_ key: String) -> String? { values[key] }
}

private struct StubProvider: Provider {
    let id: ProviderID
    let account: AccountID
    let token: String?
    var capabilities: Set<Capability> { [.webhooks] }
    var pollPolicy: PollPolicy { PollPolicy(minInterval: .seconds(30), requestsPerHour: 3600) }
    func probe() async throws -> Identity { Identity(person: PersonRef(id: "1", name: "Ada")) }
    func poll(since: Cursor?) async throws -> EventPage { EventPage(events: [], cursor: Cursor(rawValue: "0")) }
}

final class RegistryTests: XCTestCase {
    let env = ProviderEnvironment(http: NoHTTP(), commands: NoCommands(), secrets: Secrets(values: ["TOKEN_acme": "t-1"]))

    func descriptor(_ id: ProviderID, _ layer: Layer) -> ProviderDescriptor {
        ProviderDescriptor(id: id, layer: layer, displayName: id.rawValue, symbol: "circle",
                           fields: [ConfigField(key: "token", label: "Token", kind: .secret)], auth: [.token]) { c, env in
            StubProvider(id: id, account: c.account, token: c.secretKeys.first.flatMap(env.secrets.secret))
        }
    }

    func testRegisterListAndMake() throws {
        let r = ProviderRegistry()
        r.register(descriptor("tracker-a", .tracker))
        r.register(descriptor("ci-a", .ci))
        r.register(descriptor("tracker-b", .tracker))
        XCTAssertEqual(r.descriptors(.tracker).map(\.id), ["tracker-a", "tracker-b"])
        XCTAssertEqual(r.descriptors(.ci).map(\.id), ["ci-a"])
        XCTAssertTrue(r.descriptors(.runtime).isEmpty)

        let c = AccountConfig(account: AccountID(provider: "tracker-b", id: "acme"), secretKeys: ["TOKEN_acme"])
        let p = try XCTUnwrap(r.make(c, environment: env) as? StubProvider)
        XCTAssertEqual(p.id, "tracker-b")
        XCTAssertEqual(p.account, c.account)
        XCTAssertEqual(p.token, "t-1")
    }

    func testReplaceKeepsOrder() {
        let r = ProviderRegistry()
        r.register(descriptor("a", .tracker))
        r.register(descriptor("b", .tracker))
        r.register(ProviderDescriptor(id: "a", layer: .tracker, displayName: "A2", symbol: "x", fields: [], auth: []) { _, _ in
            throw ProviderError.unsupported(.intake)
        })
        XCTAssertEqual(r.descriptors(.tracker).map(\.displayName), ["A2", "b"])
    }

    func testUnknownProviderThrows() {
        let r = ProviderRegistry()
        XCTAssertThrowsError(try r.make(AccountConfig(account: AccountID(provider: "nope", id: "x")), environment: env)) { e in
            XCTAssertEqual(e as? ProviderRegistry.RegistryError, .unknownProvider("nope"))
        }
    }

    func testAccountConfigRoundTripHoldsNoSecrets() throws {
        let c = AccountConfig(account: AccountID(provider: "plane", id: "ocral"), values: ["host": "https://api.plane.so"],
                              secretKeys: ["PLANE_TOKEN_ocral"])
        let data = try JSONEncoder().encode(c)
        XCTAssertEqual(try JSONDecoder().decode(AccountConfig.self, from: data), c)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("t-1"))
    }

    func testProviderEventRoundTrip() throws {
        let acct = AccountID(provider: "github-actions", id: "oversire")
        let repo = RepoRef(account: acct, path: "oversire/oversire", url: URL(string: "https://github.com/oversire/oversire")!)
        let e = ProviderEvent(id: "d-1", provider: "github-actions", account: acct, kind: .run, action: "completed",
                              subject: .run(RunRef(account: acct, repo: repo, id: "42")), at: Date(timeIntervalSince1970: 1_700_000_000),
                              summary: EventSummary(title: "ci", conclusion: "failure"))
        XCTAssertEqual(try JSONDecoder().decode(ProviderEvent.self, from: JSONEncoder().encode(e)), e)
    }

    func testMadeProviderAnswers() async throws {
        let r = ProviderRegistry()
        r.register(descriptor("x", .tracker))
        let p = try r.make(AccountConfig(account: AccountID(provider: "x", id: "a")), environment: env)
        let me = try await p.probe()
        let page = try await p.poll(since: nil)
        XCTAssertEqual(me.person.name, "Ada")
        XCTAssertEqual(page.cursor.rawValue, "0")
    }
}
