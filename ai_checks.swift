import Foundation

// ─── AI checks of agents ─────────────────────────────────────────────────────
// An agent that goes quiet gets a check: does it look done, or stuck? Heuristics decide first.
// AI decides only when the heuristics do not know and AI is on.

struct Judgement: Codable, Equatable {
    enum Verdict: String, Codable {
        case done, stuck
        var word: String { self == .done ? "Looks done" : "Looks stuck" }
    }
    enum State: String, Codable { case pending, approved, held }

    let id: String
    let key: String
    let verdict: Verdict
    let evidence: [String]
    let action: String          // what Approve does, in words
    let nudge: String?          // the text Approve sends to a stuck agent
    let at: Date
    var byAI = false
    var state = State.pending
}

// What a check reads about one agent.
struct AgentSignals {
    var phase: ItemAgent.Phase
    var quietMinutes: Double
    var tail: [String]
    var ci: Tone?
    var prOpen: Bool
    var status: StatusCategory?
}

final class AgentJudge {
    static let changed = Notification.Name("AgentJudgeChanged")

    private(set) var checks: [Judgement] = []
    private var checkedAt: [String: Date] = [:]   // key → card activity of the last check
    private var busy: Set<String> = []
    private let path: String
    private let agents: AgentIndex
    private let queue: WorkQueue

    init(path: String, agents: AgentIndex, queue: WorkQueue) {
        self.path = path
        self.agents = agents
        self.queue = queue
        if let d = FileManager.default.contents(atPath: path), let c = try? JSONDecoder().decode([Judgement].self, from: d) { checks = c }
    }

    var pending: [Judgement] {
        guard AGENTS.aiMode != .off, AI_CFG.agentChecks else { return [] }
        return checks.filter { $0.state == .pending }
    }

    // MARK: Pure parts, for the selftest

    // The same command three times in the last lines.
    static func repeated(_ tail: [String]) -> (line: String, count: Int)? {
        let cmds = tail.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("$ ") || $0.hasPrefix("⏺ Bash(") || $0.hasPrefix("Bash(") }
        var counts: [String: Int] = [:]
        for c in cmds { counts[c, default: 0] += 1 }
        return counts.filter { $0.value >= 3 }.max { $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    // A verdict when the facts are clear. Nil: not quiet long enough, or the AI must decide.
    static func heuristic(_ s: AgentSignals, quietLimit: Double) -> (Judgement.Verdict, [String])? {
        guard s.phase == .working || s.phase == .waiting, s.quietMinutes >= quietLimit else { return nil }
        var ev = ["No output for \(Int(s.quietMinutes)) min"]
        if let r = repeated(s.tail) {
            ev.append("The same command ran \(r.count) times: \(r.line)")
            return (.stuck, ev)
        }
        if let last = s.tail.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { ev.append("The last line is \"\(last.prefix(100))\"") }
        if s.ci?.word == Tone.ok.word && s.prOpen {
            ev.append("The PR is open and CI passes")
            if s.status == .review || s.status == .done { ev.append("The Plane status is \(s.status!.label)") }
            return (.done, ev)
        }
        if s.status == .done {
            ev.append("The Plane status is Done")
            return (.done, ev)
        }
        if s.ci?.word == Tone.bad.word && s.phase == .working && s.quietMinutes >= quietLimit * 2 {
            ev.append("CI fails and the agent does nothing about it")
            return (.stuck, ev)
        }
        return nil
    }

    static func request(key: String, title: String, s: AgentSignals) -> AIRequest {
        let system = """
        You check a coding agent that went quiet. Decide if its task looks done or if it looks stuck.
        Reply with one JSON object only: {"verdict":"done|stuck","evidence":["short fact", "..."],"nudge":"one message to send to a stuck agent, or empty"}
        Use at most 4 facts. Use simple English.
        """
        var u = "Item \(key): \(title)\nQuiet for \(Int(s.quietMinutes)) min. Agent state: \(s.phase).\n"
        u += "CI: \(s.ci?.word ?? "none"). PR open: \(s.prOpen ? "yes" : "no"). Plane status: \(s.status?.label ?? "unknown").\n"
        u += "Last terminal lines:\n" + s.tail.suffix(60).joined(separator: "\n")
        return AIRequest(system: system, user: u, maxTokens: 600)
    }

    static func parse(_ text: String) -> (Judgement.Verdict, [String], String?)? {
        let t = unfenced(text)
        guard let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(t[a...b].utf8)) as? [String: Any],
              let v = (obj["verdict"] as? String).flatMap(Judgement.Verdict.init(rawValue:)) else { return nil }
        let ev = (obj["evidence"] as? [String] ?? []).prefix(4).map { String($0.prefix(160)) }
        let nudge = (obj["nudge"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return (v, Array(ev), nudge)
    }

    static func action(_ v: Judgement.Verdict, nudge: String?) -> String {
        switch v {
        case .done: return "Free the slot of this session, so the queue starts the next item of the lane."
        case .stuck: return nudge.map { "Send a nudge: \"\($0)\"" } ?? "Open the session and look."
        }
    }

    // MARK: Checks

    // Checks each quiet agent once per quiet spell.
    func tick(workstreams: WorkstreamIndex, store: ProjectStore) {
        guard AGENTS.aiMode != .off, AI_CFG.agentChecks else { return }
        let limit = AGENTS.quietMinutes
        for (key, a) in agents.agents where (a.phase == .working || a.phase == .waiting) && !busy.contains(key) {
            guard let card = agents.cards.first(where: { $0.id == a.card }) else { continue }
            let quiet = -card.lastActivity.timeIntervalSinceNow / 60
            guard quiet >= limit, checkedAt[key] != card.lastActivity,
                  !checks.contains(where: { $0.key == key && $0.state == .pending }) else { continue }
            checkedAt[key] = card.lastActivity
            busy.insert(key)
            let ws = workstreams.stream(key)
            let found = store.item(key: key)
            agents.tail(key) { [weak self] lines in
                guard let self else { return }
                let s = AgentSignals(phase: a.phase, quietMinutes: quiet, tail: lines, ci: ws?.ci,
                                     prOpen: ws?.prs.contains { $0.pr.state == "OPEN" } ?? false,
                                     status: found.flatMap { $0.snap.option($0.item.statusOptionId)?.category })
                if let (v, ev) = AgentJudge.heuristic(s, quietLimit: limit) {
                    self.add(key: key, v, ev, nudge: nil, byAI: false)
                } else if let ai = AIClient.current {
                    ai.send(AgentJudge.request(key: key, title: found?.item.title ?? "", s: s)) { r in
                        if case .success(let text) = r, let (v, ev, nudge) = AgentJudge.parse(text) {
                            self.add(key: key, v, ev, nudge: nudge, byAI: true)
                        } else {
                            self.busy.remove(key)
                        }
                    }
                } else {
                    self.busy.remove(key)
                }
            }
        }
    }

    private func add(key: String, _ v: Judgement.Verdict, _ ev: [String], nudge: String?, byAI: Bool) {
        busy.remove(key)
        var j = Judgement(id: UUID().uuidString, key: key, verdict: v, evidence: ev,
                          action: AgentJudge.action(v, nudge: nudge), nudge: nudge, at: Date(), byAI: byAI)
        checks.insert(j, at: 0)
        if AGENTS.aiMode == .auto && v == .done {
            j.state = .approved
            checks[0] = j
            queue.release(key)
        }
        save()
    }

    func approve(_ id: String) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].state = .approved
        let j = checks[i]
        switch j.verdict {
        case .done: queue.release(j.key)
        case .stuck: if let n = j.nudge { agents.send(j.key, text: n) { _ in } }
        }
        save()
    }

