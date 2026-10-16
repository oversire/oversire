import Cocoa
import Network
import Security

// ─── Cloud configuration ─────────────────────────────────────────────────────
// Optional push path: GitHub and Plane webhooks → OverSire cloud (oversire/cloud) → this Mac.

struct RelayConfig: Codable {
    var enabled = false
    var workerURL = ""
    var deviceID = ""            // from /v1/whoami; the cloud owns the device tokens
    var reconcileInterval: TimeInterval?
}

var RELAY = RelayConfig()
// v3 is a Cat Eye relay that a migrated user deployed. It has no /v1/whoami.
let CLOUD_MIN_VERSION = 3
let CLOUD_APPS: Set<String> = ["oversire-cloud", "cat-eye-relay"]
let RELAY_EVENTS = ["workflow_run", "workflow_job", "pull_request", "pull_request_review"]
let FREE_ROWS_PER_DAY = 100_000

private let secretPattern = try! NSRegularExpression(pattern: "\\b[0-9a-fA-F]{64}\\b")

// Hides device tokens and the webhook secret (32 random bytes as hex) in log text.
func maskSecrets(_ s: String) -> String {
    secretPattern.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "••••")
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

// ─── Keychain ────────────────────────────────────────────────────────────────

final class SecretStore {
    static let deviceToken = "DEVICE_TOKEN"
    static let webhookSecret = "WEBHOOK_SECRET"
    let service: String

    init(service: String = "com.oversire.app.cloud") { self.service = service }

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

    func keys() -> [String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecReturnAttributes as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
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
        case .notConfigured: return "Cloud is not set up"
        case .unauthorized: return "The cloud rejected the token"
        case .http(let c): return "Cloud answered HTTP \(c)"
        case .network(let m): return m
        case .decode: return "Unexpected cloud response"
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
    struct WhoAmI: Decodable { let deviceId: String }

    func discover() -> Discovery? {
        guard case .success(let d) = send("GET", "/", as: Discovery.self), CLOUD_APPS.contains(d.app) else { return nil }
        return d
    }
    func whoami() -> Result<WhoAmI, RelayFailure> { send("GET", "/v1/whoami") }
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

    func delete(repo: String, hookId: Int) -> Bool {
        let ok = gh(["api", "-X", "DELETE", "repos/\(repo)/hooks/\(hookId)"])?.ok == true
        lock.lock(); _statuses[repo] = nil; lock.unlock()
        return ok
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

// ─── Cloud setup: connect, hooks, retention, devices ─────────────────────────
// The cloud repo deploys the Worker and issues device tokens. This Mac only connects.

struct SetupState {
    var version: Int?
    var joined = false
    var joinError: String?
    var health: RelayHealth?

    var tooOld: Bool { version.map { $0 < CLOUD_MIN_VERSION } ?? false }
}

final class CloudSetup {
    let secrets = SecretStore()
    let hooks = HookManager()
    private let work = DispatchQueue(label: "com.oversire.app.cloud.setup")

    // Main thread only.
    private(set) var log: [String] = []
    private(set) var busy: String?
    private(set) var state = SetupState()
    var onChange: (() -> Void)?
    var onLog: (() -> Void)?

    var api: RelayAPI { RelayAPI(base: RELAY.workerURL, token: secrets.get(SecretStore.deviceToken)) }

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

    // Blocking.
    func inspect() -> SetupState {
        var s = SetupState()
        guard !RELAY.workerURL.isEmpty else { return s }
        s.version = api.discover().flatMap { Int($0.version ?? "") }
        switch api.health() {
        case .success(let h): s.joined = true; s.health = h
        case .failure(let f): s.joinError = secrets.get(SecretStore.deviceToken) == nil ? nil : f.description
        }
        return s
    }

    func refreshState(then: (() -> Void)? = nil) {
        work.async {
            let s = self.inspect()
            DispatchQueue.main.async { self.state = s; self.onChange?(); then?() }
        }
    }

    // MARK: Connect

    static func normalize(_ url: String) -> String? {
        var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while u.hasSuffix("/") { u.removeLast() }
        if !u.contains("://") { u = "https://" + u }
        guard let c = URLComponents(string: u), c.scheme == "https", let h = c.host, !h.isEmpty else { return nil }
        return u
    }

    // Checks the URL and the token, then registers this Mac. Blocking.
    func connect(url raw: String, token: String) -> Bool {
        guard let url = CloudSetup.normalize(raw) else { append("Enter an https URL"); return false }
        let open = RelayAPI(base: url, token: nil)
        guard let d = open.discover() else { append("No OverSire cloud answers at \(url)"); return false }
        guard Int(d.version ?? "") ?? 0 >= CLOUD_MIN_VERSION else { append("The cloud at \(url) is too old"); return false }
        let api = RelayAPI(base: url, token: token)
        var id = onMain { RELAY.deviceID }
        switch api.whoami() {
        case .success(let w): id = w.deviceId
        case .failure(.unauthorized): append("The cloud rejected the token"); return false
        case .failure(let f):
            // A v3 relay has no whoami. Its health call still checks the token.
            if case .failure(let h) = api.health() { append(h.description); return false }
            if id.isEmpty { append("Device ID unknown (\(f.description)). Hooks of other Macs stay.") }
        }
        secrets.set(SecretStore.deviceToken, token)
        onMain { RELAY.workerURL = url; RELAY.deviceID = id; RELAY.enabled = true; saveConfig() }
        if case .failure(let f) = api.registerSelf(name: Host.current().localizedName ?? "Mac", repos: onMain { REPOS }, orgs: trackedOrgs()) {
            append("Register this Mac: \(f.description)"); return false
        }
        if let s = api.webhookSecret() { secrets.set(SecretStore.webhookSecret, s) }
        return true
    }

    // Removes this Mac's token and settings. The hooks stay, because other Macs can use them.
    func disconnect() {
        secrets.delete(SecretStore.deviceToken)
        secrets.delete(SecretStore.webhookSecret)
        UserDefaults.standard.removeObject(forKey: "relayCursor")
        RELAY = RelayConfig()
        saveConfig()
        state = SetupState()
        onChange?()
    }

    // MARK: Hooks

    // Repos with a hook on the cloud. Nil until the first health read. Main thread only.
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

    // Plane workspaces register as "plane:<slug>". The cloud sends them to this Mac only.
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
        guard case .success(let h) = api.health() else { append("Cloud health check failed"); return false }
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
    // Without a device ID every device counts as another Mac, so nothing is deleted.
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

    // The token of the device stays valid until the cloud deletes its DEVICE_<id> secret.
    func removeDevice(_ id: String) -> Bool { api.removeDevice(id) }

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
