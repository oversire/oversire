import Cocoa
import GitHubKit
import OverSireCore

// ─── Project icons ───────────────────────────────────────────────────────────
// The icon of each project comes from the source that ProjectLocalSettings.icon names.
// Remote images are PNG files in the cache. A sync gets each source at most once a day.

let PROJECT_ICONS = ProjectIconStore(
    github: GITHUB, http: URLSessionTransport(),
    cacheDir: URL(fileURLWithPath: CONFIG_DIR).appendingPathComponent("cache/icons"),
    uploadDir: URL(fileURLWithPath: CONFIG_DIR).appendingPathComponent("icons"))

/// One place that an icon can come from.
enum IconSource: Hashable {
    case upload(String)              // project key
    case emoji(String)
    case image(String)               // URL from the tracker
    case repo(String)                // "owner/repo": a logo file in the repo
    case org(String)                 // the avatar of an org or a user
    case letter

    /// The name of the cached PNG. Only remote sources have one.
    var cacheKey: String? {
        switch self {
        case .image(let u): return "image-" + String(u.fnv1a, radix: 16)
        case .repo(let r): return "repo-" + r.replacingOccurrences(of: "/", with: "~")
        case .org(let o): return "org-" + o
        default: return nil
        }
    }
}

final class ProjectIconStore {
    static let changed = Notification.Name("ProjectIconsChanged")
    static let repoFiles = ["logo.svg", "logo.png", ".github/logo.png", "AppIcon.svg"]
    static let side: CGFloat = 128
    static let maxAge: TimeInterval = 86_400

    private let github: GitHubClient
    private let http: any HTTPTransport
    let cacheDir: URL
    let uploadDir: URL
    var settings: (String) -> ProjectLocalSettings = { PROJECTS_CFG.local($0) }
    var now: () -> Date = Date.init
    var autoSync = !CommandLine.arguments.contains("--uishots")   // uishots read only
    private(set) var projects: [String: ProjectSummary] = [:]   // by uppercase identifier
    private var tiles: [String: NSImage] = [:]
    private var tried: [String: Date] = [:]                      // cache key → last fetch
    private var syncing = Set<String>()

    init(github: GitHubClient, http: any HTTPTransport, cacheDir: URL, uploadDir: URL) {
        self.github = github
        self.http = http
        self.cacheDir = cacheDir
        self.uploadDir = uploadDir
        if let d = try? Data(contentsOf: indexURL), let t = try? JSONDecoder().decode([String: Date].self, from: d) { tried = t }
    }

    private var indexURL: URL { cacheDir.appendingPathComponent("index.json") }

    func uploadURL(_ key: String) -> URL { uploadDir.appendingPathComponent(key.uppercased() + ".png") }
    func cacheURL(_ cacheKey: String) -> URL { cacheDir.appendingPathComponent(cacheKey + ".png") }

    /// Sets the known projects. Then syncs the sources that are due.
    func track(_ list: [ProjectSummary]) {
        let new = Dictionary(list.map { ($0.identifier.uppercased(), $0) }, uniquingKeysWith: { a, _ in a })
        if new.mapValues(\.logo) != projects.mapValues(\.logo) { tiles = [:] }
        projects = new
        if autoSync { Task { @MainActor in await syncAll() } }
    }

    // MARK: Sources

    /// The choices that the settings page can show for a project.
    func candidates(for key: String) -> [IconChoice] {
        let l = settings(key)
        var out: [IconChoice] = [.auto, .upload]
        if projects[key.uppercased()]?.logo != nil { out.append(.tracker) }
        for g in l.github {
            if g.contains("/") { out.append(.repo(g)) }
            let owner = String(g.split(separator: "/").first ?? "")
            if !owner.isEmpty, !out.contains(.org(owner)) { out.append(.org(owner)) }
        }
        return out + [.letter]
    }

