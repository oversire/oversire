import Cocoa

// ─── Deploy Log & Weekly Report ──────────────────────────────────────────────
// Append-only history of every completed workflow run we witness while polling.
// Costs no extra gh calls — it reuses data already fetched each refresh. Feeds the
// Insights tab (last-7-days vs prior-7 stats + heuristics) and a markdown export
// you can paste into an AI agent to act on.

let DEPLOY_LOG_PATH = (CONFIG_DIR as NSString).appendingPathComponent("deploys.jsonl")

struct DeployRecord: Codable {
    let repo: String
    let workflow: String
    let title: String
    let branch: String
    let event: String
    let conclusion: String
    let actor: String
    let url: String
    let number: Int
    let startedAt: String?
    let completedAt: String
    let durationSec: Double
    let loggedAt: String
}

func isDeployWorkflow(_ name: String) -> Bool {
    let n = name.lowercased()
    return n.contains("deploy") || n.contains("release") || n.contains("smoke")
}

final class DeployLog {
    static let shared = DeployLog()
    private let q = DispatchQueue(label: "com.oversire.app.deploylog")
    private var seen = Set<String>()
    private var loaded = false

    // Dedup on url+conclusion so a re-run that flips failure→success logs both events
    // (honest for flakiness insights) while stable polls of the same result don't dup.
    private func key(_ url: String, _ conclusion: String) -> String { "\(url)|\(conclusion)" }

    private func readRaw() -> String {
        (try? String(contentsOfFile: DEPLOY_LOG_PATH, encoding: .utf8)) ?? ""
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        for r in DeployLog.parse(readRaw()) { seen.insert(key(r.url, r.conclusion)) }
    }

    static func parse(_ raw: String) -> [DeployRecord] {
        let dec = JSONDecoder()
        return raw.split(separator: "\n").compactMap {
            guard let d = $0.data(using: .utf8) else { return nil }
            return try? dec.decode(DeployRecord.self, from: d)
        }
    }

    // Append newly-seen completed runs. Safe to call every refresh.
    func record(_ grouped: [(String, [Run])]) {
        q.async {
            self.ensureLoaded()
            let now = isoFmt.string(from: Date())
            let enc = JSONEncoder()
            var lines: [String] = []
            for (repo, runs) in grouped {
                for r in runs where r.status == "completed" {
                    let concl = r.conclusion ?? "unknown"
                    let k = self.key(r.url, concl)
                    if self.seen.contains(k) { continue }
                    self.seen.insert(k)
                    var dur = 0.0
                    if let s = parseISO(r.startedAt) ?? parseISO(r.createdAt),
                       let e = parseISO(r.updatedAt) { dur = max(0, e.timeIntervalSince(s)) }
                    let rec = DeployRecord(repo: repo, workflow: r.workflowName ?? r.name,
                        title: r.displayTitle, branch: r.headBranch, event: r.event,
                        conclusion: concl, actor: r.actorLogin ?? "", url: r.url, number: r.number,
                        startedAt: r.startedAt, completedAt: r.updatedAt, durationSec: dur, loggedAt: now)
                    if let d = try? enc.encode(rec), let s = String(data: d, encoding: .utf8) {
                        lines.append(s)
                    }
                }
            }
            guard !lines.isEmpty else { return }
            try? FileManager.default.createDirectory(atPath: CONFIG_DIR, withIntermediateDirectories: true)
            let text = lines.joined(separator: "\n") + "\n"
            if let h = FileHandle(forWritingAtPath: DEPLOY_LOG_PATH) {
                h.seekToEndOfFile()
                if let d = text.data(using: .utf8) { h.write(d) }
                try? h.close()
            } else {
                try? text.write(toFile: DEPLOY_LOG_PATH, atomically: true, encoding: .utf8)
            }
            log.info("DeployLog: appended \(lines.count) record(s)")
        }
    }

    func all() -> [DeployRecord] { DeployLog.parse(q.sync { readRaw() }) }
}
// ponytail: log file + in-memory seen-set grow unbounded; fine for a personal tool
// (~300B/record). Add rotation/pruning only if it ever gets large.

