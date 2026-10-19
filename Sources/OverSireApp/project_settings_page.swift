import Cocoa
import OverSireCore

enum ProjectSettingsSection: String, CaseIterable {
    case appearance, links, memory, sessions, notifications
    case general, workflow, labels, members, features

    var title: String { self == .memory ? "Vision and memory" : rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
    var local: Bool { [.appearance, .links, .memory, .sessions, .notifications].contains(self) }

    var symbol: String {
        switch self {
        case .appearance: return "paintpalette"
        case .links: return "link"
        case .memory: return "scope"
        case .sessions: return "terminal"
        case .notifications: return "bell"
        case .general: return "info.circle"
        case .workflow: return "circle.dotted"
        case .labels: return "tag"
        case .members: return "person.2"
        case .features: return "switch.2"
        }
    }
}

// What the tracker group can show and change. A field shows only when the adapter has it.
struct TrackerSettingsView {
    let settings: ProjectSettings
    let editable: Set<ProjectSettingsField>

    func canEdit(_ f: ProjectSettingsField) -> Bool { editable.contains(f) }

    var sections: [ProjectSettingsSection] {
        var out: [ProjectSettingsSection] = [.general]
        if !settings.statuses.isEmpty { out.append(.workflow) }
        if !settings.labels.isEmpty || canEdit(.labels) { out.append(.labels) }
        if !settings.members.isEmpty { out.append(.members) }
        if !settings.features.isEmpty { out.append(.features) }
        return out
    }

    var generalFields: [ProjectSettingsField] {
        var out: [ProjectSettingsField] = [.name]
        if settings.description != nil || canEdit(.description) { out.append(.description) }
        if settings.lead != nil || canEdit(.lead) { out.append(.lead) }
        if settings.defaultAssignee != nil || canEdit(.defaultAssignee) { out.append(.defaultAssignee) }
        if settings.visibility != nil { out.append(.visibility) }
        return out
    }

    func canToggle(_ f: ProjectFeature) -> Bool { canEdit(.features) && !settings.readOnlyFeatures.contains(f) }
}

// A pop-up button that calls a closure with the index of the new choice.
final class PopUp: NSPopUpButton {
    private let pick: (Int) -> Void

    init(_ titles: [String], selected: Int, label: String, _ pick: @escaping (Int) -> Void) {
        self.pick = pick
        super.init(frame: .zero, pullsDown: false)
        addItems(withTitles: titles)
        selectItem(at: selected)
        controlSize = .small
        font = .systemFont(ofSize: 12)
        target = self
        action = #selector(changed)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(label)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { pick(indexOfSelectedItem) }
}

// A text field that calls a closure when the edit ends.
final class TextInput: NSTextField, NSTextFieldDelegate {
    private let commit: (String) -> Void

