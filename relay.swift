import Cocoa
import Network
import Security

// ─── Relay configuration ─────────────────────────────────────────────────────
// Optional push path: GitHub webhooks → Cloudflare Worker "oversire-relay" → this Mac.

struct RelayConfig: Codable {
    var enabled = false
    var workerURL = ""
    var deviceID = ""            // 16 uppercase hex chars, made once for each Mac
    var accountID = ""
    var reconcileInterval: TimeInterval?
    var oldOrgHooks: [String: Int]?   // GitHub org hooks of relay v2, org → hook id, still to delete
}

var RELAY = RelayConfig()
let RELAY_DIR = (CONFIG_DIR as NSString).appendingPathComponent("relay")
let RELAY_BUNDLED_VERSION = 3    // keep equal to RELAY_VERSION in worker/wrangler.jsonc
let RELAY_WORKER_NAME = "oversire-relay"
let RELAY_EVENTS = ["workflow_run", "workflow_job", "pull_request", "pull_request_review"]
let FREE_ROWS_PER_DAY = 100_000

func randomHex(_ bytes: Int) -> String {
    var b = [UInt8](repeating: 0, count: bytes)
    _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
    return b.map { String(format: "%02x", $0) }.joined()
}

private let secretPattern = try! NSRegularExpression(pattern: "\\b[0-9a-fA-F]{64}\\b")
private let ansiPattern = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

// Hides device tokens and the webhook secret (32 random bytes as hex) in log text.
func maskSecrets(_ s: String) -> String {
    secretPattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "••••")
}

func stripANSI(_ s: String) -> String {
    ansiPattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
}

// Free plan: 100k rows written per day. Projects today's count to a full UTC day.
struct WriteQuota {
    let rowsToday: Int
    let now: Date

    var projected: Int {
        let secs = now.timeIntervalSince1970.truncatingRemainder(dividingBy: 86400)
        let frac = max(secs / 86400, 1.0 / 24)   // no wild projections in the first hour
        return Int(Double(rowsToday) / frac)
    }
    var fraction: Double { Double(projected) / Double(FREE_ROWS_PER_DAY) }
    var warn: Bool { fraction >= 0.7 }
}

// ─── Toolchain: node, npm, brew, wrangler ────────────────────────────────────

struct CommandResult {
    let status: Int32
    let output: String
    var ok: Bool { status == 0 }
}

final class Toolchain {
    let dir: String
    private(set) var node: String?

    init(dir: String = RELAY_DIR) { self.dir = dir }

    var brew: String? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }
    var npm: String? { node.map { (($0 as NSString).deletingLastPathComponent as NSString).appendingPathComponent("npm") } }
    var wranglerJS: String { (dir as NSString).appendingPathComponent("node_modules/wrangler/bin/wrangler.js") }
    var hasWrangler: Bool { FileManager.default.fileExists(atPath: wranglerJS) }

    // Fixed paths and version managers first, then the user's login shell.
    @discardableResult
    func findNode() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory() as NSString
        var fixed = ["/opt/homebrew/bin/node", "/usr/local/bin/node",
                     home.appendingPathComponent(".volta/bin/node"), home.appendingPathComponent(".asdf/shims/node")]
        let nvm = home.appendingPathComponent(".nvm/versions/node")
        let versions = ((try? fm.contentsOfDirectory(atPath: nvm)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        fixed += versions.map { "\(nvm)/\($0)/bin/node" }
        if let p = fixed.first(where: { fm.isExecutableFile(atPath: $0) }) { node = p; return p }
        let shell = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_shell) } ?? "/bin/zsh"
        let res = run(shell, ["-lic", "command -v node"], cwd: nil)
        node = res.output.split(separator: "\n").map(String.init).last { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }
        return node
    }

    // Returns the version (e.g. "22.19.0") if it is at least 20.
    func nodeVersion() -> (version: String, ok: Bool)? {
        guard let node = node ?? findNode() else { return nil }
        let res = run(node, ["--version"], cwd: nil)
        guard res.ok else { return nil }
        let v = res.output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "")
        let major = Int(v.split(separator: ".").first ?? "") ?? 0
        return (v, major >= 20)
    }

    func wranglerVersion() -> String? {
        guard hasWrangler, let node = node ?? findNode() else { return nil }
        let res = run(node, [wranglerJS, "--version"], cwd: dir)
        guard res.ok else { return nil }
        return res.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .last { $0.first?.isNumber == true }
    }

    // Copies the Worker source from the app bundle into the working folder.
    func syncBundle() -> Bool {
        guard let res = Bundle.main.resourcePath else { return false }
        let src = (res as NSString).appendingPathComponent("worker")
        let fm = FileManager.default
        guard fm.fileExists(atPath: src) else { return false }
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for item in ["src", "wrangler.jsonc", "package.json"] {
            let to = (dir as NSString).appendingPathComponent(item)
            try? fm.removeItem(atPath: to)
            do { try fm.copyItem(atPath: (src as NSString).appendingPathComponent(item), toPath: to) } catch { return false }
        }
        return true
    }

    func installNode(onLine: @escaping (String) -> Void) -> CommandResult {
        guard let brew = brew else { return CommandResult(status: 1, output: "Homebrew not found") }
        let res = run(brew, ["install", "node"], cwd: nil, onLine: onLine)
        findNode()
        return res
    }

    func installWrangler(update: Bool = false, onLine: @escaping (String) -> Void) -> CommandResult {
        guard syncBundle() else { return CommandResult(status: 1, output: "Relay files are missing from the app bundle") }
        guard let npm = npm ?? (findNode() != nil ? self.npm : nil) else { return CommandResult(status: 1, output: "npm not found") }
        let args = update ? ["install", "--omit=dev", "wrangler@4"] : ["install", "--omit=dev"]
        return run(npm, args, cwd: dir, onLine: onLine)
    }

    func wrangler(_ args: [String], stdin: String? = nil, onLine: ((String) -> Void)? = nil) -> CommandResult {
        guard let node = node ?? findNode(), hasWrangler else { return CommandResult(status: 127, output: "wrangler is not installed") }
        return run(node, [wranglerJS] + args, cwd: dir, stdin: stdin, onLine: onLine)
    }

    // Allowlisted env. node must be on PATH for npm scripts and wrangler.
    var env: [String: String] {
        let pe = ProcessInfo.processInfo.environment
        var e: [String: String] = [:]
        for k in ["HOME", "LANG", "USER", "TMPDIR", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY"] { if let v = pe[k] { e[k] = v } }
        if e["HOME"] == nil { e["HOME"] = NSHomeDirectory() }
        let nodeDir = node.map { ($0 as NSString).deletingLastPathComponent }
        e["PATH"] = ([nodeDir].compactMap { $0 } + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        e["NO_COLOR"] = "1"
        e["WRANGLER_SEND_METRICS"] = "false"
        if !RELAY.accountID.isEmpty { e["CLOUDFLARE_ACCOUNT_ID"] = RELAY.accountID }
        return e
    }

    // Runs a command and streams its output line by line. Blocks: call it off the main thread.
    func run(_ exe: String, _ args: [String], cwd: String?, stdin: String? = nil,
             onLine: ((String) -> Void)? = nil) -> CommandResult {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = args
        proc.environment = env
        if let cwd = cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = out
        let inPipe = Pipe()
        proc.standardInput = stdin == nil ? FileHandle.nullDevice : inPipe

        let lock = NSLock()
        var all = Data()
        var partial = ""
        func emit(_ chunk: String, flush: Bool) {
            partial += chunk
            var lines = partial.components(separatedBy: CharacterSet.newlines)
            partial = flush ? "" : lines.removeLast()
            for l in lines where !l.trimmingCharacters(in: .whitespaces).isEmpty { onLine?(stripANSI(l)) }
        }
        let done = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; done.signal(); return }
            lock.lock(); all.append(d); emit(String(decoding: d, as: UTF8.self), flush: false); lock.unlock()
        }
        do { try proc.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return CommandResult(status: 127, output: error.localizedDescription)
        }
        if let s = stdin {
            inPipe.fileHandleForWriting.write(Data(s.utf8))
            try? inPipe.fileHandleForWriting.close()
        }
        proc.waitUntilExit()
        _ = done.wait(timeout: .now() + 5)
        lock.lock(); emit("", flush: true); let text = stripANSI(String(decoding: all, as: UTF8.self)); lock.unlock()
        return CommandResult(status: proc.terminationStatus, output: text)
    }
}

