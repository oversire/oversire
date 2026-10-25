import Cocoa
import OverSireCore
import OverSireSync

// ─── Settings › Machines ─────────────────────────────────────────────────────
// The daemon on this Mac, the machines of the group, the members found on the tailnet, and the agent hooks.

/// What the page reads from the daemons.
struct MachinesSnapshot: Equatable {
    /// The oversire CLI is at `path`.
    var installed = false
    var path = "~/.local/bin/oversire"
    /// The login shell finds an `oversire` command.
    var onPath = true
    /// The version of the latest CLI release. nil: not known.
    var latest: String?
    /// The local daemon. nil: no daemon answers on loopback.
    var info: DaemonInfo?
    var group: Group?
    var peers: [DaemonInfo] = []
    var hooks: [HarnessHooks] = []
    /// machine → its sessions. A machine without an entry has no count.
    var sessions: [String: [DaemonSession]] = [:]
    var health: [String: SourceHealth] = [:]
    /// machine → its agent runtimes. A machine without an entry gave no answer.
    var runtimes: [String: [DaemonRuntime]] = [:]
    /// The role of this app for the automations. nil: no automation owner.
    var automations: AutomationRole?
}

/// The rows of the page. It has no AppKit types, so tests compare it.
struct MachinesModel: Equatable {
    enum State: Equatable { case noDaemon, solo, group }

    struct Machine: Equatable {
        var name: String
        var host: String
        var isThis: Bool
        var home: Bool
        var runner: Bool
        var online: Bool
        /// "Online", or "Offline · 2 h ago".
        var status: String
        var sessions: Int
        var waiting: Int
        /// The machine runs the agent sessions of Work and Intake.
        var runsSessions: Bool
        var muted: Bool
        /// The CLI version. nil: not known, a CLI before 0.2.2.
        var version: String?
        /// The machine runs an older CLI than the newest in the group or on GitHub.
        var behind: Bool

        var hostText: String { "\(host) · oversire \(version ?? "before 0.2.2")" }

        var sessionsText: String {
            let n = sessions == 0 ? "No sessions" : sessions == 1 ? "1 session" : "\(sessions) sessions"
            return waiting > 0 ? "\(n) · \(waiting) waiting" : n
        }
    }

    struct Found: Equatable {
        var info: DaemonInfo
        var name: String { info.machine.rawValue }
        var detail: String { "\(info.listen.tailscale ?? name) · oversire \(info.version)" }
    }

    struct Hook: Equatable {
        enum Action: Equatable { case install, remove, none }
        var name: String
        var title: String
        var note: String
        var state: HarnessHooks.State
        var action: Action

        var status: String {
            switch state {
            case .installed: return "Installed"
            case .untrusted: return "Needs approval in \(title)"
            case .missing: return "Not installed"
            case .outdated: return "Old version"
            case .unsupported: return "No hooks"
            }
        }
    }

    /// One agent runtime of one machine, with the state of its live session view.
    struct Runtime: Equatable {
        enum State: Equatable { case live, textOnly, connecting, running, down, missing }
        var machine: String
        var id: String
        var name: String
        var version: String?
        var state: State
        /// Why the runtime has this state. nil: no reason.
        var note: String?
        /// The runtime takes a pairing link for its live view.
        var pairable = false
        var paired = false

        init(machine: String, _ r: DaemonRuntime) {
            self.machine = machine
            id = r.id
            name = r.name
            version = r.version
            if !r.installed {
                state = .missing
                note = "The daemon found no \(r.name) on \(machine)."
            } else if !r.reachable {
                state = .down
                note = r.error
            } else {
                switch r.stream?.state {
                case .live?: state = .live
                case .textOnly?: state = .textOnly
                case .pairing?: state = .connecting
                case nil: state = .running
                }
                note = r.stream?.reason
                pairable = r.stream?.pairable == true
                paired = r.stream?.paired == true
            }
        }

        var key: String { "\(machine)/\(id)" }
        var title: String { "\(name) on \(machine)" }
        var detail: String { [version.map { "\(name) \($0)" }, note].compactMap { $0 }.joined(separator: " · ") }

        var status: String {
            switch state {
            case .live: return "Live"
            case .textOnly: return "Text only"
            case .connecting: return "Connecting"
            case .running: return "Running"
            case .down: return "Not running"
            case .missing: return "Not installed"
            }
        }

        /// Retry connects the live view again, or probes a runtime that did not answer. A runtime with no pairing needs Pair first.
        var canRetry: Bool { state == .down || state == .textOnly && (!pairable || paired) }
        var canPair: Bool { pairable && state == .textOnly }
        var canUnpair: Bool { paired && state == .live }
    }

    /// The Automations row: which Mac runs the automatic actions (OVERSIRE-328).
    struct Automations: Equatable {
        enum State: Equatable { case here, other(String), paused(home: String) }
        var state: State

        static let note = "Auto start, Enhance, cleanup, Plane write-back and AI digests run on one Mac only. The other Macs show the results."

        /// home: the home of the group, for a pause before the first read.
        init(_ r: AutomationRole, home: String) {
            switch r {
            case .solo, .owner: state = .here
            case .other(let l): state = .other(l.holderName.isEmpty ? l.holder : l.holderName)
            case .paused(let m): state = .paused(home: m.isEmpty ? home : m)
            }
        }

        var detail: String {
            guard case .paused(let h) = state else { return Self.note }
            return "Paused, so that two Macs do not do the same work. They start again when \(h), the home, is online."
        }

        var status: String {
            switch state {
            case .here: return "Run on this Mac"
            case .other(let m): return "Run on \(m)"
            case .paused: return "Paused · home offline"
            }
        }

        /// "Run them here" or "Retry". nil: no button.
        var action: String? {
            switch state {
            case .here: return nil
            case .other: return "Run them here"
            case .paused: return "Retry"
            }
        }
    }

    var state: State
    var groupName: String
    var machines: [Machine]
    var found: [Found]
    var hooks: [Hook]
    var daemon: DaemonInfo?
    var installed: Bool
    var path: String
    var onPath: Bool
    /// A newer CLI release than the local daemon.
    var update: String?
    /// The last self-update check of the local daemon.
    var updateStatus: DaemonUpdate?
    /// The machines run different CLI versions. nil: one version.
    var mismatch: String?
    /// The machines that can run the sessions, this Mac first.
    var sessionChoices: [String]
    /// The machine that runs the sessions. nil: none of the list (no daemon on this Mac, or a removed machine).
    var sessionsMachine: String?
    /// The runtimes of each machine that answered, in the order of the machines.
    var runtimes: [Runtime]
    /// nil: the group has one member, or the app has no automation owner.
    var automations: Automations?

    var title: String {
        switch state {
        case .noDaemon, .group: return "\(groupName) · \(machines.count)"
        case .solo: return "\(groupName) · this Mac only"
        }
    }

    /// Hooks that the consent installs.
    var missingHooks: [String] { hooks.filter { $0.state == .missing || $0.state == .outdated }.map(\.name) }

