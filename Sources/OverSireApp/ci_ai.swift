import Foundation
import OverSireCore
import CIGitHubActions

// A short cause of a failed run, from the log and the changed files.
struct RunExplanation: Codable, Equatable {
    var cause: String
    var fix: String
    var confidence: String
    var at = Date()
}

// The digest of one morning: facts, and an AI summary when AI is on.
struct Digest: Codable, Equatable {
    var day: String
    var facts: [String]
    var summary: String?
}

// AI help for CI: explain a failure no agent watches, mark flaky workflows, write the morning digest.
final class CIAssist {
    static let changed = Notification.Name("CIAssistChanged")
    static let flakyDays: TimeInterval = 14

    private struct State: Codable {
        var explanations: [String: RunExplanation] = [:]
        var flaky: [String: Date] = [:]      // "repo|workflow" → last flaky run
        var retried: [String] = []           // run URLs that OverSire re-ran once
        var digest: Digest?
    }

    private var state = State()
    private(set) var busy: Set<String> = []
    private(set) var errors: [String: String] = [:]
    private var seen: [String: (attempt: Int, failed: Bool)] = [:]   // run URL → last state
    private let path: String
    private let q = DispatchQueue(label: "com.oversire.app.ci-assist", qos: .utility)

    init(path: String) {
        self.path = path
        if let d = FileManager.default.contents(atPath: path), let s = try? JSONDecoder().decode(State.self, from: d) { state = s }
    }

    var digest: Digest? { state.digest }

    static func runKey(_ r: Run) -> String { "\(r.url)#\(r.attempt ?? 1)" }
    static func workflowKey(repo: String, _ r: Run) -> String { "\(repo)|\(r.workflowName ?? r.name)" }

    func explanation(_ r: Run) -> RunExplanation? { state.explanations[CIAssist.runKey(r)] }
    func retried(_ r: Run) -> Bool { state.retried.contains(r.url) }

    // MARK: Flaky

    // Runs of one workflow and commit that failed first and passed later. Pure, for the selftest.
    static func flakyRuns(_ runs: [Run]) -> Set<String> {
        var out = Set<String>()
        let groups = Dictionary(grouping: runs.filter { $0.status == "completed" }) { "\($0.workflowName ?? $0.name)|\($0.headSha)" }
        for g in groups.values {
            let sorted = g.sorted { $0.createdAt < $1.createdAt }
            guard let firstFail = sorted.firstIndex(where: \.isFailure) else { continue }
            for r in sorted[(firstFail + 1)...] where r.conclusion == "success" { out.insert(r.id) }
        }
        return out
    }

    // A re-run attempt that passed after a failed attempt.
    static func passedOnRetry(old: (attempt: Int, failed: Bool)?, new r: Run) -> Bool {
        guard let old, old.failed, r.conclusion == "success" else { return false }
        return (r.attempt ?? 1) > old.attempt
    }

    func isFlaky(repo: String, _ r: Run) -> Bool {
        guard let at = state.flaky[CIAssist.workflowKey(repo: repo, r)] else { return false }
        return -at.timeIntervalSinceNow < CIAssist.flakyDays * 86_400
    }

    // Learn from each poll. Returns true when something changed.
    @discardableResult
    func observe(_ grouped: [(String, [Run])]) -> Bool {
        guard AI_CFG.flaky else { return false }
        var changed = false
        for (repo, runs) in grouped {
            let marked = CIAssist.flakyRuns(runs)
            for r in runs {
                let retry = CIAssist.passedOnRetry(old: seen[r.url], new: r)
                if marked.contains(r.id) || retry {
                    let k = CIAssist.workflowKey(repo: repo, r)
                    let at = lastActivity(r)
                    if (state.flaky[k] ?? .distantPast) < at { state.flaky[k] = at; changed = true }
                }
                if r.status == "completed" { seen[r.url] = (r.attempt ?? 1, r.isFailure) }
            }
        }
        if changed { save() }
        return changed
    }

    // A new failure of a flaky workflow gets one re-run before the alert. True: re-run it now, do not alert.
    func shouldRetry(repo: String, _ r: Run, watched: Bool) -> Bool {
        guard AI_CFG.flaky, r.isFailure, !watched, (r.attempt ?? 1) == 1,
              isFlaky(repo: repo, r), !state.retried.contains(r.url) else { return false }
        state.retried = Array((state.retried + [r.url]).suffix(200))
        save()
        return true
    }

    // MARK: Explain

    static func explainRequest(run r: Run, job: String, log: [String], files: [String]) -> AIRequest {
        let errs = log.filter(ActionsCI.isError)
        let context = (Array(errs.suffix(40)) + ["--- last lines ---"] + Array(log.suffix(60))).joined(separator: "\n")
        let system = """
        You read a failed GitHub Actions job and give the likely cause in one or two short sentences.
        Use plain technical English. Do not guess past the log. Say so when the log does not tell.
        Reply with one JSON object only:
        {"cause":"the likely cause","fix":"the first thing to try","confidence":"low|medium|high"}
        """
        let user = """
        Workflow: \(r.workflowName ?? r.name) #\(r.number) on \(r.headBranch) (\(r.headSha.prefix(7)))
        Commit: \(r.displayTitle)
        Job: \(job)
        Changed files: \(files.isEmpty ? "unknown" : files.prefix(40).joined(separator: ", "))

        Log:
        \(context)
        """
        return AIRequest(system: system, user: user, maxTokens: 400)
    }

