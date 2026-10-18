import CryptoKit
import Foundation
import OverSireCore

// "Use this Mac as the runner": downloads oversire-runner from its GitHub release, checks the SHA-256
// and the Developer ID signature, installs it, pairs it with a runner code and starts its LaunchAgent.

/// The answer of `oversire-runner status --json`.
struct RunnerStatus: Decodable, Equatable {
    struct Service: Decodable, Equatable {
        var installed: Bool
        var running: Bool
    }
    var version: String
    var paired: Bool
    var device: String?
    var hub: String?
    var connected: Bool
    var since: String?
    var lastError: String?
    var service: Service
    var runtimes: [String]?

    var summary: String {
        guard paired else { return "Installed, not paired" }
        guard service.running else { return "Stopped" }
        if connected { return "Online · v\(version)" }
        return lastError.map { "Offline · \($0)" } ?? "Offline"
    }
}

struct InstallError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

struct RunnerInstaller {
    static let repo = "oversire/runner"
    static let teamID = "Q56WK6TB88"
    static let defaultDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("OverSire/runner")

    let http: any HTTPTransport
    let commands: any CommandRunner
    let dir: URL
    /// The goreleaser arch name: arm64 or amd64.
    let arch: String

    init(http: any HTTPTransport, commands: any CommandRunner, dir: URL = RunnerInstaller.defaultDir, arch: String = RunnerInstaller.hostArch) {
        self.http = http
        self.commands = commands
        self.dir = dir
        self.arch = arch
    }

    static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    var exe: URL { dir.appendingPathComponent("oversire-runner") }
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: exe.path) }

    /// Installs the latest release, pairs it with `code()` and starts the service. `code` runs only after the checks pass.
    func install(hub: String, name: String, keepAwake: Bool, code: () async throws -> String) async throws -> RunnerStatus {
        let rel = try await latest()
        let archive = "oversire-runner_\(rel.version)_darwin_\(arch).tar.gz"
        guard let asset = rel.assets.first(where: { $0.name == archive }),
              let sums = rel.assets.first(where: { $0.name == "checksums.txt" }) else {
            throw InstallError("The release v\(rel.version) has no \(archive)")
        }
        let data = try await get(asset.browserDownloadURL)
        let want = try Self.checksum(of: archive, in: String(decoding: try await get(sums.browserDownloadURL), as: UTF8.self))
        let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard got == want else { throw InstallError("The SHA-256 of \(archive) does not match checksums.txt") }

        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let tmp = dir.appendingPathComponent(".download-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: tmp) }
        let tarball = tmp.appendingPathComponent(archive)
        try data.write(to: tarball)
        try await must("/usr/bin/tar", ["-xzf", tarball.path, "-C", tmp.path, "oversire-runner"], what: "unpack")
        let staged = tmp.appendingPathComponent("oversire-runner")
        try await verify(staged)
        // A rename on the same volume replaces the old binary in one step.
        _ = try fm.replaceItemAt(exe, withItemAt: staged)

        try await must(exe.path, ["pair", "-", "--hub", hub, "--name", name], stdin: Data((try await code() + "\n").utf8), what: "pair")
        try await must(exe.path, ["install"] + (keepAwake ? ["--keep-awake"] : []), what: "install")
        return try await status() ?? { throw InstallError("oversire-runner status gave no answer") }()
    }

    /// Nil when the runner is not installed.
    func status() async throws -> RunnerStatus? {
        guard isInstalled else { return nil }
        let out = try await must(exe.path, ["status", "--json"], what: "status")
        return try JSONDecoder().decode(RunnerStatus.self, from: out.stdout)
    }

    /// Stops the service. The binary and its config stay.
    func uninstall() async throws {
        guard isInstalled else { return }
        try await must(exe.path, ["uninstall"], what: "uninstall")
    }

    /// The trust boundary: only a binary that our team signed runs.
    func verify(_ binary: URL) async throws {
        try await must("/usr/bin/codesign", ["--verify", "--strict", binary.path], what: "check the signature of")
        let info = try await must("/usr/bin/codesign", ["-dv", binary.path], what: "read the signature of")
        guard info.stderr.split(whereSeparator: \.isNewline).contains("TeamIdentifier=\(Self.teamID)") else {
            throw InstallError("oversire-runner is not signed by the OverSire team")
        }
    }

    /// The hex digest of `name` in a goreleaser checksums.txt.
    static func checksum(of name: String, in text: String) throws -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1] == name, parts[0].count == 64 { return parts[0].lowercased() }
        }
        throw InstallError("checksums.txt has no line for \(name)")
    }

    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
        }
        let tagName: String
        let assets: [Asset]
        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", assets }
    }

    func latest() async throws -> Release {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        return try JSONDecoder().decode(Release.self, from: try await get(req))
    }

    private func get(_ url: URL) async throws -> Data { try await get(URLRequest(url: url)) }

    private func get(_ req: URLRequest) async throws -> Data {
        let (data, res) = try await http.send(req)
        guard (200..<300).contains(res.statusCode) else { throw InstallError("\(req.url?.host ?? "GitHub") returned \(res.statusCode)") }
        return data
    }

    @discardableResult
    private func must(_ exe: String, _ args: [String], stdin: Data? = nil, what: String) async throws -> CommandOutput {
        let out = try await commands.run(exe, args, stdin: stdin, timeout: .seconds(60))
        guard out.status == 0 else {
            let why = out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError("Cannot \(what) oversire-runner\(why.isEmpty ? "" : ": \(why)")")
        }
        return out
    }
}