// ─── Keychain ────────────────────────────────────────────────────────────────

final class SecretStore {
    static let deviceToken = "DEVICE_TOKEN"
    static let webhookSecret = "WEBHOOK_SECRET"
    let service: String

    init(service: String = "com.oversire.app.relay") { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }

    func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func set(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(key) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(key)
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(q as CFDictionary, nil)
        }
    }

    func delete(_ key: String) {
        SecItemDelete(query(key) as CFDictionary)
    }
}

// ─── Relay HTTP API ──────────────────────────────────────────────────────────

struct RelayEvent: Decodable {
    let seq: Int
    let deliveryId: String
    let repo: String
    let kind: String
    let action: String?
    let runId: Int?
    let jobId: Int?
    let prNumber: Int?
    let org: String?          // "plane:<slug>" for Plane events
    let projectId: String?
    let itemId: String?

    private enum CodingKeys: String, CodingKey {
        case seq, deliveryId, repo, kind, action, runId, jobId, prNumber, org, projectId, itemId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seq = try c.decode(Int.self, forKey: .seq)
        deliveryId = try c.decode(String.self, forKey: .deliveryId)
        repo = try c.decode(String.self, forKey: .repo)
        kind = try c.decode(String.self, forKey: .kind)
        action = try c.decodeIfPresent(String.self, forKey: .action)
        runId = try c.decodeIfPresent(Int.self, forKey: .runId)
        jobId = try c.decodeIfPresent(Int.self, forKey: .jobId)
        prNumber = try c.decodeIfPresent(Int.self, forKey: .prNumber)
        org = try c.decodeIfPresent(String.self, forKey: .org)
        projectId = try c.decodeIfPresent(String.self, forKey: .projectId)
        itemId = try c.decodeIfPresent(String.self, forKey: .itemId)
    }
}

struct RelayEventsPage: Decodable {
    let events: [RelayEvent]
    let head: Int
    let next: Int
    let more: Bool
    let truncated: Bool
}

struct RelayDevice: Decodable {
    let id: String
    let name: String?
    let lastSeen: Double?
    let lag: Int
    let repos: [String]
    let orgs: [String]
    let connected: Bool

    private enum CodingKeys: String, CodingKey {
        case id, name, lastSeen, lag, repos, orgs, connected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        lastSeen = try c.decodeIfPresent(Double.self, forKey: .lastSeen)
        lag = try c.decode(Int.self, forKey: .lag)
        repos = try c.decodeIfPresent([String].self, forKey: .repos) ?? []
        orgs = try c.decodeIfPresent([String].self, forKey: .orgs) ?? []
        connected = try c.decode(Bool.self, forKey: .connected)
    }
}

struct RelayHook: Decodable {
    let repo: String
    let hookId: Int?
    let lastDelivery: Double?
}

struct RelayPlaneHook: Decodable {
    let workspace: String
    let hookId: String?
    let lastDelivery: Double?
}

// Relay v2 had GitHub org hooks for GitHub Projects.
struct RelayOldOrgHook: Decodable {
    let org: String
    let hookId: Int?
}

struct RelayHealth: Decodable {
    let version: String?
    let retentionHours: Int
    let head: Int
    let events: Int
    let oldestAt: Double?
    let lastWebhookAt: Double?
    let rowsWrittenToday: Int
    let devices: [RelayDevice]
    let hooks: [RelayHook]
    let planeHooks: [RelayPlaneHook]
    let projectEventsToday: Int
    let oldOrgHooks: [RelayOldOrgHook]

    private enum CodingKeys: String, CodingKey {
        case version, retentionHours, head, events, oldestAt, lastWebhookAt, rowsWrittenToday
        case devices, hooks, planeHooks, projectEventsToday, orgHooks
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(String.self, forKey: .version)
        retentionHours = try c.decode(Int.self, forKey: .retentionHours)
        head = try c.decode(Int.self, forKey: .head)
        events = try c.decode(Int.self, forKey: .events)
        oldestAt = try c.decodeIfPresent(Double.self, forKey: .oldestAt)
        lastWebhookAt = try c.decodeIfPresent(Double.self, forKey: .lastWebhookAt)
        rowsWrittenToday = try c.decode(Int.self, forKey: .rowsWrittenToday)
        devices = try c.decode([RelayDevice].self, forKey: .devices)
        hooks = try c.decode([RelayHook].self, forKey: .hooks)
        planeHooks = try c.decodeIfPresent([RelayPlaneHook].self, forKey: .planeHooks) ?? []
        oldOrgHooks = try c.decodeIfPresent([RelayOldOrgHook].self, forKey: .orgHooks) ?? []
        projectEventsToday = try c.decodeIfPresent(Int.self, forKey: .projectEventsToday) ?? 0
    }
}

enum RelayFailure: Error, CustomStringConvertible {
    case notConfigured, unauthorized, http(Int), network(String), decode

    var description: String {
        switch self {
        case .notConfigured: return "Relay is not set up"
        case .unauthorized: return "This Mac's token was rejected"
        case .http(let c): return "Relay answered HTTP \(c)"
        case .network(let m): return m
        case .decode: return "Unexpected relay response"
        }
    }
}

// Blocking calls: use them off the main thread.
struct RelayAPI {
    let base: String
    let token: String?

