import Cocoa
import OverSireCore

// Settings › Agents and queue › Agent commands: one start command for each agent and one for the intake agent.
// Each runtime that starts the agent in a terminal uses them. A change saves at once. A bad template saves nothing.
final class AgentCommandsCard: NSStackView {
    static let known = RuntimeConfig.knownAgents
    // Flag toggles per row.
    static let flags: [String: [String]] = [
        "claude": ["--dangerously-skip-permissions", "--permission-mode acceptEdits", "--model opus", "--continue"],
        "codex": ["--dangerously-bypass-approvals-and-sandbox", "--full-auto", "--model gpt-5"],
        RuntimeConfig.intakeKey: ["--dangerously-skip-permissions", "--model opus"],
    ]
    /// Unsaved text of a row whose template is bad. The page keeps it until Settings shows another page.
    static var drafts: [String: String] = [:]
    static var exampleIndex = 0

    struct Example { var key: String; var title: String }
    struct User { var name: String; var terminal: Bool }

    private let examples: [Example]
    private var rows: [CommandRow] = []
    private let addField = NSTextField()
    private let addError = NSTextField.text("", size: 11.5, color: Palette.bad)

    init(examples: [Example], usedBy: [User]) {
        self.examples = examples
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        let resetAll = ActionButton("Reset all", style: .link) { [weak self] in self?.resetAll() }
        resetAll.isEnabled = !PROJECTS_CFG.runtime.commands.isEmpty || !Self.drafts.isEmpty
        addFull(SectionTitle("Agent commands", action: resetAll))
        let card = Card(spacing: 12)
        addFull(card)

        let note = NSTextField.text("How a runtime starts each agent in a terminal. A project keeps its agent; the command of that agent applies.",
                                    size: 12, color: Palette.dim, lines: 2)
        card.add(note)
        let used: [NSView] = [NSTextField.text("Used by", size: 12, color: Palette.mut)] + (usedBy.isEmpty
            ? [NSTextField.text("No runtime account. Add one in Settings › Accounts and sync.", size: 12, color: Palette.dim)]
            : usedBy.map { u in
                let c = Chiplet(u.terminal ? "✓ \(u.name)" : "– \(u.name) (no terminal)", color: u.terminal ? Palette.ok : Palette.dim)
                c.toolTip = u.terminal ? "Types the command into a terminal." : "Starts the agent over its protocol, without a command line."
                return c
            })
        card.add(Wrap(used))

        let pick = PopUp(examples.map(\.key), selected: min(Self.exampleIndex, examples.count - 1), label: "Example item") { [weak self] i in
            Self.exampleIndex = i
            self?.rows.forEach { $0.refresh() }
        }
        card.add(NSStackView(h: [NSTextField.text("Example item", size: 12, color: Palette.mut), pick, Spacer()], spacing: 8))

        let r = PROJECTS_CFG.runtime
        for k in r.agents + [RuntimeConfig.intakeKey] {
            let row = CommandRow(key: k, removable: !Self.known.contains(k) && k != r.agent && k != RuntimeConfig.intakeKey, card: self)
            rows.append(row)
            card.add(Self.line())
            card.add(row)
        }

        card.add(Self.line())
        addField.placeholderString = "gemini"
        addField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        addField.setAccessibilityLabel("Agent name")
        addField.target = self
        addField.action = #selector(addAgent)
        addField.widthAnchor.constraint(equalToConstant: 140).isActive = true
        let add = ActionButton("Add") { [weak self] in self?.addAgent() }
        card.add(NSStackView(h: [NSTextField.text("Add a command for another agent", size: 12, color: Palette.mut), addField, add, addError, Spacer()],
                             spacing: 8))
        card.add(NSTextField.text("{name} workspace name (the item key) · {KEY} item key · {key} lowercase key · {title} item title. "
                                  + "OverSire quotes each value for the shell.", size: 11.5, color: Palette.dim, lines: 2))

        promptEditor(card, "Snap basket prompt", value: PROJECTS_CFG.runtime.snapPrompt, initial: SnapTicket.defaultPrompt,
                     help: "The first message of the agent after Send. {key} ticket key · {item} item id · {intake} intake id · "
                         + "{count} shot count · {workspace} · {project} · {dir} folder of the images.") { PROJECTS_CFG.runtime.snapPrompt = $0 }
        promptEditor(card, "New session prompt (intake)", value: PROJECTS_CFG.runtime.sessionIntakePrompt, initial: SessionPrompt.intakeDefault,
                     help: "The first message of a new session with an intake item. {text} the prompt · {key} item key · {item} item id · "
                         + "{intake} intake id · {workspace} · {project}. With no files, the lines with {item} drop.") { PROJECTS_CFG.runtime.sessionIntakePrompt = $0 }
        promptEditor(card, "New session prompt (files)", value: PROJECTS_CFG.runtime.sessionFilesPrompt, initial: SessionPrompt.filesDefault,
                     help: "The first message of a new session with files and no item. {text} the prompt · {paths} the file paths on the Orca host, "
                         + "one on each line. With no files, the prompt goes as typed.") { PROJECTS_CFG.runtime.sessionFilesPrompt = $0 }
    }
    required init?(coder: NSCoder) { fatalError() }

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

