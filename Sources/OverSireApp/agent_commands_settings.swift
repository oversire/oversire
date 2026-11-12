import Cocoa
import OverSireCore

// Settings › Agents and queue › Agents: the shared agents of all Macs, the env for all agents, then the agents of this Mac only (OVERSIRE-399).
// Each agent is a base CLI with a command, a model, an effort, the machines it runs on and its env.
// A change saves at once. A bad template or a bad env saves nothing.
final class AgentCommandsCard: NSStackView {
    static let known = RuntimeConfig.knownAgents
    // Flag toggles per base CLI. The model has its own control.
    static let flags: [String: [String]] = [
        "claude": ["--dangerously-skip-permissions", "--permission-mode acceptEdits", "--continue"],
        "codex": ["--dangerously-bypass-approvals-and-sandbox", "--full-auto"],
        RuntimeConfig.intakeKey: ["--dangerously-skip-permissions"],
    ]
    /// Unsaved text of a row whose template is bad, by row id. The page keeps it until Settings shows another page.
    static var drafts: [String: String] = [:]
    static var exampleIndex = 0
    /// The rows that show their editor, by row id.
    static var open: Set<String> = []
    /// The local agents that the user picks to share. nil: no pick.
    static var picking: Set<String>?
    /// 0: All my Macs, 1: This Mac only.
    static var addScope = 0
    /// The secret keys on home, with no values. nil: not read yet.
    static var keys: [AgentSecretKey]?
    static var keysAt: Date?

    struct Example { var key: String; var title: String }
    /// `terminal`: the runtime types the command. Else it takes only the model and the effort.
    struct User { var name: String; var terminal: Bool }

    let catalog: AgentCatalog
    let secrets: AgentSecrets
    let places: AgentPlaces
    let model: AgentsModel
    private let examples: [Example]
    private var rows: [CommandRow] = []
    private let addField = NSTextField()
    private let addCLI: PopUp
    private let addError = NSTextField.text("", size: 11.5, color: Palette.bad)
    private var observers: [NSObjectProtocol] = []

