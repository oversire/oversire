import Cocoa
import OverSireCore

// Settings › Agents (OVERSIRE-399): the machines of the agents, the model of the two lists and the env editor.

/// One machine of the group, for Runs on and the table on Settings › Machines.
struct AgentPlace: Equatable {
    var name: String
    var home = false
    var sessions = false
    var online = true
    /// The features of its daemon. nil: the app did not read them.
    var features: [String]?

    var label: String { [name, sessions ? "sessions" : nil, home ? "home" : nil].compactMap { $0 }.joined(separator: " · ") }
}

/// The machines that can start agents, and the home that keeps the secrets.
struct AgentPlaces: Equatable {
    var this: String
    /// nil: no home daemon. Secrets are then not available.
    var home: String?
    var homeOnline = false
    var machines: [AgentPlace] = []

    /// The machine of Run sessions on.
    var sessions: String { machines.first(where: \.sessions)?.name ?? this }
}

/// The text of Settings › Agents, from the catalog, the machines and the secret keys on home.
struct AgentsModel: Equatable {
    struct Row: Equatable {
        var scope: CatalogAgent.Scope
        var name: String
        var env: String?
        var edited: String?
        /// "any machine", "only on mbp".
        var runs: String
        /// The agent cannot run on the Run sessions on machine.
        var refusal: String?
        /// A shared agent that the agent of this Mac hides.
        var shadowed = false
        /// An agent of this Mac that hides a shared agent.
        var hides = false
        /// The secret keys with no value on home.
        var missing: [String] = []
    }

    var home: String?
    var homeOnline: Bool
    var offer: String?
    var offline: String?
    var intro: String
    var shared: [Row]
    var local: [Row]
    var localTitle: String
    var localCount: String
    var sharedCount: String
    /// The keys on home. nil: not read.
    var keys: [AgentSecretKey]?
    var now: Date

    /// `offer`: the local agents for the Share banner. Empty: no banner.
    init(shared: [CatalogAgent], local: [CatalogAgent], offer: [String], places: AgentPlaces, keys: [AgentSecretKey]?, device: String, now: Date = Date()) {
        home = places.home
        homeOnline = places.homeOnline
        self.keys = keys
        self.now = now
        let n = local.count, o = offer.count
        self.offer = o == 0 ? nil
            : "\(o == 1 ? "1 agent is" : "\(o) agents are") on this Mac only: \(offer.joined(separator: ", ")). Share \(o == 1 ? "it" : "them") with all your Macs?"
        if let h = places.home, !places.homeOnline {
            offline = "Each Mac keeps a copy of the shared agents. You can start and edit them. Edits sync when \(h) is back. "
                + "A start that needs a secret fails: only \(h) has the value."
        }
        intro = places.home.map {
            "A shared agent is on all your Macs. The home store on \($0) keeps it. An agent on this Mac only stays in this app. "
                + "Secret values stay on \($0), never in the store."
        } ?? "A shared agent is on all your Macs. Make a group in Settings › Machines to share agents and to keep secret values on a home daemon."
        localTitle = "This Mac only · \(places.this)"
        localCount = "\(n == 1 ? "1 agent" : "\(n) agents") · only this app sees them"
        sharedCount = shared.count == 1 ? "1 agent" : "\(shared.count) agents"
        let sharedNames = Set(shared.map(\.name))
        func row(_ a: CatalogAgent, _ scopeID: String) -> Row {
            let d = a.def
            var r = Row(scope: a.scope, name: a.name, env: Self.envChip(d.env),
                        edited: a.scope == .shared ? d.updatedBy.map { "edited on \($0) · \(MachinesModel.ago(d.updatedAt, now: now))" } : nil,
                        runs: d.runsOn.map { "only on \($0.joined(separator: ", "))" } ?? "any machine",
                        refusal: AgentLaunch(profile: d.name, cli: d.cli ?? d.name, runsOn: d.runsOn).refusal(on: places.sessions),
                        shadowed: a.shadowed, hides: a.scope == .local && sharedNames.contains(a.name))
            if let keys {
                r.missing = d.env.filter(\.secret).map(\.key).filter { k in !keys.contains { $0.scope == scopeID && $0.agent == d.name && $0.key == k } }
            }
            return r
        }
        self.shared = shared.map { row($0, AgentSecretRef.shared) }
        self.local = local.map { row($0, device) }
    }

