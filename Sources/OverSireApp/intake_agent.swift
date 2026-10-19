import Cocoa
import OverSireCore
import OverSireAI

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
    var word: String { offVision ? "Off vision" : verdict.replacingOccurrences(of: "_", with: " ").capitalized }
    /// The ticket works against the project vision. It only informs: no action changes.
    var offVision: Bool { verdict == "off_vision" }
    /// The findings to show. Off vision shows one reason.
    var shown: [String] { offVision ? Array(findings.prefix(1)) : Array(findings.prefix(6)) }

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

/// A runtime that opens a plain terminal with a command and a first prompt.
protocol TerminalOpening: AgentHost, InstallChecking {
    func openTerminal(path: String, title: String, command: String, prompt: String) async throws -> SessionRef
}

/// A tracker with a web page for the intake of a project.
protocol IntakePage: Tracker { func intakeURL(_ p: ProjectRef) -> String }

final class IntakeAgent {
    static let changed = Notification.Name("IntakeAgentChanged")

    enum State: Equatable {
        case starting
        case running(handle: SessionRef, since: Date, tail: [String])
        case report(IntakeReport, handle: SessionRef)
        case applied(accepted: Bool)
        case failed(String)
    }

    private(set) var states: [String: State] = [:]     // intake id → state
    private var timer: Timer?
    private let store: ProjectStore
    private let writeBack: PlaneWriteBack
    private let memory: ProjectMemory

    init(store: ProjectStore, writeBack: PlaneWriteBack, memory: ProjectMemory) {
        self.store = store
        self.writeBack = writeBack
        self.memory = memory
    }

    private var runtime: (any TerminalOpening)? { ENV.runtime as? any TerminalOpening }

    var available: Bool { AI_CFG.intakeAgent && runtime?.installed == true }

    func state(_ item: IntakeItem) -> State? { states[item.id] }

    static func prompt(_ template: String, key: String, title: String, url: String, body: String, vision: String? = nil) -> String {
        let input = AgentPrompts.triageInput(template: template, key: key, title: title, url: url, body: body, vision: vision)
        return (try? AITaskKind.triage.prompt(input).user) ?? ""
    }

    // Opens the session in Orca. The project needs a saved Orca workspace.
    func start(projectKey: String, item: IntakeItem) {
        guard let snap = store.snapshots[projectKey] else { return }
        guard let root = PROJECTS_CFG.orca.roots[projectKey], !root.isEmpty else {
            set(item.id, .failed("Choose an Orca workspace for \(snap.summary.identifier) first: start any item of the project once."))
            return
        }
        guard let rt = runtime else { set(item.id, .failed("Add an agent runtime account in Settings › Accounts and sync.")); return }
        let url = (ENV.tracker(snap.summary.ref.workspace) as? any IntakePage)?.intakeURL(snap.summary.ref) ?? snap.summary.url
        set(item.id, .starting)
        store.intakeDetail(projectKey: projectKey, item: item) { [weak self] r in
            guard let self else { return }
            let detail = try? r.get()
            let body = detail?.body ?? ""
            let key = (self.store.intakeKeys[item.workItemId] ?? detail?.sequence).map { "\(snap.summary.identifier)-\($0)" } ?? snap.summary.identifier
            let vision = self.memory.vision(of: snap.summary.ref)?.text
            let prompt = IntakeAgent.prompt(AGENTS.intakePrompt, key: key, title: item.name, url: url, body: body, vision: vision)
                .replacingOccurrences(of: "\n", with: " ")
            let path = AGENTS.intakeScratch ? root + "/.wt/intake-" + key.lowercased() : root
            let title = "intake-" + key
            let command: String
            do { command = try PROJECTS_CFG.runtime.intakeCommand.resolve(name: title, key: key, title: item.name) } catch {
                set(item.id, .failed("The intake command is not valid: \(error)"))
                return
            }
            Task {
                if AGENTS.intakeScratch { try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
                let r = await Result(awaiting: {
                    try await rt.openTerminal(path: path, title: title, command: command, prompt: prompt)
                })
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
        let running = states.compactMap { id, s -> (String, SessionRef)? in
            if case .running(let h, _, _) = s { return (id, h) }
            return nil
        }
        guard !running.isEmpty, let rt = runtime else { timer?.invalidate(); timer = nil; return }
        for (id, h) in running {
            Task { [weak self] in
                let r = await Result(awaiting: { try await rt.output(h, lines: 400) })
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
            if let rt = self.runtime { Task { try? await rt.close(h) } }
            if !accept { self.set(item.id, .applied(accepted: false)); done(true); return }
            self.store.triage(projectKey: projectKey, item: item, action: .accept) { ok in
                self.set(item.id, .applied(accepted: ok))
                done(ok)
            }
        }
    }

    func reveal(_ item: IntakeItem) {
        switch states[item.id] {
        case .running(let h, _, _), .report(_, let h): if let rt = runtime { Task { try? await rt.reveal(h) } }
        default: break
        }
    }

    func discard(_ item: IntakeItem) {
        if let rt = runtime {
            if case .report(_, let h) = states[item.id] { Task { try? await rt.close(h) } }
            if case .running(let h, _, _) = states[item.id] { Task { try? await rt.close(h) } }
        }
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
            for f in rep.shown {
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
