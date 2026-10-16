import Cocoa

// One line of the inbox, from Plane, GitHub, Orca, the AI checks or the intake.
struct InboxEntry {
    enum Source: String {
        case plane = "Plane", mention = "Mention", run = "GitHub", agent = "Orca", ai = "AI", intake = "Intake"
        var tab: Route.InboxTab {
            switch self {
            case .plane: return .all
            case .mention: return .mentions
            case .run: return .runs
            case .agent, .ai: return .agents
            case .intake: return .intake
            }
        }
        var color: NSColor {
            switch self {
            case .plane, .run: return Palette.mut
            case .mention: return Palette.acc
            case .agent: return Palette.warn
            case .ai: return Palette.acc
            case .intake: return Palette.intake
            }
        }
    }

    let id: String
    let source: Source
    let title: String
    let body: String
    let at: Date
    var unread: Bool
    let route: Route?
    var url: String? = nil
    var intake: (projectKey: String, item: IntakeItem)? = nil
    var activityId: String? = nil

}

// Builds the inbox and keeps the read state of the lines that are not Plane activity.
final class InboxFeed {
    private static let readKey = "inboxRead"
    private var read: Set<String>

    init() { read = Set(UserDefaults.standard.stringArray(forKey: InboxFeed.readKey) ?? []) }

    func entries(_ data: AppData) -> [InboxEntry] {
        let store = data.projectStore
        var out: [InboxEntry] = []
        for e in store.activity(limit: 200, project: nil) {
            let found = store.item(e.itemId)
            let key = found?.item.key ?? ""
            let source: InboxEntry.Source = { if case .mention = e.change { return .mention }; return .plane }()
            out.append(InboxEntry(id: "plane|" + e.id, source: source, title: "\(key) \(found?.item.title ?? "")".trimmingCharacters(in: .whitespaces),
                                  body: (e.actor.map { "\($0): " } ?? "") + e.text, at: e.at, unread: e.unread,
                                  route: key.isEmpty ? nil : .item(key, .activity), url: e.url, activityId: e.id))
        }
        let day = Date().addingTimeInterval(-86400)
        for (repo, runs) in data.grouped {
            for r in latestPerWorkflow(runs) where r.status == "completed" && lastActivity(r) > day && (r.isFailure || data.workstreams.link(runId: r.id) != nil) {
                let t = Tone(r)
                let link = data.workstreams.link(runId: r.id)
                let id = "run|\(r.id)|\(r.attempt ?? 1)"
                out.append(InboxEntry(id: id, source: .run, title: "\(r.workflowName ?? r.name) #\(r.number) · \(t.word)",
                                      body: "\(repo) · \(r.headBranch)" + (link.map { " · \($0.key)" } ?? " · unlinked"),
                                      at: lastActivity(r), unread: !read.contains(id), route: .run(repo: repo, id: r.id)))
            }
        }
        for (key, a) in data.agentIndex.agents where a.phase != .working && a.phase != .starting {
            let id = "agent|\(key)|\(a.phase)|\(Int(a.since.timeIntervalSince1970))"
            let what = a.phase == .waiting ? "asks a question" : a.phase == .done ? "is done" : "did not start"
            out.append(InboxEntry(id: id, source: .agent, title: "\(key) session \(what)", body: a.message ?? "",
                                  at: a.since, unread: !read.contains(id), route: .item(key, .session)))
        }
        for c in data.aiChecks.checks.prefix(30) {
            let id = "ai|" + c.id
            out.append(InboxEntry(id: id, source: .ai, title: "AI check: \(c.key) · \(c.verdict.word)",
                                  body: c.evidence.joined(separator: " · "), at: c.at,
                                  unread: c.state == .pending && !read.contains(id), route: .queue))
        }
        for (pk, snap) in store.snapshots {
            for i in snap.intake ?? [] {
                let num = store.intakeKeys[i.workItemId].map { "\(snap.summary.identifier)-\($0)" } ?? snap.summary.identifier
                out.append(InboxEntry(id: "intake|" + i.id, source: .intake, title: "\(num) \(i.name)",
                                      body: [i.author.map { "by \($0)" }, i.priority, i.source?.replacingOccurrences(of: "_", with: " ").lowercased()]
                                        .compactMap { $0 }.joined(separator: " · "),
                                      at: i.createdAt, unread: true, route: nil, intake: (pk, i)))
            }
        }
        return out.sorted { $0.at > $1.at }
    }

