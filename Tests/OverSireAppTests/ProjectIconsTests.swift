import AppKit
import GitHubKit
import OverSireCore
import OverSireTestKit
import XCTest
@testable import OverSireApp

private final class StubHTTP: HTTPTransport, @unchecked Sendable {
    var bodies: [String: Data] = [:]
    var calls: [String] = []

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        calls.append(url.absoluteString)
        guard let d = bodies[url.absoluteString] else { throw ProviderError.notFound }
        return (d, HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }
}

@MainActor
final class ProjectIconsTests: XCTestCase {
    private var dir: URL!
    private var gh: ReplayGH!
    private var http: StubHTTP!
    private var local: [String: ProjectLocalSettings] = [:]
    private let notFound = answer("404 Not Found", #"{"message":"Not Found"}"#)

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("oversire-icons-\(UUID().uuidString)")
        gh = ReplayGH()
        http = StubHTTP()
        local = [:]
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func make(logo: ProjectLogo? = nil) -> ProjectIconStore {
        let s = ProjectIconStore(github: GitHubClient(commands: gh, http: NoHTTP(), gh: "/bin/sh"), http: http,
                                 cacheDir: dir.appendingPathComponent("cache"), uploadDir: dir.appendingPathComponent("icons"))
        s.autoSync = false
        s.settings = { [unowned self] in self.local[$0.uppercased()] ?? ProjectLocalSettings() }
        let ref = ProjectRef(account: AccountID(provider: ProviderID(rawValue: "plane"), id: "ocral"), id: "p1", key: "ACME")
        s.track([ProjectSummary(ref: ref, identifier: "ACME", title: "Acme", url: "https://plane/ACME", closed: false, logo: logo)])
        return s
    }

    private func link(_ github: [String], icon: IconChoice = .auto) {
        var l = ProjectLocalSettings()
        l.github = github
        l.icon = icon
        local["ACME"] = l
    }

    private func pngData(_ color: NSColor = .systemTeal) -> Data {
        let img = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { r in color.setFill(); r.fill(); return true }
        return ProjectIconStore.png(img)!
    }

    private func repoFiles(_ r: String, found: String? = nil) {
        for p in ProjectIconStore.repoFiles {
            if p == found {
                gh.on("GET", "repos/\(r)/contents/\(p)", answer("200 OK", #"{"content":"\#(pngData().base64EncodedString())"}"#))
            } else {
                gh.on("GET", "repos/\(r)/contents/\(p)", notFound)
            }
        }
    }

    private func avatar(_ o: String) {
        gh.on("GET", "users/\(o)", answer("200 OK", #"{"avatar_url":"https://avatars.example/u/1?v=4"}"#))
        http.bodies["https://avatars.example/u/1?v=4&s=128"] = pngData(.systemOrange)
    }

    func testAutoOrderWithoutCache() {
        link(["acme/app", "tools"])
        let s = make()
        XCTAssertEqual(s.sources(for: "acme"), [.repo("acme/app"), .org("tools"), .org("acme"), .letter])
        XCTAssertEqual(s.source(for: "ACME"), .letter)
    }

    func testTrackerLogoComesFirst() {
        link(["acme/app"])
        XCTAssertEqual(make(logo: ProjectLogo(kind: .emoji, value: "🦊")).source(for: "ACME"), .emoji("🦊"))
        XCTAssertEqual(make(logo: ProjectLogo(kind: .icon, value: "home", color: "#ff0000")).sources(for: "ACME").first, .repo("acme/app"))
    }

    func testRepoLogoFile() async {
        link(["acme/app"])
        repoFiles("acme/app", found: "logo.png")
        let s = make()
        await s.sync("ACME")
        XCTAssertEqual(s.source(for: "ACME"), .repo("acme/app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.cacheURL("repo-acme~app").path))
    }

    func testRepoWithoutLogoTakesOwnerAvatar() async {
        link(["acme/app"])
        repoFiles("acme/app")
        avatar("acme")
        let s = make()
        await s.sync("ACME")
        XCTAssertEqual(s.source(for: "ACME"), .org("acme"))
        XCTAssertEqual(http.calls, ["https://avatars.example/u/1?v=4&s=128"])
    }

    func testCacheHitWithinADay() async {
        link(["acme"])
        avatar("acme")
        let s = make()
        await s.sync("ACME")
        let n = gh.calls.count
        await s.sync("ACME")
        XCTAssertEqual(gh.calls.count, n)
        s.now = { Date().addingTimeInterval(ProjectIconStore.maxAge + 1) }
        await s.sync("ACME")
        XCTAssertEqual(gh.calls.count, n + 1)
        await s.sync("ACME", force: true)
        XCTAssertEqual(gh.calls.count, n + 2)
    }

    func testUploadWins() throws {
        link(["acme"])
        let s = make(logo: ProjectLogo(kind: .emoji, value: "🦊"))
        try s.setUpload(key: "acme", image: NSImage(data: pngData())!)
        XCTAssertEqual(s.source(for: "ACME"), .upload("ACME"))
        s.clearUpload(key: "ACME")
        XCTAssertEqual(s.source(for: "ACME"), .emoji("🦊"))
    }

    func testFixedChoice() {
        link(["acme/app"], icon: .letter)
        XCTAssertEqual(make(logo: ProjectLogo(kind: .emoji, value: "🦊")).sources(for: "ACME"), [.letter])
        link(["acme/app"], icon: .org("tools"))
        XCTAssertEqual(make().sources(for: "ACME"), [.org("tools"), .letter])
    }

    func testCacheKeys() {
        XCTAssertEqual(IconSource.repo("o/r").cacheKey, "repo-o~r")
        XCTAssertEqual(IconSource.org("o").cacheKey, "org-o")
        XCTAssertEqual(IconSource.image("https://x/a.png").cacheKey, IconSource.image("https://x/a.png").cacheKey)
        XCTAssertNotEqual(IconSource.image("https://x/a.png").cacheKey, IconSource.image("https://x/b.png").cacheKey)
        XCTAssertNil(IconSource.letter.cacheKey)
    }

    func testCleanupRemovesUnusedFiles() throws {
        link(["acme"])
        let s = make()
        try FileManager.default.createDirectory(at: s.cacheDir, withIntermediateDirectories: true)
        try pngData().write(to: s.cacheURL("org-acme"))
        try pngData().write(to: s.cacheURL("org-gone"))
        s.cleanup()
        XCTAssertTrue(FileManager.default.fileExists(atPath: s.cacheURL("org-acme").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: s.cacheURL("org-gone").path))
    }

    func testCandidates() {
        link(["acme/app", "tools"])
        XCTAssertEqual(make(logo: ProjectLogo(kind: .emoji, value: "🦊")).candidates(for: "ACME"),
                       [.auto, .upload, .tracker, .repo("acme/app"), .org("acme"), .org("tools"), .letter])
    }

    func testTileSize() {
        XCTAssertEqual(make().image(for: "ACME", size: 18).size, NSSize(width: 18, height: 18))
    }

    func testResolverRepoWinsOverOrg() {
        let r = ProjectResolver(links: ["AAA": ["acme"], "ZZZ": ["acme/app"]])
        XCTAssertEqual(r.project(forRepo: "acme/app"), "ZZZ")
        XCTAssertEqual(r.project(forRepo: "Acme/Other"), "AAA")
        XCTAssertNil(r.project(forRepo: "else/app"))
    }
}
