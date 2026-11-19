import Cocoa
import OverSireCore

/// The Summary segment of the Plan tab: the north star, the Now cards, the epics to close, the Next list,
/// "Since you were away" and "Up next". Each state has a glyph or a word, so color is never the only signal.
final class PlanSummaryView: NSStackView {
    private let model: PlanModel
    private let controls: PlanControls
    private weak var host: PlanHost?

    init(_ model: PlanModel, controls: PlanControls, host: PlanHost) {
        self.model = model
        self.controls = controls
        self.host = host
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 14
        translatesAutoresizingMaskIntoConstraints = false

        addFull(northStar())
        let left = NSStackView(v: [], spacing: 12)
        left.setHuggingPriority(.init(1), for: .horizontal)
        let aside = NSStackView(v: [], spacing: 14)
        aside.widthAnchor.constraint(equalToConstant: 340).isActive = true
        let columns = NSStackView(h: [left, aside], spacing: 16, align: .top)
        columns.distribution = .fill
        addFull(columns)
        nowColumn(left)
        if let away = model.away, let since = model.since { aside.addFull(awayCard(away, since: since)) }
        aside.addFull(upNextCard())
    }
    required init?(coder: NSCoder) { fatalError() }

    private var summary: PlanSummary { model.summary }
    private var ident: String { model.ident }

    // MARK: North star

