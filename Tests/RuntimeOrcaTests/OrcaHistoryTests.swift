import XCTest
import OverSireCore
@testable import RuntimeOrca

final class OrcaHistoryTests: XCTestCase {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = repo.appendingPathComponent("Contract/fixtures/session-digest")

    final class Files: TranscriptReading, @unchecked Sendable {
        var asked: [String] = []
        func digest(file: String, agent: AgentName, budget: HistoryBudget) throws -> SessionDigest {
            asked.append(file)
            return SessionDigest(harness: agent, sessionId: "S1", source: .file, turns: 1)
        }
        func locate(agent: AgentName, sessionId: String) -> String? { "/located/\(sessionId).jsonl" }
        func newest(agent: AgentName, cwd: String) -> String? { "/newest.jsonl" }
    }

    var orca: ReplayOrca!
    let session = AgentSession(phase: .waiting, since: .distantPast, card: "w1", paneKey: "t1:l1", agent: .claude, repo: "r",
                               prompt: "work on OVERSIRE-200: add a retry")
    let workspace = Workspace(id: "w1", repo: "r", path: "/w/oversire-200", name: "OVERSIRE-200", comment: nil, liveTerminals: 1,
                              lastActivity: .distantPast, agents: [])

    static func hit(file: String?) -> String {
        let source = file.map { #","source":{"presence":"present","filePath":"\#($0)"}"# } ?? ""
        return #"{"ok":true,"result":{"hits":[{"agent":"claude","sessionId":"S1","cwd":"/w/oversire-200"\#(source)}]}}"#
    }

    override func setUp() {
        orca = ReplayOrca()
        orca.on("terminal create", OrcaHostFilesTests.created)
        orca.on("terminal send", #"{"ok":true,"result":{"send":{"accepted":true}}}"#)
        orca.on("terminal close", #"{"ok":true,"result":{}}"#)
    }

    func remote() -> OrcaRuntime {
        let rt = OrcaRuntime(exe: "/bin/sh", environment: "mbp", commands: orca)
        rt.shellWait = .zero
        rt.uploadId = { "H1" }
        return rt
    }

    /// The marked output of scripts/digest.py for one fixture case.
    func marked(_ name: String) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["python3", "-I", Self.repo.appendingPathComponent("scripts/digest.py").path, "--markers",
                       Self.fixtures.appendingPathComponent("claude/\(name).jsonl").path]
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try XCTSkipIf(p.terminationStatus != 0, "no python3")
        return String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
    }

    func fixture(_ name: String) throws -> SessionDigest {
        try JSONDecoder().decode(SessionDigest.self, from: Data(contentsOf: Self.fixtures.appendingPathComponent("\(name).json")))
    }

    var sent: [String] { orca.args("terminal send").map { $0[$0.firstIndex(of: "--text")! + 1] } }

    func testScriptIsTheCopyOfDigestPy() throws {
        let file = try String(contentsOf: Self.repo.appendingPathComponent("scripts/digest.py"), encoding: .utf8)
        XCTAssertEqual(OrcaRuntime.digestScript + "\n", file)
    }

    func testRemoteWithRunner() async throws {
        orca.on("search --query", Self.hit(file: nil))
        orca.on("terminal read", OrcaHostFilesTests.read(["$ command -v oversire-runner", "OVERSIRE-RUNNER-H1"]),
                OrcaHostFilesTests.read(["$ oversire-runner digest"] + (try marked("long")) + ["$"]))
        let d = try await remote().history(of: session, in: workspace, budget: .standard)
        var want = try fixture("long")
        want.source = .orcaTerminal
        XCTAssertEqual(d, want)

        let search = try XCTUnwrap(orca.args("search --query").first)
        XCTAssertEqual(Array(search.prefix(5)), ["search", "--query", "work on OVERSIRE 200 add a retry", "--agent", "claude"])
        XCTAssertTrue(search.contains("/w/oversire-200"))
        XCTAssertEqual(sent[1], "oversire-runner digest --harness claude --session 'S1' --markers --source orca-terminal --earlier 12 --full 3 --max-chars 4000")
        XCTAssertEqual(orca.calls.last?.prefix(2), ["terminal", "close"])
    }

    func testRemoteWithPythonAndNoSearchHit() async throws {
        orca.on("search --query", #"{"ok":true,"result":{"hits":[]}}"#)
        orca.on("terminal read", OrcaHostFilesTests.read(["OVERSIRE-PY-H1"]), OrcaHostFilesTests.read(try marked("basic")))
        let d = try await remote().history(of: session, in: workspace, budget: HistoryBudget(earlier: 4, full: 2, maxChars: 900))
        XCTAssertEqual(d.turns, 3)
        let t = sent
        XCTAssertEqual(t[1], #"stty -echo; base64 -d > "${TMPDIR:-/tmp}/oversire-digest-H1.py""#)
        XCTAssertEqual(Data(base64Encoded: t[2].replacingOccurrences(of: "\n", with: "")), Data(OrcaRuntime.digestScript.utf8))
        XCTAssertEqual(t[3], "\u{04}")
        XCTAssertTrue(t[4].hasPrefix(#"stty echo; python3 -I "${TMPDIR:-/tmp}/oversire-digest-H1.py" "$(ls -t ~/.claude/projects/-w-oversire-200/*.jsonl"#), t[4])
        XCTAssertTrue(t[4].hasSuffix(#"--earlier 4 --full 2 --max-chars 900; rm -f "${TMPDIR:-/tmp}/oversire-digest-H1.py""#), t[4])
    }

    func testRemoteErrorAndNoTools() async throws {
        orca.on("terminal read", OrcaHostFilesTests.read(["OVERSIRE-RUNNER-H1"]),
                OrcaHostFilesTests.read(["OVERSIRE-DIGEST-ERROR no transcript for session S1"]))
        do { _ = try await remote().history(of: session, in: workspace, budget: .standard); XCTFail() } catch {
            XCTAssertEqual(error as? ProviderError, .notFound)
        }
        orca.on("terminal read", OrcaHostFilesTests.read(["OVERSIRE-NO-H1"]))
        do { _ = try await remote().history(of: session, in: workspace, budget: .standard); XCTFail() } catch {
            guard case .vendor("host_tools", _)? = error as? ProviderError else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(orca.calls.last?.prefix(2), ["terminal", "close"])
    }

    func testLocalUsesTheSearchFileThenTheFolder() async throws {
        let files = Files()
        let rt = OrcaRuntime(exe: "/bin/sh", environment: nil, commands: orca, transcripts: files)
        orca.on("search --query", Self.hit(file: "/u/.claude/projects/x/S1.jsonl"))
        _ = try await rt.history(of: session, in: workspace, budget: .standard)
        orca.on("search --query", Self.hit(file: nil))
        _ = try await rt.history(of: session, in: workspace, budget: .standard)
        orca.on("search --query", #"{"ok":true,"result":{"hits":[]}}"#)
        _ = try await rt.history(of: session, in: workspace, budget: .standard)
        XCTAssertEqual(files.asked, ["/u/.claude/projects/x/S1.jsonl", "/located/S1.jsonl", "/newest.jsonl"])
        XCTAssertTrue(orca.args("terminal create").isEmpty)

        let bare = OrcaRuntime(exe: "/bin/sh", environment: nil, commands: orca)
        do { _ = try await bare.history(of: session, in: workspace, budget: .standard); XCTFail() } catch {
            XCTAssertEqual(error as? ProviderError, .unsupported(.sessionHistory))
        }
    }

    func testSlug() {
        XCTAssertEqual(OrcaRuntime.slug("/Users/fritz/Projects/oversire-workspace/.wt/x_1"), "-Users-fritz-Projects-oversire-workspace--wt-x-1")
    }
}
