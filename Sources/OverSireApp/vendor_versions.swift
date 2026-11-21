import Foundation
import OverSireCore

/// Runs `<binary> --version` once for each file and keeps the result in memory. A new link target, mtime, size or
/// inode makes a new stamp, so an update of the binary gives a new probe.
actor VendorVersions {
    struct Stamp: Hashable, Sendable {
        /// The path with the links followed.
        let path: String
        let mtime: Date
        let size: Int
        let inode: Int
    }

    private let runner: any VendorProcessRunning
    private let stamp: @Sendable (String) -> Stamp?
    /// One task for each stamp. It holds the probe in flight and then its result, nil too.
    private var probes: [Stamp: Task<VendorVersion?, Never>] = [:]

    init(runner: any VendorProcessRunning, stamp: @escaping @Sendable (String) -> Stamp? = { VendorVersions.stamp($0) }) {
        self.runner = runner
        self.stamp = stamp
    }

    func version(of path: String, cli: VendorCLI) async -> VendorVersion? {
        guard let s = stamp(path) else { return nil }
        if let p = probes[s] { return await p.value }
        for old in probes.keys where old.path == s.path { probes[old] = nil }
        let runner = runner, launch = Self.launch(path, cli: cli)
        let p = Task<VendorVersion?, Never> {
            guard let exit = try? await runner.run(launch), exit.status == 0, !exit.timedOut else { return nil }
            return VendorVersion.find(in: String(decoding: exit.stdout, as: UTF8.self))
                ?? VendorVersion.find(in: String(decoding: exit.stderr, as: UTF8.self))
        }
        probes[s] = p
        return await p.value
    }

    nonisolated static func stamp(_ path: String) -> Stamp? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        let resolved = String(cString: real)
        guard let a = try? FileManager.default.attributesOfItem(atPath: resolved),
              let mtime = a[.modificationDate] as? Date else { return nil }
        let size = (a[.size] as? NSNumber)?.intValue ?? 0
        let inode = (a[.systemFileNumber] as? NSNumber)?.intValue ?? 0
        return Stamp(path: resolved, mtime: mtime, size: size, inode: inode)
    }

    nonisolated static func launch(_ path: String, cli: VendorCLI) -> VendorLaunch {
        var env = VendorCalls.base
        if let m = cli.managedEnv { env[m] = "OverSire" }
        return VendorLaunch(exe: path, args: ["--version"], environment: env, cwd: nil, timeout: .seconds(5),
                            maxStdout: 4 << 10, maxStderr: 4 << 10, logWords: [cli.binary, "--version"])
    }
}