    static func parseExplanation(_ text: String) -> RunExplanation? {
        let t = unfenced(text)
        guard let a = t.firstIndex(of: "{"), let b = t.lastIndex(of: "}"),
              let o = try? JSONSerialization.jsonObject(with: Data(t[a...b].utf8)) as? [String: Any],
              let cause = (o["cause"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !cause.isEmpty else { return nil }
        let conf = (o["confidence"] as? String).map { ["low", "medium", "high"].contains($0) ? $0 : "low" } ?? "low"
        return RunExplanation(cause: String(cause.prefix(400)), fix: String((o["fix"] as? String ?? "").prefix(300)), confidence: conf)
    }

    var canExplain: Bool { AI_CFG.ciExplain && AIClient.current != nil }

    func explain(repo: String, run r: Run, job: Job, log: [String]) {
        let k = CIAssist.runKey(r)
        guard AI_CFG.ciExplain, let ai = AIClient.current, !busy.contains(k) else { return }
        busy.insert(k)
        errors[k] = nil
        publish()
        q.async { [weak self] in
            let res = try? ghRun(["api", "repos/\(repo)/commits/\(r.headSha)", "--jq", ".files[].filename"], timeout: 20)
            let files = res?.ok == true ? String(decoding: res!.stdout, as: UTF8.self).split(separator: "\n").map(String.init) : []
            ai.send(CIAssist.explainRequest(run: r, job: job.name, log: log, files: files)) { result in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.busy.remove(k)
                    switch result {
                    case .success(let t):
                        if let e = CIAssist.parseExplanation(t) { self.state.explanations[k] = e; self.trim(); self.save() } else {
                            self.errors[k] = "The AI reply had no cause."
                            self.publish()
                        }
                    case .failure(let e):
                        self.errors[k] = e.message
                        self.publish()
                    }
                }
            }
        }
    }

    private func trim() {
        guard state.explanations.count > 100 else { return }
        for (k, _) in state.explanations.sorted(by: { $0.value.at < $1.value.at }).prefix(state.explanations.count - 100) {
            state.explanations[k] = nil
        }
    }

    // MARK: Digest

    static func day(_ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    // Facts of the last 24 hours. Pure, for the selftest.
    static func digestFacts(runs: [(String, [Run])], agents: [AgentSession], queued: Int, intake: Int, now: Date = Date()) -> [String] {
        let since = now.addingTimeInterval(-86_400)
        let recent = runs.flatMap { g in g.1.filter { (parseISO($0.createdAt) ?? .distantPast) >= since }.map { (g.0, $0) } }
        let failed = recent.filter { $0.1.isFailure }
        let passed = recent.filter { $0.1.conclusion == "success" }.count
        var out = ["\(recent.count) runs in the last 24 h: \(passed) passed, \(failed.count) failed."]
        let byRepo = Dictionary(grouping: failed) { $0.0.split(separator: "/").last.map(String.init) ?? $0.0 }
        if !byRepo.isEmpty {
            out.append("Failures: " + byRepo.sorted { $0.value.count > $1.value.count }.map { "\($0.key) \($0.value.count)" }.joined(separator: ", ") + ".")
        }
        let waiting = agents.filter { $0.phase == .waiting }.count
        let working = agents.filter { $0.phase == .working }.count
        let done = agents.filter { $0.phase == .done }.count
        if !agents.isEmpty { out.append("Sessions: \(working) work, \(waiting) wait for you, \(done) are done.") }
        if queued > 0 { out.append("\(queued) items wait in the queue.") }
        if intake > 0 { out.append("\(intake) intake items wait for triage.") }
        return out
    }

    // Due once a day after the set hour.
    func digestDue(now: Date = Date()) -> Bool {
        guard AI_CFG.digest, Calendar.current.component(.hour, from: now) >= AI_CFG.digestHour else { return false }
        return state.digest?.day != CIAssist.day(now)
    }

    func makeDigest(facts: [String]) {
        let today = CIAssist.day()
        state.digest = Digest(day: today, facts: facts, summary: nil)
        save()
        guard let ai = AIClient.current else { return }
        let system = "You write a morning digest for a developer in two or three short sentences. Use only the facts. Say first what needs action."
        ai.send(AIRequest(system: system, user: facts.joined(separator: "\n"), maxTokens: 200)) { [weak self] r in
            DispatchQueue.main.async {
                guard let self, case .success(let t) = r, self.state.digest?.day == today else { return }
                self.state.digest?.summary = t.trimmingCharacters(in: .whitespacesAndNewlines)
                self.save()
            }
        }
    }

    func dismissDigest() {
        state.digest = Digest(day: CIAssist.day(), facts: [], summary: nil)
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(state) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
        publish()
    }

    private func publish() { NotificationCenter.default.post(name: CIAssist.changed, object: self) }
}
