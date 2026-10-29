import Foundation
import OverSireCore

/// The runbook engine of a daemon, in memory, for FakeRuntime and FakeDaemon.
/// A step start sets the step to working at once. `session(_:_:)` plays the session of the current step.
/// A wrong state throws `ProviderError.vendor(code: "409")`, a wrong verdict `.vendor(code: "400")`.
public final class FakeRunbookEngine: @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [RunbookRunID: RunbookRun] = [:]
    private var order: [RunbookRunID] = []
    private var made = 0
    private var observer: (@Sendable (RunbookRun) -> Void)?

    public let machine: MachineName
    public var now: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_792_400_000) }
    public var runtime = "orca"

    public init(machine: MachineName) { self.machine = machine }

    private func with<T>(_ f: () throws -> T) rethrows -> T { try lock.withLock(f) }

    /// Gets each changed run, as the runbookRun frames of a daemon.
    public func observe(_ f: (@Sendable (RunbookRun) -> Void)?) { with { observer = f } }

    /// All runs, oldest first.
    public var all: [RunbookRun] { with { order.compactMap { runs[$0] } } }

    /// Adds runs as they are, for tests and `--uishots`.
    public func seed(_ list: [RunbookRun]) {
        with {
            for r in list {
                if runs[r.id] == nil { order.append(r.id) }
                runs[r.id] = r
            }
        }
    }

    // MARK: RunbookRunning

    public func start(_ s: RunbookStart) throws -> RunbookRun {
        try change {
            var problems = s.runbook.validate(agents: Set(s.agents.keys))
            if let at = s.startAt, s.runbook.index(of: at) == nil { problems.append(RunbookProblem(step: at, "There is no step \(at).")) }
            guard problems.isEmpty else { throw RunbookRefusal(message: "The runbook has problems.", problems: problems) }
            if let open = order.compactMap({ runs[$0] }).first(where: { $0.item.key == s.item.key && $0.state.isOpen }) {
                throw ProviderError.vendor(code: "409", message: "\(s.item.key) has the open run \(open.id).")
            }
            made += 1
            let at = now()
            var r = RunbookRun(id: RunbookRunID(rawValue: String(format: "rb_%08x", made)), item: s.item, title: s.title, machine: machine,
                               runtime: s.runtime ?? runtime, repo: s.repo, runbook: s.runbook, agents: s.agents, notes: s.notes,
                               state: .running, steps: s.runbook.steps.map { StepRun(step: $0.id, state: .waits) },
                               started: at, updated: at)
            let first = s.startAt.flatMap { s.runbook.index(of: $0) } ?? 0
            for st in s.runbook.steps.prefix(first) { set(&r, st.id) { $0.state = .skipped } }
            enter(&r, first, approved: s.startAt != nil)
            order.append(r.id)
            return r
        }
    }

    public func list(item: String?, open: Bool) -> [RunbookRun] {
        all.filter { (item == nil || $0.item.key == item) && (!open || $0.state.isOpen) }
    }

    public func get(_ id: RunbookRunID) throws -> RunbookRun {
        try with { guard let r = runs[id] else { throw ProviderError.notFound }; return r }
    }

    public func act(_ a: RunbookAction, on id: RunbookRunID) throws -> RunbookRun {
        try change(id) { r in
            switch a {
            case .approve:
                guard r.state == .gate, let cur = r.current, let i = r.runbook.index(of: cur) else { throw Self.conflict(r, "approve") }
                enter(&r, i, approved: true)
            case .pause:
                guard r.state == .running else { throw Self.conflict(r, "pause") }
                r.state = .paused
                r.reason = "You paused the run."
            case .resume:
                guard r.state == .paused, let cur = r.current, let last = r.last(cur) else { throw Self.conflict(r, "resume") }
                r.reason = nil
                switch last.state {
                case .starting, .working, .asks, .waits: r.state = .running
                case .ended, .failed, .blocked: again(&r, cur)
                case .gaps: fix(&r, review: cur)
                case .pass, .done, .skipped: next(&r, after: cur)
                }
            case .stop:
                guard r.state.isOpen else { throw Self.conflict(r, "stop") }
                for i in r.steps.indices where r.steps[i].state.isLive { r.steps[i].state = .ended; r.steps[i].ended = now() }
                r.state = .stopped
                r.reason = nil
            }
        }
    }

    public func act(_ a: StepAction, step: String, on id: RunbookRunID) throws -> RunbookRun {
        try change(id) { r in
            guard let def = r.runbook.step(step) else { throw ProviderError.notFound }
            switch a {
            case .done(let d):
                guard r.current == step, r.last(step)?.state.isLive == true else {
                    throw ProviderError.vendor(code: "409", message: "\(def.name) is not the current step. The current step is \(r.current ?? "none").")
                }
                let ok: Set<StepDone.Verdict> = def.review != nil ? [.pass, .gaps, .blocked] : [.done, .skipped, .blocked]
                guard ok.contains(d.verdict) else { throw ProviderError.vendor(code: "400", message: "\(def.name) cannot have the verdict \(d.verdict.rawValue).") }
                set(&r, step) {
                    $0.state = StepRun.State(rawValue: d.verdict.rawValue) ?? .done
                    $0.note = d.note.map { String($0.prefix(300)) }
                    $0.ended = now()
                }
                guard r.state == .running else { return }
                switch d.verdict {
                case .blocked:
                    r.state = .paused
                    r.reason = d.note ?? "The step is blocked."
                case .gaps: fix(&r, review: step)
                case .done:
                    if let review = r.runbook.review(fixedBy: step), r.last(review.id)?.state == .gaps { again(&r, review.id) } else { next(&r, after: step) }
                case .pass, .skipped: next(&r, after: step)
                }
            case .retry:
                guard r.state.isOpen else { throw Self.conflict(r, "retry") }
                r.reason = nil
                again(&r, step)
            case .skip:
                guard r.state.isOpen, let last = r.last(step), last.state == .waits || r.current == step else { throw Self.conflict(r, "skip") }
                set(&r, step) { $0.state = .skipped; $0.ended = now() }
                r.reason = nil
                r.state = .running
                next(&r, after: step)
            case .patch(let p):
                guard r.rounds(of: step).allSatisfy({ $0.started == nil }) else {
                    throw ProviderError.vendor(code: "409", message: "\(def.name) started already.")
                }
                if let agent = p.agent {
                    if let l = p.launch { r.agents[agent] = l }
                    guard r.agents[agent] != nil else { throw ProviderError.vendor(code: "400", message: "There is no agent \(agent).") }
                }
                let i = r.runbook.index(of: step)!
                if let agent = p.agent { r.runbook.steps[i].agent = agent }
                if let prompt = p.prompt { r.runbook.steps[i].prompt = prompt }
            }
        }
    }

    /// Plays the session of the current step: working, asks, or ended (no verdict).
    public func session(_ id: RunbookRunID, _ state: StepRun.State) {
        _ = try? change(id) { r in
            guard let cur = r.current, r.last(cur)?.state.isLive == true else { return }
            set(&r, cur) { $0.state = state; if !state.isLive { $0.ended = now() } }
            if state == .ended || state == .failed {
                r.state = .paused
                r.reason = "The session ended with no step done."
            }
        }
    }

    // MARK: Engine

    private static func conflict(_ r: RunbookRun, _ what: String) -> ProviderError {
        .vendor(code: "409", message: "The run is \(r.state.rawValue). It cannot \(what).")
    }

    private func change(_ body: () throws -> RunbookRun) throws -> RunbookRun {
        let (r, obs) = try with { () -> (RunbookRun, (@Sendable (RunbookRun) -> Void)?) in
            let r = try body()
            runs[r.id] = r
            return (r, observer)
        }
        obs?(r)
        return r
    }

    private func change(_ id: RunbookRunID, _ body: (inout RunbookRun) throws -> Void) throws -> RunbookRun {
        try change {
            guard var r = runs[id] else { throw ProviderError.notFound }
            try body(&r)
            r.updated = now()
            return r
        }
    }

    /// Changes the last round of the step.
    private func set(_ r: inout RunbookRun, _ step: String, _ f: (inout StepRun) -> Void) {
        guard let i = r.steps.lastIndex(where: { $0.step == step }) else { return }
        f(&r.steps[i])
    }

    /// Goes to the step at `i`: a gate when it pauses before, else a start. Past the end, the run is done.
    private func enter(_ r: inout RunbookRun, _ i: Int, approved: Bool = false) {
        guard i < r.runbook.steps.count else {
            r.state = .done
            r.current = nil
            return
        }
        let s = r.runbook.steps[i]
        r.current = s.id
        if s.pauses && !approved {
            r.state = .gate
            return
        }
        r.state = .running
        let run = r.id.rawValue
        set(&r, s.id) { $0.state = .working; $0.started = now(); $0.daemonSession = "sess-\(run)-\(s.id)-\($0.round)" }
    }

    /// The next step after `step`. A fix step of a review that passed is skipped.
    private func next(_ r: inout RunbookRun, after step: String) {
        var i = (r.runbook.index(of: step) ?? r.runbook.steps.count) + 1
        while i < r.runbook.steps.count, let review = r.runbook.review(fixedBy: r.runbook.steps[i].id), r.last(review.id)?.state == .pass {
            set(&r, r.runbook.steps[i].id) { if $0.state == .waits { $0.state = .skipped } }
            i += 1
        }
        enter(&r, i, approved: true)
    }

    /// A new round of the step, started at once.
    private func again(_ r: inout RunbookRun, _ step: String) {
        let round = (r.last(step)?.round ?? 0) + 1
        if r.last(step)?.state != .waits { r.steps.append(StepRun(step: step, round: round, state: .waits)) }
        enter(&r, r.runbook.index(of: step)!, approved: true)
    }

    /// The review found gaps: its fix step runs, else the run pauses over the round limit.
    private func fix(_ r: inout RunbookRun, review: String) {
        guard let rv = r.runbook.step(review)?.review else { return }
        if r.rounds(of: review).count > rv.rounds {
            r.state = .paused
            r.reason = "The review still finds gaps after \(r.rounds(of: review).count) rounds."
            return
        }
        again(&r, rv.fix)
    }

    // MARK: HTTP

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = .sortedKeys
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// The /v1/runbook-runs routes. nil: not a runbook route.
    func route(_ method: String, _ p: [String], query: [URLQueryItem], body: Data?) -> (Int, Data)? {
        guard p.count >= 2, p[0] == "v1", p[1] == "runbook-runs" else { return nil }
        func decode<T: Decodable>(_: T.Type) throws -> T { try Self.decoder.decode(T.self, from: body ?? Data("{}".utf8)) }
        do {
            let id = p.count > 2 ? RunbookRunID(rawValue: p[2]) : nil
            let r: any Encodable
            var status = 200
            switch (method, p.count) {
            case ("POST", 2):
                r = try start(try decode(RunbookStart.self))
                status = 201
            case ("GET", 2):
                r = list(item: query.first { $0.name == "item" }?.value, open: query.contains { $0.name == "open" && $0.value == "1" })
            case ("GET", 3): r = try get(id!)
            case ("POST", 4):
                guard let a = RunbookAction(rawValue: p[3]) else { return (404, Data(#"{"error":"not_found"}"#.utf8)) }
                r = try act(a, on: id!)
            case ("POST", 6) where p[3] == "steps":
                let a: StepAction
                switch p[5] {
                case "done": a = .done(try decode(StepDone.self))
                case "retry": a = .retry
                case "skip": a = .skip
                default: return (404, Data(#"{"error":"not_found"}"#.utf8))
                }
                r = try act(a, step: p[4], on: id!)
            case ("PATCH", 5) where p[3] == "steps": r = try act(.patch(try decode(StepPatch.self)), step: p[4], on: id!)
            default: return (404, Data(#"{"error":"not_found"}"#.utf8))
            }
            return (status, try Self.encoder.encode(r))
        } catch let e as RunbookRefusal {
            struct Body: Encodable { let error: String; let problems: [RunbookProblem] }
            return (400, (try? Self.encoder.encode(Body(error: e.message, problems: e.problems))) ?? Data())
        } catch ProviderError.notFound {
            return (404, Data(#"{"error":"not_found"}"#.utf8))
        } catch ProviderError.vendor(let code, let message) {
            return (Int(code) ?? 500, (try? Self.encoder.encode(["error": message])) ?? Data())
        } catch {
            return (400, (try? Self.encoder.encode(["error": String(describing: error)])) ?? Data())
        }
    }
}

extension FakeRuntime: RunbookRunning {
    public func startRunbook(_ s: RunbookStart) async throws -> RunbookRun {
        guard capabilities.contains(.runbooks) else { throw ProviderError.unsupported(.runbooks) }
        return try runbooks.start(s)
    }

    public func runbookRuns(item: String?, open: Bool) async throws -> [RunbookRun] { runbooks.list(item: item, open: open) }

    public func runbookRun(_ id: RunbookRunID) async throws -> RunbookRun { try runbooks.get(id) }

    public func act(_ a: RunbookAction, on id: RunbookRunID) async throws -> RunbookRun { try runbooks.act(a, on: id) }

    public func act(_ a: StepAction, step: String, on id: RunbookRunID) async throws -> RunbookRun {
        try runbooks.act(a, step: step, on: id)
    }
}
