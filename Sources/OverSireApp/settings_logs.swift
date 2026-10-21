import Cocoa
import OverSireCore

// Settings › Logs: what OverSire did in the background, and the problems at the top.

/// The rows that the filter and the search let through. Pure, for the tests.
struct LogListModel {
    enum Filter: String, CaseIterable {
        case all = "All", ai = "AI", sessions = "Sessions", sync = "Sync", runner = "Runner", problems = "Problems only"
    }

    var filter: Filter = .all
    var text = ""

    func rows(_ entries: [LogEntry]) -> [LogEntry] {
        let q = text.trimmingCharacters(in: .whitespaces).lowercased()
        return entries.filter { e in
            switch filter {
            case .all: break
            case .ai: guard e.area == .ai else { return false }
            case .sessions: guard e.area == .sessions else { return false }
            case .sync: guard e.area == .sync else { return false }
            case .runner: guard e.area == .runner else { return false }
            case .problems: guard e.level != .ok else { return false }
            }
            guard !q.isEmpty else { return true }
            return [e.job, e.subject, e.host, e.message, e.output].compactMap { $0?.lowercased() }.contains { $0.contains(q) }
        }
    }

    static func area(_ a: LogArea) -> String {
        switch a {
        case .ai: return "AI"
        case .sessions: return "Sessions"
        case .sync: return "Sync"
        case .runner: return "Runner"
        case .ui: return "UI"
        default: return a.rawValue.capitalized
        }
    }

    static func took(_ ms: Int?) -> String {
        guard let ms else { return "—" }
        return ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
    }

    /// The fields of the open row, in order. Empty fields stay out.
    static func details(_ e: LogEntry) -> [(String, String)] {
        let all: [(String, String?)] = [
            ("Engine", e.engine), ("Model", e.model), ("Host", e.host == e.engine ? nil : e.host), ("Why", e.reason),
            ("Tokens", e.tokensIn.map { i in "\(i) in" + (e.tokensOut.map { " · \($0) out" } ?? "") }), ("Stop", e.stop),
            ("Exit", e.exit.map(String.init)), ("Time", Self.stamp.string(from: e.at)),
        ]
        return all.compactMap { k, v in v.flatMap { $0.isEmpty ? nil : (k, $0) } }
    }

    static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}

/// A shape and a word for each level. Color is not the only signal.
extension LogLevel {
    var glyph: (text: String, color: NSColor, name: String) {
        switch self {
        case .ok: return ("✓", Palette.ok, "OK")
        case .warn: return ("▲", Palette.warn, "Warning")
        case .error: return ("✕", Palette.bad, "Error")
        }
    }
}

// The filter chips, the search and the rows. It renders again on each new line, with no page reload.
final class LogListView: NSStackView, NSSearchFieldDelegate {
    static var model = LogListModel()
    static var open: LogEntry?
    static let shown = 300

    private let logs: LogStore?
    private let search = NSSearchField()
    private let chips = NSStackView(h: [], spacing: 6)
    private let list = ListCard()
    private var observer: Any?

    init(logs: LogStore?) {
        self.logs = logs
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 8
        translatesAutoresizingMaskIntoConstraints = false
        search.placeholderString = "Item, session or text"
        search.stringValue = Self.model.text
        search.setAccessibilityLabel("Search the log")
        search.delegate = self
        search.widthAnchor.constraint(equalToConstant: 200).isActive = true
        addFull(NSStackView(h: [chips, Spacer(), search], spacing: 10))
        addFull(list)
        observer = NotificationCenter.default.addObserver(forName: LogStore.changed, object: logs, queue: .main) { [weak self] _ in self?.render() }
        render()
    }
    required init(coder: NSCoder) { fatalError() }
    deinit { observer.map(NotificationCenter.default.removeObserver) }

    func controlTextDidChange(_ obj: Notification) {
        Self.model.text = search.stringValue
        render()
    }

