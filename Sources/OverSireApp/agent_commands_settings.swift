import Cocoa
import OverSireCore

// Settings › Agents and queue › Agents: each agent is a base CLI with a command, a model and an effort.
// Each runtime that starts the agent in a terminal uses the command. A change saves at once. A bad template saves nothing.
final class AgentCommandsCard: NSStackView {
    static let known = RuntimeConfig.knownAgents
    // Flag toggles per base CLI. The model has its own control.
    static let flags: [String: [String]] = [
        "claude": ["--dangerously-skip-permissions", "--permission-mode acceptEdits", "--continue"],
        "codex": ["--dangerously-bypass-approvals-and-sandbox", "--full-auto"],
        RuntimeConfig.intakeKey: ["--dangerously-skip-permissions"],
    ]
    /// Unsaved text of a row whose template is bad. The page keeps it until Settings shows another page.
    static var drafts: [String: String] = [:]
    static var exampleIndex = 0

    struct Example { var key: String; var title: String }
    /// `terminal`: the runtime types the command. Else it takes only the model and the effort.
    struct User { var name: String; var terminal: Bool }

    private let examples: [Example]
    private var rows: [CommandRow] = []
    private let addField = NSTextField()
    private let addCLI: PopUp
    private let addError = NSTextField.text("", size: 11.5, color: Palette.bad)
    private var observer: NSObjectProtocol?