    init(examples: [Example], usedBy: [User], catalog: AgentCatalog, secrets: AgentSecrets, places: AgentPlaces) {
        self.examples = examples
        self.catalog = catalog
        self.secrets = secrets
        self.places = places
        model = AgentsModel(shared: catalog.shared, local: catalog.local, offer: catalog.offerNames, places: places,
                            keys: Self.keys, device: secrets.device)
        addCLI = PopUp(RuntimeConfig.baseCLIs + ["none (terminal only)"], selected: 0, label: "Base CLI of the new agent") { _ in }
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        let r = PROJECTS_CFG.runtime

        let resetAll = ActionButton("Reset all", style: .link) { [weak self] in self?.resetAll() }
        resetAll.isEnabled = !r.commands.isEmpty || !r.profiles.isEmpty || !r.env.isEmpty || !r.runsOn.isEmpty || !Self.drafts.isEmpty
        resetAll.toolTip = "Removes the agents and changes of this Mac only. The shared agents stay."
        let chip = model.homeChip
        let pill = Pill(chip.ok ? .ok : .warning, text: chip.text)
        pill.toolTip = chip.ok ? "The home daemon keeps the shared agents and the secret values." : model.offline ?? AgentSecrets.Failure.noHome.localizedDescription
        addFull(SectionTitle("Agents", action: NSStackView(h: [pill, resetAll], spacing: 10)))
        if let b = shareBanner() { addFull(b) }
        if let o = model.offline, let h = model.home { addFull(Banner(.warning, title: "Home: \(h) is offline", body: o)) }
        let card = Card(spacing: 12)
        addFull(card)

        card.add(NSTextField.text(model.intro, size: 12, color: Palette.dim, lines: 3))
        let used: [NSView] = [NSTextField.text("Used by", size: 12, color: Palette.mut)] + (usedBy.isEmpty
            ? [NSTextField.text("No reachable runtime on the sessions machine. See Settings › Machines.", size: 12, color: Palette.dim)]
            : usedBy.map { u in
                let c = Chiplet(u.terminal ? "✓ \(u.name)" : "✓ \(u.name) (model and effort only)", color: u.terminal ? Palette.ok : Palette.dim)
                c.toolTip = u.terminal ? "Types the command into a terminal, with the model and effort flags."
                                       : "Starts the agent over its protocol. It uses the model and the effort, not the command."
                return c
            })
        card.add(Wrap(used))
        let pick = PopUp(examples.map(\.key), selected: min(Self.exampleIndex, examples.count - 1), label: "Example item") { [weak self] i in
            Self.exampleIndex = i
            self?.rows.forEach { $0.refresh() }
        }
        card.add(NSStackView(h: [NSTextField.text("Example item", size: 12, color: Palette.mut), pick, Spacer()], spacing: 8))

        card.add(Self.header("Shared · all my Macs", model.sharedCount))
        if catalog.shared.isEmpty {
            card.add(NSTextField.text("No shared agent yet. Share an agent of this Mac, or add one for All my Macs.", size: 12, color: Palette.dim))
        }
        for a in catalog.shared {
            let row = CommandRow(key: a.name, scope: .shared, info: model.shared.first { $0.name == a.name }, card: self)
            rows.append(row)
            card.add(Self.line())
            card.add(row)
        }

        card.add(Self.line())
        card.add(Self.header("Env for all agents", nil))
        card.add(NSTextField.text("Each agent gets these rows. The env of an agent wins on the same key. "
                                  + "A value takes {name}, {KEY}, {key} and {title}.", size: 11.5, color: Palette.dim, lines: 2))
        card.add(EnvEditor(agent: AgentDef.allAgents, env: catalog.allEnv, secrets: secretOps(AgentDef.allAgents, .shared),
                           noSecrets: AgentSecrets.Failure.noHome.localizedDescription) { [catalog] in try catalog.saveAllEnv($0) })

        card.add(Self.line())
        card.add(Self.header(model.localTitle, model.localCount))
        let sharedNames = Set(catalog.shared.map(\.name))
        let localNames = catalog.local.map(\.name)
        let plain = r.agents.filter { !sharedNames.contains($0) && !localNames.contains($0) }
        for k in localNames + plain {
            let row = CommandRow(key: k, scope: .local, info: model.local.first { $0.name == k }, card: self)
            rows.append(row)
            card.add(DashedBox.around(row))
        }
        let intake = CommandRow(key: RuntimeConfig.intakeKey, scope: .local, info: nil, card: self)
        rows.append(intake)
        card.add(Self.line())
        card.add(intake)

        card.add(Self.line())
        addField.placeholderString = "claude-fast"
        addField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        addField.setAccessibilityLabel("Agent name")
        addField.target = self
        addField.action = #selector(addAgent)
        addField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let scopes = ["All my Macs", "This Mac only"]
        let addFor = PopUp(scopes, selected: Self.addScope, label: "List of the new agent") { Self.addScope = $0 }
        addFor.isEnabled = places.home != nil
        if places.home == nil { Self.addScope = 1; addFor.selectItem(at: 1) }
        let add = ActionButton("Add") { [weak self] in self?.addAgent() }
        card.add(Wrap([NSTextField.text("Add an agent", size: 12, color: Palette.mut), addField,
                       NSTextField.text("from", size: 12, color: Palette.mut), addCLI,
                       NSTextField.text("for", size: 12, color: Palette.mut), addFor, add, addError]))
        card.add(NSTextField.text("The new agent starts with the default command of its CLI. "
                                  + "{name} workspace name (the item key) · {KEY} item key · {key} lowercase key · {title} item title. "
                                  + "OverSire quotes each value for the shell.", size: 11.5, color: Palette.dim, lines: 2))

        promptEditor(card, "Snap basket prompt", value: PROJECTS_CFG.runtime.snapPrompt, initial: SnapTicket.defaultPrompt,
                     help: "The first message of the agent after Send. {key} ticket key · {item} item id · {intake} intake id · "
                         + "{count} shot count · {workspace} · {project} · {dir} folder of the images.") { PROJECTS_CFG.runtime.snapPrompt = $0 }
        promptEditor(card, "New session prompt (intake)", value: PROJECTS_CFG.runtime.sessionIntakePrompt, initial: SessionPrompt.intakeDefault,
                     help: "The first message of a new session with an intake item. {text} the prompt · {key} item key · {item} item id · "
                         + "{intake} intake id · {workspace} · {project}. With no files, the lines with {item} drop.") { PROJECTS_CFG.runtime.sessionIntakePrompt = $0 }
        promptEditor(card, "New session prompt (files)", value: PROJECTS_CFG.runtime.sessionFilesPrompt, initial: SessionPrompt.filesDefault,
                     help: "The first message of a new session with files and no item. {text} the prompt · {paths} the file paths on the sessions machine, "
                         + "one on each line. With no files, the prompt goes as typed.") { PROJECTS_CFG.runtime.sessionFilesPrompt = $0 }
        promptEditor(card, "Plan prompt", value: PROJECTS_CFG.runtime.refinePrompt, initial: SessionPrompt.refineDefault,
                     help: "The first message of Plan on a work item. Plan on an intake item uses the intake prompt above. "
                         + "{text} title and description · {key} item key · {item} item id · {workspace} · {project}. "
                         + "With no files, the lines with {item} drop.") { PROJECTS_CFG.runtime.refinePrompt = $0 }
        observers.append(NotificationCenter.default.addObserver(forName: AgentModelBook.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rows.forEach { $0.refreshModels() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: AgentCatalog.changed, object: catalog, queue: .main) { _ in Self.changed() })
        Self.loadKeys(secrets)
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    var example: Example { examples[min(Self.exampleIndex, examples.count - 1)] }

    // MARK: Share banner

    private func shareBanner() -> NSView? {
        if let picked = Self.picking {
            let share = ActionButton(picked.isEmpty ? "Share" : "Share \(picked.count)", style: .primary) { [weak self] in self?.share(Array(picked).sorted()) }
            share.isEnabled = !picked.isEmpty
            let cancel = ActionButton("Cancel", style: .link) { Self.picking = nil; Self.changed() }
            return Banner(Tone.info, title: "Pick the agents to share with all your Macs.", body: "Use the Share box on each agent of this Mac.",
                          actions: [share, cancel])
        }
        guard let offer = model.offer, places.home != nil else { return nil }
        let all = ActionButton("Share all", style: .primary) { [weak self] in self?.share(self?.catalog.offerNames ?? []) }
        let pick = ActionButton("Pick…") { Self.picking = []; Self.changed() }
        let later = ActionButton("Not now", style: .link) { [weak self] in self?.catalog.closeShareOffer() }
        return Banner(Tone.info, title: offer, actions: [all, pick, later])
    }

    // MARK: Secrets

    /// Reads the keys on home again after 30 s, or at once with `force`. A failed read keeps the last keys.
    static func loadKeys(_ s: AgentSecrets, force: Bool = false) {
        guard force || keysAt.map({ Date().timeIntervalSince($0) > 30 }) ?? true else { return }
        keysAt = Date()
        Task { @MainActor in
            guard let k = try? await s.list().keys, k != keys else { return }
            keys = k
            changed()
        }
    }

    /// The secret calls of one agent. nil: no home, so no secrets.
    func secretOps(_ agent: String, _ scope: CatalogAgent.Scope) -> EnvEditor.Secrets? {
        guard let home = places.home else { return nil }
        let m = model, sid = secrets.scope(scope), s = secrets
        return EnvEditor.Secrets(
            home: home,
            note: { m.secretNote(agent: agent, scope: sid, key: $0) },
            missingText: { m.missingText($0) },
            set: { [weak self] k, v in self?.secretCall("save") { try await s.set(agent, scope: scope, key: k, value: v) } },
            remove: { [weak self] k in self?.secretCall("remove") { try await s.remove(agent, scope: scope, key: k) } })
    }

    private func secretCall(_ what: String, _ op: @escaping () async throws -> Void) {
        let w = window, s = secrets
        Task { @MainActor in
            do {
                try await op()
                Self.loadKeys(s, force: true)
            } catch {
                AlertConfirm.tell("OverSire could not \(what) the secret", info: error.localizedDescription, in: w)
            }
        }
    }

    /// A moved agent keeps no secret value: the app never reads one back.
    private func tellRetype(_ keys: [String: [String]]) {
        guard !keys.isEmpty else { return }
        let list = keys.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.joined(separator: ", "))" }.joined(separator: "; ")
        AlertConfirm.tell("Type the secret values again", info: "OverSire cannot move a secret value, because it never reads one back. "
                          + "Open the agent and use Type it for \(list).", in: window)
    }

    // MARK: Actions

    private func share(_ names: [String]) {
        do {
            let keys = try catalog.share(names)
            Self.picking = nil
            window?.makeFirstResponder(nil)
            tellRetype(keys)
        } catch {
            AlertConfirm.tell("OverSire cannot share the agents", info: error.localizedDescription, in: window)
        }
        Self.changed()
    }

    func shareOne(_ name: String) { share([name]) }

    func keepLocal(_ name: String) {
        AlertConfirm.ask("Keep \(name) on this Mac only?", info: "Your other Macs lose \(name). Their starts with \(name) use the defaults of the CLI.",
                         button: "Keep on this Mac", in: window) { [weak self] in
            guard let self else { return }
            do {
                let keys = try self.catalog.keepLocal(name)
                self.window?.makeFirstResponder(nil)
                self.tellRetype(keys.isEmpty ? [:] : [name: keys])
            } catch {
                AlertConfirm.tell("OverSire cannot move \(name)", info: error.localizedDescription, in: self.window)
            }
            Self.changed()
        }
    }

    func togglePick(_ name: String) {
        guard var p = Self.picking else { return }
        if p.remove(name) == nil { p.insert(name) }
        Self.picking = p
        Self.changed()
    }

    // A prompt template with Reset. An empty text gives the default again.
    private func promptEditor(_ card: Card, _ title: String, value: String, initial: String, help: String, set: @escaping (String) -> Void) {
        card.add(Self.line())
        let reset = ActionButton("Reset", style: .link) {
            set(initial)
            saveConfig()
            Self.changed()
        }
        reset.isEnabled = value != initial
        reset.setAccessibilityLabel("Reset the \(title.lowercased())")
        card.add(NSStackView(h: [NSTextField.text(title, size: 12.5, weight: .semibold), Spacer(), reset], spacing: 8))
        let prompt = SnapNoteView(placeholder: initial)
        prompt.text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        prompt.string = value
        prompt.text.setAccessibilityLabel(title)
        prompt.onChange = { t in
            set(t.isEmpty ? initial : t)
            saveConfig()
        }
        prompt.heightAnchor.constraint(equalToConstant: 96).isActive = true
        card.add(prompt)
        card.add(NSTextField.text(help, size: 11.5, color: Palette.dim, lines: 2))
    }

    static func line() -> NSView {
        let l = Box(fill: Palette.line, border: nil, radius: 0)
        l.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return l
    }

    private static func header(_ title: String, _ count: String?) -> NSView {
        let s = NSStackView(h: [NSTextField.text(title.uppercased(), size: 11, weight: .semibold, color: Palette.dim)]
                            + (count.map { [NSTextField.text($0, size: 11, color: Palette.dim)] } ?? []) + [Spacer()], spacing: 8)
        s.setAccessibilityElement(true)
        s.setAccessibilityRole(.staticText)
        s.setAccessibilityLabel([title, count].compactMap { $0 }.joined(separator: ", "))
        return s
    }

    /// The reason a name cannot be a new agent, else nil.
    static func problem(_ name: String) -> String? {
        guard name.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else { return "Use lowercase letters, digits and dashes." }
        guard name != RuntimeConfig.intakeKey, !PROJECTS_CFG.runtime.startAgents.contains(name) else { return "\(name) is an agent already." }
        return nil
    }

    @objc private func addAgent() {
        let n = addField.stringValue.trimmingCharacters(in: .whitespaces)
        if let p = Self.problem(n) { addError.stringValue = "✕ " + p; return }
        let i = addCLI.indexOfSelectedItem
        let cli = i < RuntimeConfig.baseCLIs.count ? RuntimeConfig.baseCLIs[i] : nil
        if Self.addScope == 0 && places.home != nil {
            do { try catalog.save(AgentDef(name: n, cli: cli, command: cli == nil ? n : nil), scope: .shared) } catch {
                addError.stringValue = "✕ " + error.localizedDescription
                return
            }
        } else {
            PROJECTS_CFG.runtime.add(n, cli: cli)
            saveConfig()
        }
        Self.open.insert(CommandRow.id(n, Self.addScope == 0 && places.home != nil ? .shared : .local))
        // The window does not reload a page while a field is in focus.
        window?.makeFirstResponder(nil)
        Self.changed()
    }

    func duplicate(_ key: String, scope: CatalogAgent.Scope) {
        AlertConfirm.input("Duplicate \(key)", info: "The new agent gets the command, the model, the effort, the machines and the env of \(key). "
                           + "A secret row comes with no value: type it again.",
                           placeholder: key + "-fast", button: "Duplicate", in: window) { [weak self] n in
            guard let self else { return }
            if let p = Self.problem(n) { return AlertConfirm.tell("OverSire cannot make \(n)", info: p, in: self.window) }
            if scope == .local && !PROJECTS_CFG.runtime.isLocal(key) {
                PROJECTS_CFG.runtime.duplicate(key, as: n)
                saveConfig()
            } else {
                do { try self.catalog.duplicate(key, scope: scope, as: n) } catch {
                    return AlertConfirm.tell("OverSire cannot make \(n)", info: error.localizedDescription, in: self.window)
                }
            }
            self.window?.makeFirstResponder(nil)
            Self.changed()
        }
    }

    private func resetAll() {
        PROJECTS_CFG.runtime.commands = [:]
        PROJECTS_CFG.runtime.profiles = [:]
        PROJECTS_CFG.runtime.env = [:]
        PROJECTS_CFG.runtime.runsOn = [:]
        Self.drafts = [:]
        saveConfig()
        window?.makeFirstResponder(nil)
        Self.changed()
    }

    func remove(_ key: String, scope: CatalogAgent.Scope) {
        let go = { [weak self] in
            guard let self else { return }
            if scope == .shared { self.catalog.remove(key, scope: .shared) } else {
                self.catalog.remove(key, scope: .local)
                PROJECTS_CFG.runtime.remove(key)
                saveConfig()
            }
            Self.drafts[CommandRow.id(key, scope)] = nil
            self.window?.makeFirstResponder(nil)
            Self.changed()
        }
        guard scope == .shared else { return go() }
        AlertConfirm.ask("Remove \(key) from all your Macs?", info: "The other Macs lose \(key) at their next sync.", button: "Remove",
                         critical: true, in: window, go)
    }

    func toggle(_ id: String) {
        if Self.open.remove(id) == nil { Self.open.insert(id) }
        window?.makeFirstResponder(nil)
        Self.changed()
    }

    static func changed() { ChangeBus.shared.post(.config()) }
}

// One agent: the name, tags and actions, then (when open) the template, model and effort, flags, Runs on, env and the preview.
final class CommandRow: NSStackView, NSTextFieldDelegate {
    static let effortTitles = ["Auto", "Low", "Med", "High", "Max"]

