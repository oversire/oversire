import AppKit
import OverSireCore

/// The runtime calls of the agent index.
typealias AgentHost = AgentRuntime & SessionIO

/// A runtime that runs a local tool, which can be missing.
protocol InstallChecking { var installed: Bool { get } }

// The Orca agent of each Plane item. OverSire finds agents by the card name (the item
// key), by the pane of an agent it started, and by the item URL in the prompt.

extension AgentSession {
    func label(now: Date = Date()) -> String {
        switch phase {
        case .starting: return "Starting…"
        case .working: return "Working " + AgentSession.minutes(now.timeIntervalSince(since))
        case .waiting: return "Needs input"
        case .done: return "Session done"
        case .failed: return "Not started"
        }
    }

    static func minutes(_ t: TimeInterval) -> String {
        let m = max(0, Int(t / 60))
        return m < 60 ? "\(m)m" : "\(m / 60)h \(m % 60)m"
    }
}

// One agent state change, for the Orca activity list.
struct OrcaEvent: Equatable {
    let key: String
    let repo: String
    let phase: AgentSession.Phase
    let at: Date
    let text: String
}

// The last agent state changes, newest first.
struct OrcaFeed {
    var limit = 50
    private(set) var events: [OrcaEvent] = []

    mutating func record(before: [String: AgentSession], after: [String: AgentSession]) {
        for (key, a) in after {
            let old = before[key]
            guard old?.phase != a.phase || (a.phase != .working && old?.since != a.since) else { continue }
            events.append(OrcaEvent(key: key, repo: a.repo, phase: a.phase, at: a.since, text: OrcaFeed.text(a, from: old?.phase)))
        }
        events.sort { $0.at > $1.at }
        if events.count > limit { events.removeLast(events.count - limit) }
    }

    static func text(_ a: AgentSession, from old: AgentSession.Phase?) -> String {
        let msg = a.message.map { ": " + $0.replacingOccurrences(of: "\n", with: " ").prefix(120) } ?? ""
        switch a.phase {
        case .starting: return "Session starts"
        case .working: return old == .waiting ? "Got input, works again" : "Session works"
        case .waiting: return "Needs input" + msg
        case .done: return "Session done" + msg
        case .failed: return "Did not start" + msg
        }
    }
}

final class AgentIndex: NSObject {
    static let changed = Notification.Name("AgentIndexChanged")

    struct PendingLaunch: Equatable {
        var at: Date
        var card: String?
        var paneKey: String?
        var error: String?
    }

    private(set) var agents: [String: AgentSession] = [:]   // uppercased item key
    private(set) var cards: [Workspace] = []                // the last `worktree ps`
    private(set) var lastError: String?
    private(set) var feed = OrcaFeed()
    private(set) var watches: [String: SessionWatch] = [:]   // item key → what the screen showed
    private var reading: Set<String> = []
    private var seen: [String: String] = [:]                 // item key → phase and message hash of the last read
    private var launches: [String: PendingLaunch] = [:]
    // The panes that OverSire started. They keep the item key when the card name has none.
    private var links: [String: AgentLink] = [:]
    private let writes: StoreWrites?
    private var notified: [String: String] = [:]
    private var primed = false
    private(set) var polling = false
    private var pollAgain = false
    private var againDone: [() -> Void] = []
    private var lastPoll = Date.distantPast
    private var timer: (() -> Void)?
    private var holdChecks: [String: (tag: String, cancel: () -> Void)] = [:]   // pane key → the check at since + 10 s

    var now: () -> Date = Date.init
    var visible: () -> Bool = { false }
    /// Runs the work on main after the delay. The result cancels it. Tests use a manual scheduler.
    var schedule: (_ after: TimeInterval, _ work: @escaping () -> Void) -> () -> Void = { after, work in
        let t = Timer(timeInterval: after, repeats: false) { _ in work() }
        RunLoop.main.add(t, forMode: .common)
        return { t.invalidate() }
    }
    // Called once for each agent that holds a new waiting or done state for 10 seconds.
    var onAlert: ((_ key: String, _ agent: AgentSession) -> Void)?
    // True when the end check of this agent message found steps for the user.
    var blocked: (_ key: String, _ agent: AgentSession) -> Bool = { _, _ in false }
    var quietAfter: () -> TimeInterval = { AGENTS.quietMinutes * 60 }
    /// True when the item of the key is tracked and not Completed or Cancelled.
    var open: (String) -> Bool = { _ in false }

    var runtime: () -> (any AgentHost)? = { ENV.runtime as? any AgentHost }

