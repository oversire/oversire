import Foundation
import OverSireCore
import OverSireAI

// ─── AI checks of agents ─────────────────────────────────────────────────────
// A Quiet session gets a check: does it look done, stuck, or still working? A long command and a
// background command get one only after 60 min. A session that ends its turn gets an end check:
// done, or blocked on the user. Heuristics decide first. AI decides only when they do not know.
// A check keeps its facts. A change of the session retires it.

struct Judgement: Codable, Equatable {
    enum Verdict: String, Codable {
        case done, stuck, working
        var word: String {
            switch self {
            case .done: return "Looks done"
            case .stuck: return "Looks stuck"
            case .working: return "Still working"
            }
        }
    }
    enum State: String, Codable { case pending, approved, held, retired }

    let id: String
    let key: String
    let verdict: Verdict
    let evidence: [String]
    let action: String          // what Approve does, in words
    let nudge: String?          // the text Approve sends to a stuck agent
    let at: Date
    var byAI = false
    var state = State.pending
    // The facts at check time. Optional, so the files of version 1 load.
    var phase: SessionState?
    var since: Date?            // the screen is the same since then
    var pane: String?
    var screen: String?         // the screen fingerprint
    var message: String?        // the hash of the last agent message
    var ticking: Bool?
    var retired: String?        // why the check is out of date

    /// True for a check that the UI shows as a row to act on.
    var open: Bool { state == .pending && verdict != .working }
}

// The end check of one agent message: done, or blocked on steps that only the user can do.
struct SessionEnd: Codable, Equatable {
    enum Verdict: String, Codable { case done, blocked }
    struct Step: Codable, Equatable {
        var text: String
        var kind: String        // manual-check, secret, approval, login, deploy, other
        var ticked: Bool?
    }

    let id: String
    let key: String
    let message: String         // the hash of the agent message
    let verdict: Verdict
    var steps: [Step]
    var followUpAt: Date?
    var blockedBy: [String]
    let at: Date
    var byAI = false
    var snoozedUntil: Date?
    var told: Date?             // the last "Tell the agent"

    var passed: Int { steps.filter { $0.ticked == true }.count }

    // MARK: Heuristics