    static func id(_ key: String, _ scope: CatalogAgent.Scope) -> String { scope == .shared ? "shared/" + key : key }

    let key: String
    let scope: CatalogAgent.Scope
    private let info: AgentsModel.Row?
    private weak var card: AgentCommandsCard?
    private let field = NSTextField()
    private let tags = NSStackView(h: [], spacing: 6)
    private let reset = ActionButton("Reset", style: .link)
    private var flagButtons: [NSButton] = []
    private let modelHolder = NSStackView(h: [], spacing: 8)
    private let runsHolder = NSStackView(v: [], spacing: 6)
    private let output = NSStackView(v: [], spacing: 4)
    private let summary = NSTextField.text("", size: 12, color: Palette.dim)
    private var pending: DispatchWorkItem?

    private var id: String { Self.id(key, scope) }
    private var isIntake: Bool { key == RuntimeConfig.intakeKey }
    private var isOpen: Bool { AgentCommandsCard.open.contains(id) }
    private var cfg: RuntimeConfig { PROJECTS_CFG.runtime }
    /// The shared record. nil for a local row.
    private var def: AgentDef? { scope == .shared ? card?.catalog.agent(key, scope: .shared) : nil }
    /// The record of the row, for its env and machines.
    private var record: AgentDef {
        def ?? cfg.localDef(key) ?? AgentDef(name: key, cli: profile.cli, updatedAt: .distantPast)
    }
    private var saved: LaunchCommand {
        if isIntake { return cfg.intakeCommand }
        if scope == .shared { return def?.command.flatMap { RuntimeConfig.valid($0, key) } ?? LaunchCommand(defaultTemplate) }
        return cfg.command(for: key)
    }
    private var text: String { AgentCommandsCard.drafts[id] ?? saved.template }
    private var profile: AgentProfile {
        guard scope == .shared else { return cfg.profile(key) }
        return AgentProfile(cli: def?.cli, model: def?.model ?? "", effort: def?.effort ?? "")
    }
    private var added: Bool { !isIntake && RuntimeConfig.baseCLI(key) != key }