    /// The sources of a choice, best first. The letter is always last.
    func sources(for key: String) -> [IconSource] {
        let l = settings(key), k = key.uppercased()
        let tracker: [IconSource] = {
            guard let logo = projects[k]?.logo else { return [] }
            switch logo.kind {
            case .emoji: return [.emoji(logo.value)]
            case .image: return [.image(logo.value)]
            case .icon: return []   // icon names of the tracker have no glyph here; its color goes to the letter
            }
        }()
        let repos = l.github.filter { $0.contains("/") }
        let orgs = l.github.filter { !$0.contains("/") } + repos.compactMap { $0.split(separator: "/").first.map(String.init) }
        var out: [IconSource]
        switch l.icon {
        case .auto:
            out = (FileManager.default.fileExists(atPath: uploadURL(k).path) ? [.upload(k)] : [])
                + tracker + repos.prefix(1).map { .repo($0) } + orgs.map { .org($0) }
        case .upload: out = [.upload(k)]
        case .tracker: out = tracker
        case .repo(let r): out = [.repo(r)] + (r.split(separator: "/").first.map { [.org(String($0))] } ?? [])
        case .org(let o): out = [.org(o)]
        case .letter: out = []
        }
        var seen = Set<IconSource>()
        return out.filter { seen.insert($0).inserted } + [.letter]
    }

    /// The first source that has an image now.
    func source(for key: String) -> IconSource {
        sources(for: key).first { s in
            switch s {
            case .upload(let k): return FileManager.default.fileExists(atPath: uploadURL(k).path)
            case .emoji, .letter: return true
            case .image, .repo, .org: return s.cacheKey.map { FileManager.default.fileExists(atPath: cacheURL($0).path) } ?? false
            }
        } ?? .letter
    }

    // MARK: Images

    /// A square tile of the project icon. It does not wait for the network.
    func image(for key: String, size: CGFloat = 18) -> NSImage {
        let k = key.uppercased(), id = "\(k)@\(size)"
        if let t = tiles[id] { return t }
        let src = source(for: k)
        var picture: NSImage?
        switch src {
        case .upload(let u): picture = NSImage(contentsOf: uploadURL(u))
        case .image, .repo, .org: picture = src.cacheKey.flatMap { NSImage(contentsOf: cacheURL($0)) }
        default: break
        }
        let t = Self.tile(size: size, picture: picture, emoji: { if case .emoji(let e) = src { return e }; return nil }(),
                          letter: String(k.prefix(1)), color: letterColor(k))
        tiles[id] = t
        return t
    }

    private func letterColor(_ k: String) -> NSColor {
        let logo = projects[k]?.logo
        let hex = logo?.kind == .icon ? logo?.color : nil
        return (hex ?? settings(k).color).flatMap(Self.color(hex:)) ?? repoColor(k)
    }

    static func color(hex: String) -> NSColor? {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static func tile(size: CGFloat, picture: NSImage?, emoji: String?, letter: String, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let path = NSBezierPath(roundedRect: r, xRadius: size * 0.22, yRadius: size * 0.22)
            if let picture {
                path.addClip()
                let s = picture.size, f = min(r.width / max(s.width, 1), r.height / max(s.height, 1))
                let w = s.width * f, h = s.height * f
                picture.draw(in: NSRect(x: (r.width - w) / 2, y: (r.height - h) / 2, width: w, height: h))
                return true
            }
            let text: String, attrs: [NSAttributedString.Key: Any]
            if let emoji {
                text = emoji
                attrs = [.font: NSFont.systemFont(ofSize: size * 0.8)]
            } else {
                color.setFill()
                path.fill()
                text = letter
                attrs = [.font: NSFont.systemFont(ofSize: size * 0.56, weight: .bold), .foregroundColor: NSColor.white]
            }
            let ts = (text as NSString).size(withAttributes: attrs)
            (text as NSString).draw(at: NSPoint(x: (r.width - ts.width) / 2, y: (r.height - ts.height) / 2), withAttributes: attrs)
            return true
        }
    }

    /// Scales an image into a square PNG of `side` pixels.
    static func png(_ image: NSImage) -> Data? {
        guard image.size.width > 0, image.size.height > 0,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: side, height: side)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = image.size, f = min(side / s.width, side / s.height)
        image.draw(in: NSRect(x: (side - s.width * f) / 2, y: (side - s.height * f) / 2, width: s.width * f, height: s.height * f))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: Upload