    static let strong = ["need you", "needs you", "i can't do", "i cannot do", "manual check", "your approval",
                         "tell me when", "when you have done", "you need to", "you must", "waiting for your", "your go-ahead"]
    static let weak = ["not set", "still blocked", "not ready yet"]
    static let tellRE = try! NSRegularExpression(pattern: #"\bwhen [^.?!]{1,100}, tell me\b"#, options: [.caseInsensitive])
    static let keyRE = try! NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]*-\d+\b"#)
    static let dateRE = try! NSRegularExpression(pattern: #"\b20\d\d-\d\d-\d\d\b"#)

    static func strong(_ s: String) -> Bool {
        let l = s.lowercased().replacingOccurrences(of: "’", with: "'")
        return strong.contains { l.contains($0) } || HarnessScreen.matches(tellRE, s)
    }

    static func weak(_ s: String) -> Bool { let l = s.lowercased(); return weak.contains { l.contains($0) } }

    /// Blocked when the text asks the user for steps. Nil: no clear sign, so the AI or "done" decides.
    /// A weak sign counts only while the Plane item is open, or when the recap names the user.
    static func read(message: String, turn: String, recap: String?, status: StatusCategory?, now: Date = Date())
        -> (steps: [Step], followUpAt: Date?, blockedBy: [String])? {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? turn : message
        let blocks = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let hard = blocks.filter(strong)
        let soft = blocks.filter(weak)
        let recapAsks = recap.map { strong($0) || $0.range(of: #"\byou\b"#, options: [.regularExpression, .caseInsensitive]) != nil } ?? false
        let open = status == nil || status == .todo || status == .progress || status == .blocked
        guard !hard.isEmpty || (!soft.isEmpty && (open || recapAsks)) else { return nil }
        var steps = hard.flatMap { bullets($0) }
        if steps.isEmpty { steps = soft.flatMap { bullets($0) } }
        if steps.isEmpty { steps = (hard + soft).flatMap(sentences).filter { strong($0) || weak($0) } }
        let all = (hard + soft).joined(separator: "\n")
        let fallback = kind(all, fallback: "other")
        let out = Array(steps.prefix(8)).map { Step(text: String($0.prefix(200)), kind: kind($0, fallback: fallback)) }
        let blockedBy = text.components(separatedBy: "\n").filter { $0.lowercased().contains("blocked") }.flatMap { l in
            keyRE.matches(in: l, range: NSRange(l.startIndex..., in: l)).compactMap { Range($0.range, in: l).map { String(l[$0]) } }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withFullDate]
        let dates = dateRE.matches(in: all, range: NSRange(all.startIndex..., in: all)).compactMap { m in
            Range(m.range, in: all).flatMap { iso.date(from: String(all[$0])) }
        }
        return (out, dates.filter { $0 > now }.min(), Array(Set(blockedBy)).sorted())
    }

    static func bullets(_ block: String) -> [String] {
        block.components(separatedBy: "\n").compactMap { l in
            let t = l.trimmingCharacters(in: .whitespaces)
            guard let r = t.range(of: #"^([-*•]|\d+[.)])\s+"#, options: .regularExpression) else { return nil }
            return plain(String(t[r.upperBound...]))
        }
    }

    static func sentences(_ block: String) -> [String] {
        block.replacingOccurrences(of: "\n", with: " ").components(separatedBy: ". ")
            .map { plain($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    static func plain(_ s: String) -> String { s.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "") }

    static func kind(_ s: String, fallback: String) -> String {
        let l = s.lowercased()
        func has(_ w: [String]) -> Bool { w.contains { l.contains($0) } }
        if has(["secret", "token", "api key", "password", "credential", "not set"]) { return "secret" }
        if has(["approv", "go-ahead", "go ahead"]) { return "approval" }
        if has(["login", "log in", "sign in", "passkey", "oauth"]) { return "login" }
        if has(["deploy", "release", "publish", "upload"]) { return "deploy" }
        if has(["check", "test", "verify", "capture", "permission", "connect", "button", "opens"]) { return "manual-check" }
        return fallback
    }

    static func parse(_ text: String) -> (Verdict, [Step], Date?, [String])? {
        guard let obj = replyObject(text), let v = (obj["state"] as? String).flatMap(Verdict.init(rawValue:)) else { return nil }
        let steps = (obj["steps"] as? [[String: Any]] ?? []).prefix(8).compactMap { s -> Step? in
            guard let t = s["text"] as? String, !t.isEmpty else { return nil }
            return Step(text: String(t.prefix(200)), kind: s["kind"] as? String ?? "other")
        }
        let follow = (obj["followUpAt"] as? String).flatMap { s -> Date? in
            let f = ISO8601DateFormatter()
            if let d = f.date(from: s) { return d }
            f.formatOptions = [.withFullDate]
            return f.date(from: String(s.prefix(10)))
        }
        return (v, Array(steps), follow, (obj["blockedBy"] as? [String] ?? []).map { $0.uppercased() })
    }

    /// The text that "Tell the agent" sends.
    var report: String {
        var lines = ["Manual check: \(passed) of \(steps.count) pass."]
        for s in steps { lines.append("- [\(s.ticked == true ? "x" : " ")] \(s.text)") }
        return lines.joined(separator: "\n")
    }
}

// What a check reads about one agent.
struct AgentSignals {
    var state: SessionState
    var phase: AgentSession.Phase
    var quietMinutes: Double
    var tail: [String]
    var ci: Tone?
    var prOpen: Bool
    var status: StatusCategory?
    var message = ""
    var ticking = false
}

final class AgentJudge {
    static let changed = Notification.Name("AgentJudgeChanged")
    static let longLimit: TimeInterval = 3600
    static let checkStates: [SessionState] = [.quiet, .longCommand, .background]

    private(set) var checks: [Judgement] = []
    private(set) var ends: [SessionEnd] = []
    private(set) var checking: Set<String> = []   // keys of a "Check again" that runs
    private var busy: Set<String> = []
    private var tried: [String: String] = [:]     // "end:KEY" or "check:KEY" → the message or screen of the last AI call
    private let path: String
    private let agents: AgentIndex
    private let queue: WorkQueue
    private var world: (workstreams: WorkstreamIndex, store: ProjectStore)?
    var now: () -> Date = Date.init
    var ai: () -> AIClient? = { AIClient.current }

    private struct Book: Codable {
        var checks: [Judgement]
        var ends: [SessionEnd]
    }

    init(path: String, agents: AgentIndex, queue: WorkQueue) {
        self.path = path
        self.agents = agents
        self.queue = queue
        load()
        agents.blocked = { [weak self] key, a in self?.end(key, a)?.verdict == .blocked }
    }

    // Version 1 files hold only the checks.
    private func load() {
        guard let d = FileManager.default.contents(atPath: path) else { return }
        do {
            if let b = try? JSONDecoder().decode(Book.self, from: d) { (checks, ends) = (b.checks, b.ends); return }
            checks = try JSONDecoder().decode([Judgement].self, from: d)
        } catch {
            log.error("AI checks: load of \(self.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".bad")
        }
    }

    private var on: Bool { AGENTS.aiMode != .off && AI_CFG.agentChecks }

    /// The checks to act on: Looks done and Looks stuck.
    var pending: [Judgement] {
        guard on else { return [] }
        return checks.filter(\.open)
    }

    /// The end check of the agent's current message.
    func end(_ key: String, _ a: AgentSession) -> SessionEnd? {
        let k = key.uppercased()
        return ends.first { $0.key == k && $0.message == a.messageHash }
    }

    /// The sessions that wait for steps of the user, without the snoozed ones.
    var blocking: [SessionEnd] {
        agents.agents.compactMap { k, a -> SessionEnd? in
            guard agents.state(k) == .blocked, let e = end(k, a), (e.snoozedUntil ?? .distantPast) < now() else { return nil }
            return e
        }.sorted { $0.at > $1.at }
    }

    /// The time of the last check of the key, of any kind.
    func checkedAt(_ key: String) -> Date? {
        let k = key.uppercased()
        return [checks.first { $0.key == k }?.at, ends.first { $0.key == k }?.at].compactMap { $0 }.max()
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
    // Only a Quiet session can look done here. A long command can look stuck.
    static func heuristic(_ s: AgentSignals, quietLimit: Double) -> (Judgement.Verdict, [String])? {
        let limit = s.state == .quiet ? quietLimit : AgentJudge.longLimit / 60
        guard checkStates.contains(s.state), s.quietMinutes >= limit else { return nil }
        var ev = ["The screen did not change for \(Int(s.quietMinutes)) min"]
        if s.ticking { ev.append("The spinner counter moves") }
        if let r = repeated(s.tail) {
            ev.append("The same command ran \(r.count) times: \(r.line)")
            return (.stuck, ev)
        }
        if let last = s.tail.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { ev.append("The last line is \"\(last.prefix(100))\"") }
        guard s.state == .quiet else { return nil }
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

    static func input(key: String, title: String, s: AgentSignals) -> AIInput {
        AgentPrompts.checkInput(key: key, title: title, quietMinutes: Int(s.quietMinutes), phase: "\(s.phase)", ticking: s.ticking,
                                ci: s.ci?.word ?? "none", prOpen: s.prOpen, status: s.status?.label ?? "unknown",
                                message: s.message, turn: s.tail.joined(separator: "\n"))
    }

    static func parse(_ text: String) -> (Judgement.Verdict, [String], String?)? {
        guard let obj = replyObject(text),
              let v = (obj["verdict"] as? String).flatMap(Judgement.Verdict.init(rawValue:)) else { return nil }
        let ev = (obj["evidence"] as? [String] ?? []).prefix(4).map { String($0.prefix(160)) }
        let nudge = (obj["nudge"] as? String).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        return (v, Array(ev), nudge)
    }

    static func action(_ v: Judgement.Verdict, nudge: String?, state: SessionState?) -> String {
        switch v {
        case .done: return state == .quiet ? "Free the slot of this session, so the queue starts the next item of the lane."
                                           : "Mark the check as seen. The session keeps its slot."
        case .stuck: return nudge.map { "Send a nudge: \"\($0)\"" } ?? "Open the session and look."
        case .working: return "No action. The next check comes after a screen change."
        }
    }

    /// Why a pending check is out of date now, or nil while it still holds.
    static func stale(_ j: Judgement, state: SessionState?, watch: SessionWatch?, at: Date) -> String? {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        guard let state else { return "Session closed at \(clock.string(from: at))" }
        guard checkStates.contains(state), j.screen != nil else { return "\(state.label) at \(clock.string(from: at))" }
        if let w = watch, w.fingerprint != j.screen { return "New output at \(clock.string(from: w.changedAt))" }
        return nil
    }

    // MARK: Checks

    // Retires the checks that are out of date, then checks the sessions that are due:
    // one end check for each agent message, one quiet check for each screen.
    func tick(workstreams: WorkstreamIndex, store: ProjectStore) {
        world = (workstreams, store)
        retire()
        for (key, a) in agents.agents where !busy.contains(key) {
            guard let st = agents.state(key) else { continue }
            if a.phase == .done && st != .closed { endCheck(key, a, force: false) }
            guard on, AgentJudge.checkStates.contains(st), !busy.contains(key), let w = agents.watch(key) else { continue }
            let same = now().timeIntervalSince(w.changedAt)
            guard same >= (st == .quiet ? AGENTS.quietMinutes * 60 : AgentJudge.longLimit),
                  !checks.contains(where: { $0.key == key && $0.screen == w.fingerprint }) else { continue }
            check(key, a, st, w, force: false) {}
        }
    }

    private func retire() {
        var changed = false
        for i in checks.indices where checks[i].state == .pending {
            let k = checks[i].key
            guard let why = AgentJudge.stale(checks[i], state: agents.state(k), watch: agents.watch(k), at: now()) else { continue }
            checks[i].state = .retired
            checks[i].retired = why
            changed = true
        }
        if changed { save() }
    }

    // One quiet check of the current screen. Heuristics first, then AI. `force`: no quiet wait.
    private func check(_ key: String, _ a: AgentSession, _ st: SessionState, _ w: SessionWatch, force: Bool, done: @escaping () -> Void) {
        guard let (workstreams, store) = world else { done(); return }
        busy.insert(key)
        let ws = workstreams.stream(key)
        let found = store.item(key: key)
        let s = AgentSignals(state: st, phase: a.phase, quietMinutes: now().timeIntervalSince(w.changedAt) / 60,
                             tail: w.turn.components(separatedBy: "\n"), ci: ws?.ci,
                             prOpen: ws?.prs.contains { $0.pr.state == "OPEN" } ?? false,
                             status: found.flatMap { $0.snap.option($0.item.statusOptionId)?.category }, message: a.message ?? "",
                             ticking: w.ticking)
        let facts = { (j: inout Judgement) in
            j.phase = st
            j.since = w.changedAt
            j.pane = a.paneKey
            j.screen = w.fingerprint
            j.message = a.messageHash
            j.ticking = w.ticking
        }
        var quick = s
        if force { quick.quietMinutes = max(s.quietMinutes, st == .quiet ? AGENTS.quietMinutes : AgentJudge.longLimit / 60) }
        if let (v, ev) = AgentJudge.heuristic(quick, quietLimit: AGENTS.quietMinutes) {
            add(key: key, v, ev, nudge: nil, byAI: false, state: st, facts)
            done()
        } else if on, let ai = ai(), force || tried["check:" + key] != w.fingerprint {
            tried["check:" + key] = w.fingerprint
            ai.run(.check, AgentJudge.input(key: key, title: found?.item.title ?? "", s: s), id: "check:\(key)") { [weak self] r in
                if case .success(let text) = r, let (v, ev, nudge) = AgentJudge.parse(text) {
                    self?.add(key: key, v, ev, nudge: nudge, byAI: true, state: st, facts)
                } else {
                    self?.busy.remove(key)
                }
                done()
            }
        } else {
            busy.remove(key)
            done()
        }
    }

    private func add(key: String, _ v: Judgement.Verdict, _ ev: [String], nudge: String?, byAI: Bool, state: SessionState,
                     _ facts: (inout Judgement) -> Void) {
        busy.remove(key)
        var j = Judgement(id: UUID().uuidString, key: key, verdict: v, evidence: ev,
                          action: AgentJudge.action(v, nudge: nudge, state: state), nudge: nudge, at: now(), byAI: byAI)
        facts(&j)
        for i in checks.indices where checks[i].key == key && checks[i].state == .pending {
            checks[i].state = .retired
            checks[i].retired = "Checked again"
        }
        if AGENTS.aiMode == .auto && v == .done && state == .quiet {
            j.state = .approved
            queue.release(key)
        }
        checks.insert(j, at: 0)
        save()
    }

    // The end check of the current agent message, once for each message. It waits for a screen
    // read after the end, so the last turn is current.
    private func endCheck(_ key: String, _ a: AgentSession, force: Bool, done: @escaping () -> Void = {}) {
        let w = agents.watch(key)
        guard force || end(key, a) == nil, let world, w.map({ $0.readAt >= a.since }) ?? (a.message?.isEmpty == false) else { done(); return }
        busy.insert(key)
        let found = world.store.item(key: key)
        let status = found.flatMap { $0.snap.option($0.item.statusOptionId)?.category }
        let msg = a.message ?? ""
        let turn = w?.turn ?? ""
        let put = { [weak self] (v: SessionEnd.Verdict, steps: [SessionEnd.Step], follow: Date?, by: [String], ai: Bool) in
            guard let self else { return }
            self.busy.remove(key)
            let old = self.ends.first { $0.key == key && $0.message == a.messageHash }
            var e = SessionEnd(id: old?.id ?? UUID().uuidString, key: key, message: a.messageHash, verdict: v, steps: steps,
                               followUpAt: follow, blockedBy: by, at: self.now(), byAI: ai)
            // A check again keeps the ticks of the same steps.
            for i in e.steps.indices { e.steps[i].ticked = old?.steps.first { $0.text == e.steps[i].text }?.ticked }
            e.snoozedUntil = old?.snoozedUntil
            self.ends.removeAll { $0.key == key && $0.message == a.messageHash }
            self.ends.insert(e, at: 0)
            self.save()
            done()
        }
        if let r = SessionEnd.read(message: msg, turn: turn, recap: w?.recap, status: status, now: now()) {
            put(.blocked, r.steps, r.followUpAt, r.blockedBy, false)
        } else if on, let ai = ai(), force || tried["end:" + key] != a.messageHash {
            tried["end:" + key] = a.messageHash
            let input = AgentPrompts.sessionEndInput(key: key, title: found?.item.title ?? "", status: status?.label ?? "unknown",
                                                     message: msg, turn: turn)
            ai.run(.sessionEnd, input, id: "end:\(key)") { [weak self] r in
                if case .success(let text) = r, let (v, steps, follow, by) = SessionEnd.parse(text) {
                    put(v, steps, follow, by, true)
                } else {
                    self?.busy.remove(key)
                    done()
                }
            }
        } else {
            put(.done, [], nil, [], false)
        }
    }

    /// "Check again": polls Orca, reads the screens and checks each session at once, without the quiet wait.
    /// The result counts as the check of the current screen.
    func recheck(keys: [String]) {
        let ks = keys.map { $0.uppercased() }.filter { agents.agent($0) != nil && !busy.contains($0) && !checking.contains($0) }
        guard !ks.isEmpty else { return }
        checking.formUnion(ks)
        NotificationCenter.default.post(name: AgentJudge.changed, object: self)
        agents.poll { [weak self] in
            for k in ks {
                self?.agents.read(k) { _ in self?.recheck(k) }
            }
        }
    }

    private func recheck(_ k: String) {
        let finish = { [weak self] in
            guard let self else { return }
            self.checking.remove(k)
            NotificationCenter.default.post(name: AgentJudge.changed, object: self)
        }
        retire()
        guard let a = agents.agent(k), let st = agents.state(k), st != .closed, st != .needsInput else { finish(); return }
        if a.phase == .done && st != .background { endCheck(k, a, force: true, done: finish); return }
        guard let w = agents.watch(k) else { finish(); return }
        check(k, a, st, w, force: true, done: finish)
    }

    /// The keys that "Check again" checks on a page: each open session.
    var recheckable: [String] { agents.agents.keys.filter { k in agents.state(k).map { $0 != .closed } ?? false }.sorted() }

    func approve(_ id: String) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].state = .approved
        let j = checks[i]
        switch j.verdict {
        case .done: if j.phase == nil || j.phase == .quiet { queue.release(j.key) }
        case .stuck: if let n = j.nudge { agents.send(j.key, text: n) { _ in } }
        case .working: break
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

    /// The pending "looks done" checks of Quiet sessions: Approve frees their slots.
    static func freeing(_ checks: [Judgement]) -> [Judgement] {
        checks.filter { $0.open && $0.verdict == .done && ($0.phase == nil || $0.phase == .quiet) }
    }

    func approve(all ids: [String]) {
        for id in ids { approve(id) }
    }

    func hold(_ id: String) {
        guard let i = checks.firstIndex(where: { $0.id == id }) else { return }
        checks[i].state = .held
        save()
    }

    // MARK: Blocked on you

    /// Ticks or clears one step. The ticks stay on this Mac.
    func toggle(end id: String, step: Int) {
        guard let i = ends.firstIndex(where: { $0.id == id }), ends[i].steps.indices.contains(step) else { return }
        ends[i].steps[step].ticked = !(ends[i].steps[step].ticked ?? false)
        save()
    }

    /// Sends "N of M pass" and the checklist to the session. `extra`: a failure report.
    func tell(end id: String, extra: String = "", done: @escaping (ProviderError?) -> Void) {
        guard let e = ends.first(where: { $0.id == id }) else { return }
        let text = extra.isEmpty ? e.report : e.report + "\n\n" + extra
        agents.send(e.key, text: text) { [weak self] err in
            if err == nil, let self, let j = self.ends.firstIndex(where: { $0.id == id }) {
                self.ends[j].told = self.now()
                self.save()
            }
            done(err)
        }
    }

    func snooze(end id: String, for t: TimeInterval = 86400) {
        guard let i = ends.firstIndex(where: { $0.id == id }) else { return }
        ends[i].snoozedUntil = now().addingTimeInterval(t)
        save()
    }

    /// For `--uishots`.
    func seed(_ e: SessionEnd) { ends.insert(e, at: 0) }

    // MARK: Queue order

    /// `vision`: the project vision. `blockers`: the open blocker keys of each entry.
    func suggestOrder(_ lane: QueueLane, store: ProjectStore, vision: String?, blockers: [String: [String]],
                      done: @escaping ((order: [String], reason: String)?) -> Void) {
        guard AI_CFG.queueOrder, lane.entries.count > 1, let ai = AIClient.current else { done(nil); return }
        var bodies: [String: String] = [:]
        for e in lane.entries { bodies[e.key] = store.item(key: e.key)?.item.body }
        let input = AgentPrompts.orderInput(lane.entries, bodies: bodies, vision: vision, blockers: blockers)
        ai.run(.order, input, id: "order:\(lane.id)") { r in
            if case .success(let t) = r { done(AgentPrompts.parseOrder(t, keys: lane.entries.map(\.key))) } else { done(nil) }
        }
    }

    private func save() {
        checks = Array(checks.prefix(200))
        ends = Array(ends.prefix(200))
        do { try JSONEncoder().encode(Book(checks: checks, ends: ends)).write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { log.error("AI checks: save to \(self.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        NotificationCenter.default.post(name: AgentJudge.changed, object: self)
    }
}
