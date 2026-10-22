import Foundation
import OverSireCore

// ─── Machines ────────────────────────────────────────────────────────────────
// The daemons of the group of this user. The app finds them from the local daemon (or from the last group that it
// knows), and makes one MachineLink for each member. The daemon is a sync source like the cloud, not a provider.

/// One daemon that the app reads. The local daemon has no token: it trusts loopback.
public struct MachineLink: Hashable, Sendable {
    public var machine: String
    public var base: URL
    public var token: String?
    public var local: Bool

    public init(machine: String, base: URL, token: String?, local: Bool) {
        self.machine = machine
        self.base = base
        self.token = token
        self.local = local
    }

    public func client(http: any HTTPTransport) -> DaemonClient { DaemonClient(base: base, token: token, http: http) }

    /// The cursor of the event log of this daemon.
    public var cursorKey: String { "daemon:\(machine)" }
}

/// The Keychain items of the app. The app's SecretStore conforms.
public protocol CredentialKeeping: Sendable {
    func get(_ key: String) -> String?
    func set(_ key: String, _ value: String)
}

/// The choices of the user about the machines. config.json keeps them.
public struct MachinesConfig: Codable, Equatable, Sendable {
    public var enabled = true
    /// machine → the Orca account id in this app ("local", "mbp"). An empty id: no Orca account.
    public var runtimeAccounts: [String: String] = [:]
    /// The machines whose sessions the user hides.
    public var muted: Set<String> = []
    /// The answer to "Install agent hooks for live status?". nil: the app did not ask yet.
    public var hooksConsent: Bool?

    public init(enabled: Bool = true, runtimeAccounts: [String: String] = [:], muted: Set<String> = [], hooksConsent: Bool? = nil) {
        self.enabled = enabled
        self.runtimeAccounts = runtimeAccounts
        self.muted = muted
        self.hooksConsent = hooksConsent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        runtimeAccounts = try c.decodeIfPresent([String: String].self, forKey: .runtimeAccounts) ?? [:]
        muted = try c.decodeIfPresent(Set<String>.self, forKey: .muted) ?? []
        hooksConsent = try c.decodeIfPresent(Bool.self, forKey: .hooksConsent)
    }

    /// The Orca account id of the machine: the choice of the user; else "local" for this machine;
    /// else the Orca environment of this app with the machine name. nil: the user must pick one.
    public func runtimeAccount(_ link: MachineLink, environments: [String]) -> String? {
        if let a = runtimeAccounts[link.machine] { return a.isEmpty ? nil : a }
        if link.local { return "local" }
        return environments.first { $0.caseInsensitiveCompare(link.machine) == .orderedSame }
    }

    /// The machine of an Orca account id. The reverse of runtimeAccount.
    public func machine(account: String, links: [MachineLink], environments: [String]) -> String? {
        links.first { runtimeAccount($0, environments: environments) == account }?.machine
    }
}

public actor Machines {
    public static let defaultName = "OverSire on " + (ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "Mac")

    public static func credentialKey(_ group: String) -> String { "daemon.group.\(group)" }

    private let local: DaemonClient
    private let keychain: any CredentialKeeping
    private let http: any HTTPTransport
    private let deviceName: String
    private let cache: URL?
    private var current: [MachineLink] = []
    private var watchers: [UUID: AsyncStream<[MachineLink]>.Continuation] = [:]
    private var loop: Task<Void, Never>?

    /// The local daemon at the last read. nil: no daemon answers on loopback.
    public private(set) var info: DaemonInfo?
    /// The last group that a member gave.
    public private(set) var group: Group?
    /// The time of the last read that got a group or a local daemon.
    public private(set) var checkedAt: Date?

    /// cache: a file that keeps the last group, so an app without a local daemon finds the members after a restart.
    public init(local: DaemonClient, keychain: any CredentialKeeping, http: any HTTPTransport, deviceName: String = Machines.defaultName,
                cache: URL? = nil) {
        self.local = local
        self.keychain = keychain
        self.http = http
        self.deviceName = deviceName
        self.cache = cache
        group = cache.flatMap { try? Data(contentsOf: $0) }.flatMap { try? DaemonClient.decode($0) as Group }
    }

    public func links() -> [MachineLink] { current }

    /// The links now, then each change.
    public func changes() -> AsyncStream<[MachineLink]> {
        let (stream, cont) = AsyncStream.makeStream(of: [MachineLink].self, bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        watchers[id] = cont
        cont.yield(current)
        cont.onTermination = { _ in Task { await self.unwatch(id) } }
        return stream
    }

    private func unwatch(_ id: UUID) { watchers[id] = nil }

    /// Reads the group now and each `every`.
    public func start(every: Duration = .seconds(300), clock: any Clock<Duration> = ContinuousClock()) {
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                await self.refresh()
                try? await clock.sleep(for: every)
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Keeps the credential and the group of a join of this app (kind app). Then reads the group.
    public func joined(_ r: JoinResult) async {
        keychain.set(Self.credentialKey(r.group.id), r.credential.token)
        keep(r.group)
        await refresh()
    }

    /// Reads the local daemon and the group, and makes the links again.
    public func refresh() async {
        if let me = try? await local.whoami() {
            info = me
            checkedAt = Date()
            guard let gid = me.group else { publish([localLink(me.machine.rawValue)]); return }
            let token = await credential(gid)
            if let g = try? await local.group() { keep(g) }
            guard let g = group, g.id == gid else { publish([localLink(me.machine.rawValue)]); return }
            publish(g.members.map { m in
                m.machine == me.machine ? localLink(m.machine.rawValue) : remoteLink(m, token: token)
            }.compactMap { $0 })
            return
        }
        info = nil
        // No local daemon: the first member that answers gives the group.
        guard let known = group, let token = keychain.get(Self.credentialKey(known.id)) else { publish([]); return }
        for m in known.members {
            guard let link = remoteLink(m, token: token), let g = try? await link.client(http: http).group() else { continue }
            keep(g)
            checkedAt = Date()
            break
        }
        publish(group?.members.compactMap { remoteLink($0, token: token) } ?? [])
    }

    /// The credential of the group in the Keychain. The local daemon issues one at the first need.
    private func credential(_ group: String) async -> String? {
        let key = Self.credentialKey(group)
        if let t = keychain.get(key) { return t }
        guard let c = try? await local.issueApp(name: deviceName) else { return nil }
        keychain.set(key, c.token)
        return c.token
    }

    private func localLink(_ machine: String) -> MachineLink {
        MachineLink(machine: machine, base: local.base, token: nil, local: true)
    }

    private func remoteLink(_ m: GroupMember, token: String?) -> MachineLink? {
        guard let token, let url = URL(string: "http://\(m.host):\(m.port)") else { return nil }
        return MachineLink(machine: m.machine.rawValue, base: url, token: token, local: false)
    }

    private func keep(_ g: Group) {
        group = g
        guard let cache else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(g).write(to: cache, options: .atomic)
    }

    private func publish(_ links: [MachineLink]) {
        guard links != current else { return }
        current = links
        for w in watchers.values { w.yield(links) }
    }
}