    init(key: String, scope: CatalogAgent.Scope, info: AgentsModel.Row?, card: AgentCommandsCard) {
        self.key = key
        self.scope = scope
        self.info = info
        self.card = card
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 7
        translatesAutoresizingMaskIntoConstraints = false
        addFull(head())
        if !isOpen && !isIntake {
            addFull(summary)
            if info?.hides == true { addFull(shadowNote()) }
            refreshSummary()
            return
        }
        if info?.hides == true { addFull(shadowNote()) }

        field.stringValue = text
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = defaultTemplate
        field.setAccessibilityLabel("\(isIntake ? "Intake agent" : key) command")
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addFull(field)

        if !isIntake { addFull(modelHolder) }
        if let flags = AgentCommandsCard.flags[isIntake ? key : profile.cli ?? ""] {
            for f in flags {
                let b = NSButton(title: f, target: self, action: #selector(toggle(_:)))
                b.setButtonType(.pushOnPushOff)
                b.bezelStyle = .recessed
                b.controlSize = .small
                b.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
                b.identifier = NSUserInterfaceItemIdentifier(f)
                flagButtons.append(b)
            }
            addFull(Wrap([NSTextField.text("Flags", size: 11, color: Palette.dim)] + flagButtons))
        }
        if !isIntake {
            addFull(runsHolder)
            addFull(envSection())
        }
        addFull(output)
        if let c = profile.cli, !isIntake { AgentModelBook.shared.load(c) }
        refreshModels()
        refreshRuns()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func head() -> NSView {
        let name = NSTextField.text(isIntake ? "Intake agent" : key, size: 13, weight: .semibold)
        var top: [NSView] = []
        if let picked = AgentCommandsCard.picking, scope == .local, !isIntake {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(pick))
            box.state = picked.contains(key) ? .on : .off
            box.setAccessibilityLabel("Share \(key)")
            top.append(box)
        }
        top.append(name)
        name.setContentCompressionResistancePriority(.required, for: .horizontal)
        var chips: [NSView] = []
        if isIntake {
            top.append(NSTextField.text("new item from a note, plan mode", size: 12, color: Palette.dim))
        } else {
            if key == cfg.agent && !(scope == .shared && info?.shadowed == true) { chips.append(Chiplet("▶ default agent on this Mac", color: Palette.acc)) }
            if added { chips.append(NSTextField.text(profile.cli.map { "CLI: " + $0 } ?? "CLI: none · terminal only", size: 12, color: Palette.dim)) }
            if let e = info?.env {
                let missing = info?.missing.isEmpty == false
                let c = Chiplet(missing ? "△ " + e : e, color: missing ? Palette.warn : Palette.mut)
                c.toolTip = missing ? "A secret has no value on \(card?.places.home ?? "home"). Open the agent to type it." : nil
                chips.append(c)
            }
            if info?.shadowed == true {
                let c = Chiplet("△ this Mac uses its own", color: Palette.warn)
                c.toolTip = "An agent of this Mac has the same name. On this Mac it wins. Your other Macs use this one."
                chips.append(c)
            }
        }
        top.append(Spacer())
        if let e = info?.edited { top.append(NSTextField.text(e, size: 11.5, color: Palette.dim)) }
        if !isIntake {
            let dup = ActionButton("Duplicate", style: .link) { [weak self] in if let self { self.card?.duplicate(self.key, scope: self.scope) } }
            dup.setAccessibilityLabel("Duplicate the \(key) agent")
            top.append(dup)
            if scope == .shared {
                let keep = ActionButton("Keep on this Mac only", style: .link) { [weak self] in if let self { self.card?.keepLocal(self.key) } }
                keep.setAccessibilityLabel("Keep \(key) on this Mac only")
                top.append(keep)
            } else if card?.places.home != nil, cfg.isLocal(key) {
                let share = ActionButton("Share", style: .link) { [weak self] in if let self { self.card?.shareOne(self.key) } }
                share.setAccessibilityLabel("Share \(key) with all your Macs")
                top.append(share)
            }
        }
        reset.onClick = { [weak self] in self?.resetRow() }
        reset.setAccessibilityLabel("Reset the \(isIntake ? "intake agent" : key) command")
        if removable {
            let rm = ActionButton("Remove", style: .link) { [weak self] in if let self { self.card?.remove(self.key, scope: self.scope) } }
            rm.setAccessibilityLabel("Remove the \(key) agent")
            top.append(rm)
        } else if isOpen || isIntake {
            top.append(reset)
        }
        if !isIntake {
            let edit = ActionButton(isOpen ? "Done" : "Edit", style: isOpen ? .plain : .link) { [weak self] in if let self { self.card?.toggle(self.id) } }
            edit.setAccessibilityLabel(isOpen ? "Close \(key)" : "Edit \(key)")
            top.append(edit)
        }
        // The chips go on a second line, so that the actions fit.
        let head = NSStackView(v: [], spacing: 4)
        head.addFull(NSStackView(h: top, spacing: 8))
        head.addFull(NSStackView(h: chips + [tags, Spacer()], spacing: 8))
        return head
    }

    private var removable: Bool {
        if isIntake { return false }
        if scope == .shared { return true }
        return !AgentCommandsCard.known.contains(key) && key != cfg.agent || info?.hides == true
    }

    @objc private func pick() { card?.togglePick(key) }

    /// A local agent with the name of a shared agent.
    private func shadowNote() -> NSView {
        let share = ActionButton("Share mine", style: .link) { [weak self] in if let self { self.card?.shareOne(self.key) } }
        let remove = ActionButton("Remove mine", style: .link) { [weak self] in if let self { self.card?.remove(self.key, scope: .local) } }
        let text = "Same name in both lists. On this Mac, the agent of this Mac wins. Your other Macs use the shared one."
        let v = NSStackView(h: [NSTextField.text("△", size: 11.5, weight: .bold, color: Palette.warn),
                                NSTextField.text(text, size: 11.5, color: Palette.warn, lines: 2), share,
                                NSTextField.text("·", size: 11.5, color: Palette.dim), remove], spacing: 6, align: .firstBaseline)
        v.setAccessibilityLabel(text)
        return v
    }

    private var defaultTemplate: String {
        if scope == .shared, !isIntake { return LaunchCommand.defaultFor(AgentName(rawValue: def?.cli ?? key)).template }
        return cfg.defaultCommand(key).template
    }

    private func refreshSummary() {
        let p = profile
        let parts = [p.cli == nil ? nil : AgentModelBook.shared.detail(p), info?.runs ?? "any machine"].compactMap { $0 }
        summary.stringValue = parts.joined(separator: " · ") + (info?.refusal.map { " · ✕ " + $0 } ?? "")
        summary.textColor = info?.refusal == nil ? Palette.dim : Palette.warn
    }

    func controlTextDidChange(_ n: Notification) { apply(field.stringValue, typed: true) }

    @objc private func toggle(_ b: NSButton) {
        guard let f = b.identifier?.rawValue else { return }
        let words = " " + text.trimmingCharacters(in: .whitespaces) + " "
        let next = words.contains(" \(f) ") ? words.replacingOccurrences(of: " \(f) ", with: " ") : words + f
        apply(next.trimmingCharacters(in: .whitespaces))
    }

    // A good template saves at once. A bad one stays as a draft and the saved command does not change.
    // A typed change of a shared agent waits a short time, so the store gets one write.
    private func apply(_ t: String, typed: Bool = false) {
        if !typed { field.stringValue = t }
        do {
            try LaunchCommand(t).validate()
            AgentCommandsCard.drafts[id] = nil
            if scope == .shared {
                saveShared(typed: typed) { $0.command = t.trimmingCharacters(in: .whitespacesAndNewlines) == self.defaultTemplate ? nil : t }
            } else {
                PROJECTS_CFG.runtime.setCommand(key, t)
                saveConfig()
            }
        } catch {
            AgentCommandsCard.drafts[id] = t
        }
        refresh()
    }

    private func saveShared(typed: Bool = false, _ change: @escaping (inout AgentDef) -> Void) {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, var d = self.def else { return }
            change(&d)
            self.save(d)
        }
        pending = w
        if typed { DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w) } else { w.perform() }
    }

