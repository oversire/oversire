import CryptoKit
import Foundation
import OverSireCore

// `oversire vendor install` (OVERSIRE-582). The app puts a vendor CLI in <root>/<vendor>/<version>/<binary>.
// The trust boundary is the SHA-256 of the archive: from the signed Trebi catalog, or from checksums.txt of the
// GitHub release. The vendor binaries have an ad hoc signature, so a Developer ID check does not apply.

/// The release that an install takes.
struct VendorOffer: Hashable, Sendable {
    let version: VendorVersion
    let url: URL
    /// Lower-case hex.
    let sha256: String
    /// The file name of the archive.
    let archive: String
    /// trebi-catalog or github-release.
    let release: String
}

protocol VendorInstalling: Sendable {
    func offer(_ vendor: ProviderID, _ cli: VendorCLI) async throws -> VendorOffer
    /// Gives the path of the new binary.
    func install(_ vendor: ProviderID, _ cli: VendorCLI, _ offer: VendorOffer) async throws -> String
    /// Gives the removed versions.
    func remove(_ vendor: ProviderID) throws -> [VendorVersion]
    func ownCopy(_ vendor: ProviderID, binary: String) -> String?
}

enum VendorInstallError: Error, Equatable, CustomStringConvertible {
    case noInstall(formula: String)
    case badSignature
    case badDigest(archive: String)
    case tooOld(binary: String, newest: VendorVersion, min: VendorVersion)
    case noRelease(source: String, binary: String, platform: String)
    case rateLimited
    case wrongVersion(binary: String, got: VendorVersion?, want: VendorVersion)
    case http(host: String, status: Int)
    case tooLarge(host: String, limit: Int)
    case unpack(String)

    var description: String {
        switch self {
        case .noInstall(let f): return "OverSire does not install \(f). Install it with Homebrew: `brew install \(f)`. \(f) keeps its own login."
        case .badSignature: return "The signature of the Trebi catalog is not valid. OverSire installs nothing."
        case .badDigest(let a): return "The SHA-256 of \(a) does not match. OverSire installs nothing."
        case .tooOld(let b, let newest, let min): return "The newest \(b) is \(newest). OverSire needs \(min) or newer."
        case .noRelease(let source, let b, let platform): return "\(source) has no \(b) for \(platform)."
        case .rateLimited: return "GitHub allows 60 calls in one hour without a login. Try again later."
        case .wrongVersion(let b, let got?, let want): return "The archive holds \(b) \(got), not \(want). OverSire installs nothing."
        case .wrongVersion(let b, nil, let want): return "\(b) in the archive gives no version, not \(want). OverSire installs nothing."
        case .http(let host, let status): return "\(host) returned \(status)."
        case .tooLarge(let host, let limit): return "The answer of \(host) is larger than \(limit >> 10) KiB. OverSire installs nothing."
        case .unpack(let why): return "OverSire cannot unpack the archive: \(why)"
        }
    }
}

struct VendorInstaller: VendorInstalling {
    static let root = URL(fileURLWithPath: CONFIG_DIR).appendingPathComponent("vendors")
    static let catalogIndex = URL(string: "https://catalog.trebi.ai/v1/index.json")!
    /// Any key of the list can sign the index. A new key ships next to the old one first.
    static let catalogKeys = ["Av6bL0fDX2i7hUF5ioVDsznuNX6OJE8hzMc82/wj7oM="]
    static let maxIndex = 4 << 20
    static let maxChecksums = 64 << 10
    static let maxArchive = 64 << 20

    let http: any HTTPTransport
    let commands: any CommandRunner
    /// The version that `<path> --version` gives.
    let probe: @Sendable (String, VendorCLI) async -> VendorVersion?
    let root: URL
    /// The goreleaser arch name: arm64 or amd64.
    let arch: String
    let keys: [String]
    let userAgent: String

    init(http: any HTTPTransport, commands: any CommandRunner, probe: @escaping @Sendable (String, VendorCLI) async -> VendorVersion?,
         root: URL = VendorInstaller.root, arch: String = DaemonInstaller.hostArch, keys: [String] = VendorInstaller.catalogKeys,
         userAgent: String) {
        self.http = http
        self.commands = commands
        self.probe = probe
        self.root = root
        self.arch = arch
        self.keys = keys
        self.userAgent = userAgent
    }

    var platform: String { "darwin/\(arch)" }

