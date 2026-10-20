import CryptoKit
import XCTest
import OverSireCore
@testable import RuntimeOrca

final class OrcaHostFilesTests: XCTestCase {
    var orca: ReplayOrca!
    var rt: OrcaRuntime!

    static let created = #"{"ok":true,"result":{"terminal":{"handle":"term_up","worktreeId":"w1"}}}"#

    override func setUp() {
        orca = ReplayOrca()
        rt = OrcaRuntime(exe: "/bin/sh", environment: "mbp", commands: orca)
        rt.shellWait = .zero
        rt.uploadId = { "U1" }
        orca.on("terminal create", Self.created)
        orca.on("terminal send", #"{"ok":true,"result":{"send":{"accepted":true}}}"#)
        orca.on("terminal close", #"{"ok":true,"result":{}}"#)
    }

    static func read(_ lines: [String]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: ["ok": true, "result": ["terminal": ["tail": lines]]])
        return String(decoding: data, as: UTF8.self)
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    /// The probe answers OK, then the host prints `sums` and the marker.
    func answer(_ sums: [String]) {
        orca.on("terminal read",
                Self.read(["$ command -v base64 ... && printf 'OVERSIRE-%s-%s\\n' OK U1", "OVERSIRE-OK-U1", "$"]),
                Self.read(["$stty -echo; mkdir -p ...", "fritz@mbp:~$"] + sums + ["OVERSIRE-DONE-U1", "$"]))
    }

    /// The text of each send, in order.
    var sent: [String] { orca.args("terminal send").map { $0[$0.firstIndex(of: "--text")! + 1] } }

    func testUploadOrderAndPaths() async throws {
        let files = [HostFile(name: "a.png", data: Data("one".utf8)), HostFile(name: "b.txt", data: Data("two".utf8)),
                     HostFile(name: "c.pdf", data: Data("three".utf8))]
        answer(files.map { Self.sha($0.data) })
        let paths = try await rt.writeFiles(files, workspacePath: "/w", dir: "/tmp/oversire/s1") { _, _ in }
        XCTAssertEqual(paths, ["/tmp/oversire/s1/a.png", "/tmp/oversire/s1/b.txt", "/tmp/oversire/s1/c.pdf"])

        let kinds = orca.calls.map { $0.prefix(2).joined(separator: " ") }
        XCTAssertEqual(kinds.first, "terminal create")
        XCTAssertEqual(kinds.last, "terminal close")
        XCTAssertEqual(orca.calls[0].prefix(6), ["terminal", "create", "--worktree", "path:/w", "--title", "oversire-upload"])
        XCTAssertFalse(orca.calls[0].contains("--focus"))
        XCTAssertEqual(orca.calls[0].suffix(3), ["--json", "--environment", "mbp"])

        let t = sent
        XCTAssertTrue(t[0].hasPrefix("command -v base64"), t[0])
        XCTAssertFalse(t[0].contains("OVERSIRE-OK-U1"), "the command line does not hold the marker")
        XCTAssertEqual(t[1], "stty -echo; mkdir -p '/tmp/oversire/s1'; base64 -d > '/tmp/oversire/s1/a.png'")
        XCTAssertEqual(t[2], Data("one".utf8).base64EncodedString() + "\n")
        XCTAssertEqual(t[3], "\u{04}")
        XCTAssertEqual(t[4], "stty -echo; mkdir -p '/tmp/oversire/s1'; base64 -d > '/tmp/oversire/s1/b.txt'")
        XCTAssertEqual(t[7].prefix(12), "stty -echo; ")
        XCTAssertEqual(t[9], "\u{04}")
        XCTAssertTrue(t[10].hasPrefix("stty echo; "), t[10])
        XCTAssertTrue(t[10].contains("shasum -a 256 '/tmp/oversire/s1/a.png' '/tmp/oversire/s1/b.txt' '/tmp/oversire/s1/c.pdf'"), t[10])
        XCTAssertEqual(t.count, 11)

        let enters = orca.args("terminal send").map { $0.contains("--enter") }
        XCTAssertEqual(enters, [true, true, false, false, true, false, false, true, false, false, true], "data goes raw")
        XCTAssertFalse(orca.args("terminal send").contains { $0.contains("--wait-submit") })
    }

    func testChunksAreSmallAndEndAtLines() async throws {
        let big = Data((0..<700_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        answer([Self.sha(big)])
        let total = ProgressBox()
        _ = try await rt.writeFiles([HostFile(name: "big.bin", data: big)], workspacePath: "/w", dir: "/tmp/o") { total.set($0, $1) }
        let chunks = sent.dropFirst(2).prefix { $0 != "\u{04}" }
        XCTAssertEqual(chunks.count, 4)
        XCTAssertTrue(chunks.allSatisfy { $0.utf8.count <= OrcaRuntime.chunkBytes && $0.hasSuffix("\n") })
        XCTAssertTrue(chunks.allSatisfy { $0.split(separator: "\n").allSatisfy { $0.count <= 76 } })
        XCTAssertEqual(Data(base64Encoded: chunks.joined(), options: .ignoreUnknownCharacters), big)
        XCTAssertEqual(total.last?.0, total.last?.1)
        XCTAssertEqual(total.last?.1, chunks.reduce(0) { $0 + $1.utf8.count })
    }

    func testChecksumMismatchThrowsAndCloses() async throws {
        answer([String(repeating: "0", count: 64)])
        do {
            _ = try await rt.writeFiles([HostFile(name: "a.png", data: Data("one".utf8))], workspacePath: "/w", dir: "/tmp/o") { _, _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? ProviderError).map { if case .vendor(let c, _) = $0 { return c } else { return "" } }, "checksum")
        }
        XCTAssertEqual(orca.args("terminal close").count, 1)
        XCTAssertEqual(orca.calls.last?.prefix(4), ["terminal", "close", "--terminal", "term_up"])
    }

    func testMissingToolThrowsAndCloses() async throws {
        orca.on("terminal read", Self.read(["OVERSIRE-NO-U1"]))
        do {
            _ = try await rt.writeFiles([HostFile(name: "a.png", data: Data("one".utf8))], workspacePath: "/w", dir: "/tmp/o") { _, _ in }
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? ProviderError).map { if case .vendor(let c, _) = $0 { return c } else { return "" } }, "host_tools")
        }
        XCTAssertEqual(orca.args("terminal send").count, 1, "no file goes after a failed probe")
        XCTAssertEqual(orca.args("terminal close").count, 1)
    }

    func testSafeNames() {
        XCTAssertEqual(OrcaRuntime.safeNames(["my shot (1).png", "a.png", "a.png", "a.png", "x y", "x?y", "..", "naïve.txt"]),
                       ["my-shot--1-.png", "a.png", "a-2.png", "a-3.png", "x-y", "x-y-2", "file", "na-ve.txt"])
        XCTAssertEqual(OrcaRuntime.quote("it's"), #"'it'\''s'"#)
    }

    func testChecksumParse() {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        XCTAssertEqual(OrcaRuntime.checksums(["fritz@mbp:~$" + a, b, "OVERSIRE-DONE-1", "c" + a], before: "OVERSIRE-DONE-1"), [a, b])
    }

    func testCapabilitiesHaveHostFiles() {
        XCTAssertTrue(rt.capabilities.contains(.hostFiles))
        XCTAssertTrue((rt as Any) is any HostFileWriting)
    }
}

private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Int, Int)] = []
    func set(_ a: Int, _ b: Int) { lock.withLock { values.append((a, b)) } }
    var last: (Int, Int)? { lock.withLock { values.last } }
}