    init(_ s: MachinesSnapshot, config: MachinesConfig, now: Date = Date()) {
        daemon = s.info
        installed = s.installed
        path = s.path
        onPath = s.onPath
        if let l = s.latest, let v = s.info?.version, Updater.isNewer(l, than: v) { update = l } else { update = nil }
        updateStatus = s.info?.update
        let me = s.info?.machine.rawValue
        let members = s.group?.members ?? []
        if s.info == nil { state = .noDaemon } else { state = members.count > 1 ? .group : .solo }
        groupName = s.group?.name ?? "My machines"
        var list = members
        if list.isEmpty, let i = s.info {
            list = [GroupMember(machine: i.machine, host: i.machine.rawValue, addrs: i.listen.tailscale.map { [$0] } ?? [], port: 7690,
                                roles: i.roles, joinedAt: now)]
        }
        machines = list.map { m in
            let name = m.machine.rawValue
            let isThis = name == me
            let online: Bool
            switch s.health[name] {
            case .live?: online = true
            case nil: online = isThis || (m.lastSeen.map { now.timeIntervalSince($0) < 300 } ?? false)
            default: online = isThis && s.info != nil
            }
            let active = (s.sessions[name] ?? []).filter { [.starting, .working, .waiting].contains($0.state) }
            let runs = config.sessions.map { $0 == name } ?? isThis
            let addr = m.addrs.first ?? m.host
            let version = isThis ? s.info?.version ?? m.version : m.version
            return Machine(name: name, host: m.port == 7690 || addr.contains(":") ? addr : "\(addr):\(m.port)", isThis: isThis,
                           home: s.group?.home == m.machine || (s.group == nil && isThis), runner: m.roles.contains("runner"), online: online,
                           status: online ? "Online" : Self.offline(m.lastSeen, now: now), sessions: active.count,
                           waiting: active.filter { $0.state == .waiting }.count, runsSessions: runs, muted: config.muted.contains(name),
                           version: version, behind: false)
        }
        let newest = ([s.latest] + machines.map(\.version)).compactMap { $0 }.max { Updater.isNewer($1, than: $0) }
        if let newest {
            for i in machines.indices { machines[i].behind = machines[i].version.map { Updater.isNewer(newest, than: $0) } ?? true }
        }
        if machines.count > 1, Set(machines.map { $0.version ?? "" }).count > 1 {
            let list = machines.map { "\($0.name) \($0.version ?? "before 0.2.2")" }.joined(separator: ", ")
            mismatch = "Your machines run different oversire versions: \(list). Update the older ones, so that all machines speak the same API."
        } else {
            mismatch = nil
        }
        let known = Set(members.map(\.machine))
        found = state == .solo
            ? s.peers.filter { $0.machine.rawValue != me && !known.contains($0.machine) }.map(Found.init)
            : []
        hooks = s.info == nil ? [] : s.hooks.map(Self.hook)
        sessionChoices = machines.filter(\.isThis).map(\.name) + machines.filter { !$0.isThis }.map(\.name)
        sessionsMachine = machines.first(where: \.runsSessions)?.name
        runtimes = machines.flatMap { m in (s.runtimes[m.name] ?? []).map { Runtime(machine: m.name, $0) } }
        automations = state == .group ? s.automations.map { Automations($0, home: s.group?.home.rawValue ?? "") } : nil
    }

    static func offline(_ seen: Date?, now: Date) -> String {
        guard let seen else { return "Offline" }
        return "Offline · \(ago(seen, now: now))"
    }

    static func ago(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        return s < 3600 ? "\(max(1, Int(s / 60))) min ago" : s < 172_800 ? "\(Int(s / 3600)) h ago" : "\(Int(s / 86400)) d ago"
    }

    /// The note of the Updates row.
    func updateNote(now: Date = Date()) -> String {
        guard let u = updateStatus else { return "The daemon checks GitHub each 6 hours. No check yet." }
        if let e = u.error { return "The last update failed \(Self.ago(u.checkedAt, now: now)): \(e)" }
        return "The daemon checks GitHub each 6 hours. Last check \(Self.ago(u.checkedAt, now: now)): latest \(u.latest ?? "not known")."
    }

    static func hook(_ h: HarnessHooks) -> Hook {
        let titles = ["claude": "Claude Code", "codex": "Codex", "opencode": "OpenCode", "pi": "pi", "copilot": "Copilot",
                      "cursor": "Cursor", "gemini": "Gemini"]
        let files = ["claude": "~/.claude/settings.json", "codex": "~/.codex/hooks.json"]
        let title = titles[h.name] ?? h.name.prefix(1).uppercased() + h.name.dropFirst()
        switch h.hooks {
        case .installed: return Hook(name: h.name, title: title, note: files[h.name] ?? "Hooks installed", state: .installed, action: .remove)
        case .untrusted:
            return Hook(name: h.name, title: title, note: "\(title) asks you to trust new hooks. Open \(title) and approve them once.",
                        state: .untrusted, action: .remove)
        case .missing: return Hook(name: h.name, title: title, note: "No hooks. Orca state only, about each 20 s.", state: .missing, action: .install)
        case .outdated: return Hook(name: h.name, title: title, note: "Install again to get the new hook entries.", state: .outdated, action: .install)
        case .unsupported: return Hook(name: h.name, title: title, note: "\(title) has no hooks. Orca state only.", state: .unsupported, action: .none)
        }
    }
}

/// Reads the daemons for the page and runs its actions. Main thread only.
final class MachinesController {
    static let shared = MachinesController()

    weak var hub: MachineHub?
    var local = DaemonClient(base: DaemonClient.loopback, token: nil, http: URLSessionTransport())
    var installed: () -> Bool = { DaemonSetup.shared.installer.isInstalled }
    var path: () -> String = { (DaemonSetup.shared.installer.exe.path as NSString).abbreviatingWithTildeInPath }
    /// One HEAD request to github.com. The page asks at most once in one hour.
    var latest: () async -> String? = { try? await DaemonSetup.shared.installer.latest().version }
    private var latestAt: Date?
    private var latestVersion: String?
    var onPath: () async -> Bool = {
        let i = DaemonSetup.shared.installer
        if i.onPath { return true }
        return await i.shellFinds()
    }
    var config: () -> MachinesConfig = { MACHINES }
    /// The automation owner of the app. nil: no group sync.
    var owner: () -> AutomationOwner? = { (NSApp?.delegate as? GHActionsBar)?.automations }
    var changed: () -> Void = { ChangeBus.shared.post(DataChange(.connection, origin: .user)) }

    static let loadingChanged = Notification.Name("MachinesLoading")

