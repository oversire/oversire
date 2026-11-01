import Cocoa
import OverSireAssistant
import OverSireCore

/// The model of Settings › Agents and queue › Runbooks. Each edit saves at once through RunbookUndo, as runbook.update does.
/// An edit that makes the runbook invalid saves too. The check line shows the problem.
/// Use it on the main thread.
final class RunbookEditor {
    static let newPrompt = "Work on {key} ({url}) in worktree group {group}. Then run {done} --verdict done --note \"<one line>\"."

    private let undo: RunbookUndo
    private(set) var selected: String?
    /// The step that shows its editor under its row.
    var open: String?
    /// The steps that the last change added. They show a "+" mark until the next change.
    private(set) var added: Set<String> = []
    private var seen: Runbook?
    private var known: Set<String> = []

    init(undo: RunbookUndo = RUNBOOK_UNDO) { self.undo = undo }

    var runbooks: [Runbook] { PROJECTS_CFG.runtime.runbooks }
    var runbook: Runbook? { runbooks.first { $0.id == selected } ?? runbooks.first }
    var agents: [String] { PROJECTS_CFG.runtime.startAgents }
    var problems: [RunbookProblem] { runbook?.validate(agents: PROJECTS_CFG.runtime.runbookAgents) ?? [] }
    var undoLabel: String? { undo.last }

    /// The line under the table when the runbook has no problems.
    var valid: String {
        let n = runbook?.steps.count ?? 0
        return "✓ Valid: \(n) step\(n == 1 ? "" : "s"), all agents exist, each prompt has {done}, each review has a fix step after it."
    }

    /// The projects of `keys` that start their items with `b`.
    func users(_ b: Runbook, of keys: [String]) -> [String] {
        keys.map { $0.uppercased() }.filter { PROJECTS_CFG.runbook(for: $0)?.id == b.id }.sorted()
    }

    /// "↻ fix 6 · 1 round" for a review.
    func reviewText(_ s: RunbookStep) -> String? {
        guard let r = s.review, let b = runbook else { return nil }
        let fix = b.index(of: r.fix).map { String($0 + 1) } ?? r.fix
        return "↻ fix \(fix) · \(r.rounds) round\(r.rounds == 1 ? "" : "s")"
    }

    /// Marks the steps that the last change added, from the page or from the assistant. Call it before each build.
    /// A runbook that the assistant adds shows at once.
    func follow() {
        let ids = Set(runbooks.map(\.id))
        if !known.isEmpty, let new = runbooks.first(where: { !known.contains($0.id) }) { select(new.id) }
        known = ids
        guard let b = runbook else { selected = nil; seen = nil; added = []; return }
        if let s = seen, s.id == b.id {
            if s != b { added = Set(b.steps.map(\.id)).subtracting(s.steps.map(\.id)) }
        } else {
            added = []
        }
        seen = b
        selected = b.id
        if let o = open, b.step(o) == nil { open = nil }
    }

    func select(_ id: String) {
        selected = id
        open = nil
        seen = runbook
        added = []
    }

    func toggle(_ step: String) { open = open == step ? nil : step }

    // MARK: Edits of the selected runbook

    private func edit(_ body: (inout Runbook) -> Void) {
        guard let b = runbook else { return }
        var n = b
        body(&n)
        guard n != b else { return }
        undo.change("Change \(b.name)") { c in
            guard let i = c.runtime.runbooks.firstIndex(where: { $0.id == b.id }) else { return }
            c.runtime.runbooks[i] = n
        }
    }

    func rename(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        edit { $0.name = n }
    }

    func set(_ step: String, _ body: (inout RunbookStep) -> Void) {
        edit { b in if let i = b.index(of: step) { body(&b.steps[i]) } }
    }

    func setPause(_ step: String, _ on: Bool) { set(step) { $0.pauseBefore = on ? true : nil } }

    /// A nil fix removes the review.
    func setReview(_ step: String, fix: String?, rounds: Int = 1) {
        set(step) { $0.review = fix.map { RunbookStep.Review(fix: $0, rounds: rounds) } }
    }

