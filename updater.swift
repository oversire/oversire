import Cocoa
import Security

// Installs signed, notarized releases from GitHub and restarts the app.
// Dev builds (version ends in "-dev") only report a newer release.
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate
        case available(String)    // newer release, auto-install is off or this is a dev build
        case downloading(String)
        case ready(String)        // verified and staged, installs when the popover is closed
        case failed(String)
    }

    static let changed = Notification.Name("UpdaterChanged")
    static let repo = "oversire/oversire"
    static let bundleID = "com.oversire.app"
    static let requirement = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"Q56WK6TB88\""
    static let checkInterval: TimeInterval = 4 * 3600

    let current: String
    let appURL: URL
    private(set) var state: State = .idle { didSet { NotificationCenter.default.post(name: Updater.changed, object: self) } }
    private(set) var lastCheck: Date?
    /// False while the user looks at the app. The install waits until it is true.
    var canRestart: () -> Bool = { true }
    private var staged: URL?
    private var timer: Timer?

    init(bundle: Bundle = .main) {
        current = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        appURL = bundle.bundleURL
    }

    var isDev: Bool { current.hasSuffix("-dev") }
    var busy: Bool { state == .checking || { if case .downloading = state { return true }; return false }() }

    var statusText: String {
        switch state {
        case .idle: return isDev ? "Dev build. Auto-update is off." : ""
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let v): return "v\(v) is available"
        case .downloading(let v): return "Downloading v\(v)…"
        case .ready(let v): return "v\(v) installs when this window closes"
        case .failed(let e): return "Update failed: \(e)"
        }
    }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.check(manual: false) }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 60
    }

    // Checks on the 4-hour cadence and installs a staged release once the user is not looking.
    private func tick() {
        if case .ready = state { installIfIdle(); return }
        if Date().timeIntervalSince(lastCheck ?? .distantPast) >= Updater.checkInterval { check(manual: false) }
    }

    func check(manual: Bool) {
        guard !busy, AUTO_UPDATE || manual else { return }
        if case .ready = state { return }
        state = .checking
        lastCheck = Date()
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("OverSire/\(current)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let rel = data.flatMap { try? JSONDecoder().decode(Release.self, from: $0) }
            DispatchQueue.main.async {
                guard let rel = rel else {
                    let code = (resp as? HTTPURLResponse)?.statusCode
                    self.fail(err?.localizedDescription ?? "GitHub returned \(code.map(String.init) ?? "no data")")
                    return
                }
                let latest = rel.version
                guard Updater.isNewer(latest, than: self.current) else { self.state = .upToDate; return }
                guard !self.isDev, let asset = rel.assets.first(where: { $0.name == "OverSire.zip" }) else {
                    self.state = .available(latest); return
                }
                self.download(asset.browserDownloadURL, version: latest)
            }
        }.resume()
    }

    private func download(_ url: URL, version: String) {
        state = .downloading(version)
        log.info("Updater: downloading v\(version)")
        URLSession.shared.downloadTask(with: url) { tmp, _, err in
            guard let tmp = tmp else {
                DispatchQueue.main.async { self.fail(err?.localizedDescription ?? "download failed") }
                return
            }
            // The temp file is deleted when this closure returns, so unpack it now.
            let result = Result { try self.stage(zip: tmp, version: version) }
            DispatchQueue.main.async {
                switch result {
                case .success(let app):
                    self.staged = app
                    self.state = .ready(version)
                    log.info("Updater: v\(version) verified and staged")
                    self.installIfIdle()
                case .failure(let e):
                    self.fail("\(e)")
                }
            }
        }.resume()
    }

    // Unpacks the zip next to the app (same volume, so the swap is a rename) and verifies it.
    private func stage(zip: URL, version: String) throws -> URL {
        let fm = FileManager.default
        let dir = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        let out = try Updater.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        guard out.ok else { throw UpdateError("unzip failed: \(out.text)") }
        let app = dir.appendingPathComponent("OverSire.app")
        guard fm.fileExists(atPath: app.path) else { throw UpdateError("OverSire.app is missing from the zip") }
        try Updater.verify(app, version: version)
        return app
    }

    // The signature check is the trust boundary: only a bundle signed by our team installs.
    static func verify(_ app: URL, version: String) throws {
        var code: SecStaticCode?
        var req: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code = code,
              SecRequirementCreateWithString(requirement as CFString, [], &req) == errSecSuccess else {
            throw UpdateError("cannot read the code signature")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, req)
        guard status == errSecSuccess else { throw UpdateError("signature is not valid (\(status))") }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard info?["CFBundleShortVersionString"] as? String == version else {
            throw UpdateError("bundle version does not match v\(version)")
        }
        let notarized = try run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard notarized.ok else { throw UpdateError("not notarized: \(notarized.text)") }
    }

    func installIfIdle() {
        guard case .ready = state, canRestart() else { return }
        install()
    }

    // A detached script waits for this process to exit, swaps the bundles, and opens the new app.
    // If the new app is not running after 15 seconds, the script puts the old app back.
    func install() {
        guard case .ready(let version) = state, let staged = staged else { return }
        let parent = appURL.deletingLastPathComponent().path
        guard !appURL.path.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: parent) else {
            fail("cannot write to \(parent)"); return
        }
        let script = """
        pid=$1; app=$2; new=$3; backup="$2.previous"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        rm -rf "$backup"
        mv "$app" "$backup" || { open "$app"; exit 1; }
        if ! mv "$new" "$app"; then mv "$backup" "$app"; open "$app"; exit 1; fi
        open "$app"
        sleep 15
        if pgrep -f "$app/Contents/MacOS/oversire" >/dev/null; then rm -rf "$backup" "$(dirname "$new")"
        else rm -rf "$app"; mv "$backup" "$app"; open "$app"; fi
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "sh", "\(getpid())", appURL.path, staged.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { fail("cannot start the installer: \(error.localizedDescription)"); return }
        UserDefaults.standard.set(version, forKey: "updatedTo")
        log.info("Updater: installing v\(version) and restarting")
        NSApp.terminate(nil)
    }

    /// The version this launch updated to, once. Nil on a normal launch.
    func takeUpdateNotice() -> String? {
        guard let v = UserDefaults.standard.string(forKey: "updatedTo") else { return nil }
        UserDefaults.standard.removeObject(forKey: "updatedTo")
        return v == current ? v : nil
    }

    private func fail(_ msg: String) {
        log.error("Updater: \(msg)")
        state = .failed(msg)
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let parts = { (s: String) in s.split(separator: "-")[0].split(separator: ".").map { Int($0) ?? 0 } }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    static func run(_ path: String, _ args: [String]) throws -> (ok: Bool, text: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus == 0, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
        enum CodingKeys: String, CodingKey { case tagName = "tag_name", assets }
    }

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: URL
        enum CodingKeys: String, CodingKey { case name, browserDownloadURL = "browser_download_url" }
    }

    struct UpdateError: Error, CustomStringConvertible {
        let description: String
        init(_ d: String) { description = d }
    }
}