    func offer(_ vendor: ProviderID, _ cli: VendorCLI) async throws -> VendorOffer {
        let min = cli.minVersion.flatMap(VendorVersion.init)
        switch cli.release {
        case .trebiCatalog(let entry)?:
            return try await catalogOffer(entry: entry, binary: cli.binary, min: min)
        case .githubRelease(let repo, let prefix, let asset)?:
            return try await githubOffer(repo: repo, tagPrefix: prefix, asset: asset, binary: cli.binary, min: min)
        case .homebrew(let f)?:
            throw VendorInstallError.noInstall(formula: f)
        case nil:
            throw VendorInstallError.noInstall(formula: cli.binary)
        }
    }

    // MARK: Trebi catalog

    private struct CatalogIndex: Decodable {
        struct Entry: Decodable {
            let name: String
            let versions: [Version]
        }
        struct Version: Decodable {
            let version: String
            let yanked: Bool?
            let binaries: [Binary]?
        }
        struct Binary: Decodable {
            let platform: String
            let url: String
            let digest: String
        }
        let entries: [Entry]
    }

    /// The newest version that is not yanked and has a binary for this Mac. The signature is checked before the index is read.
    func catalogOffer(entry: String, binary: String, min: VendorVersion?) async throws -> VendorOffer {
        let index = try await get(Self.catalogIndex, max: Self.maxIndex)
        let sig = try await get(Self.catalogIndex.appendingPathExtension("sig"), max: 4 << 10)
        guard Self.verifyCatalog(index, signature: sig, keys: keys) else { throw VendorInstallError.badSignature }
        let decoded: CatalogIndex
        do { decoded = try JSONDecoder().decode(CatalogIndex.self, from: index) } catch {
            throw VendorInstallError.noRelease(source: "The Trebi catalog", binary: binary, platform: platform)
        }
        let candidates: [VendorOffer] = (decoded.entries.first { $0.name == entry }?.versions ?? []).compactMap { v in
            guard v.yanked != true, let version = VendorVersion(v.version),
                  let b = v.binaries?.first(where: { $0.platform == platform }), b.digest.hasPrefix("sha256:"),
                  let url = URL(string: b.url), url.scheme == "https" else { return nil }
            let hex = String(b.digest.dropFirst("sha256:".count)).lowercased()
            guard Self.isHex64(hex) else { return nil }
            return VendorOffer(version: version, url: url, sha256: hex, archive: url.lastPathComponent, release: "trebi-catalog")
        }
        return try Self.newest(candidates, binary: binary, min: min, source: "The Trebi catalog", platform: platform)
    }

    static func verifyCatalog(_ index: Data, signature: Data, keys: [String]) -> Bool {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sig = Data(base64Encoded: text) else { return false }
        return keys.contains { k in
            guard let raw = Data(base64Encoded: k), let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
            return key.isValidSignature(sig, for: index)
        }
    }

    // MARK: GitHub releases

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    /// The newest `<tagPrefix><version>` release that is not a draft and not a prerelease. `releases/latest` can be another product.
    func githubOffer(repo: String, tagPrefix: String, asset: String, binary: String, min: VendorVersion?) async throws -> VendorOffer {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=30")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let list = try await get(req, max: Self.maxIndex)
        let releases = (try? JSONDecoder().decode([GitHubRelease].self, from: list)) ?? []
        let tagged = releases.compactMap { r -> (VendorVersion, String, GitHubRelease)? in
            guard !r.draft, !r.prerelease, r.tag_name.hasPrefix(tagPrefix) else { return nil }
            let text = String(r.tag_name.dropFirst(tagPrefix.count))
            guard !text.contains("-"), let v = VendorVersion(text) else { return nil }
            return (v, text, r)
        }
        guard let (version, text, rel) = tagged.max(by: { $0.0 < $1.0 }) else {
            throw VendorInstallError.noRelease(source: repo, binary: binary, platform: platform)
        }
        if let min, version < min { throw VendorInstallError.tooOld(binary: binary, newest: version, min: min) }
        let name = asset.replacingOccurrences(of: "{version}", with: text).replacingOccurrences(of: "{arch}", with: arch)
        func https(_ n: String) -> URL? {
            rel.assets.first { $0.name == n }.flatMap { URL(string: $0.browser_download_url) }.flatMap { $0.scheme == "https" ? $0 : nil }
        }
        guard let url = https(name), let sums = https("checksums.txt") else {
            throw VendorInstallError.noRelease(source: repo, binary: binary, platform: platform)
        }
        let text2 = String(decoding: try await get(sums, max: Self.maxChecksums), as: UTF8.self)
        let sha = try DaemonInstaller.checksum(of: name, in: text2)
        return VendorOffer(version: version, url: url, sha256: sha, archive: name, release: "github-release")
    }