    func markRead(_ e: InboxEntry, store: ProjectStore) {
        if let a = e.activityId { store.markActivityRead(a); return }
        read.insert(e.id)
        save()
    }

    func markAllRead(_ list: [InboxEntry], store: ProjectStore) {
        for e in list where e.unread && e.source != .intake {
            if let a = e.activityId { store.markActivityRead(a) } else { read.insert(e.id) }
        }
        save()
    }

    private func save() {
        UserDefaults.standard.set(Array(read.suffix(2000)), forKey: InboxFeed.readKey)
        NotificationCenter.default.post(name: AppWindow.changed, object: nil)
    }
}

// An inbox line. Intake lines take the triage keys 1, 2, 3 and H.
final class InboxRow: Row {
    var onKey: ((String) -> Bool)?

    init(_ e: InboxEntry, onClick: @escaping () -> Void) {
        let dot = Box(fill: e.unread ? Palette.acc : .clear, border: nil, radius: 3.5)
        dot.widthAnchor.constraint(equalToConstant: 7).isActive = true
        dot.heightAnchor.constraint(equalToConstant: 7).isActive = true
        let src = Chiplet(e.source.rawValue, color: e.source.color)
        let srcBox = NSView()
        srcBox.translatesAutoresizingMaskIntoConstraints = false
        srcBox.addSubview(src)
        NSLayoutConstraint.activate([
            srcBox.widthAnchor.constraint(equalToConstant: 64), srcBox.heightAnchor.constraint(equalTo: src.heightAnchor),
            src.leadingAnchor.constraint(equalTo: srcBox.leadingAnchor), src.centerYAnchor.constraint(equalTo: srcBox.centerYAnchor),
        ])
        let when = NSTextField.text(relativeTime(e.at), size: 11.5, color: Palette.dim)
        let main = TwoLine(e.title, e.body, weight: e.unread ? .semibold : .regular)
        super.init([dot, srcBox, main, Spacer(), when], height: 48,
                   label: (e.unread ? "Unread. " : "") + "\(e.source.rawValue): \(e.title). \(e.body)", onClick: onClick)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func keyDown(with event: NSEvent) {
        if let c = event.charactersIgnoringModifiers?.lowercased(), event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           onKey?(c) == true { return }
        super.keyDown(with: event)
    }
}

final class InboxPage: Page {
    private let feed = InboxFeed()
    private var busy: Set<String> = []
    private var note: String?

    private var tab: Route.InboxTab { if case .inbox(let t) = route { return t }; return .all }

    override func build(_ col: NSStackView) {
        let all = feed.entries(data)
        for (pk, snap) in data.projectStore.snapshots where !(snap.intake ?? []).isEmpty {
            data.projectStore.loadIntakeKeys(projectKey: pk) { [weak self] in self?.reload() }
        }
        let tabs = Route.InboxTab.allCases
        let counts = tabs.map { t in all.filter { t == .all ? true : $0.source.tab == t }.count }
        col.addFull(PageHeader("Inbox", caption: "Plane, GitHub, Orca and AI checks in one list. Intake waits for triage.",
                               actions: [ActionButton("Mark all read", symbol: "checkmark") { [weak self] in
            guard let self else { return }
            self.feed.markAllRead(all, store: self.data.projectStore)
        }]))
        let strip = TabStrip(tabs.map { $0.rawValue.capitalized }, selected: tabs.firstIndex(of: tab) ?? 0, counts: counts)
        strip.onSelect = { [weak self] i in self?.go(.inbox(tabs[i])) }
        col.addArrangedSubview(strip)
        if let note { col.addFull(Banner(.info, title: note)) }
        if tab == .intake {
            col.addFull(NSTextField.text("Keys on a focused line: 1 accept · 2 duplicate · 3 decline · H snooze one day. Tab moves between lines.",
                                         size: 12, color: Palette.dim, lines: 2))
        }
        let shown = all.filter { tab == .all || $0.source.tab == tab }
        let list = ListCard()
        for e in shown.prefix(150) { list.add(row(e)) }
        if list.isEmpty { list.add(EmptyNote(tab == .intake ? "No intake waits for triage." : "Nothing here. Inbox zero.")) }
        col.addFull(list)
    }

