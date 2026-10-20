import Foundation
import OverSireCore
import OverSireAI

// ─── Session status ──────────────────────────────────────────────────────────
// The Status of a session comes from its history (a SessionDigest), the item and the screen.
// Triggers: a turn end (once for each agent message), N min idle (each screen change starts the
// wait again), and Refresh. The same screen gets no second call. Without AI, only the blocked
// heuristics of BlockedText run, at a turn end.

struct SessionStatus: Codable, Equatable {
    enum Trigger: String, Codable { case turnEnd, idle, manual }
    enum Handled: String, Codable { case open, approved, held }

    let id: String
    let key: String
    var reply: StatusReply
    var ticks: [Bool]
    let at: Date
    let trigger: Trigger
    var byAI: Bool
    // The facts at read time.
    var phase: SessionState?
    var screen: String?         // the screen fingerprint
    var message: String?        // the hash of the agent message
    var since: Date?            // the screen is the same since then
    var read: String            // what the job read, in words
    var handled = Handled.open
    var snoozedUntil: Date?
    var told: Date?             // the last "Tell the agent"

    var state: StatusReply.State { reply.state }
    var passed: Int { ticks.filter { $0 }.count }

    /// The words of the state: "Looks done", "Blocked on you".
    var word: String {
        switch reply.state {
        case .working: return "Working"
        case .done: return "Looks done"
        case .unfinished: return "Not finished"
        case .blocked: return "Blocked on you"
        case .stuck: return "Looks stuck"
        }
    }

    /// Why the job read the session, in words.
    var cause: String {
        switch trigger {
        case .turnEnd: return "at the turn end"
        case .idle: return "after \(Int(AGENTS.quietMinutes)) min with the same screen"
        case .manual: return "on Refresh"
        }
    }

    /// The text that "Tell the agent" sends.
    var report: String {
        var lines = ["Manual check: \(passed) of \(reply.needsYou.count) pass."]
        for (i, s) in reply.needsYou.enumerated() { lines.append("- [\(ticks.indices.contains(i) && ticks[i] ? "x" : " ")] \(s.text)") }
        return lines.joined(separator: "\n")
    }

    /// "Read 3 turns, 3 closing messages and the description".
    static func readText(_ d: SessionDigest?, description: Bool, screen: Bool) -> String {
        var parts: [String] = []
        if let d {
            if !d.last.isEmpty { parts.append("\(d.last.count) turn\(d.last.count == 1 ? "" : "s")") }
            if !d.earlier.isEmpty { parts.append("\(d.earlier.count) closing message\(d.earlier.count == 1 ? "" : "s")") }
        }
        if screen || d == nil { parts.append("the screen") }
        if description { parts.append("the description") }
        guard let last = parts.popLast() else { return "Read nothing" }
        return "Read " + (parts.isEmpty ? last : parts.joined(separator: ", ") + " and " + last)
    }
}