    func setUpload(key: String, image: NSImage) throws {
        guard let data = Self.png(image) else { throw ProviderError.transport("This image cannot be read") }
        try FileManager.default.createDirectory(at: uploadDir, withIntermediateDirectories: true)
        try data.write(to: uploadURL(key), options: .atomic)
        changed()
    }

    func clearUpload(key: String) {
        try? FileManager.default.removeItem(at: uploadURL(key))
        changed()
    }

    private func changed() {
        tiles = [:]
        NotificationCenter.default.post(name: Self.changed, object: self)
    }

    // MARK: Sync

    /// Gets the remote sources of a project, best first, until one has an image.
    @MainActor func sync(_ key: String, force: Bool = false) async {
        let k = key.uppercased()
        guard syncing.insert(k).inserted else { return }
        defer { syncing.remove(k) }
        var got = false
        for s in sources(for: k) {
            guard let ck = s.cacheKey else {
                if case .upload = s { break }
                if case .emoji = s { break }
                continue
            }
            let file = cacheURL(ck)
            let have = FileManager.default.fileExists(atPath: file.path)
            if !force, let t = tried[ck], now().timeIntervalSince(t) < Self.maxAge {
                if have { break } else { continue }
            }
            tried[ck] = now()
            if let data = await fetch(s) {
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
                try? data.write(to: file, options: .atomic)
                got = true
                break
            }
            if have { break }
        }
        saveIndex()
        if got { changed() }
    }

    @MainActor func syncAll(force: Bool = false) async {
        for k in projects.keys.sorted() { await sync(k, force: force) }
        cleanup()
    }

    /// Removes cached files that no project uses.
    func cleanup() {
        let used = Set(projects.keys.flatMap { k in sources(for: k).compactMap(\.cacheKey) })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path)) ?? []
        for f in files where f.hasSuffix(".png") && !used.contains(String(f.dropLast(4))) {
            try? FileManager.default.removeItem(at: cacheDir.appendingPathComponent(f))
        }
        tried = tried.filter { used.contains($0.key) }
        saveIndex()
    }

    private func saveIndex() {
        guard let d = try? JSONEncoder().encode(tried) else { return }
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? d.write(to: indexURL, options: .atomic)
    }

    private func fetch(_ s: IconSource) async -> Data? {
        switch s {
        case .image(let u): return await download(u)
        case .org(let o):
            guard let o = try? await github.json("GET", "users/\(o)") as? [String: Any],
                  let url = o["avatar_url"] as? String else { return nil }
            return await download(url + (url.contains("?") ? "&" : "?") + "s=\(Int(Self.side))")
        case .repo(let r):
            for path in Self.repoFiles {
                guard let o = try? await github.json("GET", "repos/\(r)/contents/\(path)") as? [String: Any],
                      let b64 = o["content"] as? String,
                      let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters),
                      let img = NSImage(data: raw), let png = Self.png(img) else { continue }
                return png
            }
            return nil
        default: return nil
        }
    }

    private func download(_ url: String) async -> Data? {
        guard let u = URL(string: url), u.scheme == "https",
              let (data, resp) = try? await http.send(URLRequest(url: u, timeoutInterval: 30)),
              (200..<300).contains(resp.statusCode), let img = NSImage(data: data) else { return nil }
        return Self.png(img)
    }
}

// ─── Project resolver ────────────────────────────────────────────────────────

/// Finds the project of a repo from the GitHub links of each project. A repo link wins over an org link.
struct ProjectResolver {
    let links: [String: [String]]   // project key → "org" or "owner/repo"

    init(links: [String: [String]]) { self.links = links }

    init(_ cfg: ProjectsConfig) { self.init(links: cfg.settings.mapValues(\.github)) }

    func project(forRepo repo: String) -> String? {
        let r = repo.lowercased()
        let owner = String(r.split(separator: "/").first ?? "")
        let keys = links.keys.sorted()
        return keys.first { links[$0]!.contains { $0.lowercased() == r } }
            ?? keys.first { links[$0]!.contains { !$0.contains("/") && $0.lowercased() == owner } }
    }
}