    private func save(_ d: AgentDef) {
        do { try card?.catalog.save(d, scope: scope) } catch {
            output.addFull(EnvEditor.message("✕", error.localizedDescription, Palette.bad))
        }
    }

    private func resetRow() {
        if scope == .shared {
            saveShared { $0.command = nil; $0.model = nil; $0.effort = nil }
            field.stringValue = defaultTemplate
            AgentCommandsCard.drafts[id] = nil
            AgentCommandsCard.changed()
            return
        }
        if !isIntake { PROJECTS_CFG.runtime.setProfile(key, AgentProfile(cli: profile.cli)) }
        apply(defaultTemplate)
        AgentCommandsCard.changed()
    }

    private func setProfile(_ change: (inout AgentProfile) -> Void) {
        var p = profile
        change(&p)
        if scope == .shared {
            let q = p
            saveShared { $0.cli = q.cli; $0.model = q.model.isEmpty ? nil : q.model; $0.effort = q.effort.isEmpty ? nil : q.effort }
        } else {
            PROJECTS_CFG.runtime.setProfile(key, p)
            saveConfig()
        }
        refreshModels()
        refresh()
    }

    /// The Model pop-up and the Effort control. A row with no base CLI asks for one.
    func refreshModels() {
        guard !isIntake, isOpen else { refreshSummary(); return }
        modelHolder.clear()
        let p = profile
        guard let cli = p.cli else {
            let clis = RuntimeConfig.baseCLIs
            let pick = PopUp(["none"] + clis, selected: 0, label: "Base CLI of \(key)") { [weak self] i in
                guard i > 0, let self else { return }
                self.setProfile { $0.cli = clis[i - 1] }
                AgentCommandsCard.changed()
            }
            modelHolder.addArrangedSubview(NSTextField.text("Base CLI", size: 11.5, color: Palette.mut))
            modelHolder.addArrangedSubview(pick)
            modelHolder.addArrangedSubview(Spacer())
            return
        }
        let book = AgentModelBook.shared
        let list = book.lists[cli]
        var ids = [""] + (list?.models.map(\.id) ?? [])
        var titles = ["Auto"] + (list?.models.map { $0.name ?? $0.id } ?? [])
        if !p.model.isEmpty && !ids.contains(p.model) {
            ids.append(p.model)
            titles.append(p.model)
        }
        if list == nil {
            ids.append("")
            titles.append("Loading the models…")
        }
        titles.append("Other model id…")
        let model = PopUp(titles, selected: ids.firstIndex(of: p.model) ?? 0, label: "Model of \(key)") { [weak self] i in
            guard let self else { return }
            if i == titles.count - 1 { return self.otherModel() }
            self.setProfile { $0.model = ids[i] }
        }
        if list == nil {
            model.autoenablesItems = false
            model.item(at: titles.count - 2)?.isEnabled = false
        }
        modelHolder.addArrangedSubview(NSTextField.text("Model", size: 11.5, color: Palette.mut))
        modelHolder.addArrangedSubview(model)
        if let w = list?.warning {
            let mark = Glyph("exclamationmark.triangle", color: Palette.warn, size: 11, label: w)
            mark.toolTip = w
            modelHolder.addArrangedSubview(mark)
            let part = book.part(cli)
            modelHolder.addArrangedSubview(ReadAccessory(part, compact: !part.state.didFail))
        }
        if p.hasEffort {
            let levels = AgentProfile.efforts
            modelHolder.addArrangedSubview(NSTextField.text("Effort", size: 11.5, color: Palette.mut))
            modelHolder.addArrangedSubview(Segmented(Self.effortTitles, selected: levels.firstIndex(of: p.effort) ?? 0, label: "Effort of \(key)") { [weak self] i in
                self?.setProfile { $0.effort = levels[i] }
            })
        }
        modelHolder.addArrangedSubview(Spacer())
    }