    // For a stuck agent: free its slot instead of a nudge.
    func release(_ id: String) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].state = .approved
        queue.release(checks[i].key)
        save()
    }

    func hold(_ id: String) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].state = .held
        save()
    }

    // MARK: Queue order

    static func orderRequest(_ entries: [QueueEntry], bodies: [String: String]) -> AIRequest {
        let system = """
        You order a queue of coding tasks. Put a task first when other tasks need its result.
        Reply with one JSON object only: {"order":["KEY-1","KEY-2"],"reason":"one short sentence"}
        """
        let u = entries.map { "\($0.key): \($0.title)\n\(bodies[$0.key]?.prefix(600) ?? "")" }.joined(separator: "\n\n")
        return AIRequest(system: system, user: u, maxTokens: 400)
    }

    static func parseOrder(_ text: String, keys: [String]) -> (order: [String], reason: String)? {
        let t = unfenced(text)
        guard let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(t[a...b].utf8)) as? [String: Any],
              let order = obj["order"] as? [String] else { return nil }
        let clean = order.map { $0.uppercased() }.filter(keys.contains)
        guard Set(clean) == Set(keys), clean != keys else { return nil }
        return (clean, obj["reason"] as? String ?? "")
    }

    func suggestOrder(_ lane: QueueLane, store: ProjectStore, done: @escaping ((order: [String], reason: String)?) -> Void) {
        guard AI_CFG.queueOrder, lane.entries.count > 1, let ai = AIClient.current else { done(nil); return }
        var bodies: [String: String] = [:]
        for e in lane.entries { bodies[e.key] = store.item(key: e.key)?.item.body }
        ai.send(AgentJudge.orderRequest(lane.entries, bodies: bodies)) { r in
            if case .success(let t) = r { done(AgentJudge.parseOrder(t, keys: lane.entries.map(\.key))) } else { done(nil) }
        }
    }

    private func save() {
        checks = Array(checks.prefix(200))
        if let d = try? JSONEncoder().encode(checks) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
        NotificationCenter.default.post(name: AgentJudge.changed, object: self)
    }
}