struct WFStat {
    let workflow: String
    var isDeploy = false
    var total = 0
    var success = 0
    var failure = 0
    var durations: [Double] = []
    var failRate: Double { total > 0 ? Double(failure) / Double(total) : 0 }
    var avgDuration: Double? { durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count) }
}

struct WindowStats {
    var total = 0, success = 0, failure = 0, cancelled = 0, other = 0
    var durations: [Double] = []
    var deployTotal = 0, deploySuccess = 0, deployFailure = 0
    var deployDurations: [Double] = []
    var byWorkflow: [String: WFStat] = [:]
    var branchFailures: [String: Int] = [:]

    var passRate: Double? { let d = success + failure; return d > 0 ? Double(success) / Double(d) : nil }
    var deployPassRate: Double? { let d = deploySuccess + deployFailure; return d > 0 ? Double(deploySuccess) / Double(d) : nil }
    var avgDuration: Double? { durations.isEmpty ? nil : durations.reduce(0, +) / Double(durations.count) }
}

func recordsInWindow(_ recs: [DeployRecord], from: Date, to: Date) -> [DeployRecord] {
    recs.filter {
        guard let d = parseISO($0.completedAt) else { return false }
        return d >= from && d < to
    }
}

func computeWindow(_ recs: [DeployRecord]) -> WindowStats {
    var s = WindowStats()
    for r in recs {
        s.total += 1
        let dep = isDeployWorkflow(r.workflow)
        if dep { s.deployTotal += 1 }
        switch r.conclusion {
        case "success":
            s.success += 1; if dep { s.deploySuccess += 1 }
        case "failure":
            s.failure += 1; if dep { s.deployFailure += 1 }
            s.branchFailures[r.branch, default: 0] += 1
        case "cancelled": s.cancelled += 1
        default: s.other += 1
        }
        if r.durationSec > 0 {
            s.durations.append(r.durationSec)
            if dep { s.deployDurations.append(r.durationSec) }
        }
        var wf = s.byWorkflow[r.workflow] ?? WFStat(workflow: r.workflow)
        wf.isDeploy = dep
        wf.total += 1
        if r.conclusion == "success" { wf.success += 1 }
        if r.conclusion == "failure" { wf.failure += 1 }
        if r.durationSec > 0 { wf.durations.append(r.durationSec) }
        s.byWorkflow[r.workflow] = wf
    }
    return s
}

func pct(_ x: Double) -> String { "\(Int((x * 100).rounded()))%" }

func generateInsights(this t: WindowStats, last l: WindowStats) -> [String] {
    var out: [String] = []
    if let p = t.passRate {
        var s = "Pass rate \(pct(p)) (\(t.success)/\(t.success + t.failure) runs)"
        if let lp = l.passRate {
            let d = (p - lp) * 100
            if abs(d) >= 1 { s += String(format: ", %@%.0f pts vs prior week", d >= 0 ? "up " : "down ", abs(d)) }
        }
        out.append(s + ".")
    }
    let failing = t.byWorkflow.values.filter { $0.total >= 3 && $0.failure > 0 }.sorted { $0.failRate > $1.failRate }
    if let w = failing.first, w.failRate >= 0.2 {
        out.append("\(w.workflow) failed \(pct(w.failRate)) of \(w.total) runs — your top failure source. Look at flaky steps, add retries, or gate it.")
    }
    let slow = t.byWorkflow.values.filter { ($0.avgDuration ?? 0) > 0 }.max { ($0.avgDuration ?? 0) < ($1.avgDuration ?? 0) }
    if let w = slow, let a = w.avgDuration, a > 300 {
        out.append("\(w.workflow) is your slowest at \(fmtDuration(a)) avg — consider caching dependencies or splitting jobs.")
    }
    if t.failure >= 3, let top = t.branchFailures.max(by: { $0.value < $1.value }), top.value >= 2 {
        let share = Double(top.value) / Double(t.failure)
        if share >= 0.5 { out.append("\(pct(share)) of failures were on `\(top.key)` (\(top.value) of \(t.failure)).") }
    }
    if l.total > 0 {
        let d = t.total - l.total
        out.append("\(t.total) runs this week (\(d >= 0 ? "+" : "")\(d) vs prior).")
    }
    if let a = t.avgDuration, let b = l.avgDuration, abs(a - b) >= 5 {
        out.append("Avg run time \(fmtDuration(a)) (\(a <= b ? "down " : "up ")\(fmtDuration(abs(a - b))) vs prior).")
    }
    if out.isEmpty { out.append("Not enough history yet — keep OverSire running and check back after a few days.") }
    return out
}