    func send<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil,
                            as: T.Type = T.self) -> Result<T, RelayFailure> {
        guard let url = URL(string: base + path), !base.isEmpty else { return .failure(.notConfigured) }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = method
        if let t = token { req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
        if let b = body {
            req.httpBody = try? JSONSerialization.data(withJSONObject: b)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var result: Result<T, RelayFailure> = .failure(.network("No response"))
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err = err { result = .failure(.network(err.localizedDescription)); return }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { result = .failure(.unauthorized); return }
            guard (200..<300).contains(code) else { result = .failure(.http(code)); return }
            guard let data = data, let v = try? JSONDecoder().decode(T.self, from: data) else { result = .failure(.decode); return }
            result = .success(v)
        }.resume()
        sem.wait()
        return result
    }

    struct OK: Decodable {}
    struct Discovery: Decodable { let app: String; let version: String? }
    struct Secret: Decodable { let secret: String }

    func discover() -> Discovery? {
        guard case .success(let d) = send("GET", "/", as: Discovery.self), d.app == RELAY_WORKER_NAME else { return nil }
        return d
    }
    func health() -> Result<RelayHealth, RelayFailure> { send("GET", "/v1/health") }
    func events(after: Int) -> Result<RelayEventsPage, RelayFailure> { send("GET", "/v1/events?after=\(after)&limit=500") }
    func ack(_ seq: Int) -> Bool { (try? send("POST", "/v1/ack", body: ["seq": seq], as: OK.self).get()) != nil }
    func registerSelf(name: String, repos: [String], orgs: [String] = []) -> Result<OK, RelayFailure> {
        send("PUT", "/v1/devices/self", body: ["name": name, "repos": repos, "orgs": orgs])
    }
    func removeDevice(_ id: String) -> Bool { (try? send("DELETE", "/v1/devices/\(id)", as: OK.self).get()) != nil }
    func setRetention(hours: Int) -> Result<OK, RelayFailure> { send("PUT", "/v1/config", body: ["retentionHours": hours]) }
    func webhookSecret() -> String? { try? send("GET", "/v1/webhook-secret", as: Secret.self).get().secret }
    func putHook(repo: String, id: Int) -> Bool { (try? send("PUT", "/v1/hooks/\(repo)", body: ["hookId": id], as: OK.self).get()) != nil }
    func deleteHook(repo: String) -> Bool { (try? send("DELETE", "/v1/hooks/\(repo)", as: OK.self).get()) != nil }
    func putPlaneHook(workspace: String, id: String, secret: String) -> Bool {
        (try? send("PUT", "/v1/plane-hooks/\(workspace)", body: ["hookId": id, "secret": secret], as: OK.self).get()) != nil
    }
    func deletePlaneHook(workspace: String) -> Bool { (try? send("DELETE", "/v1/plane-hooks/\(workspace)", as: OK.self).get()) != nil }
}

// ─── Webhooks on GitHub ──────────────────────────────────────────────────────

enum HookStatus {
    case unknown
    case live(String)          // detail, e.g. "200 · 2m ago"
    case waiting               // hook exists, no delivery yet
    case pollingOnly(String)   // no admin access to the repo
    case error(String)

    var isDone: Bool {
        switch self {
        case .live, .waiting, .pollingOnly: return true
        default: return false
        }
    }
}

final class HookManager {
    private let lock = NSLock()
    private var _statuses: [String: HookStatus] = [:]
    var statuses: [String: HookStatus] { lock.lock(); defer { lock.unlock() }; return _statuses }

    private func setStatus(_ repo: String, _ s: HookStatus) { lock.lock(); _statuses[repo] = s; lock.unlock() }

    struct GHHook: Decodable { let id: Int; let url: String? }
    struct Delivery: Decodable { let status_code: Int; let delivered_at: String }

    private func gh(_ args: [String], body: [String: Any]? = nil) -> GHResult? {
        let input = body.flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        return try? ghRun(args + (input != nil ? ["--input", "-"] : []), input: input)
    }

    private func denied(_ r: GHResult) -> Bool {
        let e = r.err.lowercased()
        return e.contains("http 404") || e.contains("http 403") || e.contains("not found") || e.contains("must have admin")
    }

    enum Lookup { case found(Int), missing, failed(HookStatus) }

    func find(repo: String, url: String) -> Lookup {
        guard let r = gh(["api", "repos/\(repo)/hooks?per_page=100", "--jq", "[.[] | {id, url: .config.url}]"]) else {
            return .failed(.error("gh failed to start"))
        }
        if !r.ok { return .failed(denied(r) ? .pollingOnly("No admin access") : .error(String(r.err.prefix(80)))) }
        let hooks = (try? JSONDecoder().decode([GHHook].self, from: r.out)) ?? []
        return hooks.first { $0.url == url }.map { .found($0.id) } ?? .missing
    }

