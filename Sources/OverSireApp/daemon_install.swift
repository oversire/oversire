import CryptoKit
import Foundation
import OverSireCore

// Installs the oversire CLI from its GitHub release: checks the SHA-256 and the Developer ID signature,
// puts it in ~/.local/bin (no password), pairs it with the hub when asked, and starts the daemon service.
// The service and the hooks run the binary by its full path, so it does not need to be on PATH.

/// The answer of `oversire daemon status --json`.
struct DaemonStatus: Decodable, Equatable {
    struct Service: Decodable, Equatable {
        var installed: Bool
        var running: Bool
    }
    var version: String
    var roles: [String]?
    var paired: Bool
    var device: String?
    var hub: String?
    var connected: Bool
    var since: String?
    var lastError: String?
    var service: Service
    var runtimes: [String]?

    var summary: String {
        guard service.running else { return service.installed ? "Stopped" : "Installed, not started" }
        guard paired else { return "Running · v\(version)" }
        if connected { return "Online · v\(version)" }
        return lastError.map { "Offline · \($0)" } ?? "Offline"
    }
}

struct InstallError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

struct DaemonInstaller {
    static let repo = "oversire/cli"
    static let teamID = "Q56WK6TB88"
    /// The folder on the default PATH. Root owns it on many Macs, so a write there needs a password.
    static let pathDir = URL(fileURLWithPath: "/usr/local/bin")
    static let userDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")

    /// The folder of the current install: an old install in /usr/local/bin stays there. Else the user folder.
    static var binDir: URL {
        let onPath = pathDir.appendingPathComponent("oversire")
        guard FileManager.default.isExecutableFile(atPath: onPath.path) else { return userDir }
        return onPath.resolvingSymlinksInPath().deletingLastPathComponent()
    }
    /// The folder of the old oversire-runner config. Its presence means an old install to update.
    static let legacyConfig = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/oversire-runner")

    /// A hub pairing. `code` runs only after the checks pass.
    struct Pairing {
        var hub: String
        var name: String
        var code: () async throws -> String
    }

    let http: any HTTPTransport
    let commands: any CommandRunner
    let dir: URL
    /// Add to PATH puts a link here.
    let linkDir: URL
    /// The goreleaser arch name: arm64 or amd64.
    let arch: String

    init(http: any HTTPTransport, commands: any CommandRunner, dir: URL = DaemonInstaller.binDir, linkDir: URL = DaemonInstaller.pathDir,
         arch: String = DaemonInstaller.hostArch) {
        self.http = http
        self.commands = commands
        self.dir = dir
        self.linkDir = linkDir
        self.arch = arch
    }

    static var hostArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }

    var exe: URL { dir.appendingPathComponent("oversire") }
    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: exe.path) }

    /// Installs the latest release, pairs it with the hub when `pairing` is set, and starts the service.
    func install(keepAwake: Bool = false, pairing: Pairing? = nil) async throws -> DaemonStatus {
        let rel = try await latest()
        let archive = "oversire_\(rel.version)_darwin_\(arch).tar.gz"
        guard let asset = rel.assets.first(where: { $0.name == archive }),
              let sums = rel.assets.first(where: { $0.name == "checksums.txt" }) else {
            throw InstallError("The release v\(rel.version) has no \(archive)")
        }
        let data = try await get(asset.browserDownloadURL)
        let want = try Self.checksum(of: archive, in: String(decoding: try await get(sums.browserDownloadURL), as: UTF8.self))
        let got = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard got == want else { throw InstallError("The SHA-256 of \(archive) does not match checksums.txt") }

        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("oversire-download-\(UUID().uuidString)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let tarball = tmp.appendingPathComponent(archive)
        try data.write(to: tarball)
        try await must("/usr/bin/tar", ["-xzf", tarball.path, "-C", tmp.path, "oversire"], what: "unpack")
        let staged = tmp.appendingPathComponent("oversire")
        try await verify(staged)
        try await place(staged)

        if let pairing {
            try await must(exe.path, ["hub", "pair", "-", "--hub", pairing.hub, "--name", pairing.name],
                           stdin: Data((try await pairing.code() + "\n").utf8), what: "pair")
        }
        try await must(exe.path, ["daemon", "install"] + (keepAwake ? ["--keep-awake"] : []), what: "install")
        return try await status() ?? { throw InstallError("oversire daemon status gave no answer") }()
    }

    /// Moves the checked binary into `dir`. A folder that the user cannot write needs an administrator password.
    private func place(_ staged: URL) async throws {
        let fm = FileManager.default
        if (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil, fm.isWritableFile(atPath: dir.path) {
            let next = dir.appendingPathComponent(".oversire-\(UUID().uuidString)")
            try fm.copyItem(at: staged, to: next)
            // A rename in the same folder replaces the old binary in one step.
            _ = try fm.replaceItemAt(exe, withItemAt: next)
            return
        }
        try await admin("/bin/mkdir -p \(Self.shellQuote(dir.path)) && /usr/bin/install -m 755 \(Self.shellQuote(staged.path)) \(Self.shellQuote(exe.path))",
                        what: "copy")
    }

    /// The `oversire` command in linkDir runs this install.
    var onPath: Bool {
        let link = linkDir.appendingPathComponent("oversire")
        return FileManager.default.isExecutableFile(atPath: link.path) && link.resolvingSymlinksInPath().path == exe.resolvingSymlinksInPath().path
    }

    /// The login shell of the user finds an `oversire` command.
    func shellFinds() async -> Bool {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let out = try? await commands.run(shell, ["-ilc", "command -v oversire"], stdin: nil, timeout: .seconds(5))
        return out?.status == 0
    }

    /// Links linkDir/oversire to the install, so that a terminal finds it. Root owns /usr/local/bin on many Macs: then it asks for a password.
    func linkOnPath() async throws {
        let link = linkDir.appendingPathComponent("oversire")
        let sh = "/bin/mkdir -p \(Self.shellQuote(linkDir.path)) && /bin/ln -sf \(Self.shellQuote(exe.path)) \(Self.shellQuote(link.path))"
        if FileManager.default.isWritableFile(atPath: linkDir.path) {
            try await must("/bin/sh", ["-c", sh], what: "link")
        } else {
            try await admin(sh, what: "link")
        }
    }

    private func admin(_ sh: String, what: String) async throws {
        let script = "do shell script \"\(sh.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\" with administrator privileges"
        try await must("/usr/bin/osascript", ["-e", script], what: what)
    }

    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Nil when the CLI is not installed.
    func status() async throws -> DaemonStatus? {
        guard isInstalled else { return nil }
        let out = try await must(exe.path, ["daemon", "status", "--json"], what: "status")
        return try JSONDecoder().decode(DaemonStatus.self, from: out.stdout)
    }

    /// Stops the service. The binary and its config stay.
    func uninstall() async throws {
        guard isInstalled else { return }
        try await must(exe.path, ["daemon", "uninstall"], what: "uninstall")
    }

    /// The trust boundary: only a binary that our team signed runs.
    func verify(_ binary: URL) async throws {
        try await must("/usr/bin/codesign", ["--verify", "--strict", binary.path], what: "check the signature of")
        let info = try await must("/usr/bin/codesign", ["-dv", binary.path], what: "read the signature of")
        guard info.stderr.split(whereSeparator: \.isNewline).contains("TeamIdentifier=\(Self.teamID)") else {
            throw InstallError("oversire is not signed by the OverSire team")
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
            throw InstallError("Cannot \(what) oversire\(why.isEmpty ? "" : ": \(why)")")
        }
        return out
    }
}