    /// A new id also changes the reviews that name the step as their fix.
    func setID(_ step: String, _ id: String) {
        let id = id.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, id != step else { return }
        edit { b in
            guard let i = b.index(of: step) else { return }
            b.steps[i].id = id
            for j in b.steps.indices where b.steps[j].review?.fix == step { b.steps[j].review?.fix = id }
        }
        if open == step { open = id }
        seen = runbook
        added = []
    }

    /// Moves the step `by` places. False at the top or the bottom.
    @discardableResult
    func move(_ step: String, by d: Int) -> Bool {
        guard let i = runbook?.index(of: step) else { return false }
        return move(step, to: i + d)
    }

    @discardableResult
    func move(_ step: String, to j: Int) -> Bool {
        guard let b = runbook, let i = b.index(of: step), b.steps.indices.contains(j), i != j else { return false }
        edit { $0.steps.insert($0.steps.remove(at: i), at: j) }
        return true
    }

    /// A new step after the open step, else at the end. It opens.
    @discardableResult
    func addStep() -> String? {
        guard let b = runbook else { return nil }
        let id = Self.free("step", in: Set(b.steps.map(\.id)))
        let at = open.flatMap(b.index(of:)).map { $0 + 1 } ?? b.steps.count
        let s = RunbookStep(id: id, name: "New step", agent: PROJECTS_CFG.runtime.agent, prompt: Self.newPrompt)
        edit { $0.steps.insert(s, at: at) }
        open = id
        return id
    }

    func removeStep(_ id: String) {
        edit { $0.steps.removeAll { $0.id == id } }
        if open == id { open = nil }
    }

    // MARK: Runbooks

    @discardableResult
    func addRunbook() -> String {
        let id = Self.free("runbook", in: Set(runbooks.map(\.id)))
        let step = RunbookStep(id: "implement", name: "Implement", agent: PROJECTS_CFG.runtime.agent, prompt: Runbook.Prompt.implement)
        let b = Runbook(id: id, name: "New runbook", steps: [step])
        undo.change("New \(b.name)") { $0.runtime.runbooks.append(b) }
        known.insert(id)
        select(id)
        return id
    }

    @discardableResult
    func duplicate() -> String? {
        guard var n = runbook else { return nil }
        n.id = Self.free(n.id + "-copy", in: Set(runbooks.map(\.id)))
        n.name += " copy"
        undo.change("New \(n.name)") { $0.runtime.runbooks.append(n) }
        known.insert(n.id)
        select(n.id)
        return n.id
    }

    func delete(_ id: String) {
        guard let b = runbooks.first(where: { $0.id == id }) else { return }
        undo.change("Delete \(b.name)") { $0.removeRunbook(id) }
        if selected == id { selected = nil; open = nil; seen = nil }
    }

    /// Full, Small and Plan only, for an empty list.
    func restoreDefaults() {
        undo.change("Default runbooks") { $0.runtime.runbooks = $0.runtime.defaultRunbooks }
    }

    /// The label of the change that it reverted.
    func undoLast() -> String? { undo.undo() }

    // MARK: Assistant

    /// What the assistant sees: each runbook, the steps of the selected one and the check line.
    func context(route: Route, projects: [String]) -> PageContext {
        var rows = runbooks.map { b in
            let users = self.users(b, of: projects)
            return PageContext.Row(id: "runbook:\(b.id)", text: "\(b.name) · \(b.steps.count) steps" + (users.isEmpty ? "" : " · default of " + users.joined(separator: ", ")))
        }
        if let b = runbook {
            for (i, s) in b.steps.enumerated() {
                var t = "\(i + 1). \(s.name) · agent \(s.agent)"
                if s.pauses { t += " · pause before" }
                if let r = s.review { t += " · review: fix \(r.fix), \(r.rounds) round\(r.rounds == 1 ? "" : "s")" }
                rows.append(PageContext.Row(id: "step:\(s.id)", text: t))
            }
            let p = problems
            rows.append(PageContext.Row(id: "check", text: p.isEmpty ? valid : p.map { "! " + $0.text }.joined(separator: " ")))
        }
        let sel = [runbook.map { "runbook:\($0.id)" }, open.map { "step:\($0)" }].compactMap { $0 }
        return PageContext(route: route.path, title: "Settings › Agents and queue › Runbooks", rows: rows, selection: sel)
    }