    // Creates or updates the hook of one repo, records it in the relay, and pings it.
    func ensure(repo: String, workerURL: String, secret: String, api: RelayAPI) -> HookStatus {
        let url = workerURL + "/webhook"
        let body: [String: Any] = [
            "name": "web", "active": true, "events": RELAY_EVENTS,
            "config": ["url": url, "content_type": "json", "secret": secret, "insecure_ssl": "0"],
        ]
        let existing: Int?
        switch find(repo: repo, url: url) {
        case .failed(let s): setStatus(repo, s); return s
        case .missing: existing = nil
        case .found(let id): existing = id
        }
        let res = existing.map { gh(["api", "-X", "PATCH", "repos/\(repo)/hooks/\($0)", "--jq", ".id"], body: body) }
            ?? gh(["api", "-X", "POST", "repos/\(repo)/hooks", "--jq", ".id"], body: body)
        guard let r = res else { return .error("gh failed to start") }
        guard r.ok, let id = Int(String(decoding: r.out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) else {
            let s: HookStatus = denied(r) ? .pollingOnly("No admin access") : .error(String(r.err.prefix(80)))
            setStatus(repo, s); return s
        }
        _ = api.putHook(repo: repo, id: id)
        _ = gh(["api", "-X", "POST", "repos/\(repo)/hooks/\(id)/pings"])
        setStatus(repo, .waiting)
        return .waiting
    }

    // Reads the last deliveries. 401 means the secrets do not match.
    func check(repo: String, workerURL: String) -> HookStatus {
        let id: Int
        switch find(repo: repo, url: workerURL + "/webhook") {
        case .failed(let s): setStatus(repo, s); return s
        case .missing: setStatus(repo, .error("No hook")); return .error("No hook")
        case .found(let found): id = found
        }
        guard let r = gh(["api", "repos/\(repo)/hooks/\(id)/deliveries?per_page=5",
                          "--jq", "[.[] | {status_code, delivered_at}]"]), r.ok,
              let list = try? JSONDecoder().decode([Delivery].self, from: r.out) else {
            setStatus(repo, .waiting); return .waiting
        }
        guard let last = list.first else { setStatus(repo, .waiting); return .waiting }
        let ago = parseISO(last.delivered_at).map { relativeAgo($0) } ?? ""
        let s: HookStatus
        switch last.status_code {
        case 200..<300: s = .live("\(last.status_code) · \(ago)")
        case 401: s = .error("Secret mismatch (401) · \(ago)")
        default: s = .error("HTTP \(last.status_code) · \(ago)")
        }
        setStatus(repo, s)
        return s
    }

    func patchSecret(repo: String, hookId: Int, secret: String) -> Bool {
        let body: [String: Any] = ["config": ["url": RELAY.workerURL + "/webhook", "content_type": "json",
                                              "secret": secret, "insecure_ssl": "0"]]
        return gh(["api", "-X", "PATCH", "repos/\(repo)/hooks/\(hookId)", "--jq", ".id"], body: body)?.ok == true
    }

    func delete(repo: String, hookId: Int) -> Bool {
        let ok = gh(["api", "-X", "DELETE", "repos/\(repo)/hooks/\(hookId)"])?.ok == true
        lock.lock(); _statuses[repo] = nil; lock.unlock()
        return ok
    }

    enum OrgDelete { case deleted, noScope, failed(String) }

    // GitHub gives 404 for a missing hook and for a missing scope. Only the hint of gh tells them apart.
    func deleteOrgHook(org: String, hookId: Int) -> OrgDelete {
        guard let r = gh(["api", "-X", "DELETE", "orgs/\(org)/hooks/\(hookId)"]) else { return .failed("gh failed to start") }
        if r.ok { return .deleted }
        if r.err.contains("admin:org_hook") { return .noScope }
        if r.err.lowercased().contains("not found") { return .deleted }
        return .failed(String(r.err.prefix(80)))
    }

    static func planeKey(_ slug: String) -> String { "plane:\(slug)" }
    static func planeURL(_ slug: String, workerURL: String) -> String { "\(workerURL)/plane/\(slug)" }

    // Plane shows a webhook secret only when it creates the hook. A hook that the
    // relay has no secret for is deleted and created again. Needs a workspace admin.
    func ensurePlane(_ client: PlaneClient, workerURL: String, relayHookId: String?, api: RelayAPI) -> HookStatus {
        let slug = client.workspace.slug
        let key = HookManager.planeKey(slug)
        let url = HookManager.planeURL(slug, workerURL: workerURL)
        let existing: [PlaneWebhook]
        switch client.webhooks() {
        case .success(let list): existing = list.filter { $0.url == url }
        case .failure(let e):
            let s = planeDenied(e) ? HookStatus.pollingOnly("Not a workspace admin") : .error(e.message)
            setStatus(key, s); return s
        }
        if let hook = existing.first(where: { $0.id == relayHookId }), hook.isActive, existing.count == 1 {
            setStatus(key, .waiting)
            return .waiting
        }
        for hook in existing { _ = client.deleteWebhook(id: hook.id) }
        switch client.createWebhook(url: url) {
        case .failure(let e):
            let s = planeDenied(e) ? HookStatus.pollingOnly("Not a workspace admin") : .error(e.message)
            setStatus(key, s); return s
        case .success(let made):
            guard api.putPlaneHook(workspace: slug, id: made.id, secret: made.secret) else {
                _ = client.deleteWebhook(id: made.id)
                setStatus(key, .error("The relay did not save the secret")); return .error("The relay did not save the secret")
            }
            setStatus(key, .waiting)
            return .waiting
        }
    }

    // Plane has no delivery log in its API, so the relay gives the last delivery.
    func checkPlane(_ client: PlaneClient, workerURL: String, relayHook: RelayPlaneHook?) -> HookStatus {
        let key = HookManager.planeKey(client.workspace.slug)
        let url = HookManager.planeURL(client.workspace.slug, workerURL: workerURL)
        let s: HookStatus
        switch client.webhooks() {
        case .failure(let e):
            s = planeDenied(e) ? .pollingOnly("Not a workspace admin") : .error(e.message)
        case .success(let list):
            if let hook = list.first(where: { $0.url == url }) {
                if !hook.isActive { s = .error("Off in Plane. Click Add to turn it on.") }
                else if relayHook?.hookId != hook.id { s = .error("The relay has no secret. Click Add.") }
                else if let at = relayHook?.lastDelivery { s = .live(relativeAgo(Date(timeIntervalSince1970: at / 1000))) }
                else { s = .waiting }
            } else {
                s = relayHook == nil ? .unknown : .error("No hook")
            }
        }
        setStatus(key, s)
        return s
    }

    func deletePlane(_ client: PlaneClient, hookId: String) -> Bool {
        let ok = client.deleteWebhook(id: hookId).isSuccess
        lock.lock(); _statuses[HookManager.planeKey(client.workspace.slug)] = nil; lock.unlock()
        return ok
    }

    private func planeDenied(_ e: PlaneError) -> Bool { e == .forbidden || e == .unauthorized }
}

extension Result {
    var isSuccess: Bool { if case .success = self { return true }; return false }
}

func relativeAgo(_ d: Date) -> String {
    let s = Int(max(0, -d.timeIntervalSinceNow))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

// ─── Deployer: login, deploy, join, retention, devices, remove ───────────────

struct CFAccount: Equatable { let id: String; let name: String }

struct SetupState {
    var node: String?
    var nodeOK = false
    var hasBrew = false
    var wrangler: String?
    var email: String?
    var accounts: [CFAccount] = []
    var relayVersion: Int?
    var joined = false
    var joinError: String?
    var health: RelayHealth?

    var needsRelayUpdate: Bool { (relayVersion ?? 0) < RELAY_BUNDLED_VERSION }
}

final class RelayDeployer {
    let tools = Toolchain()
    let secrets = SecretStore()
    let hooks = HookManager()
    private let work = DispatchQueue(label: "com.oversire.app.relay.setup")

    // Main thread only.
    private(set) var log: [String] = []
    private(set) var busy: String?
    private(set) var state = SetupState()
    var onChange: (() -> Void)?
    var onLog: (() -> Void)?

    var api: RelayAPI { RelayAPI(base: RELAY.workerURL, token: secrets.get(SecretStore.deviceToken)) }

    // MARK: Output parsers (pure, covered by --selftest)

    static func parseWorkerURL(_ out: String) -> String? {
        let re = try! NSRegularExpression(pattern: "https://\(RELAY_WORKER_NAME)\\.[A-Za-z0-9-]+\\.workers\\.dev")
        guard let m = re.firstMatch(in: out, range: NSRange(out.startIndex..., in: out)),
              let r = Range(m.range, in: out) else { return nil }
        return String(out[r])
    }

    static func parseWhoami(_ out: String) -> (email: String?, accounts: [CFAccount])? {
        guard let start = out.firstIndex(of: "{"),
              let obj = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [String: Any],
              obj["loggedIn"] as? Bool == true else { return nil }
        let accts = (obj["accounts"] as? [[String: Any]] ?? []).compactMap { a -> CFAccount? in
            guard let id = a["id"] as? String else { return nil }
            return CFAccount(id: id, name: a["name"] as? String ?? id)
        }
        return (obj["email"] as? String, accts)
    }

    static func parseSecretNames(_ out: String) -> [String]? {
        guard let start = out.firstIndex(of: "["),
              let arr = try? JSONSerialization.jsonObject(with: Data(out[start...].utf8)) as? [[String: Any]] else { return nil }
        return arr.compactMap { $0["name"] as? String }
    }

    // MARK: Plumbing

    func append(_ line: String) {
        let masked = maskSecrets(line)
        DispatchQueue.main.async {
            self.log.append(masked)
            if self.log.count > 500 { self.log.removeFirst(self.log.count - 500) }
            self.onLog?()
        }
    }

    // Runs one task at a time in the background. `body` returns false on failure.
    func perform(_ title: String, _ body: @escaping () -> Bool, then: ((Bool) -> Void)? = nil) {
        guard busy == nil else { return }
        busy = title
        onChange?()
        append("▸ \(title)")
        work.async {
            let ok = body()
            self.append(ok ? "✓ \(title)" : "✗ \(title) failed")
            DispatchQueue.main.async {
                self.busy = nil
                self.onChange?()
                then?(ok)
            }
        }
    }

    // MARK: Inspect

    // Collects the state of all setup steps. Blocking.
    func inspect() -> SetupState {
        var s = SetupState()
        tools.findNode()
        s.hasBrew = tools.brew != nil
        if let v = tools.nodeVersion() { s.node = v.version; s.nodeOK = v.ok }
        s.wrangler = tools.wranglerVersion()
        if s.wrangler != nil, let who = RelayDeployer.parseWhoami(tools.wrangler(["whoami", "--json"]).output) {
            s.email = who.email
            s.accounts = who.accounts
            if who.accounts.count == 1, RELAY.accountID != who.accounts[0].id {
                DispatchQueue.main.async { RELAY.accountID = who.accounts[0].id; saveConfig() }
            }
        }
        if !RELAY.workerURL.isEmpty {
            s.relayVersion = api.discover().flatMap { Int($0.version ?? "") }
            switch api.health() {
            case .success(let h): s.joined = true; s.health = h
            case .failure(let f): s.joinError = secrets.get(SecretStore.deviceToken) == nil ? nil : f.description
            }
        }
        return s
    }

    func refreshState(then: (() -> Void)? = nil) {
        work.async {
            let s = self.inspect()
            DispatchQueue.main.async { self.state = s; self.onChange?(); then?() }
        }
    }

    // MARK: Steps

    func installNode() -> Bool { tools.installNode(onLine: append).ok }
    func installWrangler(update: Bool = false) -> Bool { tools.installWrangler(update: update, onLine: append).ok }
    func login() -> Bool { tools.wrangler(["login"], onLine: append).ok }
    func logout() -> Bool { tools.wrangler(["logout"], onLine: append).ok }

    // Deploys the bundled Worker. A second Mac deploys the same version, which
    // is harmless and gives it the workers.dev URL.
    func deploy() -> Bool {
        guard tools.syncBundle() else { append("Relay files are missing from the app bundle"); return false }
        let res = tools.wrangler(["deploy"], onLine: append)
        if res.output.contains("workers.dev subdomain") {
            append("Register a workers.dev subdomain in the Cloudflare dashboard (Workers & Pages), then try again.")
            if let u = URL(string: "https://dash.cloudflare.com/?to=/:account/workers-and-pages") { NSWorkspace.shared.open(u) }
            return false
        }
        guard res.ok, let url = RelayDeployer.parseWorkerURL(res.output) else { return false }
        DispatchQueue.main.sync { RELAY.workerURL = url; saveConfig() }
        guard ensureWebhookSecret() else { return false }
        // A new workers.dev route can take a few seconds to answer.
        for _ in 0..<15 {
            if RelayAPI(base: url, token: nil).discover() != nil { return true }
            Thread.sleep(forTimeInterval: 2)
        }
        append("The relay does not answer at \(url) yet. Click Check again in a minute.")
        return false
    }

    // Deploys the bundled Worker over an older one, then moves this Mac to it:
    // registers again, adds the Plane webhooks and deletes the old GitHub org hooks.
    func updateRelay() -> Bool {
        if case .success(let h) = api.health() {
            let old = Dictionary(h.oldOrgHooks.compactMap { o in o.hookId.map { (o.org, $0) } }, uniquingKeysWith: { a, _ in a })
            if !old.isEmpty {
                onMain { RELAY.oldOrgHooks = (RELAY.oldOrgHooks ?? [:]).merging(old) { a, _ in a }; saveConfig() }
            }
        }
        guard deploy() else { return false }
        let orgs = trackedOrgs()
        if case .failure(let f) = api.registerSelf(name: Host.current().localizedName ?? "Mac", repos: onMain { REPOS }, orgs: orgs) {
            append("Register this Mac: \(f.description)")
        }
        let slugs = onMain { trackedWorkspaces() }
        if !slugs.isEmpty { _ = installPlaneHooks(slugs) }
        _ = deleteOldOrgHooks()
        return true
    }

    // Keeps the hooks that it cannot delete, to try again later.
    func deleteOldOrgHooks() -> Bool {
        let pending = onMain { RELAY.oldOrgHooks ?? [:] }
        guard !pending.isEmpty else { return true }
        var left = pending
        var noScope = false
        for (org, id) in pending.sorted(by: { $0.key < $1.key }) {
            switch hooks.deleteOrgHook(org: org, hookId: id) {
            case .deleted: left[org] = nil; append("\(org): old GitHub org hook deleted")
            case .noScope: noScope = true
            case .failed(let e): append("\(org): old GitHub org hook not deleted (\(e))")
            }
        }
        if noScope {
            append("Old GitHub org hooks need the admin:org_hook scope. Run: gh auth refresh -h github.com -s admin:org_hook")
        }
        onMain { RELAY.oldOrgHooks = left.isEmpty ? nil : left; saveConfig() }
        return left.isEmpty
    }

    // An older relay than the app bundles updates without a click. That needs wrangler and a Cloudflare login.
    func updateIfOld(then: ((Bool) -> Void)? = nil) {
        guard !RELAY.workerURL.isEmpty else { return }
        work.async {
            guard let v = self.api.discover().flatMap({ Int($0.version ?? "") }) else { return }
            guard v < RELAY_BUNDLED_VERSION else {
                if self.onMain({ RELAY.oldOrgHooks != nil }) { _ = self.deleteOldOrgHooks() }
                return
            }
            self.tools.findNode()
            guard self.tools.wranglerVersion() != nil,
                  RelayDeployer.parseWhoami(self.tools.wrangler(["whoami", "--json"]).output) != nil else {
                self.append("Relay v\(v) is old. Log in to Cloudflare in Settings → Live updates to update it.")
                return
            }
            DispatchQueue.main.async {
                self.perform("Update relay v\(v) to v\(RELAY_BUNDLED_VERSION)", self.updateRelay) { ok in
                    self.refreshState { then?(ok) }
                }
            }
        }
    }

    // The first Mac makes the webhook secret. Later Macs read it from the relay after they join.
    func ensureWebhookSecret() -> Bool {
        let list = tools.wrangler(["secret", "list"])
        guard list.ok, let names = RelayDeployer.parseSecretNames(list.output) else {
            append(list.output); return false
        }
        if names.contains(SecretStore.webhookSecret) { return true }
        let secret = randomHex(32)
        guard tools.wrangler(["secret", "put", SecretStore.webhookSecret], stdin: secret, onLine: append).ok else { return false }
        secrets.set(SecretStore.webhookSecret, secret)
        return true
    }

    func joinThisMac() -> Bool {
        var id = RELAY.deviceID
        if id.isEmpty { id = randomHex(8).uppercased() }
        let token = randomHex(32)
        guard tools.wrangler(["secret", "put", "DEVICE_\(id)"], stdin: token, onLine: append).ok else { return false }
        secrets.set(SecretStore.deviceToken, token)
        DispatchQueue.main.sync { RELAY.deviceID = id; saveConfig() }
        // A new secret takes a few seconds to reach the edge.
        let orgs = trackedOrgs()
        for _ in 0..<15 {
            if case .success = api.registerSelf(name: Host.current().localizedName ?? "Mac", repos: REPOS, orgs: orgs) {
                if let s = api.webhookSecret() { secrets.set(SecretStore.webhookSecret, s) }
                return true
            }
            Thread.sleep(forTimeInterval: 2)
        }
        append("The relay did not accept the new token in time. Try again.")
        return false
    }

    // Repos with a hook on the relay. Nil until the first health read. Main thread only.
    private(set) var hookedRepos: Set<String>?

    func refreshHookedRepos(done: @escaping () -> Void) {
        let api = self.api
        work.async {
            guard case .success(let h) = api.health() else { return }
            let hooked = Set(h.hooks.filter { $0.hookId != nil }.map { $0.repo })
            DispatchQueue.main.async { self.hookedRepos = hooked; done() }
        }
    }

    // Repos that get no webhook events, so they still need the normal poll.
    func unhookedRepos(_ repos: [String]) -> [String] {
        Self.unhooked(repos, hooked: hookedRepos, statuses: hooks.statuses)
    }

    static func unhooked(_ repos: [String], hooked: Set<String>?, statuses: [String: HookStatus]) -> [String] {
        guard let hooked = hooked else { return [] }
        return repos.filter {
            switch statuses[$0] {
            case .pollingOnly?, .error?: return true
            case .live?, .waiting?: return false
            default: return !hooked.contains($0.lowercased())
            }
        }
    }

    // Set by the app. Called on the main thread.
    var planeClient: (String) -> PlaneClient? = { _ in nil }
    var trackedWorkspaces: () -> [String] = { [] }

    private func onMain<T>(_ f: () -> T) -> T { Thread.isMainThread ? f() : DispatchQueue.main.sync(execute: f) }

    // Plane workspaces register as "plane:<slug>". The relay sends them to this Mac only.
    func trackedOrgs() -> [String] { onMain { trackedWorkspaces() }.map(HookManager.planeKey) }

    func registerRepos() {
        let api = self.api, repos = REPOS, orgs = trackedOrgs()
        work.async { _ = api.registerSelf(name: Host.current().localizedName ?? "Mac", repos: repos, orgs: orgs) }
    }

    func webhookSecret() -> String? {
        if let s = secrets.get(SecretStore.webhookSecret) { return s }
        let s = api.webhookSecret()
        if let s = s { secrets.set(SecretStore.webhookSecret, s) }
        return s
    }

    func installHooks(repos: [String]) -> Bool {
        guard let secret = webhookSecret() else { append("The webhook secret is not available"); return false }
        let api = self.api, url = RELAY.workerURL
        var ok = true
        for repo in repos {
            let s = hooks.ensure(repo: repo, workerURL: url, secret: secret, api: api)
            append("\(repo): \(describe(s))")
            if case .error = s { ok = false }
            if case .pollingOnly = s {
                append("If you are an admin of \(repo), run in Terminal: gh auth refresh -s admin:repo_hook")
            }
        }
        return ok
    }

    func checkHooks(repos: [String]) {
        let url = RELAY.workerURL
        guard !url.isEmpty else { return }
        work.async {
            DispatchQueue.concurrentPerform(iterations: repos.count) { _ = self.hooks.check(repo: repos[$0], workerURL: url) }
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    func installPlaneHooks(_ slugs: [String]) -> Bool {
        guard case .success(let h) = api.health() else { append("Relay health check failed"); return false }
        guard Int(h.version ?? "") ?? 0 >= RELAY_BUNDLED_VERSION else {
            append("The relay is too old for Plane webhooks. Update the relay first."); return false
        }
        let api = self.api, url = RELAY.workerURL
        var ok = true
        for slug in slugs {
            guard let client = onMain({ planeClient(slug) }) else { append("\(slug): no token"); ok = false; continue }
            let known = h.planeHooks.first { $0.workspace == slug }?.hookId
            let s = hooks.ensurePlane(client, workerURL: url, relayHookId: known, api: api)
            append("\(slug) (Plane): \(describe(s))")
            if case .error = s { ok = false }
            if case .pollingOnly = s { append("A Plane webhook needs a workspace admin. \(slug) stays on polling.") }
        }
        return ok
    }

    func checkPlaneHooks(_ slugs: [String]) {
        let url = RELAY.workerURL
        guard !url.isEmpty, !slugs.isEmpty else { return }
        let api = self.api
        let clients = slugs.compactMap { planeClient($0) }
        work.async {
            let h = try? api.health().get()
            for c in clients {
                _ = self.hooks.checkPlane(c, workerURL: url, relayHook: h?.planeHooks.first { $0.workspace == c.workspace.slug })
            }
            DispatchQueue.main.async { self.onChange?() }
        }
    }

    // Deletes Plane hooks of workspaces that no device tracks any more.
    func prunePlaneHooks(removed: [String]) {
        guard !removed.isEmpty, !RELAY.workerURL.isEmpty else { return }
        let api = self.api
        let clients = removed.compactMap { planeClient($0) }
        work.async {
            guard case .success(let h) = api.health() else { return }
            let others = Set(h.devices.filter { $0.id != RELAY.deviceID }.flatMap { $0.orgs })
            for c in clients where !others.contains(HookManager.planeKey(c.workspace.slug)) {
                guard let id = h.planeHooks.first(where: { $0.workspace == c.workspace.slug })?.hookId else { continue }
                if self.hooks.deletePlane(c, hookId: id) { _ = api.deletePlaneHook(workspace: c.workspace.slug) }
            }
        }
    }

    // Before the token goes away: deletes the Plane hook of the workspace, also if other Macs use it.
    func removePlaneHook(_ slug: String) {
        guard !RELAY.workerURL.isEmpty, let client = planeClient(slug) else { return }
        let api = self.api
        work.async {
            guard case .success(let h) = api.health(),
                  let id = h.planeHooks.first(where: { $0.workspace == slug })?.hookId else { return }
            if self.hooks.deletePlane(client, hookId: id) { _ = api.deletePlaneHook(workspace: slug) }
        }
    }

    // Deletes the hooks of repos that no device tracks any more.
    func pruneHooks(removed: [String]) {
        guard !removed.isEmpty, !RELAY.workerURL.isEmpty else { return }
        let api = self.api
        work.async {
            guard case .success(let h) = api.health() else { return }
            let others = Set(h.devices.filter { $0.id != RELAY.deviceID }.flatMap { $0.repos })
            for repo in removed where !others.contains(repo.lowercased()) {
                guard let hook = h.hooks.first(where: { $0.repo == repo.lowercased() }), let id = hook.hookId else { continue }
                if self.hooks.delete(repo: repo, hookId: id) { _ = api.deleteHook(repo: repo) }
            }
        }
    }

    func setRetention(hours: Int) -> Bool {
        switch api.setRetention(hours: hours) {
        case .success: return true
        case .failure(let f): append(f.description); return false
        }
    }

    func removeDevice(_ id: String) -> Bool {
        let res = tools.wrangler(["secret", "delete", "DEVICE_\(id)"], onLine: append)
        return api.removeDevice(id) && res.ok
    }

    // New secret on the Worker, then on every hook this Mac can administer.
    func rotateWebhookSecret() -> Bool {
        guard case .success(let h) = api.health() else { append("Relay health check failed"); return false }
        let secret = randomHex(32)
        guard tools.wrangler(["secret", "put", SecretStore.webhookSecret], stdin: secret, onLine: append).ok else { return false }
        secrets.set(SecretStore.webhookSecret, secret)
        var ok = true
        for hook in h.hooks {
            guard let id = hook.hookId else { continue }
            if hooks.patchSecret(repo: hook.repo, hookId: id, secret: secret) {
                append("\(hook.repo): updated")
            } else {
                ok = false
                append("\(hook.repo): not updated. Click Repair on a Mac with admin access to this repo.")
            }
        }
        // Plane hooks have their own secrets. They do not change.
        return ok
    }

    // Deletes all hooks, the Worker and the Keychain items. Affects all Macs.
    func removeRelay() -> Bool {
        if case .success(let h) = api.health() {
            for hook in h.hooks {
                guard let id = hook.hookId else { continue }
                append("\(hook.repo): \(hooks.delete(repo: hook.repo, hookId: id) ? "hook deleted" : "hook not deleted")")
            }
            for hook in h.planeHooks {
                guard let id = hook.hookId else { continue }
                guard let client = onMain({ planeClient(hook.workspace) }) else {
                    append("\(hook.workspace): no token. Delete the webhook in Plane → Workspace settings → Webhooks.")
                    continue
                }
                append("\(hook.workspace): \(hooks.deletePlane(client, hookId: id) ? "Plane hook deleted" : "Plane hook not deleted")")
            }
        }
        guard tools.wrangler(["delete", RELAY_WORKER_NAME], onLine: append).ok else { return false }
        secrets.delete(SecretStore.deviceToken)
        secrets.delete(SecretStore.webhookSecret)
        UserDefaults.standard.removeObject(forKey: "relayCursor")
        DispatchQueue.main.sync {
            let account = RELAY.accountID
            RELAY = RelayConfig()
            RELAY.accountID = account
            saveConfig()
        }
        return true
    }

    func describe(_ s: HookStatus) -> String {
        switch s {
        case .unknown: return "not checked"
        case .live(let d): return "live (\(d))"
        case .waiting: return "installed, no delivery yet"
        case .pollingOnly(let d): return "polling only (\(d))"
        case .error(let d): return "error: \(d)"
        }
    }
}

// ─── Live client ─────────────────────────────────────────────────────────────

// Keeps the last delivery IDs, so a replayed event is handled once.
struct RecentIDs {
    let capacity: Int
    private var order: [String] = []
    private var set = Set<String>()

    init(capacity: Int = 2000) { self.capacity = capacity }

    func contains(_ id: String) -> Bool { set.contains(id) }

    mutating func insert(_ id: String) {
        guard set.insert(id).inserted else { return }
        order.append(id)
        if order.count > capacity { set.remove(order.removeFirst()) }
    }
}

// 1, 2, 4 … 60 s, with up to 20% jitter.
struct Backoff {
    private(set) var attempt = 0

    mutating func next(jitter: Double = Double.random(in: 0...0.2)) -> TimeInterval {
        let base = min(60, pow(2, Double(attempt)))
        attempt += 1
        return base * (1 + jitter)
    }

    mutating func reset() { attempt = 0 }
}

// The consumer of relay events. GHActionsBar implements it.
protocol RelaySink: AnyObject {
    func relayRefresh(repos: [String], includePRs: Bool, completedRuns: [(String, Int)], done: @escaping (Bool) -> Void)
    func relayProjectRefresh(_ events: [(workspace: String, project: String?)], done: @escaping (Bool) -> Void)
    func relayFullRefresh(done: @escaping (Bool) -> Void)
    func relayStateChanged()
}

// Splits a page of relay events into a repo refresh and a project refresh.
struct RelayApplyPlan {
    var repos: [String] = []
    var includePRs = false
    var completedRuns: [(String, Int)] = []
    var plane: [(workspace: String, project: String?)] = []   // nil project: the whole workspace
    var wantsRepoRefresh: Bool { !repos.isEmpty }
    var wantsProjectRefresh: Bool { !plane.isEmpty }
}

func relayApplyPlan(_ events: [RelayEvent], knownRepos: [String]) -> RelayApplyPlan {
    let byLower = Dictionary(knownRepos.map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
    var plan = RelayApplyPlan()
    for e in events {
        switch e.kind {
        case "workflow_run", "workflow_job", "pull_request", "pull_request_review":
            if let r = byLower[e.repo], !plan.repos.contains(r) { plan.repos.append(r) }
            if e.kind.hasPrefix("pull_request") { plan.includePRs = true }
            if e.kind == "workflow_run", e.action == "completed", let id = e.runId, let r = byLower[e.repo] {
                plan.completedRuns.append((r, id))
            }
        case "plane":
            guard let org = e.org, org.hasPrefix("plane:") else { break }
            let slug = String(org.dropFirst(6))
            if plan.plane.contains(where: { $0.workspace == slug && ($0.project == nil || $0.project == e.projectId) }) { break }
            if e.projectId == nil { plan.plane.removeAll { $0.workspace == slug } }
            plan.plane.append((slug, e.projectId))
        default:
            break
        }
    }
    return plan
}

final class RelayClient: NSObject, URLSessionWebSocketDelegate {
    enum State: Equatable { case off, connecting, live, error(String) }

    weak var sink: RelaySink?
    let secrets: SecretStore

    // Main thread only.
    private(set) var state: State = .off { didSet { if state != oldValue { sink?.relayStateChanged() } } }
    private(set) var lastSync: Date?
    private(set) var lastEventAt: Date?
    private var lastPong: Date?
    private var task: URLSessionWebSocketTask?
    private var session: URLSession!
    private var backoff = Backoff()
    private var reconnectWork: DispatchWorkItem?
    private var pingTimer: Timer?
    private var debounce: DispatchWorkItem?
    private var syncing = false
    private var syncAgain = false
    private var seen = RecentIDs()
    private var pathMonitor: NWPathMonitor?
    private let syncQ = DispatchQueue(label: "com.oversire.app.relay.sync")

    private var cursor: Int {
        get { UserDefaults.standard.integer(forKey: "relayCursor") }
        set { UserDefaults.standard.set(newValue, forKey: "relayCursor") }
    }

    init(secrets: SecretStore) {
        self.secrets = secrets
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
    }

    var isHealthy: Bool {
        guard state == .live, let p = lastPong else { return false }
        return Date().timeIntervalSince(p) < 75
    }

    var api: RelayAPI { RelayAPI(base: RELAY.workerURL, token: secrets.get(SecretStore.deviceToken)) }

    var canRun: Bool { RELAY.enabled && !RELAY.workerURL.isEmpty && !RELAY.deviceID.isEmpty }

    // MARK: Lifecycle

    func start() {
        guard canRun else { stop(); return }
        if pathMonitor == nil {
            let m = NWPathMonitor()
            m.pathUpdateHandler = { [weak self] path in
                guard path.status == .satisfied else { return }
                DispatchQueue.main.async { if self?.state != .live { self?.reconnect() } }
            }
            m.start(queue: .main)
            pathMonitor = m
        }
        connect()
    }

    func stop() {
        reconnectWork?.cancel()
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        state = .off
    }

    func reconnect() {
        guard canRun else { return }
        backoff.reset()
        connect()
    }

    @objc private func didWake() { reconnect() }

    private func connect() {
        reconnectWork?.cancel()
        pingTimer?.invalidate()
        task?.cancel(with: .goingAway, reason: nil)
        guard let token = secrets.get(SecretStore.deviceToken),
              let url = URL(string: RELAY.workerURL.replacingOccurrences(of: "https://", with: "wss://")
                                .replacingOccurrences(of: "http://", with: "ws://") + "/v1/connect") else {
            state = .error("This Mac has not joined the relay")
            return
        }
        if state != .live { state = .connecting }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let t = session.webSocketTask(with: req)
        task = t
        t.resume()
        receive(t)
    }

    private func scheduleReconnect() {
        guard canRun else { return }
        let delay = backoff.next()
        let w = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        guard webSocketTask === task else { return }
        log.info("Relay connected")
        state = .live
        lastPong = Date()
        backoff.reset()
        startPings(webSocketTask)
        sync()
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                    didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        guard webSocketTask === task else { return }
        if closeCode.rawValue == 4001 { state = .error("This Mac was removed from the relay"); return }
        state = .connecting
        scheduleReconnect()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard task === self.task else { return }
        let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 401 { state = .error("The relay rejected this Mac's token"); return }
        log.info("Relay connection ended: \(error?.localizedDescription ?? "closed", privacy: .public)")
        state = .error(error.map { "Disconnected: \($0.localizedDescription)" } ?? "Disconnected")
        scheduleReconnect()
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self, t === self.task, case .success(let msg) = result else { return }
                if case .string(let text) = msg {
                    if text == "pong" { self.lastPong = Date() }
                    else if text.contains("\"poke\"") { self.lastPong = Date(); self.poke() }
                }
                self.receive(t)
            }
        }
    }

    // Text "ping" gets an auto-response from the Durable Object, so it does not wake it.
    private func startPings(_ t: URLSessionWebSocketTask) {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self, weak t] _ in
            guard let self = self, let t = t, t === self.task else { return }
            let sent = Date()
            t.send(.string("ping")) { _ in }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                guard t === self.task, (self.lastPong ?? .distantPast) < sent else { return }
                log.info("Relay pong timeout, reconnecting")
                self.connect()
            }
        }
    }