    private(set) var snapshot = MachinesSnapshot()
    private(set) var loadedAt: Date?
    private(set) var loading = false { didSet { NotificationCenter.default.post(name: Self.loadingChanged, object: self) } }
    /// True until the first read ends. The page shows rows that load, not "no daemon".
    var reading: Bool { loadedAt == nil }
    /// The last error of an action. The page shows it once.
    var notice: String?
    /// The machines that run POST /v1/update now.
    private(set) var updating: Set<String> = []
    /// The runtimes with a retry, pair or unpair call now: Runtime.key → the verb.
    private(set) var runtimeCalls: [String: String] = [:]
    /// The verb of the Automations call now: "Run them here" or "Retry".
    private(set) var automationCall: String?
    /// The daemon of a machine: loopback for this Mac, else the link of the hub. nil: no link.
    lazy var daemon: (String) -> DaemonClient? = { [unowned self] name in
        if name == self.snapshot.info?.machine.rawValue { return self.local }
        guard let hub = self.hub, let l = hub.links.first(where: { $0.machine == name && !$0.local }) else { return nil }
        return l.client(http: hub.http)
    }
    /// The wait for the restart of a daemon after an install.
    var restartWait: UInt64 = 3_000_000_000
    /// `--uishots` and tests: a fixed snapshot. load() does nothing.
    var frozen = false
    private var setupObserver: Any?

    /// The role of the automations is live, not part of the last read.
    var model: MachinesModel {
        var s = snapshot
        if let o = owner() { s.automations = o.role }
        return MachinesModel(s, config: config())
    }
    var busy: Bool { DaemonSetup.shared.busy }

    /// Reads again when the data is older than 20 s.
    func loadIfStale() {
        guard !frozen, !loading, loadedAt.map({ Date().timeIntervalSince($0) > 20 }) ?? true else { return }
        Task { @MainActor in await self.load() }
    }

    @MainActor func load() async {
        guard !frozen else { return }
        loading = true
        defer { loading = false }
        var s = MachinesSnapshot()
        s.installed = installed()
        s.path = path()
        if s.installed { s.onPath = await onPath() }
        if latestAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true, let v = await latest() {
            latestVersion = v
            latestAt = Date()
        }
        s.latest = latestVersion
        s.info = try? await local.whoami()
        if s.info != nil { s.group = try? await local.group() } else if let hub { s.group = await hub.machines.group }
        if let me = s.info {
            if (s.group?.members.count ?? 0) <= 1 { s.peers = (try? await local.peers()) ?? [] }
            s.hooks = (try? await local.hookState()) ?? me.harnesses
            if let list = try? await local.sessions() { s.sessions[me.machine.rawValue] = list.sessions }
            if let page = try? await local.runtimes() { s.runtimes[me.machine.rawValue] = page.runtimes }
            await hub?.approvals.sync()
        }
        if let hub {
            s.health = hub.health
            for l in hub.links where !l.local && hub.isLive(l.machine) {
                let client = l.client(http: hub.http)
                if let list = try? await client.sessions() { s.sessions[l.machine] = list.sessions }
                if let page = try? await client.runtimes() { s.runtimes[l.machine] = page.runtimes }
            }
        }
        snapshot = s
        loadedAt = Date()
        changed()
    }

    /// For tests and `--uishots`. loaded false: the first read did not end.
    func use(_ s: MachinesSnapshot, loaded: Bool = true) {
        snapshot = s
        loadedAt = loaded ? Date() : nil
    }

    /// op can give a warning for the page.
    private func run(_ what: String, _ op: @escaping () async throws -> String?) {
        Task { @MainActor in await self.call(what) { _ in try await op() } }
    }

    /// Runs one daemon call, shows its warning or error on the page and reloads. Gives the error text.
    @MainActor @discardableResult
    func call(_ what: String, _ op: @escaping (DaemonClient) async throws -> String?) async -> String? {
        var failed: String?
        do { if let w = try await op(local) { notice = w } } catch {
            failed = "\(what): \(DaemonClient.reason(error))"
            notice = failed
            log.error("Machines: \(failed ?? "", privacy: .public)")
        }
        hub?.refresh()
        await load()
        return failed
    }

    // MARK: Actions

    func install() {
        if setupObserver == nil {
            setupObserver = NotificationCenter.default.addObserver(forName: DaemonSetup.changed, object: nil, queue: .main) { [weak self] _ in
                self?.notice = DaemonSetup.shared.error
                self?.changed()
                if !DaemonSetup.shared.busy { Task { @MainActor in await self?.load(); self?.hub?.refresh() } }
            }
        }
        DaemonSetup.shared.install(keepAwake: false, pair: false)
        changed()
    }

    func invite(done: @escaping (GroupInvite) -> Void) {
        let local = local
        Task { @MainActor in
            do { done(try await local.invite()) } catch {
                self.notice = "Add machine: \(DaemonClient.reason(error))"
                self.changed()
            }
        }
    }

    /// The daemon of machine checks GitHub and installs a newer CLI now. A CLI before 0.2.2 has no route:
    /// on this Mac the app installs the CLI, on another machine the page tells what to do.
    func update(_ machine: String) {
        guard !updating.contains(machine) else { return }
        let isThis = machine == snapshot.info?.machine.rawValue
        guard let client = daemon(machine) else {
            notice = "Update \(machine): OverSire has no link to \(machine). Check that it is online."
            changed()
            return
        }
        updating.insert(machine)
        changed()
        Task { @MainActor in
            var installed = false
            do {
                let s = try await client.update()
                if let e = s.error { self.notice = "Update \(machine): \(e)" }
                installed = s.installed != nil
            } catch ProviderError.notFound {
                if isThis {
                    self.updating.remove(machine)
                    self.install()
                    return
                }
                self.notice = "Update \(machine): it runs a CLI before 0.2.2, which cannot update from here. "
                    + "Open OverSire on \(machine) and use Update in Settings › Machines."
            } catch {
                self.notice = "Update \(machine): \(DaemonClient.reason(error))"
            }
            if installed { try? await Task.sleep(nanoseconds: self.restartWait) }
            self.updating.remove(machine)
            self.hub?.refresh()
            await self.load()
        }
    }

    /// The daemon of machine connects the live view of the runtime again and gives its new state. done runs after a success.
    func retry(_ machine: String, runtime id: String, done: (() -> Void)? = nil) {
        runtimeCall("Retry", machine, id, done: done) { try await $0.retryRuntime(id) }
    }

    /// The link holds a device token. It goes only in the body of the request.
    func pair(_ machine: String, runtime id: String, link: String) {
        runtimeCall("Pair", machine, id) { try await $0.pairRuntime(id, link: link) }
    }

    func unpair(_ machine: String, runtime id: String) {
        runtimeCall("Unpair", machine, id) { try await $0.unpairRuntime(id) }
    }

    private func runtimeCall(_ verb: String, _ machine: String, _ id: String, done: (() -> Void)? = nil,
                             _ call: @escaping (DaemonClient) async throws -> DaemonRuntime) {
        let key = "\(machine)/\(id)"
        guard runtimeCalls[key] == nil else { return }
        guard let client = daemon(machine) else {
            notice = "\(verb) \(id) on \(machine): OverSire has no link to \(machine). Check that it is online."
            changed()
            return
        }
        runtimeCalls[key] = verb
        changed()
        Task { @MainActor in
            do {
                let d = try await call(client)
                if let i = self.snapshot.runtimes[machine]?.firstIndex(where: { $0.id == id }) { self.snapshot.runtimes[machine]?[i] = d }
                done?()
            } catch {
                self.notice = "\(verb) \(id) on \(machine): \(DaemonClient.reason(error))"
            }
            self.runtimeCalls[key] = nil
            self.changed()
        }
    }

