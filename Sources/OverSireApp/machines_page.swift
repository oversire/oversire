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
        /// The Orca account id. nil: none.
        var account: String?
        var muted: Bool

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
    /// The Orca account choices: ids, then nil for none.
    var accounts: [String?]

    var title: String {
        switch state {
        case .noDaemon, .group: return "\(groupName) · \(machines.count)"
        case .solo: return "\(groupName) · this Mac only"
        }
    }

    /// Hooks that the consent installs.
    var missingHooks: [String] { hooks.filter { $0.state == .missing || $0.state == .outdated }.map(\.name) }

    init(_ s: MachinesSnapshot, config: MachinesConfig, environments: [String], now: Date = Date()) {
        daemon = s.info
        installed = s.installed
        path = s.path
        onPath = s.onPath
        if let l = s.latest, let v = s.info?.version, Updater.isNewer(l, than: v) { update = l } else { update = nil }
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
            let account: String?
            if let a = config.runtimeAccounts[name] { account = a.isEmpty ? nil : a }
            else if isThis { account = "local" }
            else { account = environments.first { $0.caseInsensitiveCompare(name) == .orderedSame } }
            let addr = m.addrs.first ?? m.host
            return Machine(name: name, host: m.port == 7690 || addr.contains(":") ? addr : "\(addr):\(m.port)", isThis: isThis,
                           home: s.group?.home == m.machine || (s.group == nil && isThis), runner: m.roles.contains("runner"), online: online,
                           status: online ? "Online" : Self.offline(m.lastSeen, now: now), sessions: active.count,
                           waiting: active.filter { $0.state == .waiting }.count, account: account, muted: config.muted.contains(name))
        }
        let known = Set(members.map(\.machine))
        found = state == .solo
            ? s.peers.filter { $0.machine.rawValue != me && !known.contains($0.machine) }.map(Found.init)
            : []
        hooks = s.info == nil ? [] : s.hooks.map(Self.hook)
        accounts = ["local"] + environments.filter { $0 != "local" } + [nil]
    }

    static func offline(_ seen: Date?, now: Date) -> String {
        guard let seen else { return "Offline" }
        let s = max(0, now.timeIntervalSince(seen))
        let ago = s < 3600 ? "\(max(1, Int(s / 60))) min ago" : s < 172_800 ? "\(Int(s / 3600)) h ago" : "\(Int(s / 86400)) d ago"
        return "Offline · \(ago)"
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
    var environments: () -> [String] = { MachinesController.shared.hub?.environments() ?? [] }
    var changed: () -> Void = { ChangeBus.shared.post(DataChange(.connection, origin: .user)) }

    private(set) var snapshot = MachinesSnapshot()
    private(set) var loadedAt: Date?
    private(set) var loading = false
    /// The last error of an action. The page shows it once.
    var notice: String?
    /// `--uishots` and tests: a fixed snapshot. load() does nothing.
    var frozen = false
    private var setupObserver: Any?

    var model: MachinesModel { MachinesModel(snapshot, config: config(), environments: environments()) }
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
            await hub?.approvals.sync()
        }
        if let hub {
            s.health = hub.health
            for l in hub.links where !l.local && hub.isLive(l.machine) {
                if let list = try? await l.client(http: hub.http).sessions() { s.sessions[l.machine] = list.sessions }
            }
        }
        snapshot = s
        loadedAt = Date()
        changed()
    }

    /// For tests and `--uishots`.
    func use(_ s: MachinesSnapshot) {
        snapshot = s
        loadedAt = Date()
    }

    /// op can give a warning for the page.
    private func run(_ what: String, _ op: @escaping () async throws -> String?) {
        Task { @MainActor in
            do { if let w = try await op() { self.notice = w } } catch {
                self.notice = "\(what): \(DaemonClient.reason(error))"
                log.error("Machines: \(self.notice ?? "", privacy: .public)")
            }
            self.hub?.refresh()
            await self.load()
        }
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

    /// nil: no Orca account.
    func setAccount(_ machine: String, _ account: String?) {
        MACHINES.runtimeAccounts[machine] = account ?? ""
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
        hub?.applyScreens()
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
        if m.state == .noDaemon { machineSetup(b, m) }
        if m.state == .solo && !m.found.isEmpty { machineFound(b, m) }
        if m.state != .noDaemon || !m.machines.isEmpty { machineList(b, m) }
        if m.state != .noDaemon { machineHooks(b, m); machineDaemon(b, m) }
        if c.wantsConsent, MachineSheets.open == nil {
            DispatchQueue.main.async { [weak self] in
                guard let w = self?.view.window, MachineSheets.open == nil, c.wantsConsent else { return }
                MachineSheets.consent(over: w) { c.consent($0) }
            }
        }
    }

    private func machineSetup(_ b: NSStackView, _ m: MachinesModel) {
        let busy = MachinesController.shared.busy
        let install = ActionButton(busy ? "Installing…" : m.installed ? "Install again" : "Install", style: .primary) {
            MachinesController.shared.install()
        }
        install.isEnabled = !busy
        let note = m.installed
            ? "The oversire CLI is at \(m.path), but the daemon does not answer on loopback :7690."
            : "The daemon sends session state the moment an agent stops or asks a question. Without it, OverSire polls Orca each 15 to 60 s."
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
        let v = NSStackView(v: [SectionTitle(m.title, action: NSStackView(h: actions, spacing: 10))], spacing: 6)
        let card = ListCard()
        for x in m.machines {
            var badges: [NSView] = [NSTextField.text(x.name, size: 13, weight: .medium)]
            if x.isThis { badges.append(NSTextField.text("this Mac", size: 11.5, color: Palette.dim)) }
            if x.home { badges.append(Chiplet("HOME")) }
            if x.runner { badges.append(Chiplet("RUNNER")) }
            if x.muted { badges.append(Chiplet("MUTED", symbol: "speaker.slash")) }
            let name = NSStackView(v: [NSStackView(h: badges, spacing: 6),
                                       NSTextField.text(x.host, size: 11.5, color: Palette.dim, mono: true)], spacing: 3)
            name.setContentHuggingPriority(.init(1), for: .horizontal)
            let status = Pill(Tone(symbol: x.online ? "circle.fill" : "circle", color: x.online ? Palette.ok : Palette.dim, word: x.status))
            let sessions = Pill(x.waiting > 0 ? Tone(symbol: "exclamationmark.circle.fill", color: Palette.warn, word: x.sessionsText)
                                              : Tone(symbol: "terminal", color: Palette.dim, word: x.sessionsText))
            let titles = m.accounts.map { "Orca: \($0 ?? "none")" }
            let picked = m.accounts.firstIndex { $0 == x.account } ?? (m.accounts.count - 1)
            let pop = PopUp(titles, selected: picked, label: "Orca account for \(x.name)") { i in c.setAccount(x.name, m.accounts[i]) }
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
            card.add(Row([Glyph(x.runner && !x.isThis ? "server.rack" : "laptopcomputer", color: Palette.mut, size: 16), name, Spacer(),
                          status, sessions, pop, more], height: 54,
                         label: "\(x.name), \(x.status), \(x.sessionsText)\(x.home ? ", home" : "")"))
        }
        v.addFull(card)
        v.addFull(NSTextField.text("Home keeps the shared OverSire state. Use the row menu to make another machine home.",
                                   size: 11.5, color: Palette.dim, lines: 2))
        v.identifier = SettingsAnchor.machines.id
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
        if let u = m.update {
            let busy = MachinesController.shared.busy
            let up = ActionButton(busy ? "Updating…" : "Update to \(u)", style: .plain) { MachinesController.shared.install() }
            up.isEnabled = !busy
            top.append(up)
        }
        b.addFull(section(.daemon, [
            Row(top, height: 52, label: "oversire \(d.version), running\(m.update.map { ", update to \($0)" } ?? "")"),
            Row([TwoLine("Runner", "Do work orders from the cloud hub and from your other Macs."), Spacer(),
                 Pill(runner ? Tone(symbol: "checkmark.circle.fill", color: Palette.acc, word: "On") : Tone(symbol: "circle", color: Palette.dim, word: "Off"))],
                height: 52, label: "Runner, \(runner ? "on" : "off")"),
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

    private func confirmRemove(_ machine: String, group: String) {
        let a = NSAlert()
        a.messageText = "Remove \(machine) from \(group)?"
        a.informativeText = "\(machine) gets no more state from the group, and its credential stops. To add it again, use Add machine."
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        let run = { (r: NSApplication.ModalResponse) in if r == .alertFirstButtonReturn { MachinesController.shared.remove(machine) } }
        if let w = view.window { a.beginSheetModal(for: w, completionHandler: run) } else { run(a.runModal()) }
    }
}

/// Opens the menu of a button under it.
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

    override func cancelOperation(_ sender: Any?) { onCancel() }

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