    private func render() {
        chips.clear()
        for f in LogListModel.Filter.allCases {
            let c = ToggleChip(f.rawValue, on: f == Self.model.filter) { [weak self] in
                Self.model.filter = f
                self?.render()
            }
            c.setAccessibilityRole(.radioButton)
            chips.addArrangedSubview(c)
        }
        list.list.clear()
        let head = Row(["TIME", "", "AREA", "JOB", "SUBJECT", "RESULT", "TOOK"].map { NSTextField.text($0, size: 11, weight: .semibold, color: Palette.dim) }, height: 28)
        Self.columns(head)
        head.setAccessibilityElement(false)
        list.add(head)
        let rows = Self.model.rows(logs?.entries ?? [])
        if rows.isEmpty {
            list.add(Padded(EmptyNote(logs?.entries.isEmpty ?? true ? "No log lines yet." : "No line matches.", symbol: "doc.text.magnifyingglass")))
            return
        }
        for e in rows.prefix(Self.shown) {
            let open = e == Self.open
            list.add(row(e, open: open))
            if open { list.add(details(e)) }
        }
        if rows.count > Self.shown {
            list.add(Padded(NSTextField.text("\(rows.count - Self.shown) older lines. Search to find them, or open the folder.", size: 11.5, color: Palette.dim), vertical: 8))
        }
    }

    private func row(_ e: LogEntry, open: Bool) -> Row {
        let lv = e.level.glyph
        let result = NSTextField.text(e.message, size: 12, color: e.level == .ok ? Palette.fg : lv.color)
        result.lineBreakMode = .byTruncatingTail
        result.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let r = Row([NSTextField.text(LogListModel.clock.string(from: e.at), size: 11.5, color: Palette.dim, mono: true),
                     NSTextField.text(lv.text, size: 12, weight: .bold, color: lv.color),
                     NSTextField.text(LogListModel.area(e.area), size: 12, color: Palette.mut),
                     NSTextField.text(e.job, size: 12, weight: .medium),
                     NSTextField.text(e.subject ?? "—", size: 11.5, color: Palette.mut, mono: true),
                     result,
                     NSTextField.text(LogListModel.took(e.ms), size: 11.5, color: Palette.dim, mono: true)],
                    height: 34, label: "\(lv.name), \(LogListModel.area(e.area)), \(e.job), \(e.subject ?? ""), \(e.message)") { [weak self] in
            Self.open = open ? nil : e
            self?.render()
        }
        Self.columns(r)
        r.selected = open
        r.setAccessibilityExpanded(open)
        r.copyID = Self.text(e)
        return r
    }

    private func details(_ e: LogEntry) -> NSView {
        let v = NSStackView(v: [], spacing: 4)
        for (k, val) in LogListModel.details(e) {
            v.addArrangedSubview(NSStackView(h: [NSTextField.text(k, size: 11.5, color: Palette.dim).fixedWidth(80),
                                                 NSTextField.text(val, size: 11.5, color: Palette.mut, lines: 2)], spacing: 8))
        }
        for (title, text) in [("Input", e.input), ("Output", e.output), ("Command output (last lines)", e.outputTail)] {
            guard let text, !text.isEmpty else { continue }
            v.addArrangedSubview(NSTextField.text(title, size: 11, weight: .semibold, color: Palette.dim))
            let box = Box(fill: Palette.term, border: nil, radius: 6)
            let t = NSTextField.text(String(text.prefix(1500)), size: 11, color: Palette.termFg, lines: 12, mono: true)
            t.isSelectable = true
            box.addSubview(t)
            t.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                t.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 10), t.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -10),
                t.topAnchor.constraint(equalTo: box.topAnchor, constant: 8), t.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -8),
            ])
            v.addFull(box)
        }
        return Padded(v, vertical: 10, side: 24)
    }

    private static func columns(_ r: Row) {
        for (v, w) in zip(r.stack.arrangedSubviews, [62, 14, 66, 96, 112, -1, 54] as [CGFloat]) {
            if w > 0 { v.widthAnchor.constraint(equalToConstant: w).isActive = true } else { v.setContentHuggingPriority(.init(1), for: .horizontal) }
        }
    }

    /// One line of plain text for Copy.
    static func text(_ e: LogEntry) -> String {
        [LogListModel.stamp.string(from: e.at), e.level.glyph.name, LogListModel.area(e.area), e.job, e.subject ?? "-", e.host ?? "-",
         e.message, LogListModel.took(e.ms)].joined(separator: "\t")
    }
}

