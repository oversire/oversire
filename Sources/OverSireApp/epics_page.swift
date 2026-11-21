import AppKit
import OverSireCore

// Work › Epics: the epics of all projects in sections. Each row shows the progress, the due line, the sessions and one button.
final class EpicsPage: Page {
    private var filter = EpicBoard.Filter()
    private var unfolded: Set<EpicBoard.Section> = []
    override var fillsHeight: Bool { true }

    override var watches: DataDomains { [.projects, .agents, .runs, .queue, .summaries, .planner, .config, .reviews, .questions, .relations] }
    override var parts: [PagePart] { [data.projectStore.plane] }

    /// What the tracker calls an epic, with its name: "Plane module". Nil when the tracker has no noun.
    private func vendor(_ project: String) -> String? {
        guard let snap = data.projectStore.snapshot(project), let d = ENV.descriptor(snap.summary.ref.account) else { return nil }
        return d.epicNoun.map { "\(d.displayName) \($0)" }
    }

    private func fold(_ s: EpicBoard.Section) -> GroupFold {
        // Done is folded until you open it.
        let open = s == .done ? unfolded.contains(s) : !unfolded.contains(s)
        return GroupFold(expanded: open) { [weak self] in
            if self?.unfolded.remove(s) == nil { self?.unfolded.insert(s) }
            self?.reload()
        }
    }

    private func filters(projects: [String]) -> [NSView] {
        let f = filter
        let project = MenuChip(f.project ?? "All projects", symbol: "folder", color: f.project == nil ? Palette.mut : Palette.fg) { [weak self] in
            let all = ClosureItem("All projects") { self?.filter.project = nil; self?.reload() }
            all.state = f.project == nil ? .on : .off
            return [all] + projects.map { p in
                let a = ClosureItem(p) { self?.filter.project = p; self?.reload() }
                a.state = f.project?.caseInsensitiveCompare(p) == .orderedSame ? .on : .off
                return a
            }
        }
        project.setAccessibilityLabel("Project: " + (f.project ?? "all projects"))
        return [project,
                ToggleChip("Mine", on: f.mine) { [weak self] in self?.filter.mine.toggle(); self?.reload() },
                ToggleChip("Late", on: f.late) { [weak self] in self?.filter.late.toggle(); self?.reload() },
                ToggleChip("Show done", on: f.showDone) { [weak self] in self?.filter.showDone.toggle(); self?.reload() }]
    }

    override func sections() -> [PageSection]? {
        let store = data.projectStore
        let job = data.statusJob, questions = data.questions
        let snaps = store.snapshots.values.sorted { $0.summary.identifier < $1.summary.identifier }
        let projects = snaps.filter { !($0.epics ?? []).isEmpty }.map(\.summary.identifier)
        let groups = EpicBoard.build(snaps, filter: filter, sessions: { key in
            let attention = job.item(key)?.attention
            return (questions.count(key: key) > 0 || attention == 0, attention == 3)
        }, blocked: { snap in
            Set(snap.items.filter { $0.epicId != nil && !store.blockers(of: $0.key).isEmpty }.map(\.id))
        }, now: Date())
        let shown = groups.reduce(0) { $0 + $1.1.count }
        let f = filter
        let top = WorkPage.header(self, tab: .epics, caption: "Late first · then nearest target date", extra: [AnyHashable(f), AnyHashable(projects)],
                                  actions: { [] }, trailing: { [weak self] in self?.filters(projects: projects) ?? [] })

        pageBusy = data.projectsLoading
        var rows: [PageRow] = []
        for (section, list) in groups {
            let fold = fold(section)
            rows.append(StickyListCard.group(section.rawValue, section.title, count: list.count, fold: fold, trailing: {
                section == .readyToClose ? [NSTextField.text("All items are done", size: 12, color: Palette.dim)] : []
            }))
            guard fold.expanded else { continue }
            rows += list.map(line)
        }
        if rows.isEmpty {
            let loading = data.projectsLoading, supported = data.has(.epics)
            let text = !supported ? "None of your trackers has epics. A Plane module shows here as an epic."
                : f == EpicBoard.Filter() ? "No project has an epic yet." : "No epic matches the filters."
            rows = [PageRow(loading ? "loading" : "empty", loading, supported, f, shown) {
                loading ? LoadingNote("Loading the epics") : EmptyNote(text, symbol: "target")
            }]
        }
        return [PageSection("top", rows: top), PageSection("epics", rows: [PageRow.list("table", rows: rows) { StickyListCard.table(nil) }])]
    }

