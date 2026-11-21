import CryptoKit
import OverSireCore
import XCTest
@testable import OverSireApp

private final class FakeHTTP: HTTPTransport, @unchecked Sendable {
    var routes: [String: (Int, Data)] = [:]
    private(set) var asked: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        asked.append(request)
        let (code, body) = routes[request.url!.absoluteString] ?? (404, Data())
        return (body, HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }

    var urls: [String] { asked.map { $0.url!.absoluteString } }
}

/// The fake tar writes the member, and can set the quarantine attribute.
private final class FakeCommands: CommandRunner, @unchecked Sendable {
    var quarantine = false
    private(set) var quarantined = false
    private(set) var calls: [(exe: String, args: [String])] = []

    func run(_ exe: String, _ args: [String], stdin: Data?, timeout: Duration) async throws -> CommandOutput {
        calls.append((exe, args))
        if exe == "/usr/bin/tar" {
            let dir = URL(fileURLWithPath: args[args.firstIndex(of: "-C")! + 1])
            let bin = dir.appendingPathComponent(args.last!)
            try Data("#!/bin/sh\necho 0.2.2\n".utf8).write(to: bin)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: bin.path)
            if quarantine {
                let v = "0081;00000000;OverSire;"
                quarantined = v.withCString { setxattr(bin.path, "com.apple.quarantine", $0, strlen($0), 0, 0) } == 0
            }
        }
        return CommandOutput(status: 0, stdout: Data(), stderr: "")
    }
}

final class VendorInstallerTests: XCTestCase {
    let archive = Data("plane archive bytes".utf8)
    let key = Curve25519.Signing.PrivateKey()
    let plane = VendorCLI(binary: "plane-cli", minVersion: "0.2.2", release: .trebiCatalog(entry: "plane"))
    let bigTimer = VendorCLI(binary: "big-timer-cli", minVersion: "1.0.12",
                             release: .githubRelease(repo: "Big-Time-Data/big-timer-releases", tagPrefix: "cli-v",
                                                     asset: "big-timer-cli_{version}_darwin_{arch}.tar.gz"))
    fileprivate var http: FakeHTTP!
    fileprivate var commands: FakeCommands!
    var root: URL!
    var probed = "0.2.2"

    static let indexURL = "https://catalog.trebi.ai/v1/index.json"
    static let binURL = "https://catalog.trebi.ai/v1/bin/plane/0.2.2/plane-cli_darwin_arm64.tar.gz"
    static let releases = "https://api.github.com/repos/Big-Time-Data/big-timer-releases/releases?per_page=30"
    static let btBase = "https://github.com/Big-Time-Data/big-timer-releases/releases/download/cli-v1.0.12/"