extension SettingsPage {
    func logs(_ b: NSStackView) {
        let logs = data.logs
        let actions = NSStackView(h: [
            ActionButton("Copy", symbol: "doc.on.doc") {
                let text = LogListView.model.rows(logs?.entries ?? []).map(LogListView.text).joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            },
            ActionButton("Show in Finder", symbol: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: LOGS_DIR)) },
            ActionButton("Clear", style: .danger) { [weak self] in
                logs?.clear()
                self?.reload()
            },
        ], spacing: 8)
        b.addFull(NSStackView(h: [NSTextField.text("What OverSire did in the background: AI jobs, session reads, sync and the runner. The logs stay on this Mac.",
                                                   size: 12, color: Palette.dim, lines: 2), Spacer(), actions], spacing: 12))

        let open = logs?.problems.open ?? []
        let problemRows: [NSView] = open.isEmpty
            ? [Padded(EmptyNote("No problems. Each problem clears when the same job works again.", symbol: "checkmark.circle"))]
            : open.map { problemRow($0, tracker: logs?.problems) }
        b.addFull(section(.problems, problemRows))

        let list = LogListView(logs: logs)
        let v = NSStackView(v: [SectionTitle(SettingsAnchor.log.title)], spacing: 6)
        v.addFull(list)
        v.identifier = SettingsAnchor.log.id
        b.addFull(v)

        let days = [1, 3, 7, 14, 30]
        let size = ByteCountFormatter.string(fromByteCount: Int64(logs?.bytes ?? 0), countStyle: .file)
        b.addFull(section(.logSettings, [
            FieldRow("Keep logs for", note: "Now \(size) in \((LOGS_DIR as NSString).abbreviatingWithTildeInPath)",
                     PopUp(days.map { "\($0) day\($0 == 1 ? "" : "s")" }, selected: days.firstIndex(of: LOGS_CFG.keepDays) ?? 2, label: "Keep logs for") { i in
                         LOGS_CFG.keepDays = days[i]
                         settingsChanged()
                         logs?.prune()
                     }),
            SwitchRow("Keep AI input and output", note: "Turn off to keep only the job, the time, the tokens and the result.", on: LOGS_CFG.keepAIText) {
                LOGS_CFG.keepAIText = $0
                settingsChanged()
            },
            FieldRow("Detail", note: "Debug also logs each poll and each history read.",
                     PopUp(["Normal", "Debug"], selected: LOGS_CFG.debug ? 1 : 0, label: "Detail") { i in
                         LOGS_CFG.debug = i == 1
                         settingsChanged()
                     }),
            SwitchRow("Problem mark in the menu bar", note: "A small ▲ on the status light while a problem is open.", on: LOGS_CFG.menuMark) { [weak self] in
                LOGS_CFG.menuMark = $0
                settingsChanged()
                self?.app?.updateIcon()
            },
        ]))
    }

    private func problemRow(_ p: Problem, tracker: ProblemTracker?) -> NSView {
        let when = p.count == 1 ? "Once at \(LogListModel.clock.string(from: p.last))"
            : "\(p.count) times since \(LogListModel.clock.string(from: p.first)) · last \(LogListModel.clock.string(from: p.last))"
        let place = ["\(LogListModel.area(p.area)) › \(p.job)", p.host, p.subject].compactMap { $0 }.joined(separator: " · ")
        let text = NSStackView(v: [
            NSTextField.text(p.job + (p.host.map { " · \($0)" } ?? "") + ": " + p.message, size: 13, weight: .medium, lines: 2),
            NSTextField.text(when + " · " + place, size: 11.5, color: Palette.dim, lines: 1),
        ], spacing: 3)
        var cells: [NSView] = [NSTextField.text("▲", size: 13, color: Palette.warn), text, Spacer()]
        if let fix = Self.fix(p) {
            cells.append(ActionButton(fix.title) { [weak self] in self?.go(fix.route) })
        }
        let dismiss = ActionButton("Dismiss") { [weak self] in
            tracker?.dismiss(p.key)
            self?.reload()
        }
        dismiss.setAccessibilityLabel("Dismiss \(p.job)")
        cells.append(dismiss)
        return Row(cells, height: 58, label: "Problem: \(p.job), \(p.message)")
    }

    // The page that fixes the cause, when there is one.
    static func fix(_ p: Problem) -> (title: String, route: Route)? {
        switch (p.area, p.host) {
        case (.ai, "local-cli"?): return ("Open AI settings", SettingsAnchor.localCLI.route)
        case (.ai, _): return ("Open AI settings", SettingsAnchor.apiKey.route)
        case (.sync, _), (.runner, _): return ("Open accounts", SettingsAnchor.services.route)
        case (.sessions, _): return ("Open agent settings", Route.settings(.agents))
        default: return nil
        }
    }
}
