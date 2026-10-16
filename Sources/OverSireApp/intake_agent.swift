import Cocoa
import OverSireCore
import TrackerPlane

// ─── Intake agent ────────────────────────────────────────────────────────────
// A read-only Claude session in the main checkout of the project checks a new intake ticket:
// it reads the code, tries to reproduce the bug and lists missing facts. The user then adds
// its block to the ticket, and can accept it in the same step.

struct IntakeReport: Codable, Equatable {
    var verdict: String
    var findings: [String]
    var block: String
    var priority: String?
    var labels: [String]

    var tone: Tone {
        switch verdict {
        case "clear", "reproduced": return .ok
        case "duplicate": return .info
        default: return .warning
        }
    }
    var word: String { verdict.replacingOccurrences(of: "_", with: " ").capitalized }

    // The last JSON object in the output that has a verdict. Terminal lines can wrap, so lines join first.
    static func parse(_ lines: [String]) -> IntakeReport? {
        let text = lines.joined(separator: "\n")
        var end = text.endIndex
        while let close = text.range(of: "}", options: .backwards, range: text.startIndex..<end) {
            var start = close.lowerBound
            while let open = text.range(of: "{\"verdict\"", options: .backwards, range: text.startIndex..<start) {
                let raw = String(text[open.lowerBound...close.lowerBound])
                let flat = raw.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                if let obj = try? JSONSerialization.jsonObject(with: Data(flat.utf8)) as? [String: Any], let v = obj["verdict"] as? String {
                    return IntakeReport(verdict: v, findings: obj["findings"] as? [String] ?? [], block: obj["block"] as? String ?? "",
                                        priority: obj["priority"] as? String, labels: obj["labels"] as? [String] ?? [])
                }
                start = open.lowerBound
            }
            end = close.lowerBound
        }
        return nil
    }
}

final class IntakeAgent {
    static let changed = Notification.Name("IntakeAgentChanged")

    enum State: Equatable {
        case starting
        case running(handle: String, since: Date, tail: [String])
        case report(IntakeReport, handle: String)
        case applied(accepted: Bool)
        case failed(String)
    }

    private(set) var states: [String: State] = [:]     // intake id → state
    private var timer: Timer?
    private let store: ProjectStore
    private let writeBack: PlaneWriteBack
    private let q = DispatchQueue(label: "com.oversire.app.intake-agent", qos: .utility)

    init(store: ProjectStore, writeBack: PlaneWriteBack) {
        self.store = store
        self.writeBack = writeBack
    }

    var available: Bool { AI_CFG.intakeAgent && PROJECTS_CFG.orca.enabled && PROJECTS_CFG.orca.client.installed }

    func state(_ item: IntakeItem) -> State? { states[item.id] }

    static func prompt(_ template: String, key: String, title: String, url: String, body: String) -> String {
        template.replacingOccurrences(of: "{KEY}", with: key).replacingOccurrences(of: "{key}", with: key.lowercased())
            .replacingOccurrences(of: "{title}", with: title).replacingOccurrences(of: "{url}", with: url)
            .replacingOccurrences(of: "{body}", with: body.isEmpty ? "(no description)" : String(body.prefix(6000)))
    }

