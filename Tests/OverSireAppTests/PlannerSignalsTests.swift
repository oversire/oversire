import OverSireCore
import OverSireSync
import XCTest
@testable import OverSireApp

final class PlannerSignalsTests: XCTestCase {
    func testSwiftImports() {
        let text = "import Foundation\n@testable import OverSireApp\n@_exported import OverSireCore\nimport struct Foo.Bar\n// import Nope\nlet x = 1"
        XCTAssertEqual(ImportGraph.imports(path: "a.swift", text: text), ["Foundation", "OverSireApp", "OverSireCore", "Foo"])
    }

    func testTSImports() {
        let text = """
        import { a } from "./a"
        import type { B } from '../b/b.ts'
        export * from "./c"
        import "./side"
        const d = require("./d")
        const e = await import('./e')
        import x from "lodash"
        """
        XCTAssertEqual(Set(ImportGraph.imports(path: "src/x.ts", text: text)), ["./a", "../b/b.ts", "./c", "./side", "./d", "./e", "lodash"])
    }

    func testGoImports() {
        let text = "package main\n\nimport \"fmt\"\nimport w \"example.com/r/wire\"\nimport (\n\t\"os\"\n\th \"example.com/r/hub\"\n)\n"
        XCTAssertEqual(ImportGraph.imports(path: "main.go", text: text), ["fmt", "example.com/r/wire", "os", "example.com/r/hub"])
    }

    // One hub file and two clusters that import each other.
    func testGraphHubAndClusters() {
        var files: [String: String] = ["src/store.ts": "export const s = 1"]
        for n in ["a1", "a2", "a3"] { files["src/alpha/\(n).ts"] = "import { s } from '../store'\nimport './\(n == "a1" ? "a2" : "a1")'" }
        for n in ["b1", "b2", "b3"] { files["src/beta/\(n).ts"] = "import { s } from '../store'\nimport './\(n == "b1" ? "b2" : "b1")'" }
        files["src/beta/b3.ts"]! += "\nimport './b2'"
        files["src/alpha/a3.ts"]! += "\nimport './a2'"
        let g = ImportGraph(files: files)
        let hubs = g.hubs()
        XCTAssertEqual(hubs, [AreaCandidates.Hub(glob: "src/store.ts", importers: 6)])
        let clusters = g.clusters(hubs: Set(hubs.map(\.glob)))
        XCTAssertEqual(clusters.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(clusters[0].globs, ["src/alpha/a1.ts", "src/alpha/a2.ts", "src/alpha/a3.ts"])
    }

    func testSwiftModulesAndGoPackages() {
        let g = ImportGraph(files: [
            "Sources/Core/A.swift": "import Foundation",
            "Sources/App/B.swift": "import Core",
            "Sources/App/C.swift": "import Core\nimport AppKit",
            "wire/w.go": "package wire",
            "hub/h.go": "package hub\nimport \"example.com/r/wire\"",
        ], goModule: "example.com/r")
        XCTAssertEqual(g.importers["Sources/Core/**"], ["Sources/App/B.swift", "Sources/App/C.swift"])
        XCTAssertEqual(g.importers["wire/*.go"], ["hub/h.go"])
        XCTAssertNil(g.importers["AppKit"])
    }

    func testClusterName() {
        XCTAssertEqual(ImportGraph.name(["Sources/OverSireApp/queue_page.swift", "Sources/OverSireApp/queue.swift"]), "over-sire-app")
        XCTAssertEqual(ImportGraph.name(["a_b.ts", "c.ts"]), "a-b")
    }

    func testGateSendsOnlyAChange() {
        var g = ChangedPathsGate()
        let t = Date(timeIntervalSince1970: 0)
        XCTAssertTrue(g.due("i", ["a"], now: t))
        XCTAssertFalse(g.due("i", ["a"], now: t.addingTimeInterval(600)), "the same set")
        XCTAssertFalse(g.due("i", ["a", "b"], now: t.addingTimeInterval(60)), "too soon")
        XCTAssertTrue(g.due("i", ["a", "b"], now: t.addingTimeInterval(121)))
        XCTAssertTrue(g.due("j", ["a"], now: t.addingTimeInterval(121)), "each item has its own gate")
    }

    func testChangedPathsOfARepo() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-paths-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let r = ProcessRunner()
        func git(_ a: String...) throws {
            let out = try r.runSync("/usr/bin/git", ["-C", dir, "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"] + a)
            XCTAssertTrue(out.ok, "git \(a): \(out.stderr)")
        }
        try git("init", "-q", "-b", "main")
        try git("config", "user.email", "t@t")
        try git("config", "user.name", "t")
        for f in ["keep.txt", "edit.txt", "gone.txt"] { try "x".write(toFile: dir + "/" + f, atomically: true, encoding: .utf8) }
        try git("add", ".")
        try git("commit", "-q", "-m", "base")
        try git("checkout", "-q", "-b", "work")
        try "y".write(toFile: dir + "/edit.txt", atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(atPath: dir + "/gone.txt")
        try "n".write(toFile: dir + "/new.txt", atomically: true, encoding: .utf8)
        let s = PlannerSignals(commands: r, writes: StoreWrites(store: LocalStore(dir: URL(fileURLWithPath: dir + "-store"))))
        let paths = await s.changedPaths(dir)
        XCTAssertEqual(paths, ["edit.txt", "gone.txt", "new.txt"])
    }
}
