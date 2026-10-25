import AgentBinder
import XCTest
@testable import OverSireApp

// Each detect waits until the test opens its harness.
private actor GateProber: CLIProber {
    private var waits: [Harness: CheckedContinuation<Void, Never>] = [:]
    private var opened: Set<Harness> = []
    private(set) var limitCalls: [Harness] = []

    func detect(_ h: Harness) async -> Detection {
        if !opened.contains(h) { await withCheckedContinuation { waits[h] = $0 } }
        guard h != .gemini else { return Detection(harness: h, detail: .notInstalled) }
        return Detection(harness: h, path: URL(fileURLWithPath: "/opt/homebrew/bin/x"), version: "1.0", supported: true, ready: true, auth: .ok)
    }

    func open(_ h: Harness) {
        opened.insert(h)
        waits.removeValue(forKey: h)?.resume()
    }

    func planLimits(_ h: Harness) async throws -> Limits {
        limitCalls.append(h)
        return Limits(plan: "max")
    }

    func invalidateDetect(_ h: Harness) async {}
}

@MainActor
final class LocalCLITests: XCTestCase {
    private func until(_ f: () -> Bool) async {
        for _ in 0..<400 where !f() { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testEachResultPostsInArrivalOrderAndTheLimitsComeAfter() async {
        let probe = GateProber()
        let cli = LocalCLI(prober: probe, harnesses: [.claude, .codex, .gemini])
        // Each post as: results, plans, still detecting.
        var posts: [String] = []
        let o = NotificationCenter.default.addObserver(forName: LocalCLI.changed, object: cli, queue: nil) { _ in
            MainActor.assumeIsolated {
                posts.append("\((cli.detections ?? []).map(\.harness.rawValue).joined(separator: ",")) | \(cli.plans.keys.sorted().joined(separator: ",")) | \(cli.detecting)")
            }
        }
        defer { NotificationCenter.default.removeObserver(o) }

        cli.detect()
        XCTAssertEqual(cli.progress.done, 0)
        XCTAssertEqual(cli.progress.total, 3)
        await probe.open(.codex)
        await until { cli.detections?.count == 1 }
        XCTAssertEqual(cli.pending, [.claude, .gemini])
        XCTAssertEqual(cli.progress.done, 1)
        await probe.open(.gemini)
        await until { cli.detections?.count == 2 }
        await probe.open(.claude)
        await until { !cli.detecting }

        XCTAssertEqual(posts, [
            " |  | true",
            "codex |  | true",
            "codex,gemini |  | true",
            "claude,codex,gemini |  | true",
            "claude,codex,gemini | claude | true",
            "claude,codex,gemini | claude,codex | true",
            "claude,codex,gemini | claude,codex | false",
        ])
        let calls = await probe.limitCalls
        XCTAssertEqual(calls, [.claude, .codex], "only the ready CLIs, in harness order")
        XCTAssertEqual(cli.pending, [])
    }
}
