import Foundation
import OverSireCore
import OverSireAI

// What an agent session did, from its Claude transcript or its terminal.
struct SessionSummary: Codable, Equatable {
    var done: [String] = []
    var files: [String] = []
    var decisions: [String] = []
    var questions: [String] = []
    var at = Date()

    var markdown: String {
        var out = "**Session summary** (OverSire)\n"
        for (title, list) in [("Done", done), ("Files", files), ("Decisions", decisions), ("Open questions", questions)] where !list.isEmpty {
            out += "\n**\(title)**\n" + list.map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        return out
    }
}

final class SessionNotes {
    static let changed = Notification.Name("SessionNotesChanged")
    static let contextLimit = 24_000

    private(set) var summaries: [String: SessionSummary] = [:]
    private(set) var answers: [String: [(q: String, a: String)]] = [:]
    private(set) var busy: Set<String> = []
    private var phases: [String: AgentSession.Phase] = [:]
    private let path: String
    private let agents: AgentIndex
    private let store: ProjectStore
    private let writeBack: PlaneWriteBack
    /// False when another app owns the automations (AutomationOwner).
    var mayAct: () -> Bool = { true }
    private let q = DispatchQueue(label: "com.oversire.app.sessions", qos: .utility)
    var projectsDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/projects")

    init(path: String, agents: AgentIndex, store: ProjectStore, writeBack: PlaneWriteBack) {
        self.path = path
        self.agents = agents
        self.store = store
        self.writeBack = writeBack
        if let d = FileManager.default.contents(atPath: path), let s = try? JSONDecoder().decode([String: SessionSummary].self, from: d) { summaries = s }
    }

    func summary(_ key: String) -> SessionSummary? { summaries[key.uppercased()] }

    // MARK: Transcript

    // Claude keeps sessions in ~/.claude/projects/<cwd with each other char as "-">/<id>.jsonl.
    static func folder(cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    // The newest session file of the folder that changed after `since`.
    static func sessionFile(dir: String, since: Date) -> String? {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return nil }
        return names.filter { $0.hasSuffix(".jsonl") }
            .map { (dir as NSString).appendingPathComponent($0) }
            .compactMap { p -> (String, Date)? in
                guard let m = (try? fm.attributesOfItem(atPath: p))?[.modificationDate] as? Date, m >= since else { return nil }
                return (p, m)
            }
            .max { $0.1 < $1.1 }?.0
    }

    // One short line per user message, agent text and tool call. Tool results and thinking drop out.
    static func lines(jsonl: String) -> [String] {
        var out: [String] = []
        func short(_ s: String, _ n: Int) -> String {
            let one = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            return one.count > n ? String(one.prefix(n)) + "…" : one
        }
        for raw in jsonl.split(separator: "\n") {
            guard let d = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                  let type = d["type"] as? String, type == "user" || type == "assistant",
                  let msg = d["message"] as? [String: Any] else { continue }
            if let s = msg["content"] as? String {
                out.append("\(type): " + short(s, 600))
                continue
            }
            for b in msg["content"] as? [[String: Any]] ?? [] {
                switch b["type"] as? String {
                case "text":
                    if let t = b["text"] as? String, !t.hasPrefix("[Image") { out.append("\(type): " + short(t, 600)) }
                case "tool_use":
                    let name = b["name"] as? String ?? "tool"
                    let input = b["input"] as? [String: Any] ?? [:]
                    let arg = (input["file_path"] ?? input["command"] ?? input["pattern"] ?? input["description"]) as? String ?? ""
                    out.append("tool \(name): " + short(arg, 140))
                default: break
                }
            }
        }
        return out
    }

    // The first lines (the task) and as many of the last lines as fit.
    static func cap(_ lines: [String], limit: Int = contextLimit) -> String {
        let all = lines.joined(separator: "\n")
        guard all.count > limit else { return all }
        let head = lines.prefix(3).joined(separator: "\n").prefix(limit / 4)
        var tail: [String] = []
        var size = head.count + 40
        for l in lines.dropFirst(3).reversed() {
            guard size + l.count + 1 <= limit else { break }
            tail.insert(l, at: 0)
            size += l.count + 1
        }
        return head + "\n[… earlier lines left out …]\n" + tail.joined(separator: "\n")
    }

