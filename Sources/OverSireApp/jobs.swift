import Cocoa
import OverSireCore

// A job in the run detail. A click opens the job on GitHub. A hover shows a summary.
final class JobChip: NSView {
    static let height: CGFloat = 18
    static let hoverDelay: TimeInterval = 1.5
    let job: Job
    let notes: [String]
    private var hoverTimer: Timer?

    init(job: Job, notes: [String], maxW: CGFloat) {
        self.job = job
        self.notes = notes
        let color = JobChip.color(job)
        // Up to 15 characters show in full. A longer name keeps both ends, so "release-linux-amd64" and "-arm64" differ.
        let maxChars = 15, half = (maxChars - 1) / 2
        let shown = job.name.count > maxChars ? "\(job.name.prefix(half))\u{2026}\(job.name.suffix(half))" : job.name
        let l = NSTextField(labelWithString: shown)
        l.font = .systemFont(ofSize: 10, weight: .medium); l.textColor = color
        l.lineBreakMode = .byClipping
        // The label cell needs a few points more than its intrinsic width, or it truncates.
        let w = min(ceil(l.intrinsicContentSize.width) + 4 + 14, maxW)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: JobChip.height))
        wantsLayer = true
        layer?.cornerRadius = JobChip.height / 2
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        layer?.borderColor = color.withAlphaComponent(0.55).cgColor
        layer?.borderWidth = 0.5
        l.frame = NSRect(x: 7, y: 2, width: w - 14, height: 14)
        addSubview(l)
        setAccessibilityLabel("\(job.name), \(JobChip.statusText(job))")
    }
    required init?(coder: NSCoder) { fatalError() }

    static func failed(_ j: Job) -> Bool { ["failure", "timed_out", "startup_failure"].contains(j.conclusion ?? "") }

    static func color(_ j: Job) -> NSColor {
        if failed(j) { return C_FAILURE }
        switch j.conclusion ?? "" {
        case "success": return C_SUCCESS
        case "": return j.status == "in_progress" ? C_RUNNING : C_QUEUED
        default: return .systemGray
        }
    }

    static func statusText(_ j: Job) -> String {
        switch j.conclusion ?? "" {
        case "": return j.status == "in_progress" ? "Running" : "Queued"
        case "timed_out": return "Timed out"
        case "startup_failure": return "Startup failure"
        case let c: return c.prefix(1).uppercased() + c.dropFirst().replacingOccurrences(of: "_", with: " ")
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        JobSummary.cancelClose()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: JobChip.hoverDelay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            JobSummary.show(for: self)
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoverTimer?.invalidate()
        JobSummary.closeSoon()
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        JobSummary.close()
        if let s = job.url, let u = URL(string: s) { NSWorkspace.shared.open(u) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { hoverTimer?.invalidate(); JobSummary.close(anchor: self) }
    }
}

// The hover popover for a job: status, duration, runner, steps, and the end of the log.
enum JobSummary {
    static let width: CGFloat = 440
    private static var popover: NSPopover?
    private static weak var anchor: JobChip?
    private static var closeTimer: Timer?

    static func show(for chip: JobChip) {
        guard chip.window != nil else { return }
        close()
        let p = NSPopover()
        p.behavior = .applicationDefined
        p.animates = false
        let vc = NSViewController()
        vc.view = SummaryView(job: chip.job, notes: chip.notes, log: nil, loading: canLoadLog(chip.job))
        p.contentViewController = vc
        p.contentSize = vc.view.frame.size
        NSApp.withPinnedAppearance { p.show(relativeTo: chip.bounds, of: chip, preferredEdge: .maxY) }
        popover = p; anchor = chip
        guard canLoadLog(chip.job), let repo = repoOf(chip.job) else { return }
        JobLogs.shared.snippet(repo: repo, jobId: chip.job.id) { log in
            guard popover === p, let chip = anchor else { return }
            NSApp.withPinnedAppearance {
                vc.view = SummaryView(job: chip.job, notes: chip.notes, log: log ?? "", loading: false)
                p.contentSize = vc.view.frame.size
            }
        }
    }

    static func close(anchor a: JobChip? = nil) {
        if let a = a, a !== anchor { return }
        closeTimer?.invalidate(); closeTimer = nil
        popover?.close(); popover = nil; anchor = nil
    }

    // A short delay lets the mouse move from the chip into the popover.
    static func closeSoon() {
        closeTimer?.invalidate()
        closeTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { _ in close() }
    }

    static func cancelClose() { closeTimer?.invalidate(); closeTimer = nil }

    // Only a failed, finished job has a log worth a look.
    static func canLoadLog(_ j: Job) -> Bool {
        j.status == "completed" && JobChip.failed(j)
    }

    // The job URL is github.com/{owner}/{repo}/actions/runs/{run}/job/{id}.
    static func repoOf(_ j: Job) -> String? {
        guard let parts = j.url.flatMap(URL.init(string:))?.pathComponents, parts.count > 2 else { return nil }
        return "\(parts[1])/\(parts[2])"
    }

    static func duration(_ start: String?, _ end: String?) -> String? {
        guard let s = parseISO(start) else { return nil }
        return fmtDuration((parseISO(end) ?? Date()).timeIntervalSince(s))
    }

    private final class SummaryView: Flipped {
        init(job: Job, notes: [String], log: String?, loading: Bool) {
            super.init(frame: .zero)
            let pad: CGFloat = 12, w = JobSummary.width - pad * 2
            var y: CGFloat = 10

            func line(_ text: String, _ font: NSFont, _ color: NSColor, maxH: CGFloat = 16, x: CGFloat = 0) {
                let l = NSTextField(wrappingLabelWithString: text)
                l.font = font; l.textColor = color; l.isSelectable = true
                let h = min(ceil(l.sizeThatFits(NSSize(width: w - x, height: maxH)).height), maxH)
                l.frame = NSRect(x: pad + x, y: y, width: w - x, height: h)
                addSubview(l)
                y += h + 3
            }

            line(job.name, .systemFont(ofSize: 12.5, weight: .semibold), .labelColor, maxH: 34)
            var facts = [JobChip.statusText(job)]
            if let d = JobSummary.duration(job.startedAt, job.completedAt) { facts.append(d) }
            if let r = job.runnerName, !r.isEmpty { facts.append("runner \(r)") }
            line(facts.joined(separator: " \u{00B7} "), .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium), JobChip.color(job))
            if let s = parseISO(job.startedAt) {
                line("Started \(timestampFmt.string(from: s))", .systemFont(ofSize: 10.5), .secondaryLabelColor)
            }

            let steps = (job.steps ?? []).filter { $0.conclusion != "skipped" }
            if !steps.isEmpty {
                y += 4
                let failed = steps.filter { $0.conclusion == "failure" }
                let shown = steps.count > 10 ? Array(steps.suffix(10)) : steps
                for st in shown {
                    let mark = st.conclusion == "failure" ? "\u{2715}" : st.conclusion == "success" ? "\u{2713}" : "\u{2022}"
                    let d = JobSummary.duration(st.startedAt, st.completedAt).map { "  \($0)" } ?? ""
                    line("\(mark) \(st.name)\(d)", .systemFont(ofSize: 10.5),
                         st.conclusion == "failure" ? C_FAILURE : .secondaryLabelColor, maxH: 30)
                }
                if steps.count > shown.count {
                    let hidden = failed.filter { f in !shown.contains { $0.name == f.name } }
                    let extra = hidden.isEmpty ? "" : " (failed: \(hidden.map(\.name).joined(separator: ", ")))"
                    line("+ \(steps.count - shown.count) earlier steps\(extra)", .systemFont(ofSize: 10), .tertiaryLabelColor, maxH: 30)
                }
            }

            let mono = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
            let errors = notes.filter { !$0.hasPrefix("Process completed with exit code") }
            if !errors.isEmpty {
                y += 4
                for n in errors.prefix(2) { line(n, mono, .labelColor, maxH: 90) }
            }
            if loading {
                y += 4
                line("Loading the end of the log\u{2026}", .systemFont(ofSize: 10.5), .tertiaryLabelColor)
            } else if let log = log {
                y += 4
                if log.isEmpty {
                    line("The log is not available.", .systemFont(ofSize: 10.5), .tertiaryLabelColor)
                } else {
                    let box = NSTextField(wrappingLabelWithString: log)
                    box.font = mono; box.textColor = .labelColor; box.isSelectable = true
                    box.wantsLayer = true
                    box.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
                    box.layer?.cornerRadius = 4
                    let h = min(ceil(box.sizeThatFits(NSSize(width: w, height: 260)).height), 260)
                    box.frame = NSRect(x: pad, y: y, width: w, height: h)
                    addSubview(box)
                    y += h + 3
                }
            }
            y += 4
            line("Click the chip to open this job on GitHub.", .systemFont(ofSize: 10), .tertiaryLabelColor)
            frame = NSRect(x: 0, y: 0, width: JobSummary.width, height: y + 6)
        }
        required init?(coder: NSCoder) { fatalError() }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self))
        }
        override func mouseEntered(with event: NSEvent) { JobSummary.cancelClose() }
        override func mouseExited(with event: NSEvent) { JobSummary.closeSoon() }
    }
}

// The end of a job log for the UI. The adapter downloads only the last bytes.
final class JobLogs {
    static let shared = JobLogs()
    private var cache: [String: String] = [:]  // main thread only

    func snippet(repo: String, jobId: String, done: @escaping (String?) -> Void) {
        if let s = cache[jobId] { done(s); return }
        Task {
            let s = await REPO_CLIENT.rawLog(repo, jobId: jobId).map(CILog.errorSnippet)
            DispatchQueue.main.async {
                if let s = s { self.cache[jobId] = s }
                done(s)
            }
        }
    }

    private var logs: [String: [String]] = [:]  // main thread only

    // The cleaned end of the job log. GitHub gives the log only after the job ends, and a re-run makes new jobs, so the log stays.
    func lines(repo: String, jobId: String, done: @escaping ([String]?) -> Void) {
        if let l = logs[jobId] { done(l); return }
        Task {
            let l = await REPO_CLIENT.rawLog(repo, jobId: jobId).map(CILog.clean)
            DispatchQueue.main.async {
                if let l {
                    if self.logs.count >= 40, let k = self.logs.keys.first { self.logs[k] = nil }
                    self.logs[jobId] = l
                }
                done(l)
            }
        }
    }
}
