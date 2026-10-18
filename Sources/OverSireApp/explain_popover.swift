import Cocoa
import OverSireCore

// "Explain failure…" of a run or job row: the AI cause in a popover at the row.
final class ExplainPopover: NSViewController, NSPopoverDelegate {
    enum Phase: Equatable {
        case loading(String)
        case result(RunExplanation)
        case failed(String)
    }

    static let width: CGFloat = 380
    private static var current: ExplainPopover?
    static var windowNumber: Int? { current?.view.window?.windowNumber }
    static func dismiss() { current?.popover.close() }

    private let popover = NSPopover()
    private var caption: String
    private var run: Run?
    private var watch: NSObjectProtocol?
    private let openRun: () -> Void
    private var retry: (() -> Void)?
    private var phase: Phase
    private let stack = NSStackView(v: [], spacing: 10)

    private init(caption: String, phase: Phase, openRun: @escaping () -> Void) {
        self.caption = caption
        self.phase = phase
        self.openRun = openRun
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        view = stack
        render()
    }

    // Finds the failed job, loads its log and asks the engine. A cached cause shows at once.
    static func show(at anchor: NSView, repo: String, run known: Run?, runId: String, jobId: String?, cia: CIAssist, openRun: @escaping () -> Void) {
        let p = present(at: anchor, caption: "Run #\(known.map { "\($0.number)" } ?? runId)", phase: .loading("Loading the run"), openRun: openRun)
        let source = RunPage.source
        p.retry = { [weak p] in p?.start(repo: repo, known: known, runId: runId, jobId: jobId, cia: cia, source: source, force: true) }
        p.watch = NotificationCenter.default.addObserver(forName: CIAssist.changed, object: cia, queue: .main) { [weak p] _ in
            guard let p, let r = p.run else { return }
            p.follow(cia, r)
        }
        p.start(repo: repo, known: known, runId: runId, jobId: jobId, cia: cia, source: source, force: false)
    }

    // A fixed popover for `--uishots`.
    static func sample(at anchor: NSView, phase: Phase) {
        present(at: anchor, caption: "CI #128 · build (ubuntu-latest)", phase: phase, openRun: {})
    }

    @discardableResult
    private static func present(at anchor: NSView, caption: String, phase: Phase, openRun: @escaping () -> Void) -> ExplainPopover {
        current?.popover.close()
        let vc = ExplainPopover(caption: caption, phase: phase, openRun: openRun)
        vc.popover.behavior = .transient
        vc.popover.animates = false
        vc.popover.contentViewController = vc
        vc.popover.delegate = vc
        NSApp.withPinnedAppearance { vc.popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY) }
        current = vc
        return vc
    }

    func popoverDidClose(_ notification: Notification) {
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
        if Self.current === self { Self.current = nil }
    }

    private func start(repo: String, known: Run?, runId: String, jobId: String?, cia: CIAssist, source: any RunSource, force: Bool) {
        set(.loading("Loading the run"))
        Task { [weak self] in
            var r = known
            if r == nil { r = await source.run(repo, id: runId) }
            guard let r else { await MainActor.run { self?.set(.failed("Could not load the run.")) }; return }
            await MainActor.run { self?.run = r }
            if !force, let e = await MainActor.run(body: { cia.explanation(r) }) {
                await MainActor.run { self?.set(.result(e)) }
                return
            }
            let jobs = await source.jobs(repo, runId: runId) ?? []
            guard let job = jobs.first(where: { $0.id == jobId }) ?? jobs.first(where: JobChip.failed) else {
                await MainActor.run { self?.set(.failed("No failed job found in this run.")) }
                return
            }
            await MainActor.run {
                self?.caption = "\(r.workflowName ?? r.name) #\(r.number) · \(job.name)"
                self?.set(.loading("Loading the log of \(job.name)"))
                JobLogs.shared.lines(repo: repo, jobId: job.id) { [weak self] log in
                    guard let self else { return }
                    guard let log, !log.isEmpty else { self.set(.failed("The log of \(job.name) is not available.")); return }
                    self.set(.loading("The AI reads the log"))
                    cia.explain(repo: repo, run: r, job: job, log: log, force: force)
                    self.follow(cia, r)
                }
            }
        }
    }

    private func follow(_ cia: CIAssist, _ r: Run) {
        let k = CIAssist.runKey(r)
        if cia.busy.contains(k) { set(.loading("The AI reads the log")) }
        else if let err = cia.errors[k] { set(.failed("Could not explain: \(err)")) }
        else if let e = cia.explanation(r) { set(.result(e)) }
    }

    private func set(_ p: Phase) {
        guard p != phase else { return }
        phase = p
        guard isViewLoaded else { return }
        NSApp.withPinnedAppearance { render() }
    }

    private func render() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let inner = Self.width - 28
        var head: [NSView] = [Glyph("sparkles", color: Palette.acc, size: 14), NSTextField.text("Likely cause", size: 13, weight: .semibold), Spacer()]
        if case .result(let e) = phase { head.append(Chiplet("AI · \(e.confidence) confidence")) }
        stack.addArrangedSubview(NSStackView(h: head, spacing: 6))
        stack.addArrangedSubview(NSTextField.text(caption, size: 11.5, color: Palette.dim, mono: true))

        let copy = ActionButton("Copy", symbol: "doc.on.doc") { [weak self] in
            guard case .result(let e)? = self?.phase else { return }
            RowActions.copy(e.fix.isEmpty ? e.cause : "\(e.cause)\nTry: \(e.fix)")
        }
        copy.isEnabled = false
        var buttons: [NSView] = [Spacer()]
        switch phase {
        case .loading(let t):
            stack.addArrangedSubview(LoadingNote(t, compact: true))
        case .result(let e):
            stack.addArrangedSubview(wrapped(e.cause, size: 13, color: Palette.fg, width: inner))
            if !e.fix.isEmpty { stack.addArrangedSubview(wrapped("Try: " + e.fix, size: 12.5, color: Palette.mut, width: inner)) }
            copy.isEnabled = true
        case .failed(let t):
            stack.addArrangedSubview(NSStackView(h: [Glyph("exclamationmark.triangle", color: Palette.bad, size: 13, label: "Error"),
                                                     wrapped(t, size: 12.5, color: Palette.bad, width: inner - 20)], spacing: 6, align: .top))
            if let retry { buttons.append(ActionButton("Try again", symbol: "arrow.clockwise") { retry() }) }
        }
        buttons += [copy, ActionButton("Open run", symbol: "arrow.right.circle", style: .primary, key: "\r") { [weak self] in
            self?.popover.close()
            self?.openRun()
        }]
        stack.addArrangedSubview(NSStackView(h: buttons, spacing: 8))
        for v in stack.arrangedSubviews { v.widthAnchor.constraint(equalToConstant: inner).isActive = true }
        stack.layoutSubtreeIfNeeded()
        popover.contentSize = NSSize(width: Self.width, height: stack.fittingSize.height)
    }

    private func wrapped(_ s: String, size: CGFloat, color: NSColor, width: CGFloat) -> NSTextField {
        let f = NSTextField.text(s, size: size, color: color, lines: 0)
        f.isSelectable = true
        f.preferredMaxLayoutWidth = width
        return f
    }
}