    /// "Env 3 · 1 secret". nil: no env.
    static func envChip(_ env: [EnvVar]) -> String? {
        guard !env.isEmpty else { return nil }
        let s = env.filter(\.secret).count
        return "Env \(env.count)" + (s == 0 ? "" : s == 1 ? " · 1 secret" : " · \(s) secrets")
    }

    /// The home chip: "Home: mini · synced".
    var homeChip: (text: String, ok: Bool) {
        guard let home else { return ("No home daemon", false) }
        return homeOnline ? ("Home: \(home) · synced", true) : ("Home: \(home) · offline", false)
    }

    /// The note of one secret row: where the value is, or that home has no value.
    func secretNote(agent: String, scope: String, key: String) -> (text: String, missing: Bool) {
        let h = home ?? "home"
        guard let keys else { return ("kept on \(h)", false) }
        guard let k = keys.first(where: { $0.scope == scope && $0.agent == agent && $0.key == key }) else { return ("no value", true) }
        return ("kept on \(h) · set \(MachinesModel.ago(k.setAt, now: now))", false)
    }

    func missingText(_ key: String) -> String {
        "\(home ?? "Home") has no value for \(key). This occurs after the home moves to another machine. Type the value again."
    }

    /// The on and env lines of the preview. Secret values show as dots.
    static func preview(_ l: AgentLaunch, places: AgentPlaces) -> (on: String, env: String?) {
        var on = l.refusal(on: places.sessions).map { "✕ " + $0 } ?? "on \(places.sessions) (Run sessions on)"
        if !l.envSecrets.isEmpty { on += " · secrets from \(places.home ?? "home")" }
        let rows = l.env.map { ($0.key, LaunchCommand.quote($0.value)) } + l.envSecrets.keys.map { ($0, "••••••") }
        let env = rows.isEmpty ? nil : rows.sorted { $0.0 < $1.0 }.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
        return (on, env)
    }
}

/// The cells of "Agents on each machine" on Settings › Machines.
struct AgentMachineTable: Equatable {
    struct Line: Equatable {
        var name: String
        var note: String?
        var cells: [String]
    }

    var columns: [(name: String, note: String)]
    var lines: [Line]

    static func == (a: Self, b: Self) -> Bool { a.columns.map(\.name) == b.columns.map(\.name) && a.columns.map(\.note) == b.columns.map(\.note) && a.lines == b.lines }

    /// `defaults`: the built-in CLIs with no entry in either list.
    init(agents: [CatalogAgent], defaults: [String] = [], places: AgentPlaces, this: String) {
        let ms = places.machines
        columns = ms.map { m in
            (m.name, [m.name == this ? "this Mac" : nil, m.sessions ? "sessions" : nil, m.home ? "home" : nil, m.online ? "live" : "offline"]
                .compactMap { $0 }.joined(separator: " · "))
        }
        let all = agents + defaults.map { CatalogAgent(scope: .local, def: AgentDef(name: $0, cli: RuntimeConfig.baseCLI($0), updatedAt: .distantPast)) }
        let defaultNames = Set(defaults)
        lines = all.map { a in
            let d = a.def
            let plain = d.env.contains { !$0.secret }, secret = d.env.contains(where: \.secret)
            let cells = ms.map { m -> String in
                if !d.runs(on: m.name) { return "— not on its list" }
                if !m.online { return "○ offline" }
                if let f = m.features {
                    if secret && !f.contains(DaemonInfo.agentSecrets) { return "✕ old oversire: no secrets" }
                    if (plain || secret) && !f.contains(DaemonInfo.launchEnv) { return "✕ old oversire: no env" }
                }
                if secret && places.home.map({ h in !places.homeOnline && h != m.name }) == true { return "△ home offline" }
                return "✓ ready"
            }
            let note = defaultNames.contains(a.name) ? "default" : a.scope == .local ? "this Mac only" : a.shadowed ? "this Mac uses its own" : nil
            return Line(name: a.name, note: note, cells: cells)
        }
        if let h = places.home {
            lines.append(Line(name: "secrets", note: "from \(h)", cells: ms.map { m in
                if m.name == h { return m.online ? "✓ keeps them" : "○ offline" }
                if !m.online { return "○ offline" }
                if let f = m.features, !f.contains(DaemonInfo.agentSecrets) { return "✕ old oversire" }
                return places.homeOnline ? "✓ reaches \(h)" : "△ \(h) offline"
            }))
        }
    }
}