    // Opens the session in Orca. The project needs a saved Orca workspace.
    func start(projectKey: String, item: IntakeItem) {
        guard let snap = store.snapshots[projectKey] else { return }
        guard let root = PROJECTS_CFG.orca.roots[projectKey], !root.isEmpty else {
            set(item.id, .failed("Choose an Orca workspace for \(snap.summary.identifier) first: start any item of the project once."))
            return
        }
        let url = "\(PlaneWorkspace(slug: snap.summary.ref.workspace).webURL)/\(snap.summary.ref.workspace)/projects/\(snap.summary.ref.id)/intake"
        set(item.id, .starting)
        store.intakeDetail(projectKey: projectKey, item: item) { [weak self] r in
            guard let self else { return }
            let detail = try? r.get()
            let body = detail?.body ?? ""
            let key = (self.store.intakeKeys[item.workItemId] ?? detail?.sequence).map { "\(snap.summary.identifier)-\($0)" } ?? snap.summary.identifier
            let prompt = IntakeAgent.prompt(AGENTS.intakePrompt, key: key, title: item.name, url: url, body: body)
                .replacingOccurrences(of: "\n", with: " ")
            let path = AGENTS.intakeScratch ? root + "/.wt/intake-" + key.lowercased() : root
            let client = PROJECTS_CFG.orca.client
            let title = "intake-" + key
            self.q.async {
                if AGENTS.intakeScratch { try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
                let r = client.openTerminal(path: path, title: title,
                                            command: "claude -n '\(title)' --permission-mode plan", prompt: prompt)
                DispatchQueue.main.async {
                    switch r {
                    case .success(let h): self.set(item.id, .running(handle: h, since: Date(), tail: []))
                    case .failure(let e): self.set(item.id, .failed(e.message))
                    }
                    self.startTimer()
                }
            }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.poll() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func poll() {
        let running = states.compactMap { id, s -> (String, String)? in
            if case .running(let h, _, _) = s { return (id, h) }
            return nil
        }
        if running.isEmpty { timer?.invalidate(); timer = nil; return }
        let client = PROJECTS_CFG.orca.client
        for (id, h) in running {
            q.async { [weak self] in
                let r = client.output(handle: h)
                DispatchQueue.main.async {
                    guard let self, case .running(_, let since, _) = self.states[id] else { return }
                    switch r {
                    case .failure(let e): self.set(id, .failed(e.message))
                    case .success(let lines):
                        if let rep = IntakeReport.parse(lines) { self.set(id, .report(rep, handle: h)) }
                        else if -since.timeIntervalSinceNow > 1800 { self.set(id, .failed("No result after 30 minutes. Open the terminal to look.")) }
                        else { self.set(id, .running(handle: h, since: since, tail: Array(lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.suffix(6)))) }
                    }
                }
            }
        }
    }

    // Adds the block of the report to the ticket. With `accept`, also accepts the ticket.
    func apply(projectKey: String, item: IntakeItem, accept: Bool, done: @escaping (Bool) -> Void) {
        guard case .report(let rep, let h) = states[item.id] else { done(false); return }
        var md = "**Intake check: \(rep.word)**\n\n" + rep.findings.map { "- \($0)" }.joined(separator: "\n")
        if !rep.block.isEmpty { md += "\n\n" + rep.block }
        writeBack.addBlock(projectKey: projectKey, intake: item, markdown: md) { [weak self] ok in
            guard let self else { return }
            guard ok else { done(false); return }
            PROJECTS_CFG.orca.client.close(handle: h)
            if !accept { self.set(item.id, .applied(accepted: false)); done(true); return }
            self.store.triage(projectKey: projectKey, item: item, action: .accept) { ok in
                self.set(item.id, .applied(accepted: ok))
                done(ok)
            }
        }
    }

    func reveal(_ item: IntakeItem) {
        switch states[item.id] {
        case .running(let h, _, _), .report(_, let h): let c = PROJECTS_CFG.orca.client; q.async { c.reveal(handle: h) }
        default: break
        }
    }

    func discard(_ item: IntakeItem) {
        if case .report(_, let h) = states[item.id] { let c = PROJECTS_CFG.orca.client; q.async { c.close(handle: h) } }
        if case .running(let h, _, _) = states[item.id] { let c = PROJECTS_CFG.orca.client; q.async { c.close(handle: h) } }
        states[item.id] = nil
        NotificationCenter.default.post(name: IntakeAgent.changed, object: self)
    }

    private func set(_ id: String, _ s: State) {
        states[id] = s
        NotificationCenter.default.post(name: IntakeAgent.changed, object: self)
    }
}

// The card under an intake line: progress, the verdict with findings, and the actions.
final class IntakePanel: Card {
    init(_ state: IntakeAgent.State, projectKey: String, item: IntakeItem, agent: IntakeAgent, after: @escaping (String?) -> Void) {
        super.init(title: nil, padding: 12, spacing: 8, fill: Palette.raise)
        let head = NSStackView(h: [Glyph("sparkles", color: Palette.acc, size: 13),
                                   NSTextField.text("Intake agent", size: 12.5, weight: .semibold),
                                   Chiplet(AGENTS.intakeScratch ? "scratch worktree" : "main checkout", mono: true),
                                   Chiplet("read-only · plan mode")], spacing: 6)
        add(head)
        switch state {
        case .starting:
            head.addArrangedSubview(Pill(.running, text: "Starting"))
        case .running(_, _, let tail):
            head.addArrangedSubview(Pill(.running, text: "Checking"))
            add(TermView(lines: tail.isEmpty ? ["Waiting for output…"] : tail, height: 96))
            add(NSStackView(h: [ActionButton("Open terminal") { agent.reveal(item) }, ActionButton("Stop") { agent.discard(item) }], spacing: 6))
        case .report(let rep, _):
            border = rep.tone.color.withAlphaComponent(0.55)
            head.addArrangedSubview(Pill(rep.tone, text: rep.word))
            for f in rep.findings.prefix(6) {
                let dot = NSTextField.text("•", color: Palette.dim)
                dot.setContentCompressionResistancePriority(.required, for: .horizontal)
                let text = NSTextField.text(f, size: 12.5, lines: 3)
                text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
                add(NSStackView(h: [dot, text], spacing: 6, align: .top))
            }
            if !rep.block.isEmpty { add(TermView(lines: rep.block.components(separatedBy: "\n"), height: 110)) }
            var sug: [NSView] = []
            if let p = rep.priority { sug.append(Chiplet("Priority: \(p)")) }
            sug += rep.labels.map { Chiplet("Label: \($0)") as NSView }
            if !sug.isEmpty { add(NSStackView(h: [NSTextField.text("Suggested:", size: 12, color: Palette.dim)] + sug, spacing: 6)) }
            add(NSStackView(h: [
                ActionButton("Add the block to the item", style: .primary) {
                    agent.apply(projectKey: projectKey, item: item, accept: false) { ok in after(ok ? nil : "Plane did not take the block.") }
                },
                ActionButton("Add the block and accept") {
                    agent.apply(projectKey: projectKey, item: item, accept: true) { ok in after(ok ? nil : "Plane did not take the block or the accept.") }
                },
                ActionButton("Open terminal") { agent.reveal(item) },
                ActionButton("Discard") { agent.discard(item) },
            ], spacing: 6))
        case .applied(let accepted):
            head.addArrangedSubview(Pill(.ok, text: accepted ? "Added and accepted" : "Block added"))
            add(NSTextField.text("OverSire added its block at the end of the ticket. The text of the author did not change.", size: 12, color: Palette.mut, lines: 2))
        case .failed(let msg):
            head.addArrangedSubview(Pill(.bad, text: "Failed"))
            add(NSTextField.text(msg, size: 12, color: Palette.mut, lines: 3))
            add(NSStackView(h: [ActionButton("Try again") { agent.start(projectKey: projectKey, item: item) },
                                ActionButton("Dismiss") { agent.discard(item) }], spacing: 6))
        }
    }
    required init?(coder: NSCoder) { fatalError() }
}