    /// Run them here: this app takes the lease from the other app.
    func takeAutomations() { automationCall("Run them here") { await $0.take() } }

    /// Asks the home daemon again after a pause.
    func retryAutomations() { automationCall("Retry") { await $0.refresh() } }

    private func automationCall(_ verb: String, _ op: @escaping (AutomationOwner) async -> Void) {
        guard automationCall == nil, let o = owner() else { return }
        automationCall = verb
        changed()
        Task { @MainActor in
            await op(o)
            self.automationCall = nil
            self.changed()
        }
    }

    /// Updates each machine that runs an older CLI and that the page can reach.
    func updateAll() {
        for m in model.machines where m.behind && (m.isThis || m.online) { update(m.name) }
    }

    /// Asks for the admin password when root owns /usr/local/bin.
    func linkOnPath() { run("Add to PATH") { try await DaemonSetup.shared.installer.linkOnPath(); return nil } }

    func setHome(_ machine: String) { let l = local; run("Make home") { try await l.setHome(machine).warning } }
    func remove(_ machine: String) { let l = local; run("Remove \(machine)") { try await l.remove(machine); return nil } }
    func installHooks(_ names: [String]) { let l = local; run("Install hooks") { _ = try await l.hooks(install: names); return nil } }
    func removeHooks(_ names: [String]) { let l = local; run("Remove hooks") { _ = try await l.removeHooks(names); return nil } }

    func setMuted(_ machine: String, _ on: Bool) {
        if on { MACHINES.muted.insert(machine) } else { MACHINES.muted.remove(machine) }
        configChanged()
    }

    /// The machine that runs the agent sessions. This Mac is the default, kept as nil.
    func setSessions(_ machine: String) {
        MACHINES.sessions = machine == snapshot.info?.machine.rawValue ? nil : machine
        configChanged()
    }

    /// The answer to the hooks question. Yes installs the hooks that are missing.
    func consent(_ yes: Bool) {
        MACHINES.hooksConsent = yes
        saveConfig()
        if yes { installHooks(model.missingHooks) } else { changed() }
    }

    /// The page asks once, when the daemon runs and a hook is missing.
    var wantsConsent: Bool { !frozen && config().hooksConsent == nil && snapshot.info != nil && !model.missingHooks.isEmpty }

    private func configChanged() {
        saveConfig()
        hub?.onLinks()
        changed()
    }
}

// MARK: Page

extension SettingsPage {
    func machines(_ b: NSStackView) {
        let c = MachinesController.shared
        c.loadIfStale()
        let m = c.model
        b.addFull(NSTextField.text("The Macs and boxes that run your agents. OverSire gets live session state from the daemon on each one.",
                                   size: 12.5, color: Palette.dim, lines: 2))
        if let n = c.notice {
            b.addFull(Banner(.warning, title: n, actions: [ActionButton("Dismiss") { [weak self] in c.notice = nil; self?.reload() }]))
        }
        if c.reading { machineReading(b); return }
        if m.state == .noDaemon { machineSetup(b, m) }
        if m.state == .solo && !m.found.isEmpty { machineFound(b, m) }
        if m.state != .noDaemon || !m.machines.isEmpty { machineList(b, m) }
        machineRuntimes(b, m)
        if m.state != .noDaemon { machineHooks(b, m); machineDaemon(b, m) }
        if c.wantsConsent, MachineSheets.open == nil {
            DispatchQueue.main.async { [weak self] in
                guard let w = self?.view.window, MachineSheets.open == nil, c.wantsConsent else { return }
                MachineSheets.consent(over: w) { c.consent($0) }
            }
        }
    }

    private static let runSessionsNote = "Work, Intake and cleanup use the agent sessions of this machine. Each machine gives its questions."

    // The first read: gray rows, not the setup card, so the page does not say "no daemon" for a short time.
    private func machineReading(_ b: NSStackView) {
        let head = NSStackView(h: [Spinner(size: .mini), NSTextField.text("Reading the daemons…", size: 11.5, color: Palette.dim)], spacing: 6)
        let v = NSStackView(v: [SectionTitle(SettingsAnchor.machines.title, action: head)], spacing: 6)
        let card = ListCard()
        for w: CGFloat in [110, 80] {
            card.add(Row([Skeleton(width: 16, height: 16), NSStackView(v: [Skeleton(width: w), Skeleton(width: 150, height: 8)], spacing: 6),
                          Spacer(), Skeleton(width: 64, height: 18)], height: 54, label: "Machine, loading"))
        }
        let pop = PopUp(["Loading…"], selected: 0, label: "Run sessions on") { _ in }
        pop.isEnabled = false
        card.add(Row([TwoLine("Run sessions on", Self.runSessionsNote, lines: 2), Spacer(), pop], height: 62, label: "Run sessions on, loading"))
        v.addFull(card)
        v.identifier = SettingsAnchor.machines.id
        b.addFull(v)
    }

    private func machineSetup(_ b: NSStackView, _ m: MachinesModel) {
        let busy = MachinesController.shared.busy
        let install = ActionButton(busy ? "Installing…" : m.installed ? "Install again" : "Install", style: .primary) {
            MachinesController.shared.install()
        }
        install.isEnabled = !busy
        let note = m.installed
            ? "The oversire CLI is at \(m.path), but the daemon does not answer on loopback :7690."
            : "The daemon sends session state the moment an agent stops or asks a question. Without it, OverSire shows no agent sessions."
        let text = NSStackView(v: [NSTextField.text("Run the OverSire daemon on this Mac", size: 13.5, weight: .semibold),
                                   NSTextField.text(note, size: 12, color: Palette.dim, lines: 3),
                                   NSTextField.text("Installs \(m.path) from the GitHub release, checks the signature, then runs oversire daemon install. No password.",
                                                    size: 11.5, color: Palette.dim, lines: 3, mono: true)], spacing: 5)
        text.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(h: [Glyph("desktopcomputer", color: Palette.mut, size: 18), text, install], spacing: 14, align: .top)
        b.addFull(section(.thisMac, [Padded(row, vertical: 16, side: 16)]))
        b.addFull(section(.joinOnly, [Row([TwoLine("Join with code",
                                                    "For a Mac that only shows the agents of other machines. Get the code from \"Add machine\" on a member.",
                                                    lines: 2), Spacer(), joinCodeButton(.plain)], height: 66, label: "Join with code")]))
    }

    private func machineFound(_ b: NSStackView, _ m: MachinesModel) {
        let rows: [NSView] = m.found.enumerated().map { i, f in
            Row([Glyph(f.info.roles.contains("runner") ? "server.rack" : "laptopcomputer", color: Palette.mut, size: 16),
                 TwoLine(f.name, f.detail), Spacer(),
                 ActionButton("Join", style: i == 0 ? .primary : .plain) { [weak self] in self?.ask(f.info) }],
                height: 52, label: "Found \(f.name)")
        }
        let v = NSStackView(v: [SectionTitle(SettingsAnchor.found.title)], spacing: 6)
        let card = ListCard()
        rows.forEach { card.add($0) }
        v.addFull(card)
        v.addFull(NSTextField.text("Join sends a request. A member approves it once. After that, this Mac sees all members.",
                                   size: 11.5, color: Palette.dim, lines: 2))
        v.identifier = SettingsAnchor.found.id
        b.addFull(v)
    }

