import Foundation
import OverSireCore

// ─── Planner signals ─────────────────────────────────────────────────────────
// Two signals from the Mac for the Planner: the changed paths of running Orca sessions, and area candidates from
// the import graph of each project repo. Only paths leave the Mac, never file text. Without a cloud account, nothing leaves.

/// The imports of the source files of one repo, as a directed graph. Pure: the caller reads the files.
struct ImportGraph {
    static let maxFiles = 4000
    static let exts: Set<String> = ["swift", "ts", "tsx", "js", "jsx", "mjs", "go"]

    /// File → the nodes it imports. A node is a file path, or "dir/**" for a Swift module or a Go package.
    private(set) var edges: [String: Set<String>] = [:]
    let files: Set<String>

    /// `files`: repo-relative path → text. `goModule`: the module line of go.mod.
    init(files: [String: String], goModule: String? = nil) {
        self.files = Set(files.keys)
        let modules = Self.swiftModules(Array(files.keys))
        for (path, text) in files {
            var out = Set<String>()
            for spec in Self.imports(path: path, text: text) {
                if let node = resolve(spec, from: path, modules: modules, goModule: goModule), node != path { out.insert(node) }
            }
            if !out.isEmpty { edges[path] = out }
        }
    }

    /// The raw import specs of one file. Swift: module names. TS and JS: the module text. Go: the package paths.
    static func imports(path: String, text: String) -> [String] {
        let ext = (path as NSString).pathExtension
        var out: [String] = []
        switch ext {
        case "swift":
            for m in text.matches(of: #/(?m)^\s*(?:@\w+(?:\([^)]*\))?\s+)*import\s+(?:(?:class|struct|enum|protocol|func|var|let|typealias)\s+)?([A-Za-z_][A-Za-z0-9_]*)/#) {
                out.append(String(m.1))
            }
        case "go":
            for m in text.matches(of: #/(?m)^\s*import\s+(?:[A-Za-z_.]+\s+)?"([^"]+)"/#) { out.append(String(m.1)) }
            for block in text.matches(of: #/(?s)import\s*\((.*?)\)/#) {
                for m in String(block.1).matches(of: #/"([^"]+)"/#) { out.append(String(m.1)) }
            }
        case "ts", "tsx", "js", "jsx", "mjs":
            for m in text.matches(of: #/(?:import|export)\s[^'"]*?from\s*['"]([^'"]+)['"]/#) { out.append(String(m.1)) }
            for m in text.matches(of: #/(?m)^\s*import\s*['"]([^'"]+)['"]/#) { out.append(String(m.1)) }
            for m in text.matches(of: #/(?:require|import)\(\s*['"]([^'"]+)['"]\s*\)/#) { out.append(String(m.1)) }
        default: break
        }
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    /// Module name → its directory, from SwiftPM layout: Sources/<Module>/... or Sources/<Group>/<Module>/...
    private static func swiftModules(_ paths: [String]) -> [String: String] {
        var out: [String: String] = [:]
        for p in paths where p.hasSuffix(".swift") {
            let parts = p.split(separator: "/").map(String.init)
            guard let i = parts.firstIndex(of: "Sources"), parts.count > i + 2 else { continue }
            let dir = parts[...(parts.count - 2)].joined(separator: "/")
            let name = parts[parts.count - 2]
            if out[name] == nil || dir.count < out[name]!.count { out[name] = dir }
        }
        return out
    }

    private func resolve(_ spec: String, from path: String, modules: [String: String], goModule: String?) -> String? {
        if path.hasSuffix(".swift") { return modules[spec].map { $0 + "/**" } }
        if path.hasSuffix(".go") {
            guard let mod = goModule, spec == mod || spec.hasPrefix(mod + "/") else { return nil }
            let dir = String(spec.dropFirst(mod.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            return (dir.isEmpty ? "" : dir + "/") + "*.go"
        }
        guard spec.hasPrefix(".") else { return nil }
        var parts = (path as NSString).deletingLastPathComponent.split(separator: "/").map(String.init)
        for p in spec.split(separator: "/") {
            if p == ".." { if parts.popLast() == nil { return nil } } else if p != "." { parts.append(String(p)) }
        }
        let clean = parts.joined(separator: "/")
        let stem = clean.replacingOccurrences(of: "\\.(js|mjs|jsx)$", with: "", options: .regularExpression)
        for c in [clean] + ["ts", "tsx", "js", "jsx", "mjs"].map { "\(stem).\($0)" } + ["ts", "js"].map { "\(clean)/index.\($0)" } where files.contains(c) {
            return c
        }
        return nil
    }

    /// The importers of each node: the files that import it.
    var importers: [String: Set<String>] {
        var out: [String: Set<String>] = [:]
        for (f, targets) in edges { for t in targets { out[t, default: []].insert(f) } }
        return out
    }

    /// The top 5% of the nodes by importers, at least one, each with at least `minImporters`.
    func hubs(share: Double = 0.05, minImporters: Int = 3) -> [AreaCandidates.Hub] {
        let ranked = importers.map { ($0.key, $0.value.count) }.filter { $0.1 >= minImporters }.sorted { ($1.1, $0.0) < ($0.1, $1.0) }
        let n = max(1, Int((Double(ranked.count) * share).rounded(.up)))
        return ranked.prefix(min(n, 50)).map { AreaCandidates.Hub(glob: $0.0, importers: $0.1) }
    }

    /// Groups of files that import each other: label propagation on the file graph without the hubs. Pure and fixed order.
    func clusters(hubs: Set<String> = [], minSize: Int = 2) -> [AreaCandidates.Cluster] {
        var near: [String: Set<String>] = [:]
        for (f, targets) in edges {
            for t in targets where files.contains(t) && !hubs.contains(t) {
                near[f, default: []].insert(t)
                near[t, default: []].insert(f)
            }
        }
        let nodes = near.keys.sorted()
        var label = Dictionary(uniqueKeysWithValues: nodes.map { ($0, $0) })
        for _ in 0..<20 {
            var moved = false
            for n in nodes {
                var count: [String: Int] = [:]
                for m in near[n] ?? [] { count[label[m]!, default: 0] += 1 }
                guard let best = count.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key, best != label[n] else { continue }
                if count[best]! > count[label[n]!, default: 0] { label[n] = best; moved = true }
            }
            if !moved { break }
        }
        let groups = Dictionary(grouping: nodes, by: { label[$0]! }).values.filter { $0.count >= minSize }
        return groups.map { g -> AreaCandidates.Cluster in
            let sorted = g.sorted()
            return AreaCandidates.Cluster(name: Self.name(sorted), globs: Array(sorted.prefix(20)))
        }.sorted { $0.globs.first! < $1.globs.first! }.prefix(50).map { $0 }
    }

    /// The last part of the common directory, or the stem of the first file. Lower case with hyphens.
    static func name(_ paths: [String]) -> String {
        let dirs = paths.map { $0.split(separator: "/").dropLast().map(String.init) }
        var common = dirs.first ?? []
        for d in dirs.dropFirst() { common = Array(zip(common, d).prefix { $0 == $1 }.map(\.0)) }
        let raw = common.last ?? ((paths.first ?? "area") as NSString).lastPathComponent.components(separatedBy: ".").first ?? "area"
        return ItemAreas.clean([raw.replacingOccurrences(of: "_", with: "-").replacingOccurrences(of: "([a-z])([A-Z])", with: "$1-$2", options: .regularExpression)]).first ?? "area"
    }
}

/// Sends the changed paths of an item at most once each `every`, and only when the set changes.
struct ChangedPathsGate {
    var every: TimeInterval = 120
    private var sent: [String: (paths: [String], at: Date)] = [:]

    mutating func due(_ id: String, _ paths: [String], now: Date) -> Bool {
        if let last = sent[id], last.paths == paths || now.timeIntervalSince(last.at) < every { return false }
        sent[id] = (paths, now)
        return true
    }
}

final class PlannerSignals {
    private let commands: any CommandRunner
    private let writes: StoreWrites
    private var gate = ChangedPathsGate()
    private var scanned: [String: Date] = [:]   // project → last graph scan
    private var busy = false
    static let git = "/usr/bin/git"

    init(commands: any CommandRunner, writes: StoreWrites) {
        self.commands = commands
        self.writes = writes
    }

    /// The changed paths of a worktree against the merge base with the default branch, plus the untracked files.
    func changedPaths(_ dir: String) async -> [String]? {
        func git(_ args: [String]) async -> String? {
            guard let r = try? await commands.run(Self.git, ["-C", dir] + args, stdin: nil, timeout: .seconds(20)), r.ok else { return nil }
            return String(decoding: r.stdout, as: UTF8.self)
        }
        let head = await git(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"])?.trimmingCharacters(in: .whitespacesAndNewlines)
        var base: String?
        for b in [head, "origin/main", "main", "origin/master", "master"].compactMap({ $0 }) where base == nil {
            base = await git(["merge-base", "HEAD", b])?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let base, !base.isEmpty, let diff = await git(["diff", "--name-only", base]) else { return nil }
        let untracked = await git(["ls-files", "--others", "--exclude-standard"]) ?? ""
        let all = Set((diff + "\n" + untracked).split(separator: "\n").map(String.init).filter { !$0.isEmpty })
        return Array(all.sorted().prefix(ChangedPaths.maxPaths))
    }

    /// For each running item with a checkout: writes ChangedPaths when the set changed. `items`: key → (ref, checkout path).
    func tick(_ items: [String: (ItemRef, String)], now: Date = Date()) {
        guard !busy, !items.isEmpty else { return }
        busy = true
        Task {
            var out: [ChangedPaths] = []
            for (_, (ref, path)) in items.sorted(by: { $0.key < $1.key }) {
                if let paths = await changedPaths(path) { out.append(ChangedPaths(item: ref, paths: paths, at: now)) }
            }
            await MainActor.run {
                for r in out where self.gate.due(r.id, r.paths, now: now) { self.writes.put(r) }
                self.busy = false
            }
        }
    }

    /// Scans the repo of each project once a day, or at once with `force`. `repos`: project storeKey → repo path.
    func scan(_ repos: [String: String], force: Bool = false, now: Date = Date()) {
        for (project, dir) in repos.sorted(by: { $0.key < $1.key }) {
            if !force, let at = scanned[project], now.timeIntervalSince(at) < 86400 { continue }
            scanned[project] = now
            Task {
                guard let c = await candidates(project: project, dir: dir, now: now) else { return }
                await MainActor.run { self.writes.put(c) }
            }
        }
    }

    func candidates(project: String, dir: String, now: Date) async -> AreaCandidates? {
        guard let r = try? await commands.run(Self.git, ["-C", dir, "ls-files"], stdin: nil, timeout: .seconds(30)), r.ok else { return nil }
        let paths = String(decoding: r.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { ImportGraph.exts.contains(($0 as NSString).pathExtension) && !$0.contains("node_modules/") }
            .prefix(ImportGraph.maxFiles)
        var files: [String: String] = [:]
        for p in paths {
            // Only the head of a file has imports.
            guard let h = FileHandle(forReadingAtPath: (dir as NSString).appendingPathComponent(p)) else { continue }
            files[p] = String(decoding: h.readData(ofLength: 16_384), as: UTF8.self)
            try? h.close()
        }
        let goMod = (try? String(contentsOfFile: (dir as NSString).appendingPathComponent("go.mod"), encoding: .utf8))
            .flatMap { $0.firstMatch(of: #/(?m)^module\s+(\S+)/#).map { String($0.1) } }
        let g = ImportGraph(files: files, goModule: goMod)
        let hubs = g.hubs()
        return AreaCandidates(project: project, at: now, hubs: hubs, clusters: g.clusters(hubs: Set(hubs.map(\.glob))))
    }
}