    /// `base`, else `base-2`, `base-3`, …
    static func free(_ base: String, in ids: Set<String>) -> String {
        guard ids.contains(base) else { return base }
        return (2...).lazy.map { "\(base)-\($0)" }.first { !ids.contains($0) }!
    }
}

extension ProjectsConfig {
    /// The default runbook of a project. Nil goes back to Full.
    mutating func setRunbook(_ id: String?, for key: String) {
        var l = local(key)
        l.runbook = id
        setLocal(key, l)
    }
}

/// A step row. ⌥↑ and ⌥↓ move it. A drag drops it at another place.
final class RunbookStepRow: Row {
    var onMove: ((Int) -> Void)?
    var onDrop: ((NSPoint) -> Void)?
    private var dragging = false

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.option), event.keyCode == 126 || event.keyCode == 125 {
            onMove?(event.keyCode == 126 ? -1 : 1)
            return
        }
        super.keyDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard onDrop != nil else { return }
        if !dragging { dragging = true; alphaValue = 0.55; NSCursor.closedHand.push() }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { super.mouseUp(with: event); return }
        dragging = false
        alphaValue = 1
        NSCursor.pop()
        onDrop?(event.locationInWindow)
    }
}

/// Settings › Agents and queue › Runbooks: the list, the step table, the check line and Undo.
/// The assistant panel of the window sees the runbook (RunbookEditor.context).
final class RunbookEditorView: NSStackView {
    /// The control that had the focus before a rebuild. The new view gives it back.
    private static var focus: String?

    private let editor: RunbookEditor
    private let projects: [String]
    private let refusal: (Runbook) -> String?
    private let ask: () -> Void
    private var stepRows: [(id: String, row: NSView)] = []
    private var targets: [ClosureTarget] = []

    init(editor: RunbookEditor, projects: [String], refusal: @escaping (Runbook) -> String?, ask: @escaping () -> Void) {
        self.editor = editor
        self.projects = projects
        self.refusal = refusal
        self.ask = ask
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 12
        translatesAutoresizingMaskIntoConstraints = false
        identifier = SettingsAnchor.runbooks.id
        editor.follow()
        render()
    }
    required init(coder: NSCoder) { fatalError() }

    private func render() {
        let add = ActionButton("Add runbook", symbol: "plus", style: .primary) { [weak self] in self?.editor.addRunbook() }
        let assistant = ActionButton("Ask the assistant", symbol: "sparkles") { [weak self] in self?.ask() }
        assistant.toolTip = "The assistant sees this runbook. It can change it, check it and start it."
        let head = NSStackView(h: [NSTextField.text("Runbooks", size: 15, weight: .semibold), Spacer(), assistant, add], spacing: 8)
        head.distribution = .fill
        addFull(head)
        addFull(NSTextField.text("A runbook takes an item from plan to merge in fixed steps. Each step is a fresh agent session.",
                                 size: 11.5, color: Palette.dim, lines: 2))
        if let note = PROJECTS_CFG.runtime.runbookNote {
            let close = ActionButton("Close") { [weak self] in
                PROJECTS_CFG.runtime.runbookNote = nil
                saveConfig()
                self?.rebuild()
            }
            addFull(Banner(.info, title: "Plan and Ship", body: note, actions: [close]))
        }
        guard let b = editor.runbook else { empty(); return }
        addFull(runbookList(b))
        addFull(nameRow(b))
        addFull(table(b))
        addFull(checkLine())
        addFull(undoRow())
        addFull(NSTextField.text("Click a step to edit its name and prompt. The Agent list is Settings › Agents. Drag a step or press ⌥↑ ⌥↓ to move it. "
                                 + "Each change saves at once. Undo reverts the last change, also a change of the assistant.", size: 11.5, color: Palette.dim, lines: 3))
    }