    // MARK: Sync

    private func poke() {
        debounce?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.sync() }
        debounce = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: w)
    }

    // Reads the log from the cursor, refreshes the affected repos, then acks.
    func sync() {
        guard canRun else { return }
        guard !syncing else { syncAgain = true; return }
        syncing = true
        let api = self.api, start = cursor
        syncQ.async { [weak self] in
            var after = start, events: [RelayEvent] = [], truncated = false, failure: RelayFailure?
            while true {
                switch api.events(after: after) {
                case .failure(let f): failure = f
                case .success(let page):
                    // A new relay starts again at seq 1: read it from the start.
                    if page.head < after { after = 0; truncated = true; continue }
                    events += page.events
                    truncated = truncated || page.truncated
                    after = page.next
                    if page.more { continue }
                }
                break
            }
            DispatchQueue.main.async { self?.apply(events: events, truncated: truncated, upTo: after, failure: failure) }
        }
    }

    private func apply(events: [RelayEvent], truncated: Bool, upTo next: Int, failure: RelayFailure?) {
        if let f = failure {
            syncing = false
            if case .unauthorized = f { state = .error(f.description) }
            log.warning("Relay sync failed: \(f.description, privacy: .public)")
            return
        }
        let fresh = events.filter { !seen.contains($0.deliveryId) }
        if !fresh.isEmpty { lastEventAt = Date() }
        let finish: (Bool) -> Void = { [weak self] ok in
            guard let self = self else { return }
            if ok {
                for e in fresh { self.seen.insert(e.deliveryId) }
                if next != self.cursor {
                    self.cursor = next
                    let api = self.api
                    self.syncQ.async { _ = api.ack(next) }
                }
                self.lastSync = Date()
            }
            self.syncing = false
            if self.syncAgain { self.syncAgain = false; self.sync() }
        }
        if truncated {
            log.info("Relay gap detected, full refresh")
            sink?.relayFullRefresh(done: finish) ?? finish(false)
            return
        }
        guard !fresh.isEmpty else { finish(true); return }
        let plan = relayApplyPlan(fresh, knownRepos: REPOS)
        guard plan.wantsRepoRefresh || plan.wantsProjectRefresh else { finish(true); return }
        guard let sink = sink else { finish(false); return }
        let group = DispatchGroup()
        let lock = NSLock()
        var ok = true
        let note: (Bool) -> Void = { success in
            lock.lock(); ok = ok && success; lock.unlock()
            group.leave()
        }
        if plan.wantsRepoRefresh {
            group.enter()
            log.info("Relay: \(fresh.count) event(s) for \(plan.repos.count) repo(s)")
            sink.relayRefresh(repos: plan.repos, includePRs: plan.includePRs, completedRuns: plan.completedRuns, done: note)
        }
        if plan.wantsProjectRefresh {
            group.enter()
            log.info("Relay: Plane refresh for \(plan.plane.count) project(s)")
            sink.relayProjectRefresh(plan.plane, done: note)
        }
        group.notify(queue: .main) { finish(ok) }
    }

    // Footer dot: colour, tooltip.
    var statusDot: (NSColor, String)? {
        switch state {
        case .off: return nil
        case .live: return isHealthy ? (C_SUCCESS, "Live updates connected") : (.systemGray, "Live updates: waiting for the relay")
        case .connecting: return (.systemGray, "Live updates: connecting, polling meanwhile")
        case .error(let m): return (C_QUEUED, "Relay error: \(m). Polling meanwhile.")
        }
    }
}