// MARK: - Views

/// A box with a dashed border: an agent of this Mac only, or a row from the env for all agents.
final class DashedBox: Box {
    private let dash = CAShapeLayer()

    init(fill: NSColor? = nil, radius: CGFloat = 8) {
        super.init(fill: fill, border: nil, radius: radius)
        dash.fillColor = nil
        dash.lineWidth = 1
        dash.lineDashPattern = [4, 3]
        layer?.addSublayer(dash)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        dash.frame = bounds
        dash.path = CGPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    override func updateLayer() {
        super.updateLayer()
        effectiveAppearance.performAsCurrentDrawingAppearance { dash.strokeColor = Palette.line.cgColor }
    }

    /// The box around `content`, with padding.
    static func around(_ content: NSView, inset: CGFloat = 10) -> DashedBox {
        let b = DashedBox()
        b.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: inset),
            content.trailingAnchor.constraint(equalTo: b.trailingAnchor, constant: -inset),
            content.topAnchor.constraint(equalTo: b.topAnchor, constant: inset - 2),
            content.bottomAnchor.constraint(equalTo: b.bottomAnchor, constant: -(inset - 2)),
        ])
        return b
    }
}

/// The env rows of one agent: key, value, Secret and remove. A secret value goes to home at once. The app never reads it back.
final class EnvEditor: NSStackView, NSTextFieldDelegate {
    struct Secrets {
        var home: String
        var note: (String) -> (text: String, missing: Bool)
        var missingText: (String) -> String
        var set: (_ key: String, _ value: String) -> Void
        var remove: (_ key: String) -> Void
    }

    private var rows: [EnvVar]
    /// Secret keys with a value sent to home in this editor, or saved before.
    private var stored: Set<String>
    /// Rows that show a field for a new secret value.
    private var replacing: Set<Int> = []
    private let inherited: [EnvVar]
    private let agent: String
    private let save: ([EnvVar]) throws -> Void
    private let secrets: Secrets?
    private let noSecrets: String
    private let list = NSStackView(v: [], spacing: 6)
    private let problems = NSStackView(v: [], spacing: 3)
    private var pending: DispatchWorkItem?
    /// For tests: the debounce of a typed change.
    var delay: TimeInterval = 0.6