    private func machineList(_ b: NSStackView, _ m: MachinesModel) {
        let c = MachinesController.shared
        let canEdit = m.daemon != nil
        var actions: [NSView] = [joinCodeButton(.link)]
        if canEdit { actions.append(ActionButton("Add machine…") { [weak self] in self?.addMachine() }) }
        // A later read keeps the list and shows only this spinner.
        actions.insert(NotifiedView(MachinesController.loadingChanged, object: c) {
            guard c.loading else { return NSStackView(h: [], spacing: 0) }
            let s = Spinner(size: .mini)
            s.toolTip = "Reading the daemons…"
            s.setAccessibilityLabel("Reading the daemons")
            return s
        }, at: 0)
        let v = NSStackView(v: [SectionTitle(m.title, action: NSStackView(h: actions, spacing: 10))], spacing: 6)
        if let text = m.mismatch {
            let all = ActionButton("Update all") { c.updateAll() }
            all.isEnabled = m.machines.contains { $0.behind && ($0.isThis || $0.online) && !c.updating.contains($0.name) }
            v.addFull(Banner(.warning, title: "Different oversire versions", body: text, actions: [all]))
        }
        let card = ListCard()
        for x in m.machines {
            var badges: [NSView] = [NSTextField.text(x.name, size: 13, weight: .medium)]
            if x.isThis { badges.append(NSTextField.text("this Mac", size: 11.5, color: Palette.dim)) }
            if x.home { badges.append(Chiplet("HOME")) }
            if x.runner { badges.append(Chiplet("RUNNER")) }
            if x.muted { badges.append(Chiplet("MUTED", symbol: "speaker.slash")) }
            if x.runsSessions { badges.append(Chiplet("SESSIONS", symbol: "terminal")) }
            let name = NSStackView(v: [NSStackView(h: badges, spacing: 6),
                                       NSTextField.text(x.hostText, size: 11.5, color: Palette.dim, mono: true)], spacing: 3)
            name.setContentHuggingPriority(.init(1), for: .horizontal)
            let status = Pill(Tone(symbol: x.online ? "circle.fill" : "circle", color: x.online ? Palette.ok : Palette.dim, word: x.status))
            let sessions = Pill(x.waiting > 0 ? Tone(symbol: "exclamationmark.circle.fill", color: Palette.warn, word: x.sessionsText)
                                              : Tone(symbol: "terminal", color: Palette.dim, word: x.sessionsText))
            let more = IconButton("ellipsis.circle", label: "More for \(x.name)", tip: "Make home · Mute sessions · Remove…")
            let menu = NSMenu()
            let home = SnapMenuItem(title: "Make home") { c.setHome(x.name) }
            home.isEnabled = canEdit && !x.home
            menu.autoenablesItems = false
            menu.addItem(home)
            let mute = SnapMenuItem(title: "Mute sessions") { c.setMuted(x.name, !x.muted) }
            mute.state = x.muted ? .on : .off
            menu.addItem(mute)
            menu.addItem(.separator())
            let remove = SnapMenuItem(title: "Remove…") { [weak self] in self?.confirmRemove(x.name, group: m.groupName) }
            remove.isEnabled = canEdit && !x.isThis
            menu.addItem(remove)
            more.menu = menu
            more.target = MenuOpener.shared
            more.action = #selector(MenuOpener.open(_:))
            var cells: [NSView] = [Glyph(x.runner && !x.isThis ? "server.rack" : "laptopcomputer", color: Palette.mut, size: 16), name, Spacer(),
                                   status, sessions]
            // This Mac updates from the Daemon section.
            if x.behind && !x.isThis && x.online {
                let busy = c.updating.contains(x.name)
                let up = ActionButton(busy ? "Updating…" : "Update") { c.update(x.name) }
                up.isEnabled = !busy
                up.setAccessibilityLabel("Update oversire on \(x.name)")
                cells.append(up)
            }
            card.add(Row(cells + [more], height: 54,
                         label: "\(x.name), \(x.status), \(x.sessionsText), oversire \(x.version ?? "before 0.2.2")\(x.behind ? ", older version" : "")\(x.home ? ", home" : "")\(x.runsSessions ? ", runs the sessions" : "")"))
        }
        if !m.sessionChoices.isEmpty {
            let titles = m.sessionChoices.map { n in m.machines.first { $0.name == n }?.isThis == true ? "\(n) (this Mac)" : n }
            let picked = m.sessionsMachine.flatMap { m.sessionChoices.firstIndex(of: $0) }
            let pop = PopUp(titles + (picked == nil ? ["None"] : []), selected: picked ?? titles.count, label: "Run sessions on") { i in
                if i < m.sessionChoices.count { c.setSessions(m.sessionChoices[i]) }
            }
            card.add(Row([TwoLine("Run sessions on", Self.runSessionsNote, lines: 2), Spacer(), pop], height: 62, label: "Run sessions on"))
        }
        if let a = m.automations { card.add(automationsRow(a)) }
        v.addFull(card)
        v.addFull(NSTextField.text("Home keeps the shared OverSire state. Use the row menu to make another machine home.",
                                   size: 11.5, color: Palette.dim, lines: 2))
        v.identifier = SettingsAnchor.machines.id
        b.addFull(v)
    }

    private func automationsRow(_ a: MachinesModel.Automations) -> NSView {
        let c = MachinesController.shared
        let tone: Tone
        switch a.state {
        case .here: tone = Tone(symbol: "checkmark.circle", color: Palette.ok, word: a.status)
        case .other: tone = Tone(symbol: "laptopcomputer", color: Palette.acc, word: a.status)
        case .paused: tone = Tone(symbol: "exclamationmark.triangle", color: Palette.warn, word: a.status)
        }
        let note = NSTextField.text(a.detail, size: 11.5, color: Palette.dim, lines: 2)
        var cells: [NSView] = [TwoLine("Automations", subView: note), Spacer(), Pill(tone)]
        if let verb = a.action {
            let busy = c.automationCall == verb
            let b = ActionButton(busy ? (verb == "Retry" ? "Retrying…" : "Taking…") : verb) {
                if case .paused = a.state { c.retryAutomations() } else { c.takeAutomations() }
            }
            b.isEnabled = c.automationCall == nil
            b.setAccessibilityLabel(verb == "Retry" ? "Retry the automations" : "Run the automations on this Mac")
            cells.append(b)
        }
        return Row(cells, height: 66, label: "Automations, \(a.status)")
    }