func buildAIReport(this t: WindowStats, last l: WindowStats, insights: [String], thisRecs: [DeployRecord]) -> String {
    func cell(_ s: String?) -> String { s ?? "—" }
    var md = "# OverSire — Weekly Deploy Report\n\nWindow: last 7 days vs the 7 days before.\n\n## Summary\n\n"
    md += "| Metric | This week | Prior week |\n|---|---|---|\n"
    md += "| Runs | \(t.total) | \(l.total) |\n"
    md += "| Pass rate | \(cell(t.passRate.map(pct))) | \(cell(l.passRate.map(pct))) |\n"
    md += "| Failures | \(t.failure) | \(l.failure) |\n"
    md += "| Avg duration | \(cell(t.avgDuration.map(fmtDuration))) | \(cell(l.avgDuration.map(fmtDuration))) |\n"
    md += "| Deploy/smoke runs | \(t.deployTotal) | \(l.deployTotal) |\n"
    md += "| Deploy pass rate | \(cell(t.deployPassRate.map(pct))) | \(cell(l.deployPassRate.map(pct))) |\n\n"
    md += "## Per-workflow (this week)\n\n| Workflow | Runs | Failures | Fail % | Avg duration |\n|---|---|---|---|---|\n"
    for w in t.byWorkflow.values.sorted(by: { $0.total > $1.total }) {
        md += "| \(w.workflow)\(w.isDeploy ? " (deploy)" : "") | \(w.total) | \(w.failure) | \(pct(w.failRate)) | \(cell(w.avgDuration.map(fmtDuration))) |\n"
    }
    md += "\n## Insights\n\n"
    for i in insights { md += "- \(i)\n" }
    let fails = thisRecs.filter { $0.conclusion == "failure" }
    if !fails.isEmpty {
        md += "\n## Failed runs (this week)\n\n"
        for f in fails.prefix(50) { md += "- \(f.workflow) on `\(f.branch)` (\(f.event)) — \(f.url)\n" }
    }
    md += "\n---\nTask for the agent: analyze the above and propose concrete, prioritized changes to the CI/CD config, tooling, or code that would cut failures and speed up runs. Favor high-impact, low-effort fixes.\n"
    return md
}

// ─── Footer ──────────────────────────────────────────────────────────────────

// ─── Insights tab views ──────────────────────────────────────────────────────

class TitleRow: NSView {
    init(_ text: String, w: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 34))
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 12, weight: .semibold); l.textColor = .labelColor
        l.frame = NSRect(x: 12, y: 8, width: w - 24, height: 18)
        addSubview(l)
    }
    required init?(coder: NSCoder) { fatalError() }
}

class SectionLabel: NSView {
    init(_ text: String, w: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: HDR_H))
        wantsLayer = true; layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 11, weight: .bold); l.textColor = .secondaryLabelColor
        l.frame = NSRect(x: 12, y: 6, width: w - 24, height: 20)
        addSubview(l)
    }
    required init?(coder: NSCoder) { fatalError() }
}