    init(examples: [Example], usedBy: [User]) {
        self.examples = examples
        addCLI = PopUp(RuntimeConfig.baseCLIs + ["none (terminal only)"], selected: 0, label: "Base CLI of the new agent") { _ in }
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        let r = PROJECTS_CFG.runtime
        let resetAll = ActionButton("Reset all", style: .link) { [weak self] in self?.resetAll() }
        resetAll.isEnabled = !r.commands.isEmpty || !r.profiles.isEmpty || !Self.drafts.isEmpty
        addFull(SectionTitle("Agents", action: resetAll))
        let card = Card(spacing: 12)
        addFull(card)

        card.add(NSTextField.text("Each agent is a base CLI with a command, a model and an effort. "
                                  + "Make more than one agent for the same CLI to keep combinations at hand.", size: 12, color: Palette.dim, lines: 2))
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

        for k in r.agents + [RuntimeConfig.intakeKey] {
            let row = CommandRow(key: k, removable: !Self.known.contains(k) && k != r.agent && k != RuntimeConfig.intakeKey, card: self)
            rows.append(row)
            card.add(Self.line())
            card.add(row)
        }

        card.add(Self.line())
        addField.placeholderString = "claude-fast"
        addField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        addField.setAccessibilityLabel("Agent name")
        addField.target = self
        addField.action = #selector(addAgent)
        addField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let add = ActionButton("Add") { [weak self] in self?.addAgent() }
        card.add(NSStackView(h: [NSTextField.text("Add an agent", size: 12, color: Palette.mut), addField,
                                 NSTextField.text("from", size: 12, color: Palette.mut), addCLI, add, addError, Spacer()], spacing: 8))
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
        promptEditor(card, "Refine prompt", value: PROJECTS_CFG.runtime.refinePrompt, initial: SessionPrompt.refineDefault,
                     help: "The first message of Refine on a work item. Refine on an intake item uses the intake prompt above. "
                         + "{text} title and description · {key} item key · {item} item id · {workspace} · {project}. "
                         + "With no files, the lines with {item} drop.") { PROJECTS_CFG.runtime.refinePrompt = $0 }
        observer = NotificationCenter.default.addObserver(forName: AgentModelBook.changed, object: nil, queue: .main) { [weak self] _ in
            self?.rows.forEach { $0.refreshModels() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    var example: Example { examples[min(Self.exampleIndex, examples.count - 1)] }

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

    private static func line() -> NSView {
        let l = Box(fill: Palette.line, border: nil, radius: 0)
        l.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return l
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
        PROJECTS_CFG.runtime.add(n, cli: i < RuntimeConfig.baseCLIs.count ? RuntimeConfig.baseCLIs[i] : nil)
        saveConfig()
        // The window does not reload a page while a field is in focus.
        window?.makeFirstResponder(nil)
        Self.changed()
    }

    func duplicate(_ key: String) {
        AlertConfirm.input("Duplicate \(key)", info: "The new agent gets the command, the model and the effort of \(key).",
                           placeholder: key + "-fast", button: "Duplicate", in: window) { [weak self] n in
            if let p = Self.problem(n) { return AlertConfirm.tell("OverSire cannot make \(n)", info: p, in: self?.window) }
            PROJECTS_CFG.runtime.duplicate(key, as: n)
            saveConfig()
            self?.window?.makeFirstResponder(nil)
            Self.changed()
        }
    }

    private func resetAll() {
        PROJECTS_CFG.runtime.commands = [:]
        PROJECTS_CFG.runtime.profiles = [:]
        Self.drafts = [:]
        saveConfig()
        window?.makeFirstResponder(nil)
        Self.changed()
    }

    func remove(_ key: String) {
        PROJECTS_CFG.runtime.remove(key)
        Self.drafts[key] = nil
        saveConfig()
        window?.makeFirstResponder(nil)
        Self.changed()
    }

    static func changed() { ChangeBus.shared.post(.config()) }
}

// One agent: name, tags, the template, model and effort, flag toggles, the resolved command and the checks.
final class CommandRow: NSStackView, NSTextFieldDelegate {
    static let effortTitles = ["Auto", "Low", "Med", "High", "Max"]

    let key: String
    private weak var card: AgentCommandsCard?
    private let field = NSTextField()
    private let tags = NSStackView(h: [], spacing: 6)
    private let reset = ActionButton("Reset", style: .link)
    private var flagButtons: [NSButton] = []
    private let modelHolder = NSStackView(h: [], spacing: 8)
    private let output = NSStackView(v: [], spacing: 4)

    private var isIntake: Bool { key == RuntimeConfig.intakeKey }
    private var saved: LaunchCommand { isIntake ? PROJECTS_CFG.runtime.intakeCommand : PROJECTS_CFG.runtime.command(for: key) }
    private var text: String { AgentCommandsCard.drafts[key] ?? saved.template }
    private var profile: AgentProfile { PROJECTS_CFG.runtime.profile(key) }
    private var added: Bool { !isIntake && RuntimeConfig.baseCLI(key) != key }

    init(key: String, removable: Bool, card: AgentCommandsCard) {
        self.key = key
        self.card = card
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 7
        translatesAutoresizingMaskIntoConstraints = false

        let r = PROJECTS_CFG.runtime
        let name = NSTextField.text(isIntake ? "Intake agent" : key, size: 13, weight: .semibold)
        var top: [NSView] = [name]
        if isIntake {
            top.append(NSTextField.text("new item from a note, plan mode", size: 12, color: Palette.dim))
        } else if key == r.agent {
            top.append(Chiplet("▶ default agent", color: Palette.acc))
        } else if added {
            top.append(NSTextField.text(profile.cli.map { "CLI: " + $0 } ?? "CLI: none · terminal only", size: 12, color: Palette.dim))
        }
        top += [tags, Spacer()]
        if !isIntake {
            let dup = ActionButton("Duplicate", style: .link) { [weak self, weak card] in if let self { card?.duplicate(self.key) } }
            dup.setAccessibilityLabel("Duplicate the \(key) agent")
            top.append(dup)
        }
        reset.onClick = { [weak self] in self?.resetRow() }
        reset.setAccessibilityLabel("Reset the \(isIntake ? "intake agent" : key) command")
        if removable {
            let rm = ActionButton("Remove", style: .link) { [weak self, weak card] in if let self { card?.remove(self.key) } }
            rm.setAccessibilityLabel("Remove the \(key) agent")
            top.append(rm)
        } else {
            top.append(reset)
        }
        addFull(NSStackView(h: top, spacing: 8))

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
        addFull(output)
        if let c = profile.cli, !isIntake { AgentModelBook.shared.load(c) }
        refreshModels()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    private var defaultTemplate: String { PROJECTS_CFG.runtime.defaultCommand(key).template }

    func controlTextDidChange(_ n: Notification) { apply(field.stringValue, typed: true) }

    @objc private func toggle(_ b: NSButton) {
        guard let f = b.identifier?.rawValue else { return }
        let words = " " + text.trimmingCharacters(in: .whitespaces) + " "
        let next = words.contains(" \(f) ") ? words.replacingOccurrences(of: " \(f) ", with: " ") : words + f
        apply(next.trimmingCharacters(in: .whitespaces))
    }

    // A good template saves at once. A bad one stays as a draft and the saved command does not change.
    private func apply(_ t: String, typed: Bool = false) {
        if !typed { field.stringValue = t }
        do {
            try LaunchCommand(t).validate()
            AgentCommandsCard.drafts[key] = nil
            PROJECTS_CFG.runtime.setCommand(key, t)
            saveConfig()
        } catch {
            AgentCommandsCard.drafts[key] = t
        }
        refresh()
    }

    private func resetRow() {
        if !isIntake { PROJECTS_CFG.runtime.setProfile(key, AgentProfile(cli: profile.cli)) }
        apply(defaultTemplate)
        AgentCommandsCard.changed()
    }

    private func setProfile(_ change: (inout AgentProfile) -> Void) {
        var p = profile
        change(&p)
        PROJECTS_CFG.runtime.setProfile(key, p)
        saveConfig()
        refreshModels()
        refresh()
    }

    /// The Model pop-up and the Effort control. A row with no base CLI asks for one.
    func refreshModels() {
        guard !isIntake else { return }
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

    func refresh() {
        let c = LaunchCommand(text)
        let p = profile
        let custom = AgentCommandsCard.drafts[key] != nil || PROJECTS_CFG.runtime.commands[key].map { $0 != defaultTemplate } == true
            || (!isIntake && !added && PROJECTS_CFG.runtime.profiles[key] != nil)
        tags.clear()
        if !added || isIntake { tags.addArrangedSubview(Chiplet(custom ? "● custom" : "default", color: custom ? Palette.acc : Palette.dim)) }
        if c.skipsPermissions { tags.addArrangedSubview(Chiplet("⚠ Skips permissions", color: Palette.bad)) }
        reset.isEnabled = custom
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
            let box = Box(fill: Palette.side, border: Palette.line, radius: 6)
            let line = NSStackView(h: [NSTextField.text("runs", size: 11.5, color: Palette.dim, mono: true),
                                       NSTextField.text(resolved, size: 11.5, color: Palette.fg, mono: true), Spacer()], spacing: 10)
            line.edgeInsets = NSEdgeInsets(top: 5, left: 9, bottom: 5, right: 9)
            box.addSubview(line)
            NSLayoutConstraint.activate([
                line.leadingAnchor.constraint(equalTo: box.leadingAnchor), line.trailingAnchor.constraint(equalTo: box.trailingAnchor),
                line.topAnchor.constraint(equalTo: box.topAnchor), line.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            ])
            box.setAccessibilityElement(true)
            box.setAccessibilityLabel("Runs \(resolved)")
            output.addFull(box)
        } catch {
            output.addFull(message("✕", "\(error) OverSire keeps the last good command.", Palette.bad))
        }
        for w in warnings(c, p) { output.addFull(message("△", w, Palette.warn)) }
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
        let program = RuntimeConfig.baseCLI(c.program)
        if !c.program.isEmpty && program != cli {
            out.append("A runner refuses a command that does not start with \(cli).")
        }
        if !p.model.isEmpty && AgentProfile.sets(AgentProfile.modelFlags, in: c.template) {
            out.append("The template sets the model too. The template wins.")
        }
        if p.hasEffort && !p.effort.isEmpty && AgentProfile.sets(AgentProfile.effortFlags, in: c.template) {
            out.append("The template sets the effort too. The template wins.")
        }
        if let w = AgentModelBook.shared.warning(p), AgentModelBook.shared.lists[cli]?.warning != w { out.append(w) }
        return out
    }

    private func message(_ mark: String, _ text: String, _ color: NSColor) -> NSView {
        let v = NSStackView(h: [NSTextField.text(mark, size: 11.5, weight: .bold, color: color),
                                NSTextField.text(text, size: 11.5, color: color, lines: 2)], spacing: 6, align: .firstBaseline)
        v.setAccessibilityElement(true)
        v.setAccessibilityLabel(text)
        return v
    }
}