    /// `noSecrets`: why the Secret toggle is off, when `secrets` is nil.
    init(agent: String, env: [EnvVar], inherited: [EnvVar] = [], secrets: Secrets?, noSecrets: String = "", save: @escaping ([EnvVar]) throws -> Void) {
        self.agent = agent
        rows = env
        stored = Set(env.filter(\.secret).map(\.key))
        self.inherited = inherited
        self.secrets = secrets
        self.noSecrets = noSecrets
        self.save = save
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        addFull(list)
        let add = ActionButton("+ Add a variable", style: .link) { [weak self] in self?.addRow() }
        add.setAccessibilityLabel("Add an env variable to \(agent == AgentDef.allAgents ? "all agents" : agent)")
        addArrangedSubview(add)
        addFull(problems)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The rows as the editor has them now. Blank rows are not part of the env.
    var env: [EnvVar] { rows.filter { !($0.key.isEmpty && ($0.value ?? "").isEmpty && !$0.secret) } }

    private func build() {
        list.clear()
        for i in rows.indices { list.addFull(row(i)) }
        let own = Set(rows.map(\.key))
        for v in inherited where !own.contains(v.key) {
            let text = NSTextField.text("\(v.key)=\(v.secret ? "••••••" : v.value ?? "")", size: 11.5, color: Palette.mut, mono: true)
            let line = NSStackView(h: [text, Spacer(), NSTextField.text("from Env for all agents", size: 11, color: Palette.dim)], spacing: 8)
            let box = DashedBox.around(line, inset: 7)
            box.setAccessibilityElement(true)
            box.setAccessibilityLabel("\(v.key), from the env for all agents")
            list.addFull(box)
        }
        showProblems()
    }

    private func row(_ i: Int) -> NSView {
        let v = rows[i]
        let name = v.key.isEmpty ? "row \(i + 1)" : v.key
        let key = NSTextField()
        key.stringValue = v.key
        key.placeholderString = "Key"
        key.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        key.tag = i * 2
        key.delegate = self
        key.setAccessibilityLabel("Key of \(name)")
        key.isEditable = !(v.secret && stored.contains(v.key))
        key.widthAnchor.constraint(equalToConstant: 190).isActive = true

        let value: NSView
        if v.secret && stored.contains(v.key) && !replacing.contains(i) {
            let note: (text: String, missing: Bool) = secrets?.note(v.key) ?? ("kept on home", false)
            let dots = NSTextField.text("••••••", size: 12, color: Palette.mut, mono: true)
            let label = NSTextField.text(note.text, size: 11.5, color: note.missing ? Palette.bad : Palette.dim)
            let replace = ActionButton(note.missing ? "Type it" : "Replace", style: .link) { [weak self] in
                self?.replacing.insert(i)
                self?.build()
            }
            replace.setAccessibilityLabel("\(note.missing ? "Type" : "Replace") the value of \(v.key)")
            replace.isEnabled = secrets != nil
            let s = NSStackView(h: [dots, label, Spacer(), replace], spacing: 8)
            s.setAccessibilityElement(true)
            s.setAccessibilityLabel("Secret value of \(v.key), \(note.text)")
            value = s
        } else if v.secret {
            let f = NSSecureTextField()
            f.placeholderString = "Value of \(v.key.isEmpty ? "the secret" : v.key) · Return sends it to \(secretsHome)"
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.tag = i * 2 + 1
            f.delegate = self
            f.setAccessibilityLabel("Secret value of \(name)")
            value = f
        } else {
            let f = NSTextField()
            f.stringValue = v.value ?? ""
            f.placeholderString = "Value of \(v.key.isEmpty ? "the key" : v.key)"
            f.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            f.tag = i * 2 + 1
            f.delegate = self
            f.setAccessibilityLabel("Value of \(name)")
            value = f
        }
        value.setContentHuggingPriority(.init(1), for: .horizontal)

        let secret = NSButton(checkboxWithTitle: "Secret", target: self, action: #selector(toggleSecret(_:)))
        secret.tag = i
        secret.state = v.secret ? .on : .off
        secret.controlSize = .small
        secret.isEnabled = secrets != nil || v.secret
        secret.toolTip = secrets == nil ? noSecrets : "The value stays on \(secretsHome). OverSire does not show it again."
        secret.setAccessibilityLabel("\(name) is a secret")
        let remove = ActionButton("", symbol: "minus.circle", style: .ghost) { [weak self] in self?.removeRow(i) }
        remove.setAccessibilityLabel("Remove \(name)")
        remove.toolTip = "Remove \(name)"
        return NSStackView(h: [key, value, secret, remove], spacing: 8)
    }

    private var secretsHome: String { secrets?.home ?? "home" }

    func controlTextDidChange(_ n: Notification) {
        guard let f = n.object as? NSTextField, f.tag / 2 < rows.count else { return }
        let i = f.tag / 2
        if f.tag % 2 == 0 {
            rows[i].key = f.stringValue.trimmingCharacters(in: .whitespaces)
        } else if !rows[i].secret {
            rows[i].value = f.stringValue
        } else {
            return
        }
        changed()
    }

    // Return in a secret field sends the value to home.
    func controlTextDidEndEditing(_ n: Notification) {
        guard let f = n.object as? NSSecureTextField, f.tag % 2 == 1, f.tag / 2 < rows.count else { return }
        let i = f.tag / 2
        let value = f.stringValue
        guard !value.isEmpty, AgentEnv.validKey(rows[i].key), !AgentEnv.reserved(rows[i].key) else { return }
        sendSecret(i, value)
    }

    private func sendSecret(_ i: Int, _ value: String) {
        guard let secrets else { return }
        secrets.set(rows[i].key, value)
        stored.insert(rows[i].key)
        replacing.remove(i)
        changed(now: true)
        build()
    }

    @objc private func toggleSecret(_ b: NSButton) {
        let i = b.tag
        guard rows.indices.contains(i) else { return }
        let v = rows[i]
        if v.secret {
            if stored.remove(v.key) != nil { secrets?.remove(v.key) }
            rows[i] = EnvVar(key: v.key, value: "")
        } else {
            rows[i] = EnvVar(key: v.key, secret: true)
            if let value = v.value, !value.isEmpty, AgentEnv.validKey(v.key), !AgentEnv.reserved(v.key) {
                sendSecret(i, value)
                return
            }
        }
        changed(now: true)
        build()
    }

    private func addRow() {
        rows.append(EnvVar(key: "", value: ""))
        build()
        (list.arrangedSubviews.last?.subviews.first as? NSTextField).map { window?.makeFirstResponder($0) }
    }

    private func removeRow(_ i: Int) {
        guard rows.indices.contains(i) else { return }
        let v = rows.remove(at: i)
        if v.secret, stored.remove(v.key) != nil { secrets?.remove(v.key) }
        replacing = []
        changed(now: true)
        build()
    }

    /// Saves after a short pause, when the env has no errors.
    private func changed(now: Bool = false) {
        showProblems()
        pending?.cancel()
        let env = env
        guard AgentEnv.errors(env).isEmpty else { return }
        let w = DispatchWorkItem { [weak self] in self?.commit(env) }
        pending = w
        if now { w.perform() } else { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w) }
    }

    /// Saves a change that waits. The page calls it before it goes away.
    func flush() {
        guard let w = pending, !w.isCancelled else { return }
        w.perform()
        w.cancel()
    }

    private func commit(_ env: [EnvVar]) {
        do { try save(env) } catch {
            problems.addFull(Self.message("✕", error.localizedDescription, Palette.bad))
        }
    }

    private func showProblems() {
        problems.clear()
        let p = AgentEnv.problems(env)
        let errors = p.filter { !$0.isWarning }
        for (n, e) in errors.enumerated() {
            problems.addFull(Self.message("✕", e.description + (n == errors.count - 1 ? " OverSire keeps the last good env." : ""), Palette.bad))
        }
        for w in p where w.isWarning { problems.addFull(Self.message("△", w.description, Palette.warn)) }
        for v in rows where v.secret && stored.contains(v.key) && secrets?.note(v.key).missing == true {
            problems.addFull(Self.message("✕", secrets?.missingText(v.key) ?? "", Palette.bad))
        }
    }

    static func message(_ mark: String, _ text: String, _ color: NSColor) -> NSView {
        let v = NSStackView(h: [NSTextField.text(mark, size: 11.5, weight: .bold, color: color),
                                NSTextField.text(text, size: 11.5, color: color, lines: 3)], spacing: 6, align: .firstBaseline)
        v.distribution = .fill
        v.setAccessibilityElement(true)
        v.setAccessibilityLabel(text)
        return v
    }
}