    private func machineRuntimes(_ b: NSStackView, _ m: MachinesModel) {
        guard !m.runtimes.isEmpty else { return }
        let c = MachinesController.shared
        let rows: [NSView] = m.runtimes.map { r in
            let tone: Tone
            switch r.state {
            case .live, .running: tone = Tone(symbol: "checkmark.circle.fill", color: Palette.ok, word: r.status)
            case .textOnly, .down: tone = Tone(symbol: "exclamationmark.circle.fill", color: Palette.warn, word: r.status)
            case .connecting: tone = Tone(symbol: "circle.dashed", color: Palette.acc, word: r.status)
            case .missing: tone = Tone(symbol: "circle.dashed", color: Palette.dim, word: r.status)
            }
            var cells: [NSView] = [Glyph("terminal", color: Palette.mut, size: 16), TwoLine(r.title, r.detail, lines: 2), Spacer(), Pill(tone)]
            let call = c.runtimeCalls[r.key]
            if r.canRetry {
                let retry = ActionButton(call == "Retry" ? "Retrying…" : "Retry") { c.retry(r.machine, runtime: r.id) }
                retry.isEnabled = call == nil
                retry.setAccessibilityLabel("Retry \(r.title)")
                cells.append(retry)
            }
            if r.canPair {
                let pair = ActionButton(call == "Pair" ? "Pairing…" : r.paired ? "Pair again…" : "Pair…", style: r.paired ? .plain : .primary) { [weak self] in
                    self?.askPair(r)
                }
                pair.isEnabled = call == nil
                pair.setAccessibilityLabel("Pair \(r.title)")
                cells.append(pair)
            }
            if r.canUnpair {
                let unpair = ActionButton(call == "Unpair" ? "Unpairing…" : "Unpair", style: .plain) { [weak self] in self?.askUnpair(r) }
                unpair.isEnabled = call == nil
                unpair.setAccessibilityLabel("Unpair \(r.title)")
                cells.append(unpair)
            }
            return Row(cells, height: r.note == nil ? 52 : 62, label: "\(r.title), \(r.status)\(r.note.map { ", \($0)" } ?? "")")
        }
        let v = NSStackView(v: [SectionTitle(SettingsAnchor.runtimes.title)], spacing: 6)
        let card = ListCard()
        rows.forEach { card.add($0) }
        v.addFull(card)
        v.addFull(NSTextField.text("Each daemon drives the runtimes of its own machine. Live: the session view has color and keys. "
                                   + "Text only: the daemon reads the screen as text.", size: 11.5, color: Palette.dim, lines: 2))
        v.identifier = SettingsAnchor.runtimes.id
        b.addFull(v)
    }

    private func machineHooks(_ b: NSStackView, _ m: MachinesModel) {
        let c = MachinesController.shared
        var rows: [NSView] = m.hooks.map { h in
            let tone: Tone
            switch h.state {
            case .installed: tone = Tone(symbol: "checkmark.circle.fill", color: Palette.ok, word: h.status)
            case .untrusted, .outdated: tone = Tone(symbol: "exclamationmark.circle.fill", color: Palette.warn, word: h.status)
            case .missing, .unsupported: tone = Tone(symbol: "circle.dashed", color: Palette.dim, word: h.status)
            }
            var cells: [NSView] = [TwoLine(h.title, h.note, lines: 2), Spacer(), Pill(tone)]
            switch h.action {
            case .install: cells.append(ActionButton("Install hooks") { c.installHooks([h.name]) })
            case .remove: cells.append(ActionButton("Remove hooks") { c.removeHooks([h.name]) })
            case .none: break
            }
            return Row(cells, height: 54, label: "\(h.title) hooks: \(h.status)")
        }
        if rows.isEmpty { rows = [Padded(NSTextField.text("The daemon found no agent CLI on this Mac.", size: 12, color: Palette.dim))] }
        let v = NSStackView(v: [SectionTitle(SettingsAnchor.hooks.title)], spacing: 6)
        let card = ListCard()
        rows.forEach { card.add($0) }
        v.addFull(card)
        v.addFull(NSTextField.text("OverSire adds its own entries only. Your other hooks and Orca's hooks stay.", size: 11.5, color: Palette.dim))
        v.identifier = SettingsAnchor.hooks.id
        b.addFull(v)
    }

    private func machineDaemon(_ b: NSStackView, _ m: MachinesModel) {
        guard let d = m.daemon else { return }
        let where_ = ["loopback \(d.listen.loopback)", d.listen.tailscale.map { "tailnet \($0)" }].compactMap { $0 }.joined(separator: " · ")
        let runner = d.roles.contains("runner")
        var top: [NSView] = [TwoLine("oversire \(d.version)", where_), Spacer(), Pill(Tone(symbol: "circle.fill", color: Palette.ok, word: "Running"))]
        let c = MachinesController.shared
        let busy = c.busy || c.updating.contains(d.machine.rawValue)
        if let u = m.update {
            let up = ActionButton(busy ? "Updating…" : "Update to \(u)", style: .plain) { c.update(d.machine.rawValue) }
            up.isEnabled = !busy
            top.append(up)
        }
        let failed = m.updateStatus?.error != nil
        let check = ActionButton(busy ? "Checking…" : failed ? "Try again" : "Check now", style: .plain) { c.update(d.machine.rawValue) }
        check.isEnabled = !busy
        var cells: [NSView] = [TwoLine("Updates", subView: NSTextField.text(m.updateNote(), size: 11.5, color: Palette.dim, lines: 3)), Spacer()]
        if failed { cells.append(Pill(Tone(symbol: "exclamationmark.triangle.fill", color: Palette.warn, word: "Failed"))) }
        let updates = Row(cells + [check], height: failed ? 80 : 66, label: "Updates, \(m.updateNote())")
        b.addFull(section(.daemon, [
            Row(top, height: 52, label: "oversire \(d.version), running\(m.update.map { ", update to \($0)" } ?? "")"),
            Row([TwoLine("Runner", "Do work orders from the cloud hub and from your other Macs."), Spacer(),
                 Pill(runner ? Tone(symbol: "checkmark.circle.fill", color: Palette.acc, word: "On") : Tone(symbol: "circle", color: Palette.dim, word: "Off"))],
                height: 52, label: "Runner, \(runner ? "on" : "off")"),
            updates,
            pathRow(m),
        ]))
    }

    /// The daemon runs the CLI by its full path. PATH is only for a terminal.
    private func pathRow(_ m: MachinesModel) -> NSView {
        if m.onPath || !m.installed {
            return Row([TwoLine("Terminal command", m.path), Spacer(), Pill(Tone(symbol: "checkmark.circle.fill", color: Palette.acc, word: "In PATH"))],
                       height: 52, label: "Terminal command, in PATH")
        }
        let add = ActionButton("Add to PATH", style: .plain) { MachinesController.shared.linkOnPath() }
        return Row([TwoLine("Terminal command", "\(m.path) is not in PATH. The link in /usr/local/bin can ask for your password.", lines: 2),
                    Spacer(), add], height: 66, label: "Terminal command, not in PATH")
    }

    private func joinCodeButton(_ style: ActionButton.Style) -> ActionButton {
        ActionButton("Join with code…", style: style) { [weak self] in
            guard let w = self?.view.window, let hub = MachinesController.shared.hub else { return }
            MainActor.assumeIsolated { MachineSheets.joinCode(over: w, flow: hub.joins) }
        }
    }