    init(_ value: String, placeholder: String = "", label: String, mono: Bool = false, lines: Int = 1, _ commit: @escaping (String) -> Void) {
        self.commit = commit
        super.init(frame: .zero)
        stringValue = value
        placeholderString = placeholder
        font = mono ? .monospacedSystemFont(ofSize: 12, weight: .regular) : .systemFont(ofSize: 12.5)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(label)
        delegate = self
        if lines > 1 {
            usesSingleLineMode = false
            cell?.wraps = true
            cell?.isScrollable = false
            heightAnchor.constraint(equalToConstant: CGFloat(lines) * 17 + 8).isActive = true
        }
        setContentHuggingPriority(.init(1), for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidEndEditing(_ obj: Notification) { commit(stringValue) }
}

// A text field with a character limit. It reports each change. Command-S saves and Esc reverts.
final class LimitedInput: NSTextField, NSTextFieldDelegate {
    var onChange: ((String) -> Void)?
    var onSave: (() -> Void)?
    var onRevert: (() -> Void)?

    init(_ value: String, placeholder: String = "", label: String, lines: Int) {
        super.init(frame: .zero)
        stringValue = value
        placeholderString = placeholder
        font = .systemFont(ofSize: 12.5)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityLabel(label)
        delegate = self
        usesSingleLineMode = false
        cell?.wraps = true
        cell?.isScrollable = false
        heightAnchor.constraint(equalToConstant: CGFloat(lines) * 17 + 8).isActive = true
        setContentHuggingPriority(.init(1), for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    func controlTextDidChange(_ obj: Notification) { onChange?(stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.cancelOperation(_:)): onRevert?(); return true
        case #selector(NSResponder.insertNewline(_:)): textView.insertNewlineIgnoringFieldEditor(nil); return true
        default: return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if currentEditor() != nil, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "s" {
            onSave?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

// Settings of one project. "In OverSire" stays on this Mac; "In the tracker" changes the project for everyone.
final class ProjectSettingsPage: Page {
    static let okabe = ["#E69F00", "#56B4E9", "#009E73", "#F0E442", "#0072B2", "#D55E00", "#CC79A7", "#999999"]
    static let categories: [(StatusCategory, String)] = [(.todo, "Todo"), (.progress, "In progress"), (.review, "In review"), (.blocked, "Blocked"), (.done, "Done")]

    private var remote: TrackerSettingsView?
    private var remoteError: String?
    private var loadedAt: Date?
    private var loadingKey: String?
    private var draft = ProjectSettingsPatch()
    private var saving = false
    private var note: (Tone, String)?
    private var linkField: NSTextField?
    private var visionDraft: String?
    private var editingFact: String?    // a fact id, or "" for a new entry
    private var iconObserver: Any?

    private var key: String { if case .projectSettings(let k, _) = route { return k }; return "" }
    private var section: ProjectSettingsSection { if case .projectSettings(_, let s) = route { return s }; return .appearance }
    private var project: ProjectSummary? { data.projectStore.tracked.first { $0.identifier.uppercased() == key } }
    private var trackerName: String {
        guard let p = project else { return "the tracker" }
        let id = p.ref.account.provider.rawValue
        return id == "plane" ? "Plane" : id.prefix(1).uppercased() + id.dropFirst()
    }
    private var local: ProjectLocalSettings { PROJECTS_CFG.local(key) }

    override var isEditing: Bool { super.isEditing || !draft.isEmpty || visionDraft != nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        iconObserver = NotificationCenter.default.addObserver(forName: ProjectIconStore.changed, object: nil, queue: .main) { [weak self] _ in
            guard let self, self.section == .appearance, !self.isEditing else { return }
            self.reload()
        }
    }

    deinit { iconObserver.map(NotificationCenter.default.removeObserver) }

    override func build(_ col: NSStackView) {
        guard let p = project else {
            col.addFull(PageHeader("\(key) settings", caption: "Project settings"))
            col.addFull(data.projectsLoading ? LoadingNote("Loading \(key)") : EmptyNote("OverSire does not track a project with the key \(key).", symbol: "questionmark.folder"))
            return
        }
        if loadingKey != key { load(p) }
        let icon = NSImageView(image: PROJECT_ICONS.image(for: key, size: 28))
        icon.translatesAutoresizingMaskIntoConstraints = false
        let open = ActionButton("Open project", symbol: "list.bullet") { [weak self] in self?.go(.project(p.identifier.uppercased())) }
        col.addFull(NSStackView(h: [icon, PageHeader("\(p.title) settings", caption: "\(key) · \(trackerName) · \(p.ref.workspace)", actions: [open])], spacing: 12, align: .top))
        if let note { col.addFull(Banner(note.0, title: note.1)) }

        let nav = ListCard()
        nav.add(groupTitle("In OverSire"))
        for s in ProjectSettingsSection.allCases where s.local { nav.add(navRow(s)) }
        nav.add(groupTitle("In \(trackerName)"))
        for s in remote?.sections ?? [.general] { nav.add(navRow(s)) }

        let body = NSStackView(v: [], spacing: 12)
        switch section {
        case .appearance: appearance(body, p)
        case .links: links(body, p)
        case .memory: memory(body, p)
        case .sessions: sessions(body)
        case .notifications: notifications(body)
        default: tracker(body, p)
        }
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        filler.setContentCompressionResistancePriority(.init(1), for: .vertical)
        let navCol = NSStackView(v: [], spacing: 0)
        navCol.addFull(nav)
        navCol.addArrangedSubview(filler)
        let rest = NSView()
        rest.setContentHuggingPriority(.init(1), for: .vertical)
        rest.setContentCompressionResistancePriority(.init(1), for: .vertical)
        body.addArrangedSubview(rest)
        let two = NSStackView(h: [navCol, body], spacing: 16, align: .top)
        col.addFull(two)
        navCol.widthAnchor.constraint(equalToConstant: 200).isActive = true
        body.widthAnchor.constraint(equalTo: two.widthAnchor, constant: -216).isActive = true
    }

    private func groupTitle(_ t: String) -> NSView {
        let l = NSTextField.text(t.uppercased(), size: 10.5, weight: .semibold, color: Palette.dim)
        let v = NSStackView(h: [l], spacing: 0)
        v.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 4, right: 10)
        v.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return v
    }

    private func navRow(_ s: ProjectSettingsSection) -> NSView {
        let r = Row([Glyph(s.symbol, size: 13), NSTextField.text(s.title, size: 12.5, weight: s == section ? .semibold : .regular), Spacer()],
                    height: 30, label: s.title) { [weak self] in
            guard let self else { return }
            self.go(.projectSettings(self.key, s))
        }
        r.selected = s == section
        return r
    }

    // A card with the source of its settings in the header.
    private func card(_ title: String, local: Bool, trailing: [NSView] = []) -> Card {
        let when = loadedAt.map { " · \(relativeTime($0))" } ?? ""
        let src = Chiplet(local ? "Saved in OverSire" : "Synced with \(trackerName)\(when)", symbol: local ? "laptopcomputer" : "arrow.triangle.2.circlepath",
                          color: local ? Palette.mut : Palette.acc)
        return Card(title: title, trailing: [src] + trailing)
    }

    // A label column, a control and an optional help line.
    private func field(_ name: String, _ control: NSView, help: String? = nil) -> NSView {
        let n = NSTextField.text(name, size: 12, color: Palette.dim)
        n.widthAnchor.constraint(equalToConstant: 130).isActive = true
        var right: [NSView] = [control]
        if let help { right.append(NSTextField.text(help, size: 11.5, color: Palette.dim, lines: 3)) }
        let r = NSStackView(v: right, spacing: 4)
        r.setContentHuggingPriority(.init(1), for: .horizontal)
        let row = NSStackView(h: [n, r], spacing: 12, align: .top)
        row.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        return row
    }

    private func editLocal(_ change: (inout ProjectLocalSettings) -> Void) {
        var l = local
        change(&l)
        PROJECTS_CFG.setLocal(key, l)
        saveConfig()
        NotificationCenter.default.post(name: AppWindow.changed, object: nil)
        reload()
    }

    private func openInTracker() { if let u = project.flatMap({ URL(string: $0.url) }) { NSWorkspace.shared.open(u) } }

    // MARK: In OverSire

    private func appearance(_ body: NSStackView, _ p: ProjectSummary) {
        let l = local
        let c = card("Icon", local: true)
        let big = NSImageView(image: PROJECT_ICONS.image(for: key, size: 48))
        big.translatesAutoresizingMaskIntoConstraints = false
        let from = describe(PROJECT_ICONS.source(for: key)) + (l.icon == .auto ? " (auto)" : "")
        c.add(field("Preview", NSStackView(h: [big, NSTextField.text("Icon from \(from)", size: 12, color: Palette.dim), Spacer()], spacing: 10)))
        let chips: [NSView] = PROJECT_ICONS.candidates(for: key).map { choice in
            ToggleChip(label(choice), on: l.icon == choice) { [weak self] in self?.editLocal { $0.icon = choice } }
        }
        c.add(field("Source", Wrap(chips), help: "Auto takes the first source it finds: your image, the \(trackerName) logo, a GitHub repo logo, a GitHub org avatar, then the letter."))
        let upload = ActionButton("Upload…", symbol: "square.and.arrow.up") { [weak self] in self?.pickImage() }
        var acts: [NSView] = [upload]
        if FileManager.default.fileExists(atPath: PROJECT_ICONS.uploadURL(key).path) {
            acts.append(ActionButton("Remove", style: .danger) { [weak self] in
                guard let self else { return }
                PROJECT_ICONS.clearUpload(key: self.key)
                self.editLocal { if $0.icon == .upload { $0.icon = .auto } }
            })
        }
        let sync = ActionButton("Sync now", symbol: "arrow.clockwise")
        sync.onClick = { [weak self, weak sync] in
            guard let self else { return }
            sync?.busy("Syncing…")
            let k = self.key
            let t = self.data.busy.begin("Syncing the icon of \(k)")
            Task { @MainActor in
                await PROJECT_ICONS.sync(k, force: true)
                self.data.busy.end(t)
                self.reload()
            }
        }
        acts += [sync, Spacer()]
        c.add(field("Your image", NSStackView(h: acts, spacing: 6), help: "PNG, JPEG or SVG. OverSire scales it to 128 px. It stays until you change it."))
        body.addFull(c)

        let c2 = card("Color and sidebar", local: true)
        let swatches: [NSView] = Self.okabe.map { hex in
            let on = l.color?.uppercased() == hex
            let b = Chiplet(on ? "✓" : " ", color: .white, fill: ProjectIconStore.color(hex: hex) ?? Palette.raise) { [weak self] in
                self?.editLocal { $0.color = on ? nil : hex }
            }
            b.setAccessibilityLabel("Color \(hex)\(on ? ", selected" : "")")
            return b
        }
        c2.add(field("Color", NSStackView(h: swatches + [Spacer()], spacing: 6), help: "For the letter icon and the project chips. The palette is Okabe-Ito."))
        c2.add(SwitchRow("Show in sidebar", on: !l.hidden) { [weak self] on in self?.editLocal { $0.hidden = !on } })
        body.addFull(c2)
    }

    private func label(_ c: IconChoice) -> String {
        switch c {
        case .auto: return "Auto"
        case .upload: return "Your image"
        case .tracker: return "\(trackerName) logo"
        case .repo(let r): return r
        case .org(let o): return "\(o) avatar"
        case .letter: return "Letter"
        }
    }

    private func describe(_ s: IconSource) -> String {
        switch s {
        case .upload: return "your image"
        case .emoji, .image: return "the \(trackerName) logo"
        case .repo(let r): return r
        case .org(let o): return "the \(o) avatar"
        case .letter: return "the letter"
        }
    }

    private func pickImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .svg]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) else { return }
        do {
            try PROJECT_ICONS.setUpload(key: key, image: img)
            editLocal { $0.icon = .upload }
        } catch {
            note = (.bad, "Could not save the image: \(error.localizedDescription)")
            reload()
        }
    }

    private func links(_ body: NSStackView, _ p: ProjectSummary) {
        let l = local
        let c = card("GitHub", local: true)
        let chips: [NSView] = l.github.map { g in
            let chip = Chiplet("\(g)  ×", symbol: g.contains("/") ? "shippingbox" : "building.2", mono: true) { [weak self] in
                self?.editLocal { $0.github.removeAll { $0 == g } }
            }
            chip.setAccessibilityLabel("Remove \(g)")
            return chip
        }
        c.add(field("Orgs and repos", chips.isEmpty ? NSTextField.text("No links", size: 12, color: Palette.dim) : Wrap(chips),
                    help: "A link is an icon source. It also maps runs and pull requests to this project for the Inbox filter, Runs and Pull requests."))
        let f = TextInput("", placeholder: "org or owner/repo", label: "GitHub org or repo", mono: true) { _ in }
        f.target = self
        f.action = #selector(addLink)
        linkField = f
        c.add(field("Add", NSStackView(h: [f, ActionButton("Link") { [weak self] in self?.addLink() }], spacing: 6)))
        let suggested = suggestions(p).filter { !l.github.contains($0) }.prefix(6)
        if !suggested.isEmpty {
            c.add(field("Suggested", Wrap(suggested.map { g in
                Chiplet("+ \(g)", mono: true) { [weak self] in self?.editLocal { $0.github.append(g) } } as NSView
            }), help: "Tracked repos whose name matches this project."))
        }
        body.addFull(c)

        let c2 = card("Orca and branches", local: true)
        let root = TextInput(PROJECTS_CFG.orcaRoot(p) ?? "", placeholder: "~/Projects/\(p.identifier.lowercased())", label: "Orca workspace", mono: true) { [weak self] v in
            guard let self, let p = self.project else { return }
            let path = v.trimmingCharacters(in: .whitespaces)
            guard path != PROJECTS_CFG.orcaRoot(p) ?? "" else { return }
            PROJECTS_CFG.setOrcaRoot(p, path.isEmpty ? nil : path)
            saveConfig()
        }
        let choose = ActionButton("Choose…") { [weak self] in self?.chooseRoot() }
        let md = Self.claudeMDState(PROJECTS_CFG.orcaRoot(p), remote: PROJECTS_CFG.orca.environment != nil)
        c2.add(field("Orca workspace", NSStackView(h: [root, choose], spacing: 6), help: "The folder that Orca opens for new sessions of this project." + (md.map { " Root CLAUDE.md: \($0)." } ?? "")))
        let sample = data.projectStore.snapshots.values.first { $0.summary.identifier.uppercased() == key }?.items.first
        let branch = TextInput(l.branchTemplate ?? "", placeholder: ProjectLocalSettings.defaultBranch, label: "Branch name", mono: true) { [weak self] v in
            guard let self, v != (self.local.branchTemplate ?? "") else { return }
            self.editLocal { $0.branchTemplate = v.isEmpty ? nil : v }
        }
        let example = sample.map { "Example: \(l.branch(for: $0))." } ?? ""
        c2.add(field("Branch name", branch, help: "Used by \"Copy branch name\" and new sessions. Placeholders: {key}, {KEY}, {slug}, {title}. \(example)"))
        body.addFull(c2)
    }

    private func suggestions(_ p: ProjectSummary) -> [String] {
        let words = Set([p.identifier.lowercased(), p.title.lowercased().replacingOccurrences(of: " ", with: "-")])
        return REPOS.filter { r in
            let name = String(r.split(separator: "/").last ?? "").lowercased()
            return words.contains { name == $0 || name.hasPrefix($0 + "-") || name.hasSuffix("-" + $0) }
        }
    }

    @objc private func addLink() {
        guard let f = linkField else { return }
        let g = f.stringValue.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = g.split(separator: "/")
        guard !g.isEmpty, parts.count <= 2, !g.contains(" ") else { note = (.warning, "Type an org, or owner/repo."); reload(); return }
        f.stringValue = ""
        guard !local.github.contains(where: { $0.caseInsensitiveCompare(g) == .orderedSame }) else { return }
        editLocal { $0.github.append(g) }
    }

    // "worktree groups" when the root CLAUDE.md tells the agent about worktree groups.
    static func claudeMDState(_ root: String?, remote: Bool) -> String? {
        guard let root, !root.isEmpty else { return nil }
        if remote { return "on the server" }
        let path = ((root as NSString).expandingTildeInPath as NSString).appendingPathComponent("CLAUDE.md")
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return "missing" }
        return text.range(of: "worktree group", options: .caseInsensitive) != nil ? "worktree groups" : "no worktree groups"
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url, let p = project else { return }
        PROJECTS_CFG.setOrcaRoot(p, url.path)
        saveConfig()
        reload()
    }

    // MARK: Vision and memory

    private func memory(_ body: NSStackView, _ p: ProjectSummary) {
        let mem = data.memory
        let saved = mem.vision(of: p.ref)
        let c = card("Vision", local: true)
        c.add(NSTextField.text("The true north of \(p.title). Triage and the queue order read it. Keep it short.", size: 12, color: Palette.dim, lines: 2))
        let text = visionDraft ?? saved?.text ?? ""
        let input = LimitedInput(text, placeholder: "What this project is for, and what is out of scope.", label: "Project vision", lines: 5)
        let counter = NSTextField.text("", size: 11.5, color: Palette.dim)
        let revert = ActionButton("Revert") { [weak self] in self?.revertVision() }
        let save = ActionButton("Save", style: .primary) { [weak self] in self?.saveVision(p) }
        let update = { [weak self] (t: String) in
            let n = t.trimmingCharacters(in: .whitespacesAndNewlines).count
            let over = n > MemoryDraft.maxText
            counter.stringValue = over ? "⚠ \(n) / \(MemoryDraft.maxText) · \(n - MemoryDraft.maxText) over the limit" : "\(n) / \(MemoryDraft.maxText)"
            counter.textColor = over ? Palette.bad : Palette.dim
            counter.setAccessibilityLabel(over ? "\(n) of \(MemoryDraft.maxText) characters, \(n - MemoryDraft.maxText) over the limit" : "\(n) of \(MemoryDraft.maxText) characters")
            let changed = t != (saved?.text ?? "")
            save.isEnabled = changed && !over
            revert.isEnabled = changed
            self?.visionDraft = changed ? t : nil
        }
        input.onChange = update
        input.onSave = { [weak self] in self?.saveVision(p) }
        input.onRevert = { [weak self] in self?.revertVision() }
        update(text)
        c.add(input)
        let who = saved.map { "Last saved by \(source($0)) · \(relativeTime($0.updatedAt))" } ?? "No vision yet"
        c.add(NSStackView(h: [counter, NSTextField.text("·", size: 11.5, color: Palette.dim), NSTextField.text(who, size: 11.5, color: Palette.dim), Spacer(), revert, save], spacing: 6))
        c.add(NSTextField.text("⌘S saves. Esc reverts. One vision for each project, at most \(MemoryDraft.maxText) characters.", size: 11, color: Palette.dim))
        body.addFull(c)

        let facts = mem.facts(of: p.ref)
        let add = ActionButton("Add entry", symbol: "plus") { [weak self] in self?.editFact("") }
        let c2 = card("Project memory", local: true, trailing: [add])
        c2.add(NSTextField.text("Short facts that AI jobs read. An accepted AI suggestion adds one here.", size: 12, color: Palette.dim, lines: 2))
        let list = ListCard()
        for f in facts { list.add(factRow(f, p)) }
        if editingFact == "" { list.add(factEditor(nil, p)) }
        if facts.isEmpty && editingFact != "" {
            list.add(Row([NSTextField.text("No entries", size: 12, color: Palette.dim), Spacer()], height: 36, label: "No memory entries"))
        }
        c2.add(list)
        body.addFull(c2)
    }

    private func source(_ e: MemoryEntry) -> String { e.source == .user ? "You" : "AI · accepted" }

    private func factRow(_ f: MemoryEntry, _ p: ProjectSummary) -> NSView {
        if editingFact == f.id { return factEditor(f, p) }
        let src = Chiplet(source(f), symbol: f.source == .user ? "person" : "sparkles", color: f.source == .user ? Palette.mut : Palette.acc)
        let edit = ActionButton("Edit") { [weak self] in self?.editFact(f.id) }
        let del = ActionButton("Delete", style: .danger) { [weak self] in
            self?.data.memory.remove(id: f.id)
            self?.reload()
        }
        edit.setAccessibilityLabel("Edit entry: \(f.text)")
        del.setAccessibilityLabel("Delete entry: \(f.text)")
        return Row([NSTextField.text(f.text, size: 12.5, lines: 3), Spacer(), src, edit, del], height: 44,
                   label: "\(f.text). Source: \(source(f)). \(relativeTime(f.updatedAt))")
    }

    // One line to add or change a fact. Return saves, Esc cancels.
    private func factEditor(_ f: MemoryEntry?, _ p: ProjectSummary) -> NSView {
        let input = LimitedInput(f?.text ?? "", placeholder: "For example: the app never stores GitHub tokens.", label: f == nil ? "New memory entry" : "Memory entry", lines: 2)
        let commit = { [weak self, weak input] in
            guard let self, let input else { return }
            do {
                try self.data.memory.saveFact(input.stringValue, id: f?.id, of: p.ref)
                self.editingFact = nil
                self.note = nil
            } catch ProjectMemory.SaveError.tooLong(let n) {
                self.note = (.warning, "An entry has at most \(MemoryDraft.maxText) characters. This one has \(n).")
            } catch {
                self.editingFact = nil
            }
            self.reload()
        }
        input.onSave = commit
        input.onRevert = { [weak self] in self?.editingFact = nil; self?.reload() }
        let save = ActionButton("Save", style: .primary) { commit() }
        let cancel = ActionButton("Cancel") { [weak self] in self?.editingFact = nil; self?.reload() }
        DispatchQueue.main.async { [weak input] in input?.window?.makeFirstResponder(input) }
        let r = NSStackView(h: [input, cancel, save], spacing: 6)
        r.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        return r
    }

    private func editFact(_ id: String) {
        editingFact = id
        reload()
    }

    private func saveVision(_ p: ProjectSummary) {
        guard let t = visionDraft else { return }
        do {
            try data.memory.saveVision(t, of: p.ref)
            visionDraft = nil
            note = nil
        } catch ProjectMemory.SaveError.tooLong(let n) {
            note = (.warning, "The vision has at most \(MemoryDraft.maxText) characters. It has \(n). Make it shorter to save.")
        } catch {}
        reload()
    }

    private func revertVision() {
        visionDraft = nil
        view.window?.makeFirstResponder(nil)
        reload()
    }

    private func sessions(_ body: NSStackView) {
        let l = local
        let c = card("Agent sessions", local: true)
        let agents = PROJECTS_CFG.runtime.agents + (l.agent.map { PROJECTS_CFG.runtime.agents.contains($0) ? [] : [$0] } ?? [])
        let titles = ["App default (\(PROJECTS_CFG.runtime.agent))"] + agents
        c.add(field("Agent", PopUp(titles, selected: l.agent.flatMap { agents.firstIndex(of: $0) }.map { $0 + 1 } ?? 0, label: "Agent") { [weak self] i in
            self?.editLocal { $0.agent = i == 0 ? nil : agents[i - 1] }
        }, help: "The agent CLI that the runtime starts for this project. The app default and the start command of each agent are in Settings › Agents and queue."))
        c.add(SwitchRow("Use the app default prompt", note: PROJECTS_CFG.runtime.prompt, on: l.prompt == nil) { [weak self] on in
            guard let self else { return }
            self.editLocal { $0.prompt = on ? nil : PROJECTS_CFG.runtime.prompt }
        })
        if let prompt = l.prompt {
            c.add(field("Prompt", TextInput(prompt, label: "Prompt template", mono: true, lines: 3) { [weak self] v in
                guard let self, v != self.local.prompt else { return }
                self.editLocal { $0.prompt = v }
            }, help: "Placeholders: {url}, {key}, {title}."))
        }
        body.addFull(c)
    }

    private func notifications(_ body: NSStackView) {
        let l = local
        let c = card("Notifications", local: true, trailing: [ActionButton(l.muted ? "Unmute project" : "Mute project", symbol: l.muted ? "bell" : "bell.slash") { [weak self] in
            self?.editLocal { $0.muted.toggle() }
        }])
        if l.muted { c.add(Banner(.idle, title: "This project is muted. OverSire sends no notifications for it.")) }
        c.add(SwitchRow("Use the app defaults", note: "Settings › Notifications", on: l.notifications == nil) { [weak self] on in
            self?.editLocal { $0.notifications = on ? nil : PROJECTS_CFG.notifications }
        })
        if let n = l.notifications {
            let scopes: [(String, WritableKeyPath<ProjectNotificationSettings, NotifyScope>)] = [
                ("New comment", \.comment), ("Status changes", \.status), ("Item is added", \.added),
                ("Item is closed or set to Done", \.closed), ("Other fields change", \.otherFields),
            ]
            for (title, path) in scopes {
                let s = n[keyPath: path]
                c.add(Row([NSTextField.text(title, size: 12.5), Spacer(),
                           ToggleChip("Any item", on: s.any) { [weak self] in self?.editLocal { $0.notifications?[keyPath: path].any.toggle() } },
                           ToggleChip("My items", on: s.mine) { [weak self] in self?.editLocal { $0.notifications?[keyPath: path].mine.toggle() } }],
                          height: 34, label: title))
            }
            let flags: [(String, WritableKeyPath<ProjectNotificationSettings, Bool>)] = [
                ("Someone mentions me", \.mention), ("Item is assigned to me", \.assigned), ("Intake item is new", \.intake),
                ("Orca session needs input", \.agentWaiting), ("Orca session is done", \.agentDone),
            ]
            for (title, path) in flags {
                c.add(SwitchRow(title, on: n[keyPath: path]) { [weak self] on in self?.editLocal { $0.notifications?[keyPath: path] = on } })
            }
        }
        body.addFull(c)
    }

    // MARK: In the tracker

    private func load(_ p: ProjectSummary) {
        loadingKey = key
        guard let t = ENV.tracker(p.ref.workspace) as? any ProjectSettingsReading else {
            remoteError = "\(trackerName) gives no project settings to OverSire."
            return
        }
        let editable = (t as? any ProjectSettingsEditing)?.editableSettings ?? []
        pageBusy = true
        let k = key, ref = p.ref
        Task { [weak self] in
            let r = await Result(awaiting: { try await t.settings(ref) })
            await MainActor.run {
                guard let self, self.key == k else { return }
                self.pageBusy = false
                switch r {
                case .success(let s): self.remote = TrackerSettingsView(settings: s, editable: editable); self.remoteError = nil; self.loadedAt = Date()
                case .failure(let e): self.remoteError = e.message
                }
                if !self.isEditing || self.draft.isEmpty { self.reload() }
            }
        }
    }

    private func refresh() {
        guard let p = project else { return }
        draft = ProjectSettingsPatch()
        load(p)
        reload()
    }

    private func tracker(_ body: NSStackView, _ p: ProjectSummary) {
        guard let v = remote else {
            let c = card(section.title, local: false)
            if let remoteError {
                c.add(EmptyNote(remoteError, symbol: "exclamationmark.triangle"))
                c.add(NSStackView(h: [ActionButton("Retry", symbol: "arrow.clockwise") { [weak self] in self?.refresh() },
                                      ActionButton("Open in \(trackerName)", symbol: "arrow.up.right.square") { [weak self] in self?.openInTracker() }, Spacer()], spacing: 6))
            } else {
                c.add(LoadingNote("Loading the \(trackerName) settings"))
            }
            body.addFull(c)
            return
        }
        switch section {
        case .general: general(body, v)
        case .workflow: workflow(body, v)
        case .labels: labels(body, v)
        case .members: members(body, v)
        case .features: features(body, v)
        default: break
        }
        if !draft.isEmpty { body.addFull(saveBar()) }
    }

    private func editInTracker(_ help: String? = nil) -> NSView {
        let b = ActionButton("Edit in \(trackerName) ↗", style: .link) { [weak self] in self?.openInTracker() }
        guard let help else { return b }
        return NSStackView(h: [NSTextField.text(help, size: 11.5, color: Palette.dim, lines: 2), b, Spacer()], spacing: 6)
    }

    private func general(_ body: NSStackView, _ v: TrackerSettingsView) {
        let s = v.settings
        let c = card("General", local: false, trailing: [ActionButton("Refresh", symbol: "arrow.clockwise") { [weak self] in self?.refresh() }])
        let people = s.members.map(\.person)
        for f in v.generalFields {
            switch f {
            case .name:
                if v.canEdit(.name) {
                    c.add(field("Name", TextInput(draft.name ?? s.name, label: "Name") { [weak self] t in
                        self?.change { $0.name = t == s.name ? nil : t }
                    }))
                } else { c.add(field("Name", NSTextField.text(s.name, size: 12.5), help: nil)); c.add(field("", editInTracker())) }
            case .description:
                let cur = draft.description ?? s.description ?? ""
                if v.canEdit(.description) {
                    c.add(field("Description", TextInput(cur, label: "Description", lines: 4) { [weak self] t in
                        self?.change { $0.description = t == (s.description ?? "") ? nil : t }
                    }))
                } else { c.add(field("Description", NSTextField.text(cur, size: 12.5, lines: 6), help: nil)) }
            case .lead, .defaultAssignee:
                let isLead = f == .lead
                let current = isLead ? s.lead : s.defaultAssignee
                let pending: String?? = isLead ? draft.lead : draft.defaultAssignee
                let id = pending ?? current?.id
                if v.canEdit(f) {
                    let titles = ["None"] + people.map(\.name)
                    let sel = id.flatMap { i in people.firstIndex { $0.id == i } }.map { $0 + 1 } ?? 0
                    c.add(field(f.label, PopUp(titles, selected: sel, label: f.label) { [weak self] i in
                        let new: String? = i == 0 ? nil : people[i - 1].id
                        self?.change { p in
                            let value: String?? = new == current?.id ? .none : .some(new)
                            if isLead { p.lead = value } else { p.defaultAssignee = value }
                        }
                    }))
                } else { c.add(field(f.label, NSTextField.text(current?.name ?? "None", size: 12.5))) }
            case .visibility:
                let cur = draft.visibility ?? s.visibility ?? .private
                if v.canEdit(.visibility) {
                    let all = ProjectVisibility.allCases
                    c.add(field("Visibility", PopUp(all.map(\.label), selected: all.firstIndex(of: cur) ?? 0, label: "Visibility") { [weak self] i in
                        self?.change { $0.visibility = all[i] == s.visibility ? nil : all[i] }
                    }))
                } else { c.add(field("Visibility", NSTextField.text(cur.label, size: 12.5))) }
            default: break
            }
        }
        if let k = s.key {
            c.add(field("Key", NSTextField.text(k, size: 12.5, mono: true), help: nil))
            c.add(field("", editInTracker("A new key changes the ID of every item.")))
        }
        body.addFull(c)
    }

    private func workflow(_ body: NSStackView, _ v: TrackerSettingsView) {
        let c = card("Statuses", local: false)
        let cats = Self.categories
        for o in v.settings.statuses {
            let cur = PROJECTS_CFG.category(o, project: key)
            let dot = Glyph("circle.fill", color: ProjectIconStore.color(hex: o.color) ?? Palette.dim, size: 10)
            let group = o.group.map { " · \(trackerName) group: \($0)" } ?? ""
            let pop = PopUp(cats.map(\.1), selected: cats.firstIndex { $0.0 == cur } ?? 0, label: "OverSire category of \(o.name)") { [weak self] i in
                self?.editLocal { $0.categories[o.id] = cats[i].0 == o.autoCategory ? nil : cats[i].0 }
                self?.data.projectStore.applyLocalSettings()
            }
            c.add(Row([dot, NSTextField.text(o.name, size: 12.5, weight: .medium), NSTextField.text(group, size: 11.5, color: Palette.dim), Spacer(),
                       NSTextField.text("OverSire", size: 11.5, color: Palette.dim), pop,
                       NSTextField.text(cur == o.autoCategory ? "auto" : "changed", size: 11.5, color: cur == o.autoCategory ? Palette.dim : Palette.warn).fixedWidth(54)],
                      height: 36, label: "\(o.name), OverSire category \(cur.label)"))
        }
        c.add(NSTextField.text("The OverSire category sets the light, the order and \"Show done\". It stays on this Mac and does not change the \(trackerName) group.",
                               size: 11.5, color: Palette.dim, lines: 3))
        c.add(editInTracker("Add or rename statuses in \(trackerName)."))
        body.addFull(c)
    }

    private func labels(_ body: NSStackView, _ v: TrackerSettingsView) {
        var trailing: [NSView] = []
        if v.canEdit(.labels) { trailing.append(ActionButton("New label", symbol: "plus") { [weak self] in self?.newLabel() }) }
        let c = card("Labels", local: false, trailing: trailing)
        let counts = Dictionary(grouping: data.projectStore.snapshots.values.first { $0.summary.identifier.uppercased() == key }?.items.flatMap(\.labels) ?? [], by: { $0 }).mapValues(\.count)
        for o in v.settings.labels {
            c.add(Row([Glyph("circle.fill", color: ProjectIconStore.color(hex: o.color) ?? Palette.dim, size: 10), NSTextField.text(o.name, size: 12.5), Spacer(),
                       NSTextField.text(counts[o.name].map { "\($0) open items" } ?? "", size: 11.5, color: Palette.dim)], height: 32, label: o.name))
        }
        for d in draft.newLabels ?? [] {
            c.add(Row([Glyph("circle.dashed", color: ProjectIconStore.color(hex: d.color) ?? Palette.dim, size: 10), NSTextField.text(d.name, size: 12.5), Spacer(),
                       NSTextField.text("new", size: 11.5, color: Palette.warn)], height: 32, label: "New label \(d.name)"))
        }
        if v.settings.labels.isEmpty && (draft.newLabels ?? []).isEmpty { c.add(EmptyNote("No labels.", symbol: "tag")) }
        if !v.canEdit(.labels) { c.add(editInTracker()) }
        body.addFull(c)
    }

    private func newLabel() {
        let a = NSAlert()
        a.messageText = "New label in \(project?.title ?? key)"
        a.informativeText = "The label is added in \(trackerName) when you save."
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        f.placeholderString = "Label name"
        a.accessoryView = f
        a.addButton(withTitle: "Add")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let name = f.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let color = Self.okabe[((draft.newLabels?.count ?? 0) + (remote?.settings.labels.count ?? 0)) % Self.okabe.count]
        change { $0.newLabels = ($0.newLabels ?? []) + [LabelDraft(name: name, color: color)] }
    }

    private func members(_ body: NSStackView, _ v: TrackerSettingsView) {
        let c = card("Members", local: false)
        for m in v.settings.members {
            let initials = m.person.name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
            c.add(Row([Chiplet(initials.isEmpty ? "?" : initials, mono: true), NSTextField.text(m.person.name, size: 12.5),
                       NSTextField.text(m.person.login.map { "@" + $0 } ?? "", size: 11.5, color: Palette.dim, mono: true), Spacer(),
                       Chiplet((m.role ?? "member").capitalized)], height: 34, label: "\(m.person.name), \(m.role ?? "member")"))
        }
        c.add(NSStackView(h: [NSTextField.text("\(trackerName) manages members and roles. OverSire reads them for the assignee lists.", size: 11.5, color: Palette.dim, lines: 2),
                              ActionButton("Manage in \(trackerName) ↗", style: .link) { [weak self] in self?.openInTracker() }, Spacer()], spacing: 6))
        body.addFull(c)
    }

    private func features(_ body: NSStackView, _ v: TrackerSettingsView) {
        let c = card("Features", local: false)
        for f in ProjectFeature.allCases {
            guard let saved = v.settings.features[f] else { continue }
            let on = draft.features?[f] ?? saved
            let uses = f == .intake ? "OverSire uses Intake for triage in the Inbox." : nil
            let why = v.canToggle(f) ? uses : [uses, "\(trackerName) does not let OverSire change it."].compactMap { $0 }.joined(separator: " ")
            c.add(SwitchRow(f.label, note: why, on: on, enabled: v.canToggle(f)) { [weak self] new in
                self?.change { p in
                    var fs = p.features ?? [:]
                    fs[f] = new == saved ? nil : new
                    p.features = fs.isEmpty ? nil : fs
                }
            })
        }
        body.addFull(c)
    }

    // MARK: Save

    private func change(_ edit: (inout ProjectSettingsPatch) -> Void) {
        edit(&draft)
        reload()
    }

    private func saveBar() -> NSView {
        let names = draft.fields.map(\.label).sorted().joined(separator: ", ")
        let save = ActionButton("Save to \(trackerName)", style: .primary) { [weak self] in self?.save() }
        if saving { save.busy("Saving…") }
        let revert = ActionButton("Revert") { [weak self] in self?.draft = ProjectSettingsPatch(); self?.reload() }
        revert.isEnabled = !saving
        return Banner(.warning, title: "This changes \(names) in \(trackerName) for everyone.", actions: [revert, save])
    }

    private func save() {
        guard let p = project, let t = ENV.tracker(p.ref.workspace) as? any ProjectSettingsEditing, !draft.isEmpty else { return }
        saving = true
        reload()
        let patch = draft, ref = p.ref, k = key
        let token = data.busy.begin("Saving the \(trackerName) settings of \(k)")
        Task { [weak self] in
            let r = await Result(awaiting: { try await t.update(ref, patch) })
            await MainActor.run {
                guard let self else { return }
                self.data.busy.end(token)
                self.saving = false
                switch r {
                case .success:
                    self.draft = ProjectSettingsPatch()
                    self.note = (.ok, "\(self.trackerName) saved \(patch.fields.map(\.label).sorted().joined(separator: ", ")).")
                    self.load(p)
                    self.data.projectStore.refresh([ref.storeKey], force: true) { _ in }
                case .failure(let e):
                    self.note = (.bad, "\(self.trackerName) did not save: \(e.message)")
                }
                self.reload()
            }
        }
    }
}