    @objc private func addAgent() {
        let n = addField.stringValue.trimmingCharacters(in: .whitespaces)
        guard n.range(of: "^[a-z0-9][a-z0-9-]*$", options: .regularExpression) != nil else {
            addError.stringValue = "✕ Use lowercase letters, digits and dashes."
            return
        }
        guard !rows.contains(where: { $0.key == n }) else { addError.stringValue = "✕ \(n) has a command already."; return }
        PROJECTS_CFG.runtime.setCommand(n, PROJECTS_CFG.runtime.defaultCommand(n).template)
        saveConfig()
        // The window does not reload a page while a field is in focus.
        window?.makeFirstResponder(nil)
        Self.changed()
    }

    private func resetAll() {
        PROJECTS_CFG.runtime.commands = [:]
        Self.drafts = [:]
        saveConfig()
        Self.changed()
    }

    func remove(_ key: String) {
        PROJECTS_CFG.runtime.commands[key] = nil
        Self.drafts[key] = nil
        saveConfig()
        Self.changed()
    }

    static func changed() { ChangeBus.shared.post(.config()) }
}

// One agent: name, tags, the template, flag toggles, the resolved command and the checks.
final class CommandRow: NSStackView, NSTextFieldDelegate {
    let key: String
    private weak var card: AgentCommandsCard?
    private let field = NSTextField()
    private let tags = NSStackView(h: [], spacing: 6)
    private let reset = ActionButton("Reset", style: .link)
    private var flagButtons: [NSButton] = []
    private let output = NSStackView(v: [], spacing: 4)

    private var isIntake: Bool { key == RuntimeConfig.intakeKey }
    private var saved: LaunchCommand { isIntake ? PROJECTS_CFG.runtime.intakeCommand : PROJECTS_CFG.runtime.command(for: key) }
    private var text: String { AgentCommandsCard.drafts[key] ?? saved.template }

    init(key: String, removable: Bool, card: AgentCommandsCard) {
        self.key = key
        self.card = card
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 7
        translatesAutoresizingMaskIntoConstraints = false

        let name = NSTextField.text(isIntake ? "Intake agent" : key, size: 13, weight: .semibold)
        let when = NSTextField.text(isIntake ? "new item from a note, plan mode" : "▶ start item", size: 12, color: Palette.dim)
        reset.onClick = { [weak self] in self?.apply(self?.defaultTemplate ?? "") }
        reset.setAccessibilityLabel("Reset the \(isIntake ? "intake agent" : key) command")
        var top: [NSView] = [name, when, tags, Spacer(), reset]
        if removable {
            let rm = ActionButton("Remove", style: .link) { [weak self, weak card] in if let self { card?.remove(self.key) } }
            rm.setAccessibilityLabel("Remove the \(key) command")
            top.append(rm)
        }
        addFull(NSStackView(h: top, spacing: 8))

        field.stringValue = text
        field.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        field.placeholderString = defaultTemplate
        field.setAccessibilityLabel("\(isIntake ? "Intake agent" : key) command")
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addFull(field)

        if let flags = AgentCommandsCard.flags[key] {
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

    func refresh() {
        let c = LaunchCommand(text)
        let custom = AgentCommandsCard.drafts[key] != nil || PROJECTS_CFG.runtime.commands[key].map { $0 != defaultTemplate } == true
        tags.clear()
        tags.addArrangedSubview(Chiplet(custom ? "● custom" : "default", color: custom ? Palette.acc : Palette.dim))
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
            let resolved = try c.resolve(name: isIntake ? "intake-" + ex.key : ex.key, key: ex.key, title: ex.title)
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
        for w in warnings(c) { output.addFull(message("△", w, Palette.warn)) }
    }

    private func warnings(_ c: LaunchCommand) -> [String] {
        var out: [String] = []
        if c.program == "claude" && !c.template.contains("{name}") {
            out.append("Without -n {name}, the Claude session does not show the item key.")
        }
        if isIntake {
            if !(" " + c.template + " ").contains(" --permission-mode plan ") {
                out.append("The intake agent writes the item. Without plan mode it can also change files.")
            }
        } else if !c.program.isEmpty && c.program != key && !c.program.hasSuffix("/" + key) {
            out.append("A runner refuses a command that does not start with \(key).")
        }
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
