import Cocoa
import OverSireCore

// Settings › Projects and repos › Projects: the tracked projects, and a picker to track more. Each change saves at once.
final class ProjectListView: NSStackView {
    private let catalog: ProjectCatalog
    private let open: (String) -> Void
    private var observer: Any?
    private var applyQueued = false

    init(catalog: ProjectCatalog, open: @escaping (String) -> Void) {
        self.catalog = catalog
        self.open = open
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false
        observer = NotificationCenter.default.addObserver(forName: ProjectCatalog.changed, object: catalog, queue: .main) { [weak self] _ in self?.render() }
        render()
        if NSApp.delegate is GHActionsBar { catalog.refreshIfStale() }
    }
    required init(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    private func render() {
        arrangedSubviews.forEach { $0.removeFromSuperview() }
        let card = ListCard()
        let tracked = catalog.resolve(PROJECTS_CFG)
        if catalog.workspaces.isEmpty {
            card.add(Padded(EmptyNote("Add a tracker account in Accounts and sync.", symbol: "tray")))
        } else if tracked.isEmpty {
            card.add(Padded(EmptyNote(catalog.refreshing ? "Loading projects…" : "No project is tracked.", symbol: "tray")))
        }
        tracked.forEach { card.add(row($0)) }
        if !catalog.workspaces.isEmpty { card.add(picker()) }
        addFull(card)
    }

    private func row(_ p: ProjectSummary) -> NSView {
        let key = p.identifier.uppercased()
        let s = PROJECTS_CFG.local(key)
        var meta = ["\(trackerName(p.ref.account)) \(p.ref.workspace)"]
        meta.append(s.github.isEmpty ? "no repos" : s.github.count == 1 ? "1 repo" : "\(s.github.count) repos")
        if let root = s.orcaRoot { meta.append("Orca " + (root as NSString).abbreviatingWithTildeInPath) }
        if s.notifications != nil { meta.append("custom notifications") }
        let icon = NSImageView(image: PROJECT_ICONS.image(for: key, size: 28))
        icon.setAccessibilityElement(false)
        let name = NSStackView(h: [NSTextField.text(p.title, size: 13, weight: .medium), NSTextField.text(key, size: 11.5, color: Palette.dim, mono: true)], spacing: 6)
        var views: [NSView] = [icon, NSStackView(v: [name, NSTextField.text(meta.joined(separator: " · "), size: 11.5, color: Palette.dim)], spacing: 2), Spacer()]
        if s.muted {
            let m = Pill(.idle, text: "Muted")
            m.toolTip = "This project sends no notifications."
            views.append(m)
        }
        let b = ActionButton("Settings ›") { [weak self] in self?.open(key) }
        b.setAccessibilityLabel("Settings of \(p.title)")
        views.append(b)
        return Row(views, height: 52, label: p.title)
    }

    // The projects of each workspace, with a check box each. A workspace check tracks all, also new ones.
    private func picker() -> NSView {
        let d = Disclosure("Track a project", id: "track-project")
        for slug in catalog.workspaces {
            let projects = PROJECTS_CFG.sorted(catalog.projects(of: slug)).filter { !$0.closed }
            let all = PROJECTS_CFG.allOf.contains(slug)
            var head: [NSView] = [NSTextField.text(slug, size: 12.5, weight: .semibold)]
            switch catalog.fetch(slug) {
            case .loading: head.append(NSTextField.text("Loading…", size: 11.5, color: Palette.dim))
            case .failed(let msg):
                let p = Pill(.bad, text: "Failed")
                p.toolTip = msg
                head.append(p)
            case .idle: head.append(NSTextField.text(all ? "All \(projects.count) · includes new projects" : "\(projects.count) projects", size: 11.5, color: Palette.dim))
            }
            head.append(Spacer())
            let t = ActionButton(all ? "Untrack all" : "Track all", style: .link) { [weak self] in self?.toggleAll(slug) }
            t.toolTip = "Track all projects of \(slug), also projects added later"
            head.append(t)
            let r = ActionButton("", symbol: "arrow.clockwise") { [weak self] in self?.catalog.refresh(slug, force: true) }
            r.setAccessibilityLabel("Refresh \(slug)")
            head.append(r)
            d.add(Row(head, height: 36, inset: 26, label: slug))
            for p in projects {
                let cb = NSButton(checkboxWithTitle: " \(p.title)  \(p.identifier)", target: self, action: #selector(toggleProject(_:)))
                cb.font = .systemFont(ofSize: 13)
                cb.state = all || PROJECTS_CFG.picked.contains(p.ref.storeKey) ? .on : .off
                cb.identifier = NSUserInterfaceItemIdentifier(p.ref.storeKey)
                cb.setAccessibilityLabel(p.title)
                d.add(Row([cb, Spacer()], height: 32, inset: 44, label: p.title))
            }
        }
        return d
    }

    private func trackerName(_ account: AccountID) -> String {
        ENV.descriptor(account)?.displayName ?? account.provider.rawValue
    }

    // MARK: Changes

    private func toggleAll(_ slug: String) {
        let was = PROJECTS_CFG.allOf.contains(slug)
        PROJECTS_CFG.allOf.removeAll { $0 == slug }
        PROJECTS_CFG.picked.removeAll { $0.hasPrefix(slug + "/") }
        if !was { PROJECTS_CFG.allOf.append(slug) }
        save()
    }

    @objc private func toggleProject(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        let slug = key.split(separator: "/").first.map(String.init) ?? key
        if PROJECTS_CFG.allOf.contains(slug) {
            PROJECTS_CFG.allOf.removeAll { $0 == slug }
            PROJECTS_CFG.picked = PROJECTS_CFG.picked.filter { !$0.hasPrefix(slug + "/") }
                + catalog.projects(of: slug).filter { !$0.closed && $0.ref.storeKey != key }.map(\.ref.storeKey)
        } else if sender.state == .on {
            if !PROJECTS_CFG.picked.contains(key) { PROJECTS_CFG.picked.append(key) }
        } else {
            PROJECTS_CFG.picked.removeAll { $0 == key }
        }
        save()
    }

    // Saves at once, and applies the picks once after a burst of clicks.
    private func save() {
        saveConfig()
        render()
        guard !applyQueued else { return }
        applyQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.applyQueued = false
            (NSApp.delegate as? GHActionsBar)?.applyProjectSelection()
            self?.catalog.refreshAll()
        }
    }
}

extension SettingsPage {
    static let trackerPoll = [2, 5, 10, 15, 30]

    func projects(_ b: NSStackView) {
        let list = ProjectListView(catalog: data.projectCatalog) { [weak self] key in self?.go(.projectSettings(key, .appearance)) }
        list.identifier = SettingsAnchor.projects.id
        b.addFull(list)
        let poll = Segmented(Self.trackerPoll.map { "\($0) min" }, selected: Self.trackerPoll.firstIndex(of: PROJECTS_CFG.pollMinutes) ?? 1,
                             label: "Check trackers every") { [weak self] i in
            PROJECTS_CFG.pollMinutes = Self.trackerPoll[i]
            saveConfig()
            self?.app?.projectStore.restartTimer()
        }
        b.addFull(section(.refresh, [
            FieldRow("Check trackers every", note: "For workspaces without a webhook, and when the cloud is off.", poll),
        ]))
    }
}