    static func newest(_ offers: [VendorOffer], binary: String, min: VendorVersion?, source: String, platform: String) throws -> VendorOffer {
        guard let top = offers.max(by: { $0.version < $1.version }) else {
            throw VendorInstallError.noRelease(source: source, binary: binary, platform: platform)
        }
        if let min, top.version < min { throw VendorInstallError.tooOld(binary: binary, newest: top.version, min: min) }
        return top
    }

    static func isHex64(_ s: String) -> Bool { s.count == 64 && s.allSatisfy(\.isHexDigit) }

    // MARK: Install

    func folder(_ vendor: ProviderID) -> URL { root.appendingPathComponent(vendor.rawValue, isDirectory: true) }

    /// Downloads, checks and unpacks into a staging folder, then moves the folder in with one rename.
    func install(_ vendor: ProviderID, _ cli: VendorCLI, _ offer: VendorOffer) async throws -> String {
        let fm = FileManager.default
        let dir = folder(vendor)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        // Jobs of one vendor run one at a time, so these are left from a stop of the app.
        for name in names(in: dir) where name.hasPrefix(".staging-") || name.hasPrefix(".old-") {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        let data = try await get(offer.url, max: Self.maxArchive)
        guard Self.hex(SHA256.hash(data: data)) == offer.sha256 else { throw VendorInstallError.badDigest(archive: offer.archive) }

        let staging = dir.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        let final = dir.appendingPathComponent(offer.version.description, isDirectory: true)
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false)
            let tarball = staging.appendingPathComponent(offer.archive)
            try data.write(to: tarball)
            let out = try await commands.run("/usr/bin/tar", ["-xzf", tarball.path, "-C", staging.path, cli.binary], stdin: nil, timeout: .seconds(60))
            guard out.ok else { throw VendorInstallError.unpack(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
            try fm.removeItem(at: tarball)
            let bin = staging.appendingPathComponent(cli.binary)
            guard (try? fm.attributesOfItem(atPath: bin.path)[.type] as? FileAttributeType) == .typeRegular else {
                throw VendorInstallError.unpack("the archive has no file \(cli.binary).")
            }
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path)
            _ = removexattr(bin.path, "com.apple.quarantine", XATTR_NOFOLLOW)
            let got = await probe(bin.path, cli)
            guard got == offer.version else { throw VendorInstallError.wrongVersion(binary: cli.binary, got: got, want: offer.version) }
            if fm.fileExists(atPath: final.path) {
                try fm.moveItem(at: final, to: dir.appendingPathComponent(".old-\(UUID().uuidString)"))
            }
            try fm.moveItem(at: staging, to: final)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
        for name in names(in: dir) where name != final.lastPathComponent && (name.hasPrefix(".old-") || VendorVersion(name) != nil) {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
        return final.appendingPathComponent(cli.binary).path
    }

    /// The binary in the highest version folder. Folders whose names start with a dot are skipped.
    func ownCopy(_ vendor: ProviderID, binary: String) -> String? {
        let dir = folder(vendor)
        return versions(in: dir).reversed().lazy
            .map { dir.appendingPathComponent($0.name).appendingPathComponent(binary).path }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func remove(_ vendor: ProviderID) throws -> [VendorVersion] {
        let dir = folder(vendor)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        let gone = versions(in: dir).map(\.version)
        try FileManager.default.removeItem(at: dir)
        return gone
    }

    /// The version folders, lowest first.
    private func versions(in dir: URL) -> [(name: String, version: VendorVersion)] {
        names(in: dir).filter { !$0.hasPrefix(".") }.compactMap { n in VendorVersion(n).map { (n, $0) } }.sorted { $0.version < $1.version }
    }

    private func names(in dir: URL) -> [String] { (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] }

    // MARK: HTTP

    private func get(_ url: URL, max: Int) async throws -> Data {
        var req = URLRequest(url: url)
        req.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return try await get(req, max: max)
    }

    private func get(_ req: URLRequest, max: Int) async throws -> Data {
        let (data, res) = try await http.send(req)
        let host = req.url?.host ?? "The server"
        if req.url?.host == "api.github.com", res.statusCode == 403 || res.statusCode == 429 { throw VendorInstallError.rateLimited }
        guard (200..<300).contains(res.statusCode) else { throw VendorInstallError.http(host: host, status: res.statusCode) }
        guard data.count <= max else { throw VendorInstallError.tooLarge(host: host, limit: max) }
        return data
    }

    static func hex(_ d: SHA256.Digest) -> String { d.map { String(format: "%02x", $0) }.joined() }
}