    override func setUpWithError() throws {
        http = FakeHTTP()
        commands = FakeCommands()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vendors-\(UUID().uuidString)")
        try sign(index())
        http.routes[Self.binURL] = (200, archive)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    var installer: VendorInstaller {
        let probed = probed
        return VendorInstaller(http: http, commands: commands, probe: { _, _ in VendorVersion(probed) }, root: root, arch: "arm64",
                               keys: [key.publicKey.rawRepresentation.base64EncodedString()], userAgent: "OverSire/test")
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

    func binary(_ version: String, platform: String = "darwin/arm64", digest: String? = nil) -> [String: Any] {
        ["platform": platform, "url": "https://catalog.trebi.ai/v1/bin/plane/\(version)/plane-cli_\(platform.replacingOccurrences(of: "/", with: "_")).tar.gz",
         "digest": "sha256:" + (digest ?? Self.sha(archive))]
    }

    func index(_ versions: [[String: Any]]? = nil) throws -> Data {
        let v = versions ?? [
            ["version": "0.2.1", "binaries": [binary("0.2.1")]],
            ["version": "0.2.2", "binaries": [binary("0.2.2"), binary("0.2.2", platform: "darwin/amd64")]],
        ]
        return try JSONSerialization.data(withJSONObject: ["generated_at": "2026-11-21T00:00:00Z",
                                                           "entries": [["name": "slack", "versions": []], ["name": "plane", "versions": v]]])
    }

    func sign(_ index: Data) throws {
        http.routes[Self.indexURL] = (200, index)
        http.routes[Self.indexURL + ".sig"] = (200, Data((try key.signature(for: index).base64EncodedString() + "\n").utf8))
    }

    func install(_ cli: VendorCLI? = nil, vendor: ProviderID = "plane") async throws -> String {
        let cli = cli ?? plane
        let i = installer
        return try await i.install(vendor, cli, try await i.offer(vendor, cli))
    }

    func names(_ vendor: String = "plane") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(vendor).path)) ?? []).sorted()
    }

    func assertThrows(_ want: VendorInstallError, _ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await body()
            XCTFail("no throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? VendorInstallError, want, file: file, line: line)
        }
    }

    // MARK: Trebi catalog

    func testCatalogInstallChecksSignatureAndDigest() async throws {
        let path = try await install()
        XCTAssertEqual(path, root.appendingPathComponent("plane/0.2.2/plane-cli").path)
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o755)
        XCTAssertEqual(names(), ["0.2.2"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("plane/0.2.2").path), ["plane-cli"],
                       "the archive goes after the unpack")
        XCTAssertEqual(http.urls, [Self.indexURL, Self.indexURL + ".sig", Self.binURL])
        XCTAssertEqual(Set(http.asked.map(\.cachePolicy)), [.reloadIgnoringLocalCacheData], "a cached index hides a new release")
        let tar = try XCTUnwrap(commands.calls.first)
        XCTAssertEqual(tar.exe, "/usr/bin/tar")
        XCTAssertEqual(tar.args.last, "plane-cli", "only the binary is unpacked")
    }

    func testRealCatalogSignatureVerifies() throws {
        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/vendors")
        let index = try Data(contentsOf: dir.appendingPathComponent("index.json"))
        let sig = try Data(contentsOf: dir.appendingPathComponent("index.json.sig"))
        XCTAssertTrue(VendorInstaller.verifyCatalog(index, signature: sig, keys: VendorInstaller.catalogKeys))
        XCTAssertTrue(VendorInstaller.verifyCatalog(index, signature: sig, keys: ["bm90IGEga2V5", key.publicKey.rawRepresentation.base64EncodedString()] + VendorInstaller.catalogKeys),
                      "any key of the list can verify")
        var changed = index
        changed[changed.count / 2] ^= 1
        XCTAssertFalse(VendorInstaller.verifyCatalog(changed, signature: sig, keys: VendorInstaller.catalogKeys))
    }

    func testCatalogBadSignatureInstallsNothing() async throws {
        http.routes[Self.indexURL + ".sig"] = (200, Data(try Curve25519.Signing.PrivateKey().signature(for: try index()).base64EncodedString().utf8))
        await assertThrows(.badSignature) { _ = try await self.install() }
        XCTAssertFalse(http.urls.contains(Self.binURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertEqual(VendorInstallError.badSignature.description, "The signature of the Trebi catalog is not valid. OverSire installs nothing.")
    }

    func testCatalogBadDigestInstallsNothing() async throws {
        http.routes[Self.binURL] = (200, Data("other bytes".utf8))
        await assertThrows(.badDigest(archive: "plane-cli_darwin_arm64.tar.gz")) { _ = try await self.install() }
        XCTAssertEqual(names(), [])
        XCTAssertTrue(commands.calls.isEmpty)
    }

    func testCatalogPicksNewestAtOrAboveMin() async throws {
        try sign(try index([
            ["version": "0.2.2", "binaries": [binary("0.2.2")]],
            ["version": "0.2.4", "yanked": true, "binaries": [binary("0.2.4")]],
            ["version": "0.2.3", "binaries": [binary("0.2.3", platform: "linux/arm64")]],
        ]))
        let offer = try await installer.offer("plane", plane)
        XCTAssertEqual(offer.version, VendorVersion("0.2.2"))
        XCTAssertEqual(offer.url.absoluteString, Self.binURL)
        XCTAssertEqual(offer.sha256, Self.sha(archive))
        XCTAssertEqual(offer.release, "trebi-catalog")
    }

    func testCatalogNewestBelowMinFails() async throws {
        try sign(try index([["version": "0.2.1", "binaries": [binary("0.2.1")]]]))
        let i = installer, cli = plane
        await assertThrows(.tooOld(binary: "plane-cli", newest: VendorVersion("0.2.1")!, min: VendorVersion("0.2.2")!)) {
            _ = try await i.offer("plane", cli)
        }
        XCTAssertEqual(VendorInstallError.tooOld(binary: "plane-cli", newest: VendorVersion("0.2.1")!, min: VendorVersion("0.2.2")!).description,
                       "The newest plane-cli is 0.2.1. OverSire needs 0.2.2 or newer.")
        try sign(try index([["version": "0.2.2", "binaries": [binary("0.2.2", platform: "linux/arm64")]]]))
        await assertThrows(.noRelease(source: "The Trebi catalog", binary: "plane-cli", platform: "darwin/arm64")) { _ = try await i.offer("plane", cli) }
    }

    // MARK: GitHub releases

    func release(_ tag: String, prerelease: Bool = false, assets: [String]) -> [String: Any] {
        ["tag_name": tag, "draft": false, "prerelease": prerelease,
         "assets": assets.map { ["name": $0, "browser_download_url": "https://github.com/Big-Time-Data/big-timer-releases/releases/download/\(tag)/\($0)"] }]
    }

    func githubRoutes(sum: String? = nil) throws {
        let name = "big-timer-cli_1.0.12_darwin_arm64.tar.gz"
        let list: [[String: Any]] = [
            release("cli-v1.0.13-rc1", prerelease: true, assets: ["big-timer-cli_1.0.13-rc1_darwin_arm64.tar.gz", "checksums.txt"]),
            release("v0.2.8", assets: ["BigTimer-0.2.8.dmg"]),
            release("cli-v1.0.12", assets: [name, "checksums.txt"]),
            release("cli-v1.0.11", assets: ["big-timer-cli_1.0.11_darwin_arm64.tar.gz", "checksums.txt"]),
        ]
        http.routes[Self.releases] = (200, try JSONSerialization.data(withJSONObject: list))
        http.routes[Self.btBase + "checksums.txt"] = (200, Data("\(String(repeating: "0", count: 64))  big-timer-cli_1.0.12_linux_amd64.tar.gz\n\(sum ?? Self.sha(archive))  \(name)\n".utf8))
        http.routes[Self.btBase + name] = (200, archive)
    }

    func testGitHubPicksNewestCLITag() async throws {
        try githubRoutes()
        probed = "1.0.12"
        let offer = try await installer.offer("bigtimer", bigTimer)
        XCTAssertEqual(offer.version, VendorVersion("1.0.12"))
        XCTAssertEqual(offer.archive, "big-timer-cli_1.0.12_darwin_arm64.tar.gz")
        XCTAssertEqual(offer.release, "github-release")
        let list = try XCTUnwrap(http.asked.first)
        XCTAssertEqual(list.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(list.value(forHTTPHeaderField: "User-Agent"), "OverSire/test")
        let path = try await installer.install("bigtimer", bigTimer, offer)
        XCTAssertEqual(path, root.appendingPathComponent("bigtimer/1.0.12/big-timer-cli").path)
    }

    func testGitHubBadChecksumInstallsNothing() async throws {
        try githubRoutes(sum: String(repeating: "a", count: 64))
        probed = "1.0.12"
        await assertThrows(.badDigest(archive: "big-timer-cli_1.0.12_darwin_arm64.tar.gz")) {
            _ = try await self.install(self.bigTimer, vendor: "bigtimer")
        }
        XCTAssertEqual(names("bigtimer"), [])
    }

    func testGitHubRateLimitText() async throws {
        http.routes[Self.releases] = (403, Data(#"{"message":"API rate limit exceeded"}"#.utf8))
        let i = installer, cli = bigTimer
        await assertThrows(.rateLimited) { _ = try await i.offer("bigtimer", cli) }
        XCTAssertEqual(VendorInstallError.rateLimited.description, "GitHub allows 60 calls in one hour without a login. Try again later.")
    }

    // MARK: Folders

    func testStagedVersionMustMatch() async throws {
        probed = "0.2.1"
        await assertThrows(.wrongVersion(binary: "plane-cli", got: VendorVersion("0.2.1"), want: VendorVersion("0.2.2")!)) {
            _ = try await self.install()
        }
        XCTAssertEqual(names(), [], "no staging folder stays")
        XCTAssertEqual(VendorInstallError.wrongVersion(binary: "plane-cli", got: VendorVersion("0.2.1"), want: VendorVersion("0.2.2")!).description,
                       "The archive holds plane-cli 0.2.1, not 0.2.2. OverSire installs nothing.")
    }

    func testInstallReplacesOldVersionFolder() async throws {
        let old = root.appendingPathComponent("plane/0.2.1")
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: old.appendingPathComponent("plane-cli"))
        _ = try await install()
        XCTAssertEqual(names(), ["0.2.2"])
        _ = try await install()
        XCTAssertEqual(names(), ["0.2.2"], "a second install of the same version leaves one folder")
    }

    func testQuarantineIsRemoved() async throws {
        commands.quarantine = true
        let path = try await install()
        XCTAssertTrue(commands.quarantined, "the fake tar set the attribute")
        XCTAssertEqual(getxattr(path, "com.apple.quarantine", nil, 0, 0, XATTR_NOFOLLOW), -1)
    }

    func testStaleStagingRemovedAndIgnored() async throws {
        let stale = root.appendingPathComponent("plane/.staging-x")
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: stale.appendingPathComponent("plane-cli"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stale.appendingPathComponent("plane-cli").path)
        XCTAssertNil(installer.ownCopy("plane", binary: "plane-cli"))
        _ = try await install()
        XCTAssertEqual(names(), ["0.2.2"])
    }

    func testOwnCopyPicksHighestVersion() throws {
        for v in ["0.2.1", "0.10.0", "0.2.2", "notes"] {
            let dir = root.appendingPathComponent("plane/\(v)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("#!/bin/sh\n".utf8).write(to: dir.appendingPathComponent("plane-cli"))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.appendingPathComponent("plane-cli").path)
        }
        XCTAssertEqual(installer.ownCopy("plane", binary: "plane-cli"), root.appendingPathComponent("plane/0.10.0/plane-cli").path)
        XCTAssertNil(installer.ownCopy("bigtimer", binary: "big-timer-cli"))
    }

    func testRemoveDeletesOnlyOwnFolder() async throws {
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("path-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: other) }
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: other.appendingPathComponent("plane-cli"))
        _ = try await install()
        XCTAssertEqual(try installer.remove("plane"), [VendorVersion("0.2.2")!])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("plane").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.appendingPathComponent("plane-cli").path))
        XCTAssertEqual(try installer.remove("plane"), [])
    }

    func testHomebrewHasNoInstall() async {
        let gh = VendorCLI(binary: "gh", release: .homebrew(formula: "gh"))
        let i = installer
        await assertThrows(.noInstall(formula: "gh")) { _ = try await i.offer("github", gh) }
        XCTAssertTrue(http.asked.isEmpty)
    }
}