class StatTile: NSView {
    init(frame: NSRect, title: String, value: String, sub: String, subColor: NSColor) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        layer?.cornerRadius = 8
        let t = NSTextField(labelWithString: title.uppercased())
        t.font = .systemFont(ofSize: 9, weight: .semibold); t.textColor = .tertiaryLabelColor
        t.frame = NSRect(x: 10, y: frame.height - 22, width: frame.width - 20, height: 13)
        addSubview(t)
        let v = NSTextField(labelWithString: value)
        v.font = .monospacedDigitSystemFont(ofSize: 21, weight: .medium); v.textColor = .labelColor
        v.frame = NSRect(x: 10, y: frame.height - 50, width: frame.width - 20, height: 26)
        addSubview(v)
        if !sub.isEmpty {
            let s = NSTextField(labelWithString: sub)
            s.font = .systemFont(ofSize: 10, weight: .medium); s.textColor = subColor
            s.lineBreakMode = .byTruncatingTail
            s.frame = NSRect(x: 10, y: 8, width: frame.width - 20, height: 14)
            addSubview(s)
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

class InsightsSummaryView: NSView {
    override var isFlipped: Bool { true }
    init(this t: WindowStats, last l: WindowStats, w: CGFloat) {
        let pad: CGFloat = 12, gap: CGFloat = 10, cols: CGFloat = 3
        let tileW = (w - pad * 2 - gap * (cols - 1)) / cols
        let tileH: CGFloat = 76
        let h = pad + tileH * 2 + gap + pad
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))

        // Returns ("▲ 12% vs prior", color) — green when the move is an improvement.
        func delta(_ a: Double?, _ b: Double?, higherBetter: Bool, fmt: (Double) -> String, suffix: String = "") -> (String, NSColor) {
            guard let a = a, let b = b else { return ("", .secondaryLabelColor) }
            let d = a - b
            if abs(d) < 0.0001 { return ("no change", .secondaryLabelColor) }
            let up = d > 0
            let good = (up == higherBetter)
            return ("\(up ? "▲" : "▼") \(fmt(abs(d)))\(suffix) vs prior", good ? .systemGreen : .systemRed)
        }
        let intFmt: (Double) -> String = { String(Int($0)) }
        let ptsFmt: (Double) -> String = { String(format: "%.0f", $0) }

        let tiles: [(String, String, (String, NSColor))] = [
            ("Runs", "\(t.total)", delta(Double(t.total), Double(l.total), higherBetter: true, fmt: intFmt)),
            ("Pass rate", t.passRate.map(pct) ?? "—",
             delta(t.passRate.map { $0 * 100 }, l.passRate.map { $0 * 100 }, higherBetter: true, fmt: ptsFmt, suffix: " pts")),
            ("Failures", "\(t.failure)", delta(Double(t.failure), Double(l.failure), higherBetter: false, fmt: intFmt)),
            ("Avg time", t.avgDuration.map(fmtDuration) ?? "—",
             delta(t.avgDuration, l.avgDuration, higherBetter: false, fmt: fmtDuration)),
            ("Deploys", "\(t.deployTotal)", delta(Double(t.deployTotal), Double(l.deployTotal), higherBetter: true, fmt: intFmt)),
            ("Deploy pass", t.deployPassRate.map(pct) ?? "—",
             delta(t.deployPassRate.map { $0 * 100 }, l.deployPassRate.map { $0 * 100 }, higherBetter: true, fmt: ptsFmt, suffix: " pts")),
        ]
        for (i, tile) in tiles.enumerated() {
            let col = CGFloat(i % 3), row = CGFloat(i / 3)
            let x = pad + col * (tileW + gap)
            let y = pad + row * (tileH + gap)
            addSubview(StatTile(frame: NSRect(x: x, y: y, width: tileW, height: tileH),
                                title: tile.0, value: tile.1, sub: tile.2.0, subColor: tile.2.1))
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}

class InsightBulletRow: NSView {
    init(_ text: String, w: CGFloat) {
        let x: CGFloat = 14
        let textW = w - x - 14
        let font = NSFont.systemFont(ofSize: 12)
        let h = textHeight("•  " + text, font: font, width: textW) + 14
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: h))
        let l = NSTextField(wrappingLabelWithString: "•  " + text)
        l.font = font; l.textColor = .labelColor
        l.frame = NSRect(x: x, y: 7, width: textW, height: h - 14)
        addSubview(l)
    }
    required init?(coder: NSCoder) { fatalError() }
}