    private func ask(_ found: DaemonInfo) {
        guard let w = view.window, let hub = MachinesController.shared.hub else { return }
        MainActor.assumeIsolated {
            let flow = hub.joins
            MachineSheets.waiting(over: w, flow: flow)
            Task { await flow.join(found: found) }
        }
    }

    private func addMachine() {
        MachinesController.shared.invite { [weak self] inv in
            guard let w = self?.view.window else { return }
            MachineSheets.add(over: w, invite: inv)
        }
    }

    private func askPair(_ r: MachinesModel.Runtime) {
        AlertConfirm.input("Pair \(r.title)",
                           info: "In \(r.name), open Settings and make a runtime pairing link. Pick This computer only. Paste the link here. "
                               + "The daemon on \(r.machine) checks the link, then keeps it in the Keychain.",
                           placeholder: "orca://pair?code=…", button: "Pair", width: 420, in: view.window) {
            MachinesController.shared.pair(r.machine, runtime: r.id, link: $0)
        }
    }

    private func askUnpair(_ r: MachinesModel.Runtime) {
        AlertConfirm.ask("Unpair \(r.title)?",
                         info: "The session view goes back to text only. The daemon forgets the link. The device stays in \(r.name) › Settings until you remove it there.",
                         button: "Unpair", in: view.window) { MachinesController.shared.unpair(r.machine, runtime: r.id) }
    }

    private func confirmRemove(_ machine: String, group: String) {
        AlertConfirm.ask("Remove \(machine) from \(group)?",
                         info: "\(machine) gets no more state from the group, and its credential stops. To add it again, use Add machine.",
                         button: "Remove", in: view.window) { MachinesController.shared.remove(machine) }
    }
}

/// Opens the menu of a button under it.
/// The banner of Work and the Session tab when this Mac needs a daemon. It has the install button of Settings › Machines.
enum DaemonBanner {
    static var shown: () -> Bool = { ENV.machines?.needsDaemon == true }

    static func rows() -> [PageRow] {
        guard shown() else { return [] }
        let busy = DaemonSetup.shared.busy
        return [PageRow("daemon", busy) {
            let install = ActionButton(busy ? "Installing…" : "Install", style: .primary) { MachinesController.shared.install() }
            install.isEnabled = !busy
            return Banner(.warning, title: "Install the OverSire daemon to see agent sessions",
                          body: "The daemon on this Mac runs the agent sessions and sends their state. Installs the oversire CLI from the GitHub release.",
                          actions: [install])
        }]
    }
}

final class MenuOpener: NSObject {
    static let shared = MenuOpener()
    @objc func open(_ sender: NSButton) {
        sender.menu?.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height + 4), in: sender)
    }
}

// MARK: Sheets

/// A small dialog: a title, notes, a code box, and buttons. Return presses the primary button, Escape the cancel button.
/// It shows as a sheet on a window, or alone when no window is open.
final class DialogSheet: NSWindow {
    let stack = NSStackView(v: [], spacing: 12)
    private(set) var cancelButton: ActionButton?
    private(set) var primaryButton: ActionButton?
    private let foot = NSStackView(h: [], spacing: 8)
    private var onCancel: () -> Void = {}
    private var timer: Timer?
    var onClose: () -> Void = {}

    init(title: String, width: CGFloat = 460) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 200), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        self.title = title
        isReleasedWhenClosed = false
        autorecalculatesKeyViewLoop = true
        let card = Box(fill: Palette.panel, border: nil, radius: 0)
        card.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -22),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            card.widthAnchor.constraint(equalToConstant: width),
        ])
        contentView = card
        setTitle(title)
    }

    private let heading = NSTextField.text("", size: 15, weight: .semibold, lines: 2)

    func setTitle(_ t: String) {
        title = t
        heading.stringValue = t
        heading.setAccessibilityRole(.staticText)
        if heading.superview == nil { stack.addFull(heading) }
    }

    func note(_ s: String, mono: Bool = false, color: NSColor = Palette.dim) -> NSTextField {
        let f = NSTextField.text(s, size: mono ? 12 : 12.5, color: color, lines: 4, mono: mono)
        stack.addFull(f)
        return f
    }

    /// A large code, for example "mbp · K7Q2-M9XD".
    @discardableResult
    func code(_ s: String, label: String) -> NSTextField {
        let box = Box(fill: Palette.raise, border: Palette.line, radius: 10)
        let f = NSTextField.text(s, size: 26, weight: .semibold, mono: true)
        f.alignment = .center
        f.setAccessibilityLabel(label)
        box.addSubview(f)
        NSLayoutConstraint.activate([
            f.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14), f.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            f.topAnchor.constraint(equalTo: box.topAnchor, constant: 14), f.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
        ])
        stack.addFull(box)
        return f
    }

    /// A line that counts down to `end` each second.
    func countdown(to end: Date, _ text: @escaping (String) -> String) -> NSTextField {
        let f = note("")
        let tick = { f.stringValue = text(DialogSheet.clock(end.timeIntervalSinceNow)) }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in tick() }
        return f
    }

    static func clock(_ s: TimeInterval) -> String {
        let n = max(0, Int(s.rounded()))
        return String(format: "%d:%02d", n / 60, n % 60)
    }

    /// cancel: Escape. primary: Return.
    func buttons(cancel: String, primary: String? = nil, onCancel: @escaping () -> Void, onPrimary: (() -> Void)? = nil) {
        foot.arrangedSubviews.forEach { $0.removeFromSuperview() }
        self.onCancel = onCancel
        let c = ActionButton(cancel, key: "\u{1b}") { onCancel() }
        cancelButton = c
        var views: [NSView] = [Spacer(), c]
        if let primary, let onPrimary {
            let p = ActionButton(primary, style: .primary, key: "\r") { onPrimary() }
            primaryButton = p
            views.append(p)
        } else {
            primaryButton = nil
            c.keyEquivalent = "\r"   // the only button: Return and Escape both close
        }
        views.forEach(foot.addArrangedSubview)
        if foot.superview == nil { stack.addFull(foot) }
        recalculateKeyViewLoop()
    }

    override func cancelOperation(_ sender: Any?) {
        UILog.write("Dialog", "\(title): Escape")
        onCancel()
    }

    func present(over parent: NSWindow?) {
        MachineSheets.open = self
        if let parent, parent.isVisible {
            parent.beginSheet(self)
        } else {
            styleMask = [.titled, .closable]
            level = .floating
            center()
            NSApp.activate(ignoringOtherApps: true)
            makeKeyAndOrderFront(nil)
        }
        makeFirstResponder(stack.arrangedSubviews.first { $0 is NSTextField && ($0 as! NSTextField).isEditable } ?? primaryButton ?? cancelButton)
    }

    func dismiss() {
        timer?.invalidate()
        timer = nil
        if let p = sheetParent { p.endSheet(self) } else { orderOut(nil) }
        if MachineSheets.open === self { MachineSheets.open = nil }
        onClose()
    }
}

