import XCTest
import OverSireCore
import OverSireTestKit
@testable import OverSireSync

final class CloudPairingTests: XCTestCase {
    let base = URL(string: "https://cloud.test")!

    func testReadsTheCode() {
        XCTAssertEqual(CloudPairing.code("abcd-2345"), "ABCD2345")
        XCTAssertEqual(CloudPairing.code(" ABCD 2345 "), "ABCD2345")
        XCTAssertNil(CloudPairing.code("ABCD-234"))
        XCTAssertNil(CloudPairing.code("ILOU2345"))
        XCTAssertNil(CloudPairing.code(String(repeating: "a", count: 64)))
    }

    func testPairsThenReadsWhoAmI() async throws {
        let http = RecordedHTTP()
        let token = String(repeating: "ab", count: 32)
        http.on("POST", "https://cloud.test/pair", 200,
                #"{"token":"\#(token)","deviceId":"0A1B2C3D4E5F6071","role":"client","account":"acct1","hookRoute":"a1b2c3d4e5f60718"}"#)
        http.on("GET", "https://cloud.test/v1/whoami", 200,
                #"{"deviceId":"0A1B2C3D4E5F6071","role":"client","account":"acct1","hookRoute":"a1b2c3d4e5f60718"}"#)
        let pairing = CloudPairing(base: base, http: http)
        let r = try await pairing.pair(code: "ABCD2345", name: "mbp")
        XCTAssertEqual(r, PairResult(token: token, deviceId: "0A1B2C3D4E5F6071", role: .client, account: "acct1", hookRoute: "a1b2c3d4e5f60718"))
        let body = try XCTUnwrap(http.requests[0].httpBody)
        XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: body), ["code": "ABCD2345", "name": "mbp"])
        XCTAssertNil(http.requests[0].value(forHTTPHeaderField: "Authorization"))

        let me = try await pairing.whoami(token: r.token)
        XCTAssertEqual(me.hookRoute, "a1b2c3d4e5f60718")
        XCTAssertEqual(http.requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer \(token)")
    }

    func testAnOldCodeIsUnauthorized() async {
        let http = RecordedHTTP()
        http.on("POST", "https://cloud.test/pair", 401, #"{"error":"unknown or old code"}"#)
        do {
            _ = try await CloudPairing(base: base, http: http).pair(code: "ABCD2345", name: "mbp")
            XCTFail("no error")
        } catch { XCTAssertEqual(error as? ProviderError, .unauthorized) }
    }

    func testAnOldRelayHasOnlyTheDeviceID() async throws {
        let http = RecordedHTTP()
        http.on("GET", "https://cloud.test/v1/whoami", 200, #"{"deviceId":"AAAA","role":"client","account":null,"hookRoute":null}"#)
        let me = try await CloudPairing(base: base, http: http).whoami(token: "t")
        XCTAssertEqual(me, WhoAmI(deviceId: "AAAA", role: .client))
    }
}