// The blocked heuristics of an agent message. They run when no AI engine is set.
enum BlockedText {
    static let strong = ["need you", "needs you", "i can't do", "i cannot do", "manual check", "your approval",
                         "tell me when", "when you have done", "you need to", "you must", "waiting for your", "your go-ahead"]
    static let weak = ["not set", "still blocked", "not ready yet"]
    static let tellRE = try! NSRegularExpression(pattern: #"\bwhen [^.?!]{1,100}, tell me\b"#, options: [.caseInsensitive])
    static let keyRE = try! NSRegularExpression(pattern: #"\b[A-Z][A-Z0-9]*-\d+\b"#)

    static func strong(_ s: String) -> Bool {
        let l = s.lowercased().replacingOccurrences(of: "’", with: "'")
        return strong.contains { l.contains($0) } || HarnessScreen.matches(tellRE, s)
    }

    static func weak(_ s: String) -> Bool { let l = s.lowercased(); return weak.contains { l.contains($0) } }

    /// The steps when the text asks the user for them. Nil: no clear sign.
    /// A weak sign counts only while the Plane item is open, or when the recap names the user.
    static func read(message: String, turn: String, recap: String?, status: StatusCategory?, key: String = "")
        -> (steps: [StatusReply.Step], blockedBy: [String])? {
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
        let fallback = kind((hard + soft).joined(separator: "\n"), fallback: "other")
        let out = Array(steps.prefix(8)).map { StatusReply.Step(text: String($0.prefix(200)), kind: kind($0, fallback: fallback)) }
        let own = key.uppercased()
        let blockedBy = text.components(separatedBy: "\n").filter { $0.lowercased().contains("blocked") }.flatMap { l in
            keyRE.matches(in: l, range: NSRange(l.startIndex..., in: l)).compactMap { Range($0.range, in: l).map { String(l[$0]) } }
        }.filter { $0 != own }
        return (out, Array(Set(blockedBy)).sorted())
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
}

final class StatusJob {
    static let changed = Notification.Name("StatusJobChanged")

    private(set) var statuses: [SessionStatus] = []
    private(set) var reading: Set<String> = []     // keys with a read that runs
    private(set) var errors: [String: String] = [:]
    private var tried: [String: String] = [:]      // key → the screen and message of the last call
    private let path: String
    private let agents: AgentIndex
    private let queue: WorkQueue
    private var world: (workstreams: WorkstreamIndex, store: ProjectStore)?
    var now: () -> Date = Date.init
    var ai: () -> AIClient? = { AIClient.current }

    init(path: String, agents: AgentIndex, queue: WorkQueue) {
        self.path = path
        self.agents = agents
        self.queue = queue
        load()
        agents.blocked = { [weak self] key, a in
            guard let s = self?.status(key) else { return false }
            return s.state == .blocked && s.message == a.messageHash
        }
    }

    private func load() {
        guard let d = FileManager.default.contents(atPath: path) else { return }
        do { statuses = try JSONDecoder().decode([SessionStatus].self, from: d) } catch {
            log.error("Status: load of \(self.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            try? FileManager.default.moveItem(atPath: path, toPath: path + ".bad")
        }
    }

    var on: Bool { AGENTS.aiMode != .off && AI_CFG.agentChecks }

    /// The last status of the key.
    func status(_ key: String) -> SessionStatus? {
        let k = key.uppercased()
        return statuses.first { $0.key == k }
    }

    /// Why the status is older than the screen, or nil while it holds.
    func outOfDate(_ s: SessionStatus) -> String? {
        let clock = DateFormatter()
        clock.dateFormat = "HH:mm"
        guard let st = agents.state(s.key) else { return "Session closed" }
        if let w = agents.watch(s.key), let screen = s.screen, w.fingerprint != screen {
            return "Out of date: the screen changed at \(clock.string(from: w.changedAt))"
        }
        if let a = agents.agent(s.key), let m = s.message, m != a.messageHash, st != .working { return "Out of date: a new agent message" }
        return nil
    }

    /// The statuses to act on: Looks done, Not finished and Looks stuck, while they hold.
    var pending: [SessionStatus] {
        agents.agents.keys.compactMap { k -> SessionStatus? in
            guard let s = status(k), s.handled == .open, [.done, .unfinished, .stuck].contains(s.state),
                  let st = agents.state(k), st != .closed, st != .needsInput, outOfDate(s) == nil else { return nil }
            return s
        }.sorted { $0.at > $1.at }
    }

    /// The sessions that wait for steps of the user, without the snoozed ones.
    var blocking: [SessionStatus] {
        agents.agents.compactMap { k, a -> SessionStatus? in
            guard agents.state(k) == .blocked, let s = status(k), s.message == a.messageHash,
                  (s.snoozedUntil ?? .distantPast) < now() else { return nil }
            return s
        }.sorted { $0.at > $1.at }
    }

    /// A pending status whose Approve frees the slot of a quiet session.
    static func frees(_ s: SessionStatus) -> Bool { s.state == .done && (s.phase == nil || s.phase == .quiet || s.phase == .done) }

    // MARK: Triggers

    /// Reads each session that is due: once at a turn end, then after N min with the same screen.
    func tick(workstreams: WorkstreamIndex, store: ProjectStore) {
        world = (workstreams, store)
        for (key, a) in agents.agents where !reading.contains(key) {
            guard let st = agents.state(key), st != .closed, let w = agents.watch(key) else { continue }
            let mark = w.fingerprint + "|" + a.messageHash
            guard tried[key] != mark, status(key).map({ $0.screen != w.fingerprint || $0.message != a.messageHash }) ?? true else { continue }
            let ended = (a.phase == .done || a.phase == .waiting) && w.readAt >= a.since
            if ended && status(key)?.message != a.messageHash {
                run(key, trigger: .turnEnd)
            } else if on, now().timeIntervalSince(w.changedAt) >= AGENTS.quietMinutes * 60 {
                run(key, trigger: .idle)
            }
        }
    }

    /// Refresh: polls Orca, reads the screens, then reads each session at once, also while it works.
    func refresh(keys: [String]) {
        let ks = keys.map { $0.uppercased() }.filter { agents.agent($0) != nil && !reading.contains($0) }
        guard !ks.isEmpty else { return }
        reading.formUnion(ks)
        changed()
        agents.poll { [weak self] in
            for k in ks {
                self?.agents.read(k) { _ in
                    self?.reading.remove(k)
                    self?.run(k, trigger: .manual)
                }
            }
        }
    }

    /// The keys that "Status for all" reads: each open session.
    var refreshable: [String] { agents.agents.keys.filter { k in agents.state(k).map { $0 != .closed } ?? false }.sorted() }

    // MARK: Read

    private func run(_ key: String, trigger: SessionStatus.Trigger) {
        guard let a = agents.agent(key), let st = agents.state(key), let w = agents.watch(key) else { changed(); return }
        tried[key] = w.fingerprint + "|" + a.messageHash
        let found = world?.store.item(key: key)
        let status = found.flatMap { $0.snap.option($0.item.statusOptionId)?.category }
        let facts = { (r: StatusReply, byAI: Bool, read: String) -> SessionStatus in
            let old = self.status(key)
            // A read of the same steps keeps their ticks.
            let ticks = r.needsYou.map { s in
                old.flatMap { o in o.reply.needsYou.firstIndex(of: s).flatMap { o.ticks.indices.contains($0) ? o.ticks[$0] : nil } } ?? false
            }
            return SessionStatus(id: UUID().uuidString, key: key, reply: r, ticks: ticks, at: self.now(), trigger: trigger, byAI: byAI,
                                 phase: st, screen: w.fingerprint, message: a.messageHash, since: w.changedAt, read: read,
                                 snoozedUntil: old?.message == a.messageHash ? old?.snoozedUntil : nil)
        }
        guard on, let ai = ai() else {
            if trigger == .turnEnd, let b = BlockedText.read(message: a.message ?? "", turn: w.turn, recap: w.recap, status: status, key: key) {
                let r = StatusReply(state: .blocked, headline: w.recap ?? "The agent waits for steps that only you can do.",
                                    needsYou: b.steps, blockedBy: b.blockedBy)
                put(facts(r, false, "Read the last agent message"))
            }
            changed()
            return
        }
        reading.insert(key)
        changed()
        agents.history(key) { [weak self] r in
            guard let self else { return }
            var digest: SessionDigest?
            switch r {
            case .success(let d): digest = d
            case .failure(let e): log.info("Status: no history for \(key, privacy: .public): \(e.message, privacy: .public)")
            }
            let live = [.working, .longCommand, .background].contains(st) || digest == nil
            let ws = self.world?.workstreams.stream(key)
            let pr = ws?.prs.first.map { "#\($0.pr.number) \($0.pr.state.lowercased())" } ?? "none"
            let body = found?.item.body ?? ""
            let input = AgentPrompts.statusInput(
                key: key, title: found?.item.title ?? "", status: status?.label ?? "unknown", description: body, digest: digest,
                screen: live ? w.turn : "", state: st.label, idleMinutes: Int(self.now().timeIntervalSince(w.changedAt) / 60),
                ci: ws?.ci?.word ?? "none", pr: pr, previous: self.status(key)?.reply.headline ?? "")
            let read = SessionStatus.readText(digest, description: !body.isEmpty, screen: live)
            ai.run(.status, input, id: "status:\(key)", subject: found.flatMap { f in f.item.ref(in: f.snap.summary.ref).map { .item($0) } }) { [weak self] r in
                guard let self else { return }
                self.reading.remove(key)
                switch r {
                case .success(let text):
                    if let reply = AgentPrompts.parseStatus(text, key: key) {
                        self.errors[key] = nil
                        self.put(facts(reply, true, read))
                    } else {
                        self.errors[key] = "The AI reply had no status"
                    }
                case .failure(let e):
                    self.errors[key] = e.localizedDescription
                }
                self.changed()
            }
        }
    }

    private func put(_ s: SessionStatus) {
        var s = s
        if AGENTS.aiMode == .auto && StatusJob.frees(s) && s.phase == .quiet {
            s.handled = .approved
            queue.release(s.key)
        }
        statuses.insert(s, at: 0)
        save()
    }

    // MARK: Actions

    private func update(_ id: String, _ body: (inout SessionStatus) -> Void) {
        guard let i = statuses.firstIndex(where: { $0.id == id }) else { return }
        body(&statuses[i])
        save()
    }

    /// Looks done: frees the slot. Looks stuck: sends the nudge.
    func approve(_ id: String) {
        guard let s = statuses.first(where: { $0.id == id }) else { return }
        switch s.state {
        case .done: if StatusJob.frees(s) { queue.release(s.key) }
        case .stuck: if !s.reply.nudge.isEmpty { agents.send(s.key, text: s.reply.nudge) { _ in } }
        default: break
        }
        update(id) { $0.handled = .approved }
    }

    func approve(all ids: [String]) { ids.forEach(approve) }

    /// Frees the slot instead of a nudge.
    func release(_ id: String) {
        guard let s = statuses.first(where: { $0.id == id }) else { return }
        queue.release(s.key)
        update(id) { $0.handled = .approved }
    }

    func hold(_ id: String) { update(id) { $0.handled = .held } }

    /// Not finished: the developer says that the session waits for them.
    func markBlocked(_ id: String) {
        update(id) { s in
            s.reply.state = .blocked
            if s.reply.needsYou.isEmpty { s.reply.needsYou = s.reply.next.map { StatusReply.Step(text: $0) } }
            s.ticks = s.reply.needsYou.map { _ in false }
        }
    }

    /// Not finished: asks the agent to go on with the open steps.
    func ask(_ id: String) {
        guard let s = statuses.first(where: { $0.id == id }) else { return }
        let open = s.reply.next.map { "- " + $0 }.joined(separator: "\n")
        agents.send(s.key, text: open.isEmpty ? "The goal of \(s.key) is not met yet. Continue." :
                        "The goal of \(s.key) is not met yet. Continue with:\n" + open) { _ in }
        update(id) { $0.handled = .approved }
    }

    /// Ticks or clears one step. The ticks stay on this Mac.
    func toggle(_ id: String, step: Int) {
        update(id) { s in
            guard s.reply.needsYou.indices.contains(step) else { return }
            while s.ticks.count < s.reply.needsYou.count { s.ticks.append(false) }
            s.ticks[step].toggle()
        }
    }

    /// Sends "N of M pass" and the checklist to the session. `extra`: a failure report.
    func tell(_ id: String, extra: String = "", done: @escaping (ProviderError?) -> Void) {
        guard let s = statuses.first(where: { $0.id == id }) else { return }
        agents.send(s.key, text: extra.isEmpty ? s.report : s.report + "\n\n" + extra) { [weak self] err in
            if err == nil { self?.update(id) { $0.told = self?.now() } }
            done(err)
        }
    }

    func snooze(_ id: String, for t: TimeInterval = 86400) { update(id) { $0.snoozedUntil = self.now().addingTimeInterval(t) } }

    /// For `--uishots`.
    func seed(_ s: SessionStatus) { statuses.insert(s, at: 0) }

    private func changed() { NotificationCenter.default.post(name: StatusJob.changed, object: self) }

    private func save() {
        statuses = Array(statuses.prefix(200))
        do { try JSONEncoder().encode(statuses).write(to: URL(fileURLWithPath: path), options: .atomic) }
        catch { log.error("Status: save to \(self.path, privacy: .public) failed: \(error.localizedDescription, privacy: .public)") }
        changed()
    }
}