    private func northStar() -> NSView {
        let box = Box(fill: Palette.panel, border: Palette.line, radius: 10)
        let star = Glyph("star", color: PlanColor.critical, size: 24)
        let cap = NSTextField.text("", size: 11, weight: .semibold, color: Palette.dim)
        cap.attributedStringValue = NSAttributedString(string: "NORTH STAR", attributes: [
            .kern: 0.5, .font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: Palette.dim])
        let col = NSStackView(v: [cap], spacing: 4)
        col.setHuggingPriority(.init(1), for: .horizontal)
        var right: [NSView] = []
        if let end = endOfWork { right.append(NSTextField.text(end, size: 12, color: Palette.mut)) }
        if controls.editingNorthStar {
            col.addFull(editor())
        } else {
            if let v = model.vision {
                col.addFull(NSTextField.text(v, size: 15.5, weight: .semibold, lines: 4))
            } else {
                col.addFull(NSTextField.text("No north star yet. Write one short goal for \(model.snap.summary.title). Triage and the queue order read it.",
                                             size: 13.5, color: Palette.mut, lines: 2))
            }
            col.addFull(NSTextField.text(focusText, size: 12.5, color: Palette.mut, lines: 2))
            let edit = ActionButton(model.vision == nil ? "Add" : "Edit") { [weak self] in
                guard let self else { return }
                self.controls.editingNorthStar = true
                self.host?.planChanged()
            }
            edit.setAccessibilityLabel(model.vision == nil ? "Add the north star" : "Edit the north star")
            right.append(edit)
        }
        let side = NSStackView(v: right, spacing: 6, align: .trailing)
        let row = NSStackView(h: [star, col, side], spacing: 16)
        row.distribution = .fill
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -18),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -14),
        ])
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel("North star: " + (model.vision ?? "none") + ". " + focusText)
        return box
    }

    private var endOfWork: String? {
        summary.end > 0 ? "Forecast end of open work: " + model.date(summary.end - 1) : nil
    }

    private var focusText: String {
        var s = "Focus now: " + (summary.focusEpic.map(model.name) ?? "nothing active")
        if let q = summary.focusQuestion { s += ". First answer the question on " + PlanModel.inline(model.title(q)) }
        return s + "."
    }

    private func editor() -> NSView {
        let c = controls
        let input = LimitedInput(c.northStarDraft ?? model.vision ?? "", placeholder: "What this project is for, and what is out of scope.",
                                 label: "North star", lines: 3)
        let counter = NSTextField.text("", size: 11.5, color: Palette.dim)
        let save = ActionButton("Save", style: .primary) { [weak self] in self?.saveNorthStar() }
        let cancel = ActionButton("Cancel") { [weak self] in self?.closeEditor() }
        let update = { (t: String) in
            let n = t.trimmingCharacters(in: .whitespacesAndNewlines).count
            let over = n > MemoryDraft.maxText
            counter.stringValue = over ? "⚠ \(n) / \(MemoryDraft.maxText) · \(n - MemoryDraft.maxText) over the limit" : "\(n) / \(MemoryDraft.maxText)"
            counter.textColor = over ? Palette.bad : Palette.dim
            save.isEnabled = n > 0 && !over
            c.northStarDraft = t
        }
        input.onChange = update
        input.onSave = { [weak self] in self?.saveNorthStar() }
        input.onRevert = { [weak self] in self?.closeEditor() }
        update(input.stringValue)
        DispatchQueue.main.async { [weak input] in input?.window?.makeFirstResponder(input) }
        let col = NSStackView(v: [], spacing: 6)
        col.addFull(input)
        col.addFull(NSStackView(h: [counter, NSTextField.text("⌘S saves. Esc cancels.", size: 11.5, color: Palette.dim), Spacer(), cancel, save], spacing: 8))
        return col
    }

    private func saveNorthStar() {
        guard let host, let text = controls.northStarDraft ?? model.vision else { return }
        host.data.actions.click("project.setNorthStar", ["project": .string(ident), "text": .string(text)], in: window) { [weak self] r in
            guard let self else { return }
            if case .ok = r { self.closeEditor() }
        }
    }

    private func closeEditor() {
        controls.editingNorthStar = false
        controls.northStarDraft = nil
        window?.makeFirstResponder(nil)
        host?.planChanged()
    }

    // MARK: Now, ready to close and Next

    private func nowColumn(_ col: NSStackView) {
        let n = summary.now.count
        col.addFull(heading("Now", n == 0 ? "No active epic with open items" : "\(n) active epic\(n == 1 ? "" : "s") · late ones first"))
        for card in summary.now { col.addFull(nowCard(card)) }
        for id in summary.readyToClose { col.addFull(readyCard(id)) }
        guard !summary.next.isEmpty else { return }
        if let last = col.arrangedSubviews.last { col.setCustomSpacing(16, after: last) }
        col.addFull(heading("Next", "planned, in order"))
        let box = Box(fill: Palette.panel, border: Palette.line, radius: 10)
        let list = NSStackView(v: [], spacing: 0)
        for (i, e) in summary.next.enumerated() {
            if i > 0 { list.addFull(Self.line()) }
            list.addFull(nextRow(e))
        }
        box.addSubview(list)
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            list.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            list.topAnchor.constraint(equalTo: box.topAnchor, constant: 2),
            list.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -2),
        ])
        col.addFull(box)
    }

    private func heading(_ title: String, _ note: String) -> NSView {
        NSStackView(h: [NSTextField.text(title, size: 13, weight: .bold), NSTextField.text(note, size: 12, color: Palette.dim), Spacer()],
                    spacing: 8, align: .firstBaseline)
    }

    /// "▲ 3d late · due Nov 16", "On time · due Dec 11" or "No target date".
    private func dueText(_ id: EpicID, _ f: EpicForecast) -> (String, NSColor) {
        let due = model.epic(id)?.targetDate.map { "due " + EpicBoard.day($0) }
        if let late = f.lateBy, late > 0 { return ("▲ \(late)d late" + (due.map { " · " + $0 } ?? ""), Palette.bad) }
        return (due.map { "On time · " + $0 } ?? "No target date", Palette.dim)
    }

    private func nowCard(_ card: PlanSummary.NowCard) -> NSView {
        let id = card.epic, name = model.name(id)
        let r = model.rollup(id)
        let (due, dueColor) = dueText(id, card.forecast)
        let c = Card(padding: 15, spacing: 10)
        let bar = EpicBar(done: r?.done ?? 0, started: r?.started ?? 0, total: r?.total ?? 0)
        bar.widthAnchor.constraint(equalToConstant: 120).isActive = true
        let progress = "\(r?.done ?? 0) of \(r?.total ?? 0) done"
        let title = NSTextField.text(name, size: 15, weight: .bold)
        title.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        c.add(NSStackView(h: [EpicGlyph(.active, late: card.forecast.isLate, size: 18), title,
                              NSTextField.text(due, size: 12, color: dueColor), Spacer(),
                              NSTextField.text(progress, size: 12.5, color: Palette.mut), bar], spacing: 10))
        let status = [model.status(id), model.endText(card.forecast.end).map { "Forecast end: \($0)." }].compactMap { $0 }.joined(separator: " ")
        if !status.isEmpty { c.add(NSTextField.text(status, size: 13, color: Palette.fg, lines: 3)) }
        let steps = NSStackView(v: [], spacing: 2)
        for (i, key) in card.steps.enumerated() { steps.addFull(stepRow(i + 1, key)) }
        c.add(steps)

        var foot: [NSView] = []
        if let k = card.startKey, let item = model.snap.items.first(where: { $0.key.uppercased() == k }) {
            let start = ActionButton("Start \(model.short(k)) \(model.title(k))", style: .primary)
            start.truncates()
            start.onClick = { [weak self, weak start] in
                guard let self, let start, let host = self.host else { return }
                SessionStartMenu(host.data).start(item, snap: self.model.snap, at: start)
            }
            start.setAccessibilityLabel("Start \(k) \(model.title(k))")
            foot.append(start)
        }
        foot.append(link("Show on map ›", color: Palette.acc) { [weak self] in self?.host?.show(plan: .map, focus: nil, epic: id) })
        foot.append(link("Show on timeline ›", color: Palette.acc) { [weak self] in self?.host?.show(plan: .timeline, focus: nil, epic: id) })
        foot.append(Spacer())
        if card.more > 0 { foot.append(NSTextField.text("+\(card.more) more step\(card.more == 1 ? "" : "s")", size: 12, color: Palette.dim)) }
        c.add(NSStackView(h: foot, spacing: 10))

        let late = card.forecast.lateBy.flatMap { $0 > 0 ? "\($0) day\($0 == 1 ? "" : "s") late" : nil } ?? "on time"
        c.setAccessibilityElement(true)
        c.setAccessibilityRole(.group)
        c.setAccessibilityLabel("\(name), \(late), \(progress)")
        return c
    }

    private func stepRow(_ n: Int, _ key: String) -> NSView {
        let num = NSTextField.text("\(n)", size: 11.5, color: Palette.dim)
        num.alignment = .center
        num.widthAnchor.constraint(equalToConstant: 16).isActive = true
        let chip = Chiplet(key, mono: true)
        chip.onClick = { [weak chip] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(key, forType: .string)
            chip?.flash("Copied ✓")
        }
        chip.setAccessibilityRole(.button)
        chip.setAccessibilityLabel("Copy \(key)")
        chip.toolTip = "Copy \(key)"
        let text = model.stepText(key)
        let title = link(text, size: 13, color: Palette.fg) { [weak self] in self?.host?.show(plan: .map, focus: key, epic: nil) }
        title.setAccessibilityLabel("\(key) \(text). Show on the map")
        let (state, color) = model.state(key)
        let s = NSTextField.text(state, size: 12, color: color)
        s.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        let row = NSStackView(h: [num, chip, title, Spacer(), s], spacing: 10)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        return row
    }

    private func readyCard(_ id: EpicID) -> NSView {
        let name = model.name(id), total = model.rollup(id)?.total ?? 0
        let text = "All \(total) done. Ready to close."
        let close = ActionButton("Close epic") { [weak self] in self?.close(id) }
        close.setAccessibilityLabel("Close epic \(name)")
        let row = NSStackView(h: [EpicGlyph(.done, size: 18), NSTextField.text(name, size: 14, weight: .bold),
                                  NSTextField.text(text, size: 12.5, color: Palette.mut), Spacer(), close], spacing: 10)
        let box = Box(fill: Palette.panel, border: Palette.line, radius: 10)
        box.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 16),
            row.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -16),
            row.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            row.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
        ])
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
        box.setAccessibilityLabel("\(name), ready to close. \(text)")
        return box
    }

    private func close(_ id: EpicID) {
        guard let host else { return }
        host.data.actions.click("epic.close", ["project": .string(ident), "epic": .string(id.rawValue)], in: window, confirm: "Close \(model.name(id))?")
    }

    private func nextRow(_ e: PlanSummary.NextEpic) -> NSView {
        let id = e.epic, name = model.name(id)
        let epic = model.epic(id)
        let r = model.rollup(id)
        let glyph = EpicGlyph(epic?.state ?? .planned, late: e.forecast.isLate, size: 16)
        let title = link(name, size: 13.5, weight: .semibold, color: Palette.fg) { [weak self] in self?.host?.show(plan: .map, focus: nil, epic: id) }
        title.widthAnchor.constraint(equalToConstant: 130).isActive = true
        let why = NSTextField.text(model.status(id) ?? "", size: 12.5, color: Palette.mut)
        why.setContentHuggingPriority(.init(1), for: .horizontal)
        let prog = NSTextField.text("\(r?.done ?? 0) of \(r?.total ?? 0)", size: 12, color: Palette.mut)
        prog.widthAnchor.constraint(equalToConstant: 56).isActive = true
        var forecast = "No items", color = Palette.mut
        if let end = model.endText(e.forecast.end) {
            forecast = "Ends " + end
            if let late = e.forecast.lateBy, late > 0 { forecast += " · ▲ \(late)d late"; color = Palette.bad }
        }
        let f = NSTextField.text(forecast, size: 12, color: color)
        f.alignment = .right
        f.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(h: [glyph, title, why, prog, f], spacing: 10)
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("\(name), \(EpicColor.word(epic?.state ?? .planned)). \(r?.done ?? 0) of \(r?.total ?? 0) done. \(forecast.replacingOccurrences(of: "▲ ", with: ""))")
        return row
    }

    // MARK: Aside

    private func awayCard(_ away: PlanAway, since: Date) -> NSView {
        let c = Card(padding: 15, spacing: 10)
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: since), to: cal.startOfDay(for: model.today)).day ?? 0
        let ago = days <= 0 ? "today" : "\(days) day\(days == 1 ? "" : "s")"
        c.add(NSStackView(h: [NSTextField.text("Since you were away", size: 13, weight: .bold), Spacer(), NSTextField.text(ago, size: 12, color: Palette.dim)], spacing: 8))
        func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : many }
        let late = away.late.map(model.name).joined(separator: ", ")
        let rows: [(NSView, Int, String, String?)] = [
            (Glyph("checkmark.circle.fill", color: Palette.ok, size: 14), away.done.count, plural(away.done.count, "item done", "items done"), nil),
            (EpicGlyph(.active, size: 14), away.readyToClose.count, plural(away.readyToClose.count, "epic ready to close", "epics ready to close"), nil),
            (symbol("▲"), away.late.count, plural(away.late.count, "epic late", "epics late"), late.isEmpty ? nil : late),
            (symbol("?"), away.questions.count, plural(away.questions.count, "question waits for you", "questions wait for you"), nil),
        ]
        let list = NSStackView(v: [], spacing: 7)
        for (glyph, n, noun, note) in rows {
            let t = NSTextField.text("", size: 13)
            let s = NSMutableAttributedString(string: "\(n)", attributes: [.font: NSFont.systemFont(ofSize: 13, weight: .bold), .foregroundColor: Palette.fg])
            s.append(NSAttributedString(string: " " + noun, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: Palette.fg]))
            t.attributedStringValue = s
            var views: [NSView] = [glyph, t, Spacer()]
            if let note { views.append(NSTextField.text(note, size: 12, color: Palette.dim)) }
            let row = NSStackView(h: views, spacing: 9)
            row.setAccessibilityElement(true)
            row.setAccessibilityRole(.staticText)
            row.setAccessibilityLabel("\(n) \(noun)" + (note.map { ": " + $0 } ?? ""))
            list.addFull(row)
        }
        c.add(list)
        c.add(NSTextField.text(away.sentence(name: model.name, title: model.title), size: 12.5, color: Palette.mut, lines: 4))
        c.setAccessibilityElement(true)
        c.setAccessibilityRole(.group)
        c.setAccessibilityLabel("Since you were away, \(ago)")
        return c
    }

    private func symbol(_ s: String) -> NSView {
        let t = NSTextField.text(s, size: 12, weight: .semibold, color: Palette.warn)
        t.alignment = .center
        t.widthAnchor.constraint(equalToConstant: 14).isActive = true
        return t
    }

    private func upNextCard() -> NSView {
        let c = Card(padding: 15, spacing: 6)
        c.add(NSStackView(h: [NSTextField.text("Up next, in order", size: 13, weight: .bold),
                              NSTextField.text("click to show on the map", size: 11.5, color: Palette.dim), Spacer()], spacing: 8, align: .firstBaseline))
        if summary.upNext.isEmpty { c.add(NSTextField.text("Nothing waits. Start an epic or add items.", size: 12.5, color: Palette.dim)) }
        for (i, next) in summary.upNext.enumerated() {
            let (title, sub, color, go) = upNext(next)
            let num = NSTextField.text("\(i + 1)", size: 12, color: Palette.dim)
            num.widthAnchor.constraint(equalToConstant: 16).isActive = true
            let t = link(title, size: 13, color: Palette.fg, action: go)
            t.setAccessibilityLabel("\(i + 1). \(title). \(sub.replacingOccurrences(of: "◆ ", with: ""))")
            let col = NSStackView(v: [t, NSTextField.text(sub, size: 11.5, color: color)], spacing: 2)
            col.setHuggingPriority(.init(1), for: .horizontal)
            let row = NSStackView(h: [num, col], spacing: 10, align: .top)
            row.edgeInsets = NSEdgeInsets(top: 7, left: 0, bottom: 7, right: 0)
            c.add(Self.line())
            c.add(row)
        }
        c.setAccessibilityElement(true)
        c.setAccessibilityRole(.group)
        c.setAccessibilityLabel("Up next, in order")
        return c
    }

    /// The title, the sub line, its color and the click of an Up next row.
    private func upNext(_ n: PlanSummary.Next) -> (String, String, NSColor, () -> Void) {
        let show: (String) -> () -> Void = { k in { [weak self] in self?.host?.show(plan: .map, focus: k, epic: nil) } }
        func epicName(_ k: String) -> String { model.graph.nodes[k]?.epic.map(model.name) ?? "" }
        switch n {
        case .answer(let k):
            let b = model.graph.dependents(of: k).count
            return ("Answer: " + model.title(k), "\(k) · \(epicName(k)) · blocks \(b)", Palette.warn, show(k))
        case .close(let id):
            let total = model.rollup(id)?.total ?? 0
            return ("Close epic: " + model.name(id), "All \(total) done. Ready to close.", Palette.dim, { [weak self] in self?.close(id) })
        case .start(let k, let critical, let slack):
            return ("Start: " + model.title(k), "\(k) · \(epicName(k)) · " + (critical ? "◆ critical path" : "slack \(slack)d"),
                    critical ? PlanColor.critical : Palette.dim, show(k))
        case .plan(let k):
            return ("Plan: " + model.title(k), "\(k) · \(epicName(k)) · no spec", Palette.dim, show(k))
        }
    }

    // MARK: Kit

    /// A text button with no border, in the given font and color.
    private func link(_ title: String, size: CGFloat = 12.5, weight: NSFont.Weight = .medium, color: NSColor,
                      action: @escaping () -> Void) -> ActionButton {
        let b = ActionButton(title, style: .link, action)
        b.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: color, .font: NSFont.systemFont(ofSize: size, weight: weight)])
        b.truncates()
        b.alignment = .left
        return b
    }

    private static func line() -> NSView {
        let l = Box(fill: Palette.line, border: nil, radius: 0)
        l.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return l
    }
}
