import XCTest
import OverSireCore
@testable import OverSireTestKit

final class ReplayTests: XCTestCase {
    var dir: URL!

    override func setUp() { dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-replay-\(UUID().uuidString)") }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func request(_ method: String, _ url: String, body: String? = nil) -> URLRequest {
        var r = URLRequest(url: URL(string: url)!)
        r.httpMethod = method
        r.httpBody = body.map { Data($0.utf8) }
        r.setValue("Bearer ghp_abcdefghijklmnopqrstuvwxyz", forHTTPHeaderField: "Authorization")
        return r
    }

    func testRecordThenReplayHTTP() async throws {
        let vendor = RecordedHTTP()
        vendor.on("POST", "https://api.x.dev/graphql?token=ghp_abcdefghijklmnopqrstuvwxyz", 200,
                  headers: ["X-RateLimit-Remaining": "4999", "Set-Cookie": "s=1", "X-Api-Token": "t"],
                  #"{"data":{"viewer":{"login":"ada","token":"plain-secret"}},"note":"Bearer abc.def"}"#)
        let url = "https://api.x.dev/graphql?token=ghp_abcdefghijklmnopqrstuvwxyz"
        let rec = ReplayTransport(dir: dir, upstream: vendor, record: true)
        let (live, _) = try await rec.send(request("POST", url, body: "{\"query\":\"q1\"}"))
        XCTAssertTrue(String(decoding: live, as: UTF8.self).contains("plain-secret"), "the caller gets the real answer")

        let file = dir.appendingPathComponent(ReplayTransport.name(request("POST", url, body: "{\"query\":\"q1\"}")) + ".json")
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertFalse(text.contains("plain-secret") || text.contains("ghp_") || text.contains("abc.def") || text.contains("s=1"), text)
        XCTAssertTrue(text.contains("X-RateLimit-Remaining"))
        XCTAssertFalse(text.contains("X-Api-Token"))

        let replay = ReplayTransport(dir: dir, upstream: vendor, record: false)
        let (data, resp) = try await replay.send(request("POST", url, body: "{\"query\":\"q1\"}"))
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertEqual(resp.value(forHTTPHeaderField: "X-RateLimit-Remaining"), "4999")
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(((obj?["data"] as? [String: Any])?["viewer"] as? [String: Any])?["login"] as? String, "ada")
        XCTAssertEqual(vendor.requests.count, 1, "a replay does not call the vendor")

        do { _ = try await replay.send(request("POST", url, body: "{\"query\":\"q2\"}")); XCTFail("an other body has no fixture") } catch {
            XCTAssertTrue((error as? ProviderError)?.message.hasPrefix("no fixture POST-") == true, "\(error)")
        }
        XCTAssertEqual(replay.missing.count, 1)
    }

    func testRecordThenReplayCommands() async throws {
        let gh = ReplayGH()
        gh.on("GET", "/user", "HTTP/2.0 200 OK\r\n\r\n{\"login\":\"ada\",\"token\":\"x\"}")
        let args = ["api", "-i", "-X", "GET", "/user"]
        let rec = ReplayCommandRunner(dir: dir, upstream: gh, record: true)
        _ = try await rec.run("/opt/homebrew/bin/gh", args, stdin: nil, timeout: .seconds(5))

        let replay = ReplayCommandRunner(dir: dir, record: false)
        let out = try await replay.run("/usr/local/bin/gh", args, stdin: nil, timeout: .seconds(5))
        XCTAssertEqual(out.status, 0)
        XCTAssertTrue(String(decoding: out.stdout, as: UTF8.self).hasPrefix("HTTP/2.0 200 OK"), "the program folder does not count")
        do { _ = try await replay.run("gh", ["api", "/other"], stdin: nil, timeout: .seconds(5)); XCTFail("no fixture") } catch {
            XCTAssertEqual(replay.missing, ["\(ReplayCommandRunner.name("gh", ["api", "/other"], stdin: nil)) for gh api /other"])
        }
    }

    func testRecordNeedsAnUpstream() async {
        let t = ReplayTransport(dir: dir, record: true)
        do { _ = try await t.send(request("GET", "https://x.dev/a")); XCTFail("no fixture") } catch {
            XCTAssertEqual(t.missing.count, 1, "without an upstream, record mode replays")
        }
    }
}