    private func row(_ e: InboxEntry) -> NSView {
        var actions: [NSView] = []
        if let (pk, item) = e.intake {
            if busy.contains(item.id) {
                let p = NSProgressIndicator()
                p.style = .spinning; p.controlSize = .small
                p.startAnimation(nil)
                actions.append(p)
            } else {
                if data.intakeAgent.available && data.intakeAgent.state(item) == nil {
                    actions.append(ActionButton("Check in Orca", symbol: "sparkles", style: .primary) { [weak self] in
                        self?.data.intakeAgent.start(projectKey: pk, item: item)
                    })
                }
                actions.append(ActionButton("Accept  1") { [weak self] in self?.triage(pk, item, .accept) })
                actions.append(ActionButton("Duplicate  2") { IntakeWindow.show(projectKey: pk, workItemId: item.workItemId) })
                actions.append(ActionButton("Decline  3") { [weak self] in self?.triage(pk, item, .decline) })
                actions.append(ActionButton("Snooze  H") { [weak self] in self?.triage(pk, item, .snooze(until: Date().addingTimeInterval(86400))) })
            }
        }
        actions.forEach { ($0 as? NSButton)?.controlSize = .small }
        let r = InboxRow(e) { [weak self] in self?.open(e) }
        r.hoverViews = actions
        if let (pk, item) = e.intake {
            r.onKey = { [weak self] c in
                switch c {
                case "1": self?.triage(pk, item, .accept)
                case "2": IntakeWindow.show(projectKey: pk, workItemId: item.workItemId)
                case "3": self?.triage(pk, item, .decline)
                case "h": self?.triage(pk, item, .snooze(until: Date().addingTimeInterval(86400)))
                default: return false
                }
                return true
            }
        }
        r.menuItems = { [weak self] in
            guard let self else { return [] }
            var items: [NSMenuItem] = []
            if e.unread && e.intake == nil { items.append(MenuAction("Mark as read") { self.feed.markRead(e, store: self.data.projectStore) }.item) }
            if let u = e.url { items.append(MenuAction("Open in Plane") { NSWorkspace.shared.open(URL(string: u)!) }.item) }
            return items
        }
        guard let (pk, item) = e.intake, let state = data.intakeAgent.state(item) else { return r }
        let panel = IntakePanel(state, projectKey: pk, item: item, agent: data.intakeAgent) { [weak self] err in
            self?.note = err
            self?.reload()
        }
        let v = NSStackView(v: [r, panel], spacing: 6)
        r.widthAnchor.constraint(equalTo: v.widthAnchor).isActive = true
        panel.widthAnchor.constraint(equalTo: v.widthAnchor, constant: -28).isActive = true
        v.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 10, right: 0)
        v.alignment = .centerX
        return v
    }

    private func open(_ e: InboxEntry) {
        if e.unread && e.intake == nil { feed.markRead(e, store: data.projectStore) }
        if let (pk, item) = e.intake { IntakeWindow.show(projectKey: pk, workItemId: item.workItemId); return }
        if let r = e.route { go(r) }
    }

    private func triage(_ pk: String, _ item: IntakeItem, _ action: IntakeAction) {
        busy.insert(item.id)
        reload()
        data.projectStore.triage(projectKey: pk, item: item, action: action) { [weak self] ok in
            guard let self else { return }
            self.busy.remove(item.id)
            self.note = ok ? nil : (self.data.projectStore.lastError ?? "Plane did not accept the change.")
            self.reload()
        }
    }
}

// A menu item that runs a closure. Keep the object alive with the item.
final class MenuAction: NSObject {
    private let run: () -> Void
    let item: NSMenuItem

    init(_ title: String, _ run: @escaping () -> Void) {
        self.run = run
        item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        super.init()
        item.action = #selector(fire)
        item.target = self
        item.representedObject = self
    }

    @objc private func fire() { run() }
}
