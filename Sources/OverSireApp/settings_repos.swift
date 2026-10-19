import Cocoa
import OverSireCore

// Settings › Projects and repos › Repos: a filter header that stays, and the repos by owner.
// The view renders RepoListModel. Each change saves at once.
final class RepoListView: NSStackView, NSSearchFieldDelegate {
    static var text = ""
    static var limits: [String: Int] = [:]

    private let catalog: RepoCatalog
    private let setup: CloudSetup
    private let filter: RepoListModel.Filter
    private let onFilter: (RepoListModel.Filter) -> Void
    private var model: RepoListModel
    private let card: StickyListCard
    private let search = NSSearchField()
    private let chips = NSStackView(h: [], spacing: 6)
    private let refresh = ActionButton("Refresh")
    private var observer: Any?
    private var applyQueued = false

    init(catalog: RepoCatalog, setup: CloudSetup, filter: RepoListModel.Filter, onFilter: @escaping (RepoListModel.Filter) -> Void) {
        self.catalog = catalog
        self.setup = setup
        self.filter = filter
        self.onFilter = onFilter
        model = RepoListModel(catalog: [], picked: [], orgs: [], hooks: nil)
        search.placeholderString = "Filter, or type owner/repo to add"
        search.stringValue = Self.text
        search.setAccessibilityLabel("Filter or add a repo")
        search.setContentHuggingPriority(.init(1), for: .horizontal)
        search.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        card = StickyListCard(header: NSStackView(h: [search, chips, refresh], spacing: 10))
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 0
        translatesAutoresizingMaskIntoConstraints = false
        addFull(card)
        search.delegate = self
        refresh.onClick = { [weak self] in self?.catalog.refreshAll() }
        observer = NotificationCenter.default.addObserver(forName: RepoCatalog.changed, object: catalog, queue: .main) { [weak self] _ in self?.update() }
        update()
        if NSApp.delegate is GHActionsBar { catalog.refreshIfStale() }
    }
    required init(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func controlTextDidChange(_ obj: Notification) {
        Self.text = search.stringValue
        model.text = Self.text
        render()
    }

    // A new model from the catalog, the saved picks and the hooks. The hooks count only with the cloud on.
    private func update() {
        model = RepoListModel(catalog: catalog.owners.map { ($0.login, $0.repos) }, picked: Set(PICKED_REPOS), orgs: Set(PICKED_ORGS),
                              hooks: setup.state.joined ? setup.hooks.statuses : nil)
        model.text = Self.text
        model.filter = filter
        model.limits = Self.limits
        render()
    }

    private func render() {
        let counts = model.counts
        chips.clear()
        for (f, name) in [(RepoListModel.Filter.all, "All"), (.tracked, "Tracked"), (.problems, "Problems")] {
            let c = ToggleChip("\(name) \(counts[f] ?? 0)", on: f == filter) { [weak self] in self?.onFilter(f) }
            c.setAccessibilityRole(.radioButton)
            chips.addArrangedSubview(c)
        }
        refresh.title = catalog.refreshing ? "Refreshing…" : "Refresh"
        refresh.isEnabled = !catalog.refreshing
        refresh.toolTip = catalog.fetchedAt.map { "Updated \(relativeTime($0))" }
        card.clear()
        if let name = model.addable {
            card.add(Row([Glyph("plus.circle", color: Palette.acc, size: 13), NSTextField.text("Add \(name)", size: 13, weight: .medium), Spacer()],
                         height: 38, label: "Add \(name)") { [weak self] in self?.add(name) })
        }
        let groups = model.groups
        for g in groups {
            card.addGroup { self.header(g) }
            if g.repos.isEmpty {
                let loading: Bool = { if case .loading = catalog.fetch(g.owner) { return true }; return false }()
                card.add(Row([NSTextField.text(loading ? "Loading…" : "No repos", size: 12, color: Palette.dim)], height: 32, inset: 44))
            }
            g.repos.forEach { card.add(row($0)) }
            if g.hidden > 0 {
                let more = min(g.hidden, RepoListModel.moreRows)
                card.add(Row([ActionButton("Show \(more) more of \(g.hidden)", style: .link) { [weak self] in self?.showMore(g.owner) }, Spacer()],
                             height: 32, inset: 44))
            }
        }
        if groups.isEmpty, model.addable == nil {
            let text: String
            if !model.text.isEmpty || filter != .all { text = filter == .problems ? "No problems." : "No repo matches." }
            else if catalog.refreshing { text = "Loading repos…" }
            else { text = catalog.authChecked && catalog.user == nil ? "Login to see your repos" : "No repos found" }
            card.add(Padded(EmptyNote(text, symbol: filter == .problems ? "checkmark.circle" : "tray")))
        }
    }

    private func header(_ g: RepoListModel.Group) -> NSView {
        let avatar = Box(fill: Palette.raise, border: nil, radius: 5)
        let letter = NSTextField.text(String(g.owner.prefix(1)).uppercased(), size: 10, weight: .bold, color: Palette.mut)
        letter.translatesAutoresizingMaskIntoConstraints = false
        avatar.addSubview(letter)
        NSLayoutConstraint.activate([avatar.widthAnchor.constraint(equalToConstant: 20), avatar.heightAnchor.constraint(equalToConstant: 20),
                                     letter.centerXAnchor.constraint(equalTo: avatar.centerXAnchor), letter.centerYAnchor.constraint(equalTo: avatar.centerYAnchor)])
        let count = g.wholeOwner ? "All \(g.total) · includes new repos" : g.total == 0 ? "" : "\(g.tracked) of \(g.total) tracked"
        var views: [NSView] = [avatar, NSTextField.text(g.owner, size: 12.5, weight: .semibold), NSTextField.text(count, size: 11.5, color: Palette.dim)]
        if case .failed(let msg) = catalog.fetch(g.owner) {
            let p = Pill(.bad, text: "Failed")
            p.toolTip = msg
            views.append(p)
        }
        views.append(Spacer())
        let all = ActionButton(g.wholeOwner ? "Untrack all" : "Track all", style: .link) { [weak self] in self?.toggleOwner(g.owner) }
        all.toolTip = "Track all repos of \(g.owner), also repos added later"
        views.append(all)
        let r = ActionButton("", symbol: "arrow.clockwise") { [weak self] in self?.catalog.refresh(owner: g.owner) }
        r.setAccessibilityLabel("Refresh \(g.owner)")
        if case .loading = catalog.fetch(g.owner) { r.isEnabled = false }
        views.append(r)
        return Row(views, height: 36, label: g.owner)
    }

    private func row(_ r: RepoListModel.Repo) -> NSView {
        let cb = NSButton(checkboxWithTitle: " " + r.short, target: self, action: #selector(toggleRepo(_:)))
        cb.font = .systemFont(ofSize: 13)
        cb.state = r.tracked ? .on : .off
        cb.identifier = NSUserInterfaceItemIdentifier(r.name)
        cb.setAccessibilityLabel(r.name)
        var views: [NSView] = [cb, Spacer()]
        if let b = r.badge {
            let pill: Pill
            switch b {
            case .webhook: pill = Pill(.ok, text: "Webhook")
            case .missing: pill = Pill(.warning, text: "No webhook · polls")
            case .pollingOnly(let d):
                pill = Pill(.warning, text: "No webhook · polls")
                pill.toolTip = "Needs an admin of the repo: \(d)"
            case .failed(let d): pill = Pill(.bad, text: "Failed · \(d)")
            }
            views.append(pill)
            if b.fixable {
                let fix = ActionButton("Fix") { [weak self] in self?.fix(r.name) }
                fix.isEnabled = setup.busy == nil
                views.append(fix)
            }
        }
        return Row(views, height: 34, inset: 44, label: r.name)
    }

    // MARK: Changes

    @objc private func toggleRepo(_ sender: NSButton) {
        guard let repo = sender.identifier?.rawValue else { return }
        model.set(repo, tracked: sender.state == .on)
        save()
    }

    private func showMore(_ owner: String) {
        model.showMore(owner)
        Self.limits = model.limits
        render()
    }

    private func toggleOwner(_ owner: String) {
        model.toggleOwner(owner)
        save()
    }

    private func add(_ repo: String) {
        model.set(repo, tracked: true)
        Self.text = ""
        search.stringValue = ""
        model.text = ""
        save()
    }

    private func fix(_ repo: String) {
        let s = setup
        s.perform("Install the webhook of \(repo)", { s.installHooks(repos: [repo]) }) { [weak self] _ in
            s.checkHooks(repos: [repo])
            self?.update()
        }
    }

    // Saves at once, and applies the picks once after a burst of clicks.
    private func save() {
        PICKED_REPOS = model.savedRepos
        PICKED_ORGS = model.savedOrgs
        saveConfig()
        render()
        guard !applyQueued else { return }
        applyQueued = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.applyQueued = false
            (NSApp.delegate as? GHActionsBar)?.applyRepoSelection(reopen: false)
        }
    }
}
