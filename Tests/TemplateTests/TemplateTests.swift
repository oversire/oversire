import XCTest
import OverSireCore
import OverSireTestKit
import TrackerTemplate
import CodeHostTemplate
import CITemplate

struct NoSecrets: SecretReader {
    func secret(_ key: String) -> String? { nil }
}

/// The templates build, the registry makes them, and each call refuses until a vendor call replaces it.
final class TemplateTests: XCTestCase {
    let env = ProviderEnvironment(http: NoHTTP(), commands: ReplayGH(), secrets: NoSecrets())

    func testTheRegistryMakesEachTemplate() throws {
        let registry = ProviderRegistry()
        let all = [TemplateTracker.descriptor, TemplateCodeHost.descriptor, TemplateCI.descriptor]
        for d in all { registry.register(d) }
        XCTAssertEqual(all.map(\.layer), [.tracker, .codeHost, .ci])
        for d in all {
            let p = try registry.make(AccountConfig(account: AccountID(provider: d.id, id: "acme")), environment: env)
            XCTAssertEqual(p.id, d.id)
            XCTAssertEqual(p.account.provider, p.id)
            let r = ProviderConformance.capabilities(p)
            XCTAssertTrue(r.passed, r.description)
        }
    }

    func testEachCallIsUnsupported() async {
        let a = { (p: ProviderID) in AccountID(provider: p, id: "acme") }
        let providers: [any Provider] = [
            TemplateTracker(account: a(.trackerTemplate), http: NoHTTP(), token: nil),
            TemplateCodeHost(account: a(.codeHostTemplate), http: NoHTTP(), token: nil),
            TemplateCI(account: a(.ciTemplate), http: NoHTTP(), token: nil),
        ]
        for p in providers {
            do {
                _ = try await p.probe()
                XCTFail("\(p.id) probe did not throw")
            } catch let e as ProviderError {
                XCTAssertEqual(e, .unsupported("probe"))
            } catch {
                XCTFail("\(error)")
            }
        }
        // The suite reports the template as not done.
        let r = await ProviderConformance.run { _ in providers[0] }
        XCTAssertFalse(r.passed)
    }
}