    private func line(_ r: EpicBoard.Row) -> PageRow {
        let e = r.epic
        let id = r.project + "/" + e.id.rawValue
        let noun = vendor(r.project)
        return PageRow("epic." + id, hash: PageRow.hash([r, noun])) { [weak self] in
            let late = r.rollup.lateDays != nil
            let sub = [r.projectTitle, noun, e.lead.map { "lead \($0)" }]
            let title = NSTextField.text(e.title, size: 13, weight: .semibold)
            let line = NSTextField.text(sub.compactMap { $0 }.joined(separator: " · "), size: 11.5, color: Palette.dim)
            let name = NSStackView(v: [title, line], spacing: 2)
            name.setContentHuggingPriority(.init(1), for: .horizontal)
            name.setContentCompressionResistancePriority(.init(200), for: .horizontal)

            let bar = EpicBar(done: r.rollup.done, started: r.rollup.started, total: r.rollup.total)
            let progress = NSStackView(v: [bar, NSTextField.text(r.progressText, size: 11.5, color: Palette.mut)], spacing: 4, align: .leading)
            bar.widthAnchor.constraint(equalTo: progress.widthAnchor).isActive = true

            let due = NSTextField.text(r.dueText, size: 11.5, weight: late ? .semibold : .regular, color: late ? Palette.bad : Palette.mut)
            let tone = r.needsInput > 0 ? Palette.warn : r.working > 0 ? Palette.run : Palette.dim
            let status = NSStackView(v: [due, NSTextField.text(r.sessionText, size: 11.5, color: tone)], spacing: 4)

            let who: NSView = e.lead.map { Avatar($0) } ?? Spacer(22)
            var cells: [NSView] = [EpicGlyph(e.state, late: late), name, progress.fixedWidth(210), status.fixedWidth(128), who, self?.button(r) ?? Spacer(96)]
            if e.lead != nil { cells[4] = cells[4].fixedWidth(22) }
            let label = [e.title, r.project, EpicColor.word(e.state), r.progressText, r.dueText.replacingOccurrences(of: "▲ ", with: ""),
                         r.sessionText.replacingOccurrences(of: "▲ ", with: "").replacingOccurrences(of: "● ", with: "")].joined(separator: ", ")
            return Row(cells, height: 58, inset: 14, label: label) { self?.go(.epic(r.project, e.id.rawValue, .overview)) }
        }
    }

    // The button of a row: Open, Close epic or Start next.
    private func button(_ r: EpicBoard.Row) -> NSView {
        let args: [String: JSONValue] = ["project": .string(r.project), "epic": .string(r.epic.id.rawValue)]
        let b: ActionButton
        switch r.action {
        case .open:
            b = ActionButton("Open") { [weak self] in self?.go(.epic(r.project, r.epic.id.rawValue, .overview)) }
        case .close:
            b = ActionButton("Close epic", action: "epic.close", args, confirm: "Close \(r.epic.title)?")
        case .startNext(let key):
            b = ActionButton("Start next")
            b.toolTip = "Start \(key)"
            b.onClick = { [weak self, weak b] in
                guard let self, let b, let (_, snap, item) = self.data.projectStore.item(key: key) else { return }
                SessionStartMenu(self.data).start(item, snap: snap, at: b)
            }
        }
        b.setAccessibilityLabel("\(b.title), \(r.epic.title)")
        return b.fixedWidth(96)
    }
}