    private func otherModel() {
        AlertConfirm.input("Model id for \(key)", info: "The id that the CLI takes, for example claude-opus-5-5.",
                           value: profile.model, button: "Use", in: window) { [weak self] id in
            self?.setProfile { $0.model = id }
        }
        refreshModels()
    }

    // MARK: Runs on and env

    /// Any machine, or a list of machines as chips. A list keeps at least one machine.
    private func refreshRuns() {
        runsHolder.clear()
        guard let places = card?.places else { return }
        let list = record.runsOn
        let seg = Segmented(["Any machine", "Only…"], selected: list == nil ? 0 : 1, label: "Runs on of \(key)") { [weak self] i in
            self?.setRunsOn(i == 0 ? nil : [places.sessions])
        }
        var views: [NSView] = [NSTextField.text("Runs on", size: 11.5, color: Palette.mut), seg]
        if let list {
            for m in places.machines {
                let on = list.contains(m.name)
                let chip = ToggleChip(m.label, on: on, enabled: !(on && list.count == 1)) { [weak self] in
                    self?.setRunsOn(on ? list.filter { $0 != m.name } : list + [m.name])
                }
                chip.setAccessibilityLabel("Runs on \(m.name)")
                views.append(chip)
            }
            for gone in list where !places.machines.contains(where: { $0.name == gone }) {
                let chip = Chiplet("✕ \(gone): not in the group", color: Palette.bad) { [weak self] in
                    let rest = list.filter { $0 != gone }
                    self?.setRunsOn(rest.isEmpty ? nil : rest)
                }
                chip.toolTip = "Click to remove \(gone) from the list."
                views.append(chip)
            }
        }
        runsHolder.addFull(Wrap(views))
    }