    private func empty() {
        let card = ListCard()
        card.add(EmptyNote("There are no runbooks. Add one, or ask the assistant to make one.", symbol: "list.number"))
        card.add(Row([Spacer(), ActionButton("Add Plan and Ship") { [weak self] in self?.editor.restoreDefaults() }], height: 40))
        addFull(card)
    }

    // MARK: List

    // One chip for each runbook. The chip of the selected runbook has a check mark.
    private func runbookList(_ sel: Runbook) -> NSView {
        let chips: [NSView] = editor.runbooks.map { b in
            let users = editor.users(b, of: projects)
            let isDefault = !users.isEmpty || (projects.isEmpty && b.id == PROJECTS_CFG.runbook(for: "")?.id)
            let text = "\(b.name.isEmpty ? "No name" : b.name) · \(b.steps.count)" + (isDefault ? " · default" : "")
            let c = ToggleChip(text, on: b.id == sel.id) { [weak self] in
                Self.focus = "rb-list-\(b.id)"
                self?.editor.select(b.id)
                self?.rebuild()
            }
            c.identifier = NSUserInterfaceItemIdentifier("rb-list-\(b.id)")
            c.setAccessibilityLabel("\(b.name), \(b.steps.count) steps" + (isDefault ? ", default" : ""))
            c.toolTip = users.isEmpty ? nil : "Default of " + users.joined(separator: ", ")
            return c
        }
        return Wrap(chips)
    }

    private func confirmDelete(_ b: Runbook) {
        if let why = refusal(b) { AlertConfirm.tell("\(b.name) cannot go.", info: why, in: window); return }
        AlertConfirm.ask("Delete the runbook \(b.name)?", info: "The projects that use it go back to Full. Undo brings it back.",
                         button: "Delete", critical: true, in: window) { [weak self] in self?.editor.delete(b.id) }
    }

    // MARK: Table

    private func nameRow(_ b: Runbook) -> NSView {
        let name = TextInput(b.name, placeholder: "Name", label: "Runbook name") { [weak self] v in self?.editor.rename(v) }
        name.identifier = NSUserInterfaceItemIdentifier("rb-name")
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        let id = NSTextField.text("id \(b.id)", size: 11.5, color: Palette.dim, mono: true)
        id.setContentCompressionResistancePriority(.required, for: .horizontal)
        let dup = ActionButton("Duplicate") { [weak self] in self?.editor.duplicate() }
        let del = ActionButton("Delete", style: .danger) { [weak self] in self?.confirmDelete(b) }
        dup.setAccessibilityLabel("Duplicate \(b.name)")
        del.setAccessibilityLabel("Delete \(b.name)")
        let row = NSStackView(h: [name, id, dup, del], spacing: 10)
        row.distribution = .fill
        return row
    }