class WorkflowStatRow: NSView {
    init(_ s: WFStat, w: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 30))
        let name = NSTextField(labelWithString: s.workflow)
        name.font = .systemFont(ofSize: 12, weight: .medium); name.textColor = .labelColor
        name.lineBreakMode = .byTruncatingTail
        name.frame = NSRect(x: 14, y: 6, width: w - 250, height: 18)
        addSubview(name)
        let stats = "\(s.total) runs   \(pct(s.failRate)) fail   \(s.avgDuration.map(fmtDuration) ?? "—")"
        let r = NSTextField(labelWithString: stats)
        r.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        r.textColor = s.failRate >= 0.2 ? .systemRed : .secondaryLabelColor
        r.alignment = .right
        r.frame = NSRect(x: w - 230, y: 7, width: 216, height: 16)
        addSubview(r)
    }
    required init?(coder: NSCoder) { fatalError() }
}

class CopyReportRow: NSView {
    let markdown: String
    init(this t: WindowStats, last l: WindowStats, insights: [String], thisRecs: [DeployRecord], w: CGFloat) {
        self.markdown = buildAIReport(this: t, last: l, insights: insights, thisRecs: thisRecs)
        super.init(frame: NSRect(x: 0, y: 0, width: w, height: 52))
        let btn = NSButton(title: "Copy report for AI", target: self, action: #selector(copyIt(_:)))
        btn.bezelStyle = .rounded; btn.font = .systemFont(ofSize: 12, weight: .medium)
        btn.frame = NSRect(x: 12, y: 12, width: 170, height: 28)
        addSubview(btn)
        let hint = NSTextField(labelWithString: "Copies a markdown report to paste into an AI agent.")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .tertiaryLabelColor
        hint.frame = NSRect(x: 190, y: 17, width: w - 202, height: 16)
        addSubview(hint)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func copyIt(_ sender: NSButton) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown, forType: .string)
        sender.title = "Copied ✓"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { sender.title = "Copy report for AI" }
    }
}

extension TabVC {
func buildInsightsContent(_ w: CGFloat) -> [NSView] {
    var rows: [NSView] = []
    let recs = DeployLog.shared.all()
    if recs.isEmpty {
        rows.append(EmptyRow("No deploy history yet. OverSire logs every workflow run it sees — check back after a few runs complete.", w: w, icon: "chart.bar"))
        return rows
    }
    let now = Date()
    let day = 86400.0
    var thisR = recordsInWindow(recs, from: now.addingTimeInterval(-7 * day), to: now.addingTimeInterval(1))
    var lastR = recordsInWindow(recs, from: now.addingTimeInterval(-14 * day), to: now.addingTimeInterval(-7 * day))
    if let sel = selectedRepo {
        thisR = thisR.filter { $0.repo == sel }
        lastR = lastR.filter { $0.repo == sel }
    }
    let tw = computeWindow(thisR)
    let lw = computeWindow(lastR)
    let insights = generateInsights(this: tw, last: lw)

    rows.append(TitleRow("Last 7 days vs previous 7", w: w))
    rows.append(InsightsSummaryView(this: tw, last: lw, w: w))
    rows.append(SectionLabel("INSIGHTS", w: w))
    for i in insights { rows.append(InsightBulletRow(i, w: w)) }
    if !tw.byWorkflow.isEmpty {
        rows.append(SectionLabel("PER-WORKFLOW (7d)", w: w))
        for wf in tw.byWorkflow.values.sorted(by: { $0.total > $1.total }).prefix(12) {
            rows.append(WorkflowStatRow(wf, w: w))
        }
    }
    rows.append(CopyReportRow(this: tw, last: lw, insights: insights, thisRecs: thisR, w: w))
    return rows
}
}