    static let linkAge: TimeInterval = 30 * 86400

    /// The card of the last session that OverSire started for the item, in the last 30 days.
    func launchedCard(_ key: String) -> String? { links[key.uppercased()]?.workspace.id }
    private var observer: NSObjectProtocol?

    /// For `--uishots`: a session without Orca. The next poll replaces it.
    /// `--uishots`: the seeded sessions stay, no poll replaces them.
    var hold = false

    func seed(cards: [Workspace]) { self.cards = cards }

    func seed(_ key: String, _ a: AgentSession, watch: SessionWatch? = nil) {
        agents[key.uppercased()] = a
        watches[key.uppercased()] = watch
    }

    init(writes: StoreWrites? = nil) {
        self.writes = writes
        super.init()
        let old = Date().addingTimeInterval(-AgentIndex.linkAge)
        for l in writes?.load(AgentLink.self) ?? [] {
            if l.at < old { writes?.delete(AgentLink.self, id: l.id) } else { links[l.key] = l }
        }
        guard let writes else { return }
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard let self, n.userInfo?["collection"] as? String == AgentLink.collection else { return }
            self.links = Dictionary(writes.load(AgentLink.self).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }

    func agent(_ key: String) -> AgentSession? { agents[key.uppercased()] }

    // MARK: Session state

    func facts(_ key: String) -> SessionFacts? {
        let k = key.uppercased()
        guard let a = agents[k] else { return nil }
        let w = watches[k]
        let live = a.card.flatMap { c in cards.first { $0.id == c } }?.liveTerminals ?? 1
        return SessionFacts(phase: a.phase, liveTerminals: live, blocked: a.phase == .done && blocked(k, a), shells: w?.shells ?? 0,
                            sameFor: w.map { now().timeIntervalSince($0.changedAt) } ?? 0, ticking: w?.ticking ?? false)
    }

    func state(_ key: String) -> SessionState? { facts(key)?.state(quietAfter: quietAfter()) }

    func watch(_ key: String) -> SessionWatch? { watches[key.uppercased()] }

    // Reads the screens that are due: a live session each minute, an ended one each 5 minutes,
    // and at once after a state or message change.
    private func readScreens(at: Date) {
        watches = watches.filter { agents[$0.key] != nil }
        for (key, a) in agents where a.phase != .failed && a.phase != .starting && !reading.contains(key) {
            let tag = "\(a.phase)|\(a.messageHash)"
            let age = watches[key].map { at.timeIntervalSince($0.readAt) } ?? .infinity
            guard seen[key] != tag || age >= (a.phase == .done ? 300 : 60) else { continue }
            seen[key] = tag
            read(key) { _ in }
        }
    }

    /// Reads the screen of one session now. `done` gets false when no terminal answered.
    func read(_ key: String, done: @escaping (Bool) -> Void) {
        let k = key.uppercased()
        guard let a = agents[k], runtime() != nil else { done(false); return }
        reading.insert(k)
        terminal(k) { rt, s -> [String]? in
            guard let s, case .success(let lines) = await Result(awaiting: { try await rt.output(s, lines: 300) }) else { return nil }
            return lines
        } done: { [weak self] lines in
            guard let self else { return }
            self.reading.remove(k)
            guard let lines, !lines.isEmpty else { done(false); return }
            let before = self.state(k)
            var w = self.watches[k] ?? SessionWatch(at: self.now())
            w.observe(HarnessScreen(lines, harness: a.agent), at: self.now())
            self.watches[k] = w
            if self.state(k) != before { self.publish() }
            done(true)
        }
    }

    // Self when a runtime account exists and its tool is installed, else nil. The UI shows no agent controls then.
    var ready: AgentIndex? {
        guard let rt = runtime() else { return nil }
        return (rt as? any InstallChecking)?.installed ?? true ? self : nil
    }

    /// Polls each 15 s with a window open or while an agent works or waits. Else each 60 s.
    func startTimer() {
        timer?()
        tick(first: true)
    }

    private func tick(first: Bool = false) {
        let busy = agents.values.contains { $0.phase == .working || $0.phase == .waiting || $0.phase == .starting }
        // 1 s less, so a late tick does not skip a cycle.
        if first || visible() || now().timeIntervalSince(lastPoll) >= (busy ? 15 : 60) - 1 { poll() }
        timer = schedule(15) { [weak self] in self?.tick() }
    }

    /// A hint that the agents of the account changed. Callable from any thread. nil: any account.
    func hint(account: AccountID? = nil) {
        let go = { [weak self] in
            guard let self else { return }
            if let account, let rt = self.runtime(), rt.account != account { return }
            self.poll()
        }
        if Thread.isMainThread { go() } else { DispatchQueue.main.async(execute: go) }
    }

    func didWake() { poll() }

    /// A call during a poll runs one more poll after it.
    func poll(done: (() -> Void)? = nil) {
        if polling {
            pollAgain = true
            if let done { againDone.append(done) }
            return
        }
        guard ready != nil, !hold, let rt = runtime() else { done?(); return }
        polling = true
        lastPoll = now()
        Task { [weak self] in
            let r = await Result(awaiting: { try await rt.workspaces() })
            DispatchQueue.main.async {
                guard let self else { return }
                self.polling = false
                switch r {
                case .failure(let e): self.lastError = e.message
                case .success(let cards):
                    self.lastError = nil
                    self.absorb(cards)
                }
                done?()
                guard self.pollAgain else { return }
                self.pollAgain = false
                let after = self.againDone
                self.againDone = []
                self.poll { after.forEach { $0() } }
            }
        }
    }

    /// The Orca workspaces, for the start menu.
    func workspaces(done: @escaping (Result<[RuntimeRepo], ProviderError>) -> Void) {
        guard let rt = runtime() else { done(.failure(.unsupported(.sessionInput))); return }
        Task {
            let r = await Result(awaiting: { try await rt.repos(in: nil) })
            DispatchQueue.main.async { done(r) }
        }
    }

    func fail(_ key: String, _ message: String) {
        let k = key.uppercased()
        launches[k] = PendingLaunch(at: now(), error: message)
        let before = agents
        agents[k] = AgentSession(phase: .failed, since: now(), message: message)
        feed.record(before: before, after: agents)
        publish()
    }

    // Opens a Claude session for the item in its Orca workspace, then sends the prompt.
    func start(_ item: Item, root: String, agent: String? = nil, done: @escaping (Result<Launch, ProviderError>) -> Void) {
        let key = item.key.uppercased()
        guard let rt = runtime() else { done(.failure(.unsupported(.sessionInput))); return }
        let (agent, prompt, command) = PROJECTS_CFG.launch(for: item, agent: agent)
        launches[key] = PendingLaunch(at: now())
        agents[key] = AgentSession(phase: .starting, since: now(), agent: AgentName(rawValue: agent), repo: (root as NSString).lastPathComponent, prompt: prompt)
        publish()
        Task { [weak self] in
            let req = LaunchRequest(repo: root, name: item.key, note: item.url, agent: AgentName(rawValue: agent), prompt: prompt,
                                    command: command)
            let r = await Result(awaiting: { try await rt.launch(req) })
            DispatchQueue.main.async {
                guard let self else { return }
                switch r {
                case .success(let l):
                    self.launches[key] = PendingLaunch(at: self.now(), card: l.card, paneKey: l.paneKey)
                    let link = AgentLink(key: key, workspace: WorkspaceRef(account: rt.account, id: l.card), pane: l.paneKey, at: self.now())
                    self.links[key] = link
                    self.writes?.put(link)
                case .failure(let e): self.fail(key, e.message)
                }
                self.publish()
                self.poll()
                done(r)
            }
        }
    }

    /// The key of the item that OverSire started last.
    var lastStarted: String? { links.values.max { $0.at < $1.at }?.key }

    func clearFailure(_ key: String) {
        let k = key.uppercased()
        guard launches[k]?.error != nil else { return }
        launches[k] = nil
        agents[k] = nil
        publish()
    }

    /// Only a session on this Mac opens in the runtime UI.
    var canReveal: Bool { runtime() is any Revealing }

    /// "this Mac", or the name of the sessions machine.
    var place: String { remote ? runtime()?.account.id ?? "this Mac" : "this Mac" }

    /// The sessions machine is not this Mac.
    var remote: Bool { runtime().map { !($0 is any Revealing) } ?? false }

    // Shows the item's terminal in Orca.
    func reveal(_ key: String, done: @escaping (ProviderError?) -> Void) {
        guard let a = agent(key), let card = a.card else { done(.notFound); return }
        reveal(card: card, pick: { AgentIndex.pick($0, agent: a, key: key) }, done: done)
    }

    // Shows the first live terminal of a worktree in Orca.
    func reveal(card: String, pick: @escaping ([RuntimeSession]) -> RuntimeSession? = { _ in nil }, done: @escaping (ProviderError?) -> Void) {
        guard let rt = runtime() as? any Revealing & AgentHost else { done(.unsupported(.reveal)); return }
        Task {
            let r = await Result(awaiting: { () async throws -> Void in
                let ts = try await rt.sessions(WorkspaceRef(account: rt.account, id: card))
                guard let t = pick(ts) ?? ts.first(where: { !$0.orphaned }) else {
                    throw ProviderError.vendor(code: "no_terminal", message: "The worktree has no live terminal")
                }
                try await rt.reveal(t.ref)
            })
            DispatchQueue.main.async { if case .failure(let e) = r { done(e) } else { done(nil) } }
        }
    }

    /// The history of the session of the key, when the runtime can read it.
    func history(_ key: String, budget: HistoryBudget = .standard, done: @escaping (Result<SessionDigest, ProviderError>) -> Void) {
        guard let a = agent(key), let card = a.card, let ws = cards.first(where: { $0.id == card }),
              let rt = runtime() as? any SessionHistoryReading else {
            done(.failure(.unsupported(.sessionHistory)))
            return
        }
        Task {
            let start = Date()
            let r = await Result(awaiting: { try await rt.history(of: a, in: ws, budget: budget) })
            let ms = Int(Date().timeIntervalSince(start) * 1000)
            switch r {
            case .success(let d):
                var e = LogEntry(level: .ok, area: .sessions, job: "History read", subject: key, host: "\(rt.account)",
                                 message: "\(d.turns) turns", ms: ms)
                e.verbose = true
                APP_LOG.write(e)
            case .failure(.unsupported): break
            case .failure(let e):
                APP_LOG.write(LogEntry(level: .warn, area: .sessions, job: "History read", subject: key, host: "\(rt.account)",
                                       message: "Used the screen only: \(e.message)", ms: ms))
            }
            DispatchQueue.main.async { done(r) }
        }
    }

    func send(_ key: String, text: String, done: @escaping (ProviderError?) -> Void) {
        guard runtime() != nil else { done(.vendor(code: "no_runtime", message: "No machine runs the sessions. Pick one in Settings › Machines.")); return }
        terminal(key) { rt, s in
            guard let s else { return ProviderError.vendor(code: "no_terminal", message: "The session terminal is closed") }
            if case .failure(let e) = await Result(awaiting: { try await rt.send(s, text: text) }) { return e }
            return nil
        } done: { done($0) }
    }

    func tail(_ key: String, lines n: Int = 8, done: @escaping ([String]) -> Void) {
        terminal(key) { rt, s -> [String] in
            guard let s, case .success(let lines) = await Result(awaiting: { try await rt.tail(s, lines: n) }) else { return [] }
            return lines
        } done: { done($0) }
    }

    private func terminal<T>(_ key: String, _ work: @escaping (any AgentHost, SessionRef?) async -> T, done: @escaping (T) -> Void) {
        let a = agent(key)
        guard let rt = runtime() else { return }
        Task {
            var session: SessionRef?
            if let a, let card = a.card, case .success(let ts) = await Result(awaiting: { try await rt.sessions(WorkspaceRef(account: rt.account, id: card)) }) {
                session = AgentIndex.pick(ts, agent: a, key: key)?.ref
            }
            let r = await work(rt, session)
            DispatchQueue.main.async { done(r) }
        }
    }

    // The agent's own terminal: its pane, else a live tab titled with the item key.
    static func pick(_ ts: [RuntimeSession], agent: AgentSession, key: String) -> RuntimeSession? {
        if let p = agent.paneKey, let t = ts.first(where: { $0.paneKey == p }) { return t }
        if let t = ts.first(where: { !$0.orphaned && $0.title.range(of: key, options: .caseInsensitive) != nil }) { return t }
        // The only terminal with an agent title (not "Terminal N") that names no other item.
        let titled = ts.filter { t in
            !t.title.isEmpty && t.title.range(of: #"^Terminal \d+$"#, options: .regularExpression) == nil
                && WorkstreamIndex.keyRE.firstMatch(in: t.title, range: NSRange(t.title.startIndex..., in: t.title)) == nil
        }
        return titled.count == 1 ? titled[0] : nil
    }

    func absorb(_ cards: [Workspace]) {
        let at = now()
        launches = launches.filter { at.timeIntervalSince($0.value.at) < ($0.value.error == nil ? 90 : 600) }
        let before = agents
        let cardsChanged = self.cards != cards
        self.cards = cards
        agents = AgentIndex.index(cards, launches: launches, links: links, open: open, now: at)
        feed.record(before: before, after: agents)
        readScreens(at: at)
        var young: [String: (tag: String, due: Date)] = [:]
        for (key, a) in agents where a.phase == .waiting || a.phase == .done {
            let tag = "\(a.phase)|\(a.paneKey ?? "")|\(Int(a.since.timeIntervalSince1970))"
            guard notified[key] != tag else { continue }
            if !primed { notified[key] = tag; continue }
            // A short state gets no alert. A check at since + 10 s sees if it holds.
            if at.timeIntervalSince(a.since) < 10 {
                young[a.paneKey ?? key] = (tag, a.since.addingTimeInterval(10))
                continue
            }
            // An old done agent comes back when its item opens again: it is no news.
            guard at.timeIntervalSince(a.since) < 86400 else { continue }
            notified[key] = tag
            onAlert?(key, a)
        }
        primed = true
        planHoldChecks(young, at: at)
        // Working minutes change without a state change. A publish each minute keeps them current.
        if agents != before || cardsChanged || (agents.values.contains { $0.phase == .working } && at.timeIntervalSince(lastPublish) >= 60) { publish() }
    }

    // One check for each pane. A new state replaces the check, and an old one goes.
    private func planHoldChecks(_ young: [String: (tag: String, due: Date)], at: Date) {
        for (pane, c) in holdChecks where young[pane]?.tag != c.tag {
            c.cancel()
            holdChecks[pane] = nil
        }
        for (pane, y) in young where holdChecks[pane] == nil {
            let cancel = schedule(max(0, y.due.timeIntervalSince(at))) { [weak self] in
                guard let self, self.holdChecks[pane]?.tag == y.tag else { return }
                self.holdChecks[pane] = nil
                self.poll()
            }
            holdChecks[pane] = (y.tag, cancel)
        }
    }

    var holdCheckCount: Int { holdChecks.count }

    static let browseRE = try! NSRegularExpression(pattern: "/browse/([A-Za-z][A-Za-z0-9]*-[0-9]+)\\b")
    static let keyRE = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9]*-[0-9]+$")
    static let keyPrefixRE = try! NSRegularExpression(pattern: "^([A-Za-z][A-Za-z0-9]*-[0-9]+)[/_]")

    // Item key → the most urgent agent. Agents of closed terminals drop out.
    // A done agent older than a day stays only while its item is open: Session done does not mean the item is done.
    static func index(_ cards: [Workspace], launches: [String: PendingLaunch], links: [String: AgentLink] = [:],
                      open: (String) -> Bool = { _ in false }, now: Date) -> [String: AgentSession] {
        var out: [String: AgentSession] = [:]
        var byPane: [String: String] = [:]
        for (k, l) in links { if let p = l.pane { byPane[p] = k } }
        for (k, l) in launches { if let p = l.paneKey { byPane[p] = k } }
        func put(_ key: String, _ a: AgentSession) {
            if let cur = out[key], cur.rank <= a.rank { return }
            out[key] = a
        }
        for c in cards {
            var name = c.name.uppercased()
            var named = keyRE.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil
            // A branch name as card name: FRITZ-28/desktop-app.
            if !named, let m = keyPrefixRE.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)), let r = Range(m.range(at: 1), in: name) {
                name = String(name[r])
                named = true
            }
            for g in c.agents {
                let key: String
                if named { key = name }
                else if let k = g.paneKey.flatMap({ byPane[$0] }) { key = k }
                else if let p = g.prompt, let m = browseRE.firstMatch(in: p, range: NSRange(p.startIndex..., in: p)),
                        let r = Range(m.range(at: 1), in: p) { key = String(p[r]).uppercased() }
                else { continue }
                if g.phase == .done && (c.liveTerminals == 0 || (now.timeIntervalSince(g.since) > 86400 && !open(key))) { continue }
                put(key, g)
            }
        }
        for (key, l) in launches where out[key] == nil || (out[key]?.phase == .done && l.error == nil && l.card != nil && out[key]?.paneKey != l.paneKey) {
            if let e = l.error {
                out[key] = AgentSession(phase: .failed, since: l.at, message: e)
            } else {
                out[key] = AgentSession(phase: .starting, since: l.at, card: l.card, paneKey: l.paneKey,
                                     repo: cards.first { $0.id == l.card }?.repo ?? "")
            }
        }
        return out
    }

    private var lastPublish = Date.distantPast

    private func publish() {
        lastPublish = now()
        NotificationCenter.default.post(name: AgentIndex.changed, object: self)
    }
}