    private func setRunsOn(_ list: [String]?) {
        var d = record
        d.runsOn = list
        save(d)
        refreshRuns()
        refresh()
    }

    private func envSection() -> NSView {
        guard let card else { return NSView() }
        let shared = scope == .shared
        let editor = EnvEditor(agent: key, env: record.env, inherited: card.catalog.allEnv, secrets: card.secretOps(key, scope),
                               noSecrets: AgentSecrets.Failure.noHome.localizedDescription) { [weak self] env in
            guard let self else { return }
            var d = self.record
            d.env = env
            try card.catalog.save(d, scope: self.scope)
            self.refresh()
        }
        let note = shared ? "Env · all your Macs get these rows." : "Env · only this Mac has these rows."
        return NSStackView(v: [NSTextField.text(note, size: 11.5, color: Palette.mut), editor], spacing: 4)
    }

    /// The start of the example item: the merged env and the machines of the row.
    private var launch: AgentLaunch {
        let ex = card?.example ?? AgentCommandsCard.Example(key: "ENG-42", title: "Sample item")
        let d = record
        let ref = AgentSecretRef(agent: key, scope: card?.secrets.scope(scope) ?? AgentSecretRef.shared)
        let e = AgentEnv.merged(shared: card?.catalog.allEnv ?? [], agent: d.env, agentRef: ref, name: ex.key, key: ex.key, title: ex.title)
        return AgentLaunch(profile: key, cli: profile.cli ?? key, env: e.env, envSecrets: e.secrets, runsOn: d.runsOn)
    }