    private func table(_ b: Runbook) -> NSView {
        let card = ListCard()
        func head(_ s: String, _ w: CGFloat?) -> NSView {
            let t = NSTextField.text(s, size: 10.5, weight: .semibold, color: Palette.dim)
            if let w { t.widthAnchor.constraint(equalToConstant: w).isActive = true }
            return t
        }
        let header = NSStackView(h: [head("#", 20), head("STEP", nil), Spacer(), head("AGENT", 150), head("PAUSE", 44)], spacing: 10)
        header.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 4, right: 14)
        header.distribution = .fill
        header.setAccessibilityElement(false)
        card.add(header)
        let problems = Dictionary(grouping: editor.problems.filter { $0.step != nil }, by: { $0.step! })
        stepRows = []
        for (i, s) in b.steps.enumerated() {
            let r = stepRow(i, s, problems: problems[s.id] ?? [])
            stepRows.append((s.id, r))
            card.add(r)
            if editor.open == s.id { card.add(stepEditor(b, i, s)) }
        }
        let add = ActionButton("Add step", symbol: "plus", style: .link) { [weak self] in
            if let id = self?.editor.addStep() { Self.focus = "rb-step-name-\(id)" }
        }
        card.add(Row([add, Spacer()], height: 36))
        return card
    }

    private func stepRow(_ i: Int, _ s: RunbookStep, problems: [RunbookProblem]) -> NSView {
        let num = NSTextField.text("\(i + 1)", size: 12, color: Palette.dim, mono: true)
        num.widthAnchor.constraint(equalToConstant: 20).isActive = true
        var cells: [NSView] = [num, TwoLine(s.name.isEmpty ? "No name" : s.name, editor.reviewText(s), titleSize: 12.5)]
        let new = editor.added.contains(s.id)
        if new {
            let plus = NSTextField.text("+", size: 13, weight: .bold, color: Palette.ok)
            plus.setAccessibilityLabel("new")
            cells.insert(plus, at: 1)
        }
        if !problems.isEmpty {
            let g = Glyph("exclamationmark.circle.fill", color: Palette.warn, size: 13, label: "problem")
            g.toolTip = problems.map(\.text).joined(separator: "\n")
            cells.append(g)
        }
        cells.append(Spacer())
        var names = editor.agents
        if !names.contains(s.agent) { names.append(s.agent) }
        let agent = PopUp(names.map { editor.agents.contains($0) ? $0 : "\($0) (missing)" }, selected: names.firstIndex(of: s.agent) ?? 0,
                          label: "Agent of \(s.name)") { [weak self] k in
            Self.focus = "rb-step-\(s.id)"
            self?.editor.set(s.id) { $0.agent = names[k] }
        }
        agent.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.state = s.pauses ? .on : .off
        sw.setAccessibilityLabel("Pause before \(s.name)")
        let t = ClosureTarget { [weak self, weak sw] in
            Self.focus = "rb-step-\(s.id)"
            self?.editor.setPause(s.id, sw?.state == .on)
        }
        targets.append(t)
        sw.target = t
        sw.action = #selector(ClosureTarget.fire)
        let swBox = NSStackView(h: [sw], spacing: 0)
        swBox.widthAnchor.constraint(equalToConstant: 44).isActive = true
        cells += [agent, swBox]
        var label = "Step \(i + 1), \(s.name), agent \(s.agent)" + (s.pauses ? ", pause before" : "")
        if new { label += ", new" }
        let r = RunbookStepRow(cells, height: 44, label: label) { [weak self] in
            Self.focus = "rb-step-\(s.id)"
            self?.editor.toggle(s.id)
            self?.rebuild()
        }
        r.identifier = NSUserInterfaceItemIdentifier("rb-step-\(s.id)")
        r.selected = editor.open == s.id
        if new { r.restFill = Palette.ok.withAlphaComponent(0.12) }
        r.onMove = { [weak self] d in
            Self.focus = "rb-step-\(s.id)"
            self?.editor.move(s.id, by: d)
        }
        r.onDrop = { [weak self] p in self?.drop(s.id, at: p) }
        return r
    }

    // The row under the point gets the step. Above the first row is the top, below the last row is the end.
    private func drop(_ step: String, at p: NSPoint) {
        let frames = stepRows.map { $0.row.convert($0.row.bounds, to: nil) }
        guard let first = frames.first else { return }
        let j = frames.firstIndex { p.y >= $0.minY && p.y <= $0.maxY } ?? (p.y > first.maxY ? 0 : frames.count - 1)
        Self.focus = "rb-step-\(step)"
        editor.move(step, to: j)
    }

    private func stepEditor(_ b: Runbook, _ i: Int, _ s: RunbookStep) -> NSView {
        let name = TextInput(s.name, placeholder: "Name", label: "Step name") { [weak self] v in
            self?.editor.set(s.id) { $0.name = v.trimmingCharacters(in: .whitespaces) }
        }
        name.identifier = NSUserInterfaceItemIdentifier("rb-step-name-\(s.id)")
        let id = TextInput(s.id, placeholder: "id", label: "Step id", mono: true) { [weak self] v in self?.editor.setID(s.id, v) }
        id.identifier = NSUserInterfaceItemIdentifier("rb-step-id-\(s.id)")
        id.widthAnchor.constraint(equalToConstant: 150).isActive = true
        id.toolTip = "a-z, 0-9 and -. A review names its fix step by the id."
        let prompt = TextInput(s.prompt, placeholder: RunbookEditor.newPrompt, label: "Prompt of \(s.name)", mono: true, lines: 6) { [weak self] v in
            self?.editor.set(s.id) { $0.prompt = v.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        prompt.identifier = NSUserInterfaceItemIdentifier("rb-prompt-\(s.id)")
        let help = "Placeholders: " + Runbook.placeholders.map { "{\($0)}" }.joined(separator: " ")
            + ". {done} is the command that ends the step. Each prompt needs it."
        let v = NSStackView(v: [], spacing: 8)
        v.edgeInsets = NSEdgeInsets(top: 10, left: 44, bottom: 12, right: 14)
        let names = NSStackView(h: [label("Name"), name, label("ID"), id], spacing: 8)
        names.distribution = .fill
        v.addFull(names)
        v.addArrangedSubview(label("Prompt"))
        v.addFull(prompt)
        v.addFull(NSTextField.text(help, size: 11.5, color: Palette.dim, lines: 2))
        v.addFull(reviewRow(b, i, s))
        let remove = ActionButton("Remove step", style: .danger) { [weak self] in self?.editor.removeStep(s.id) }
        remove.controlSize = .small
        remove.setAccessibilityLabel("Remove \(s.name)")
        v.addFull(NSStackView(h: [Spacer(), remove], spacing: 8))
        let box = Box(fill: Palette.raise, border: Palette.line, radius: 8)
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor), v.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            v.topAnchor.constraint(equalTo: box.topAnchor), v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        return box
    }

    // Review: the fix step is a step after the review. Gaps runs it, then the review again, up to the rounds.
    private func reviewRow(_ b: Runbook, _ i: Int, _ s: RunbookStep) -> NSView {
        let after = Array(b.steps.dropFirst(i + 1)).filter { $0.review == nil }
        let sw = NSSwitch()
        sw.controlSize = .small
        sw.state = s.review == nil ? .off : .on
        sw.isEnabled = s.review != nil || !after.isEmpty
        sw.setAccessibilityLabel("\(s.name) is a review")
        let t = ClosureTarget { [weak self, weak sw] in
            Self.focus = "rb-step-\(s.id)"
            self?.editor.setReview(s.id, fix: sw?.state == .on ? after.first?.id : nil)
        }
        targets.append(t)
        sw.target = t
        sw.action = #selector(ClosureTarget.fire)
        var cells: [NSView] = [label("Review"), sw]
        if let r = s.review {
            var fixes = after.map(\.id)
            if !fixes.contains(r.fix) { fixes.insert(r.fix, at: 0) }
            let fix = PopUp(fixes.map { id in b.step(id).map { "\(b.index(of: id)! + 1). \($0.name)" } ?? "\(id) (missing)" },
                            selected: fixes.firstIndex(of: r.fix) ?? 0, label: "Fix step of \(s.name)") { [weak self] k in
                self?.editor.setReview(s.id, fix: fixes[k], rounds: r.rounds)
            }
            let rounds = PopUp((0...Runbook.maxRounds).map { "\($0) round\($0 == 1 ? "" : "s")" }, selected: r.rounds,
                               label: "Rounds of \(s.name)") { [weak self] k in
                self?.editor.setReview(s.id, fix: r.fix, rounds: k)
            }
            cells += [label("fix step"), fix, rounds]
        } else {
            cells.append(NSTextField.text(after.isEmpty ? "A review needs a step after it to fix the gaps." : "Off: the step ends with done.",
                                          size: 11.5, color: Palette.dim))
        }
        cells.append(Spacer())
        let row = NSStackView(h: cells, spacing: 8)
        row.distribution = .fill
        return row
    }

    private func label(_ s: String) -> NSTextField {
        let t = NSTextField.text(s, size: 12, weight: .medium, color: Palette.mut)
        t.setContentCompressionResistancePriority(.required, for: .horizontal)
        return t
    }

    // MARK: Check line and Undo

    private func checkLine() -> NSView {
        let card = ListCard()
        // A label in a row wraps only with a width.
        func line(_ symbol: String, _ text: String, _ color: NSColor, _ label: String, _ click: (() -> Void)? = nil) -> Row {
            let t = NSTextField.text(text, size: 12, color: color, lines: 3)
            let r = Row([Glyph(symbol, color: color, size: 13, label: label), t], height: 36, label: "\(label): \(text)", onClick: click)
            t.widthAnchor.constraint(equalTo: r.widthAnchor, constant: -51).isActive = true
            return r
        }
        let problems = editor.problems
        if problems.isEmpty { card.add(line("checkmark.circle.fill", editor.valid, Palette.ok, "Valid")) }
        for p in problems {
            card.add(line("exclamationmark.circle.fill", p.text, Palette.warn, "Problem") { [weak self] in
                guard let step = p.step else { return }
                Self.focus = "rb-step-\(step)"
                self?.editor.open = step
                self?.rebuild()
            })
        }
        return card
    }

    private func undoRow() -> NSView {
        let last = editor.undoLabel
        let undo = ActionButton("Undo", symbol: "arrow.uturn.backward") { [weak self] in _ = self?.editor.undoLast() }
        undo.isEnabled = last != nil
        undo.toolTip = last.map { "Undo: \($0)" } ?? "There is no change to undo."
        undo.setAccessibilityLabel(last.map { "Undo \($0)" } ?? "Undo")
        let note = NSTextField.text(last.map { "Last change: \($0)" } ?? "", size: 11.5, color: Palette.dim)
        let row = NSStackView(h: [undo, note, Spacer()], spacing: 8)
        row.distribution = .fill
        return row
    }

    // MARK: Builds

    // An edit saves and posts .config, so the page builds again. A selection builds only this view.
    private func rebuild() {
        editor.follow()
        targets = []
        clear()
        render()
        restoreFocus()
    }

    override func viewWillMove(toWindow w: NSWindow?) {
        if w == nil, let fr = window?.firstResponder as? NSView, fr.isDescendant(of: self) {
            let v = (fr as? NSTextView).flatMap { $0.delegate as? NSView } ?? fr
            if let id = v.identifier?.rawValue, id.hasPrefix("rb-"), Self.focus == nil { Self.focus = id }
        }
        super.viewWillMove(toWindow: w)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { DispatchQueue.main.async { [weak self] in self?.restoreFocus() } }
    }

    private func restoreFocus() {
        guard let id = Self.focus, let w = window, let v = find(id) else { return }
        Self.focus = nil
        w.makeFirstResponder(v)
    }

    private func find(_ id: String) -> NSView? {
        func walk(_ v: NSView) -> NSView? {
            if v.identifier?.rawValue == id { return v }
            for s in v.subviews { if let f = walk(s) { return f } }
            return nil
        }
        return walk(self)
    }
}

extension SettingsPage {
    static let runbookEditor = RunbookEditor()

    func runbooks(_ b: NSStackView) {
        let book = RUNBOOKS, queue = data.queue
        b.addFull(RunbookEditorView(editor: Self.runbookEditor, projects: data.projectStore.tracked.map(\.identifier),
                                    refusal: { RunbookActions.deleteRefusal($0, book: book, queue: queue) },
                                    ask: { [weak self] in (self?.view.window?.windowController as? AppWindow)?.showAssistant() }))
    }
}