    // The transcript of the item's agent: the local Claude session, else the terminal screen.
    func transcript(_ key: String, done: @escaping (String) -> Void) {
        guard let a = agents.agent(key) else { done(""); return }
        let card = agents.cards.first { $0.id == a.card }
        let dir = card.map { (projectsDir as NSString).appendingPathComponent(SessionNotes.folder(cwd: $0.path)) }
        let since = a.since.addingTimeInterval(-6 * 3600)
        q.async { [weak self] in
            if let dir, let f = SessionNotes.sessionFile(dir: dir, since: since),
               let text = try? String(contentsOfFile: f, encoding: .utf8) {
                let l = SessionNotes.lines(jsonl: text)
                if !l.isEmpty { DispatchQueue.main.async { done(SessionNotes.cap(l)) }; return }
            }
            DispatchQueue.main.async {
                self?.agents.tail(key, lines: 200) { done(SessionNotes.cap($0)) }
            }
        }
    }

    // MARK: AI

    static func parse(_ text: String) -> SessionSummary? {
        guard let obj = replyObject(text) else { return nil }
        func list(_ k: String, _ n: Int) -> [String] {
            (obj[k] as? [String] ?? []).map { String($0.prefix(300)) }.filter { !$0.isEmpty }.prefix(n).map { $0 }
        }
        let s = SessionSummary(done: list("done", 8), files: list("files", 15), decisions: list("decisions", 6), questions: list("questions", 6))
        return s.done.isEmpty && s.files.isEmpty && s.questions.isEmpty ? nil : s
    }

    func summarize(_ key: String, done: ((SessionSummary?) -> Void)? = nil) {
        let k = key.uppercased()
        guard AI_CFG.sessionSummary, let ai = AIClient.current, !busy.contains(k) else { done?(nil); return }
        busy.insert(k)
        publish()
        let title = store.item(key: k)?.item.title ?? ""
        transcript(k) { [weak self] text in
            guard let self else { return }
            guard !text.isEmpty else { self.busy.remove(k); self.publish(); done?(nil); return }
            ai.run(.sessionSummary, AgentPrompts.sessionInput(key: k, title: title, transcript: text), id: "sessionSummary:\(k)") { r in
                self.busy.remove(k)
                var s: SessionSummary?
                if case .success(let t) = r { s = SessionNotes.parse(t) }
                if let s { self.summaries[k] = s; self.save() } else { self.publish() }
                done?(s)
            }
        }
    }

    func ask(_ key: String, question: String, done: @escaping (String?) -> Void) {
        let k = key.uppercased()
        guard let ai = AIClient.current else { done(nil); return }
        transcript(k) { [weak self] text in
            ai.run(.question, AgentPrompts.questionInput(transcript: text, question: question)) { r in
                guard let self else { return }
                if case .success(let a) = r {
                    self.answers[k, default: []].append((question, a.trimmingCharacters(in: .whitespacesAndNewlines)))
                    self.publish()
                    done(a)
                } else { done(nil) }
            }
        }
    }

    // A note for the next person or agent that takes the item.
    func handoff(_ key: String) -> String {
        let k = key.uppercased()
        var out = "Hand-off for \(k)"
        if let item = store.item(key: k)?.item { out += ": \(item.title)\n\(item.url)" }
        out += "\n"
        if let a = agents.agent(k), let card = agents.cards.first(where: { $0.id == a.card }) {
            out += "\nWorktree: \(card.path) (Orca card \(card.name))\nAgent: \(a.agent.rawValue), \(a.label())\n"
        }
        if let s = summaries[k] { out += "\n" + s.markdown }
        return out
    }

    // When an agent ends, write one summary comment on the item.
    func tick() {
        let now = agents.agents.mapValues(\.phase)
        defer { phases = now }
        guard AI_CFG.sessionSummary, AGENTS.writeBack.enabled, AGENTS.writeBack.sessionComment, mayAct() else { return }
        for (k, p) in now where p == .done {
            guard let old = phases[k], old == .working || old == .waiting else { continue }
            summarize(k) { [weak self] s in
                guard let self, let s else { return }
                self.writeBack.comment(key: k, markdown: s.markdown) { _ in }
            }
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(summaries) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
        publish()
    }

    private func publish() { NotificationCenter.default.post(name: SessionNotes.changed, object: self) }
}