/// The sheets of the Machines page. Main thread only.
enum MachineSheets {
    static weak var open: DialogSheet?
    static var windowNumber: Int? { open?.windowNumber }
    private static var observers: [Any] = []

    @discardableResult
    static func add(over w: NSWindow?, invite: GroupInvite) -> DialogSheet {
        let s = DialogSheet(title: "Add a machine")
        _ = s.note("On the new machine, open OverSire › Machines › Join with code. Or run the command below on a box with no app.")
        s.code("\(invite.via) · \(invite.code)", label: "Host \(invite.via), code \(invite.code)")
        let command = "oversire join \(invite.via) \(invite.code)"
        let cmd = NSTextField(labelWithString: command)
        cmd.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        cmd.isSelectable = true
        cmd.setAccessibilityLabel("Command for a box with no app")
        let copy = ActionButton("Copy") { RowActions.copy(command) }
        s.stack.addFull(NSStackView(h: [cmd, Spacer(), copy], spacing: 8))
        _ = s.countdown(to: invite.expiresAt) { "The code works once and expires in \($0)." }
        s.buttons(cancel: "Done") { [weak s] in s?.dismiss() }
        s.present(over: w)
        return s
    }

    @MainActor @discardableResult
    static func joinCode(over w: NSWindow?, flow: JoinFlow) -> DialogSheet {
        let s = DialogSheet(title: "Join with code")
        _ = s.note("Get the code from Add machine on a member of the group.")
        let host = NSTextField(), code = NSTextField()
        for (f, label, hint) in [(host, "Machine", "mbp or 100.97.81.23"), (code, "Code", "XXXX-XXXX")] {
            f.placeholderString = hint
            f.font = .monospacedSystemFont(ofSize: 12.5, weight: .regular)
            f.setAccessibilityLabel(label)
            f.translatesAutoresizingMaskIntoConstraints = false
            let v = NSStackView(v: [NSTextField.text(label, size: 12, weight: .medium), f], spacing: 5)
            f.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
            s.stack.addFull(v)
        }
        let status = s.note("")
        status.isHidden = true
        let watcher = NotificationCenter.default.addObserver(forName: JoinFlow.changed, object: flow, queue: .main) { [weak s] _ in
            guard let s else { return }
            MainActor.assumeIsolated {
                switch flow.phase {
                case .sending(let h): status.stringValue = "Joining \(h)…"; status.textColor = Palette.dim; status.isHidden = false
                case .failed(let why): status.stringValue = "▲ " + why; status.textColor = Palette.bad; status.isHidden = false
                case .joined: s.dismiss()
                default: break
                }
            }
        }
        s.onClose = { NotificationCenter.default.removeObserver(watcher) }
        s.buttons(cancel: "Cancel", primary: "Join", onCancel: { [weak s] in flow.cancel(); s?.dismiss() }) {
            Task { await flow.join(host: host.stringValue, code: code.stringValue) }
        }
        s.present(over: w)
        s.makeFirstResponder(host)
        return s
    }

    /// The wait for the approval on a member. It closes when the member approves, and shows the reason when the join fails.
    @MainActor @discardableResult
    static func waiting(over w: NSWindow?, flow: JoinFlow) -> DialogSheet {
        let s = waiting(over: w, phase: flow.phase, expires: flow.expiresAt) { flow.cancel() }
        let watcher = NotificationCenter.default.addObserver(forName: JoinFlow.changed, object: flow, queue: .main) { [weak s] _ in
            guard let s else { return }
            MainActor.assumeIsolated {
                if case .joined = flow.phase { s.dismiss(); return }
                fill(s, phase: flow.phase, expires: flow.expiresAt) { flow.cancel() }
            }
        }
        s.onClose = { NotificationCenter.default.removeObserver(watcher) }
        return s
    }

    @MainActor @discardableResult
    static func waiting(over w: NSWindow?, phase: JoinFlow.Phase, expires: Date?, cancel: @escaping () -> Void) -> DialogSheet {
        let s = DialogSheet(title: "Join")
        fill(s, phase: phase, expires: expires, cancel: cancel)
        s.present(over: w)
        return s
    }

    @MainActor private static func fill(_ s: DialogSheet, phase: JoinFlow.Phase, expires: Date?, cancel: @escaping () -> Void) {
        s.stack.arrangedSubviews.dropFirst().forEach { $0.removeFromSuperview() }
        switch phase {
        case .idle, .sending:
            let host: String
            if case .sending(let h) = phase { host = h } else { host = "the member" }
            s.setTitle("Sending the request to \(host)…")
            _ = s.note("The daemon on this Mac asks \(host) to admit it.")
        case .waiting(let confirm, let host):
            s.setTitle("Waiting for approval on \(host)")
            _ = s.note("Approve the request on \(host). Make sure that \(host) shows the same code.")
            s.code(confirm, label: "Code \(confirm)")
            if let expires { _ = s.countdown(to: expires) { "The request expires in \($0)." } }
        case .joined(let m):
            s.setTitle("Joined \(m)")
        case .failed(let why):
            s.setTitle("Could not join")
            _ = s.note("▲ " + why, color: Palette.bad)
        }
        let failed: Bool
        if case .failed = phase { failed = true } else { failed = false }
        s.buttons(cancel: failed ? "Close" : "Cancel") { [weak s] in cancel(); s?.dismiss() }
    }

    /// A join request on this member. The code must match the code on the new machine.
    @discardableResult
    static func approve(_ r: JoinRequestFrame, group: String, over w: NSWindow?, decide: @escaping (Bool) -> Void) -> DialogSheet {
        let s = DialogSheet(title: ApproveCenter.title(r, group: group))
        _ = s.note("Approve only if \(r.machine) shows the same code. \(r.machine) can then see the sessions of all members"
                   + (r.kind == .daemon ? " and send work orders." : "."))
        s.code(r.confirm, label: "Code \(r.confirm)")
        _ = s.note("from \(r.host) · \(r.kind == .app ? "the app" : "the daemon") on \(r.machine)", mono: true)
        _ = s.countdown(to: r.expiresAt) { "The request expires in \($0)." }
        s.buttons(cancel: "Deny", primary: "Approve", onCancel: { [weak s] in decide(false); s?.dismiss() }) { [weak s] in
            decide(true)
            s?.dismiss()
        }
        s.present(over: w)
        return s
    }

    @discardableResult
    static func consent(over w: NSWindow?, answer: @escaping (Bool) -> Void) -> DialogSheet {
        let s = DialogSheet(title: "Install agent hooks for live status?")
        _ = s.note("OverSire adds entries to ~/.claude/settings.json and ~/.codex/hooks.json. Your other hooks and Orca's hooks stay.")
        _ = s.note("If you say no, OverSire still reads Orca, about each 20 s. You can change this later on this page.")
        s.buttons(cancel: "Not now", primary: "Install hooks", onCancel: { [weak s] in answer(false); s?.dismiss() }) { [weak s] in
            answer(true)
            s?.dismiss()
        }
        s.present(over: w)
        return s
    }
}