    func refresh() {
        guard isOpen || isIntake else { refreshSummary(); return }
        let c = LaunchCommand(text)
        let p = profile
        let custom = AgentCommandsCard.drafts[id] != nil
            || (scope == .shared ? def?.command != nil : cfg.commands[key].map { $0 != defaultTemplate } == true)
            || (!isIntake && !added && scope == .local && cfg.profiles[key] != nil)
        tags.clear()
        if (!added || isIntake) && scope == .local { tags.addArrangedSubview(Chiplet(custom ? "● custom" : "default", color: custom ? Palette.acc : Palette.dim)) }
        if c.skipsPermissions { tags.addArrangedSubview(Chiplet("⚠ Skips permissions", color: Palette.bad)) }
        reset.isEnabled = custom || (scope == .shared && (def?.model != nil || def?.effort != nil))
        for b in flagButtons {
            let f = b.identifier?.rawValue ?? ""
            let on = (" " + text + " ").contains(" \(f) ")
            b.state = on ? .on : .off
            b.title = on ? "✓ " + f : f
            b.setAccessibilityValue(on ? "on" : "off")
        }

        output.clear()
        let ex = card?.example ?? AgentCommandsCard.Example(key: "ENG-42", title: "Sample item")
        do {
            let resolved = ([try c.resolve(name: isIntake ? "intake-" + ex.key : ex.key, key: ex.key, title: ex.title)]
                            + p.flags(for: c).map(LaunchCommand.quote)).joined(separator: " ")
            var lines: [(String, String)] = []
            if !isIntake, let places = card?.places {
                let pv = AgentsModel.preview(launch, places: places)
                lines.append(("on", pv.on))
                if let e = pv.env { lines.append(("env", e)) }
            }
            lines.append(("runs", resolved))
            output.addFull(Self.preview(lines))
        } catch {
            output.addFull(EnvEditor.message("✕", "\(error) OverSire keeps the last good command.", Palette.bad))
        }
        for w in warnings(c, p) { output.addFull(EnvEditor.message("△", w, Palette.warn)) }
    }

    private static func preview(_ lines: [(String, String)]) -> NSView {
        let box = Box(fill: Palette.side, border: Palette.line, radius: 6)
        let stack = NSStackView(v: [], spacing: 3)
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
        for (k, v) in lines {
            let row = NSStackView(h: [NSTextField.text(k, size: 11.5, color: Palette.dim, mono: true).fixedWidth(34),
                                      NSTextField.text(v, size: 11.5, color: Palette.fg, lines: 3, mono: true)], spacing: 10, align: .firstBaseline)
            row.distribution = .fill
            stack.addFull(row)
        }
        box.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor), stack.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            stack.topAnchor.constraint(equalTo: box.topAnchor), stack.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        box.setAccessibilityElement(true)
        box.setAccessibilityLabel(lines.map { "\($0.0) \($0.1)" }.joined(separator: ". "))
        return box
    }

    private func warnings(_ c: LaunchCommand, _ p: AgentProfile) -> [String] {
        var out: [String] = []
        if c.program == "claude" && !c.template.contains("{name}") {
            out.append("Without -n {name}, the Claude session does not show the item key.")
        }
        if isIntake {
            if !(" " + c.template + " ").contains(" --permission-mode plan ") {
                out.append("The intake agent writes the item. Without plan mode it can also change files.")
            }
            return out
        }
        guard let cli = p.cli else {
            out.append("\(key) is not a known CLI. Pick a base CLI to set a model and an effort.")
            return out
        }
        if AgentEnv.commandSetsEnv(c.template) {
            out.append("Put the env in the Env rows. A runner refuses a command that does not start with \(cli).")
        } else {
            let program = RuntimeConfig.baseCLI(c.program)
            if !c.program.isEmpty && program != cli { out.append("A runner refuses a command that does not start with \(cli).") }
        }
        if !p.model.isEmpty && AgentProfile.sets(AgentProfile.modelFlags, in: c.template) {
            out.append("The template sets the model too. The template wins.")
        }
        if p.hasEffort && !p.effort.isEmpty && AgentProfile.sets(AgentProfile.effortFlags, in: c.template) {
            out.append("The template sets the effort too. The template wins.")
        }
        if let w = AgentModelBook.shared.warning(p), AgentModelBook.shared.lists[cli]?.warning != w { out.append(w) }
        if let r = card.flatMap({ launch.refusal(on: $0.places.sessions) }) { out.append(r + " Pick another machine in the start menu.") }
        return out
    }
}
