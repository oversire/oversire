import Cocoa
import OverSireCore
import OverSireAI

// ─── Groom start sheet ───────────────────────────────────────────────────────
// The scope, the label, the stale check and an estimate. Start Groom starts the session (OVERSIRE-340).

final class GroomSheet {
    /// The open sheet. It holds the sheet while the window shows.
    private(set) static var open: GroomSheet?
    static var windowNumber: Int? { open?.window.windowNumber }

    private let agent: GroomAgent
    private let pk: String
    private let identifier: String
    private let labels: [String]
    private var options: GroomAgent.Options
    private let window: NSWindow
    private var keep: [ClosureTarget] = []

    init(agent: GroomAgent, projectKey pk: String, identifier: String, labels: [String], options: GroomAgent.Options = .init()) {
        self.agent = agent
        self.pk = pk
        self.identifier = identifier
        self.labels = labels
        self.options = options
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 300), styleMask: [.titled, .docModalWindow], backing: .buffered, defer: false)
        window.title = "Groom \(identifier)"
        build()
    }

    /// The card of the sheet, also for `--uishots`.
    private(set) var card: Card!

    func present(over parent: NSWindow) {
        Self.open = self
        parent.beginSheet(window)
    }

    func close() {
        window.sheetParent?.endSheet(window)
        if Self.open === self { Self.open = nil }
    }

    private func build() {
        keep = []
        let c = Card(title: nil, padding: 20, spacing: 14, fill: Palette.raise, border: .clear)
        c.add(NSStackView(h: [Glyph(Tone.groom.symbol, color: Palette.intake, size: 14), NSTextField.text("Groom \(identifier)", size: 15, weight: .semibold)],
                          spacing: 8))
        c.add(NSTextField.text("An agent reads the items in the scope and the code of the project. It asks you what the code cannot tell. "
                               + "Nothing goes to Plane before you click Apply.", size: 12.5, color: Palette.mut, lines: 3))
        let all = agent.plan(pk, GroomAgent.Options(scope: .all, stale: options.stale, staleDays: options.staleDays, label: options.label))
        let plan = agent.plan(pk, options)
        let intakeN = all?.intake.count ?? 0, backlogN = all?.backlog.count ?? 0

        let intake = radio("Intake only", note: "\(intakeN) item\(intakeN == 1 ? "" : "s")", on: options.scope == .intake) { [weak self] in self?.set { $0.scope = .intake } }
        let both = radio("Intake and backlog", note: "\(intakeN) intake + \(backlogN) backlog · finds a new note that repeats an old item",
                         on: options.scope == .all) { [weak self] in self?.set { $0.scope = .all } }
        c.add(field("Scope", NSStackView(v: [intake, both], spacing: 6)))

        if !labels.isEmpty {
            let pop = NSPopUpButton(frame: .zero, pullsDown: false)
            pop.addItem(withTitle: "All backlog items")
            for l in labels { pop.addItem(withTitle: l) }
            if let l = options.label, let i = labels.firstIndex(of: l) { pop.selectItem(at: i + 1) }
            pop.isEnabled = options.scope == .all
            pop.setAccessibilityLabel("Backlog label")
            let t = ClosureTarget { [weak self, weak pop] in
                guard let pop else { return }
                let i = pop.indexOfSelectedItem
                self?.set { $0.label = i > 0 ? self?.labels[i - 1] : nil }
            }
            keep.append(t)
            pop.target = t
            pop.action = #selector(ClosureTarget.fire)
            c.add(field("Label", NSStackView(v: [pop, NSTextField.text("Only the backlog items with this label. The intake has all items.", size: 11.5, color: Palette.dim)],
                                             spacing: 4)))
        }

        let check = NSButton(checkboxWithTitle: "Check items older than", target: nil, action: nil)
        check.state = options.stale ? .on : .off
        let ct = ClosureTarget { [weak self, weak check] in self?.set { $0.stale = check?.state == .on } }
        keep.append(ct)
        check.target = ct
        check.action = #selector(ClosureTarget.fire)
        let days = [7, 14, 30]
        let seg = NSSegmentedControl(labels: days.map { "\($0) d" }, trackingMode: .selectOne, target: nil, action: nil)
        seg.selectedSegment = days.firstIndex(of: options.staleDays) ?? 1
        seg.controlSize = .small
        seg.isEnabled = options.stale
        seg.setAccessibilityLabel("Stale after")
        let st = ClosureTarget { [weak self, weak seg] in
            guard let i = seg?.selectedSegment, days.indices.contains(i) else { return }
            self?.set { $0.staleDays = days[i] }
        }
        keep.append(st)
        seg.target = st
        seg.action = #selector(ClosureTarget.fire)
        c.add(field("Stale check", NSStackView(v: [NSStackView(h: [check, seg], spacing: 8),
                                                   NSTextField.text("Reads git log, the PRs that name the key, and the code that the item names.", size: 11.5, color: Palette.dim, lines: 2)],
                                               spacing: 4)))
        c.add(field("Runs on", NSStackView(h: [Chiplet("\(agent.place) · main checkout · read-only"), Spacer()], spacing: 6)))

        if let plan {
            let m = plan.minutes
            let est = Card(title: nil, padding: 9, spacing: 4, fill: Palette.panel)
            let parts = [("Items", "\(plan.count)"), ("Stale check", options.stale ? "\(plan.stale)" : "off"), ("Skipped", "\(plan.skipped.count)"),
                         ("Time", "about \(m.lowerBound)–\(m.upperBound) min")]
            est.add(NSStackView(h: parts.map { p in
                NSStackView(h: [NSTextField.text(p.0, size: 12, color: Palette.mut), NSTextField.text(p.1, size: 12, weight: .semibold)], spacing: 4)
            } + [Spacer()], spacing: 16))
            est.setAccessibilityElement(true)
            est.setAccessibilityLabel(parts.map { "\($0.0) \($0.1)" }.joined(separator: ", "))
            c.add(est)
            if plan.tooMany {
                c.add(NSTextField.text(GroomInput.TooMany(count: plan.count).description, size: 12, color: Palette.bad, lines: 2))
            } else if plan.count == 0 {
                c.add(NSTextField.text("No open item is in the scope.", size: 12, color: Palette.bad))
            }
        }
        let cancel = ActionButton("Cancel", style: .ghost, key: "\u{1b}") { [weak self] in self?.close() }
        let start = ActionButton("Start Groom", style: .primary, key: "\r") { [weak self] in
            guard let self else { return }
            self.close()
            self.agent.start(projectKey: self.pk, options: self.options)
        }
        start.isEnabled = plan.map { !$0.tooMany && $0.count > 0 } ?? false
        c.add(NSStackView(h: [Spacer(), cancel, start], spacing: 8))
        c.widthAnchor.constraint(equalToConstant: 560).isActive = true
        card = c
        window.contentView = c
        window.recalculateKeyViewLoop()
    }

    private func set(_ change: (inout GroomAgent.Options) -> Void) {
        change(&options)
        build()
    }

    private func radio(_ title: String, note: String, on: Bool, _ pick: @escaping () -> Void) -> NSView {
        let t = ClosureTarget(pick)
        keep.append(t)
        let b = NSButton(radioButtonWithTitle: title, target: t, action: #selector(ClosureTarget.fire))
        b.state = on ? .on : .off
        b.setAccessibilityLabel("\(title), \(note)")
        let n = NSTextField.text(note, size: 11.5, color: Palette.dim, lines: 2)
        let v = NSStackView(v: [b, n], spacing: 1)
        v.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        n.leadingAnchor.constraint(equalTo: b.leadingAnchor, constant: 20).isActive = true
        return v
    }

    private func field(_ title: String, _ content: NSView) -> NSView {
        let l = NSTextField.text(title, size: 12.5, color: Palette.dim)
        l.widthAnchor.constraint(equalToConstant: 110).isActive = true
        return NSStackView(h: [l, content, Spacer()], spacing: 10, align: .top)
    }
}
