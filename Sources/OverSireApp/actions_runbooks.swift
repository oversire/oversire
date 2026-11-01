import Foundation
import OverSireCore
import OverSireAI
import OverSireAssistant

// The runbook actions: the runbooks of config.json (RunbookUndo) and the runs on the sessions machine (RunbookBook).
struct RunbookActions {
    let link: ActionLink
    var runtime: () -> (any RunbookRunning)? = { ENV.runtime as? any RunbookRunning }
    var undo = RUNBOOK_UNDO
    var book = RUNBOOKS

    static let id: (String, String) = ("string", "The runbook id, for example full.")
    static let runbook: (String, String) = ("object", "The runbook: {id?, name, steps: [{id?, name, agent, prompt, pauseBefore?, review?: {fix, rounds}}]}.")
    static let rules = "Rules: ids use only a-z, 0-9 and - (a missing id comes from the name). Each step has a name, an agent of runbook.get `agents`, "
        + "and a prompt with {done}. Placeholders: {key} item key, {url} item link, {title}, {item} item id, {workspace} tracker workspace, "
        + "{project} project key, {round} review round, {notes} the notes of the steps before, {worktree} .wt/<key>, {done} the command that ends the step. "
        + "The first step cannot pause before. A review step has review {fix: a later step that is not a review, rounds: 0 to \(Runbook.maxRounds)}; "
        + "a fix step serves one review. Verdicts: a review ends with pass or gaps (gaps runs the fix step, then the review again), "
        + "the other steps with done; blocked pauses the run for the user. The steps get the item and the notes through the tracker."

    var specs: [ActionSpec] {
        [list, get, validate, create, update, delete, setDefault, undoLast, start, status]
            + RunbookAction.allCases.map(runAction) + [retry, skip, markDone]
    }

    // MARK: Runbooks

    private var list: ActionSpec {
        let link = link
        return ActionSpec(id: "runbook.list", title: "Runbooks", help: "Lists the runbooks: id, name, step names, and the projects that use each one as default.",
                          kind: .read) { _ in
            await link.run { d, done in
                let cfg = PROJECTS_CFG
                let keys = d.projectStore.snapshots.values.map(\.summary.identifier).sorted()
                let rows: [JSONValue] = cfg.runtime.runbooks.map { b in
                    .object(["id": .string(b.id), "name": .string(b.name), "steps": .array(b.steps.map { .string($0.name) }),
                             "defaultOf": .array(keys.filter { cfg.runbook(for: $0)?.id == b.id }.map { .string($0) })])
                }
                done(.ok(summary: cfg.runtime.runbooks.map(\.name).joined(separator: ", "), data: .array(rows)))
            }
        }
    }

    private var get: ActionSpec {
        let link = link
        return ActionSpec(id: "runbook.get", title: "Runbook", help: "Reads one runbook as JSON, and `agents`: the agent names that a step can use.",
                          kind: .read, input: ActionSpec.args(["id": Self.id], required: ["id"])) { a in
            await link.run { _, done in
                guard let b = Self.find(a.string("id")) else { done(Self.unknown(a.string("id"))); return }
                var o = JSONValue(encoding: b)?.object ?? [:]
                o["agents"] = .array(PROJECTS_CFG.runtime.runbookAgents.sorted().map { .string($0) })
                done(.ok(summary: "\(b.name): \(b.steps.map(\.name).joined(separator: " → "))", data: .object(o)))
            }
        }
    }

    private var validate: ActionSpec {
        let link = link
        return ActionSpec(id: "runbook.validate", title: "Check runbook", help: "Checks a runbook (JSON) or a saved runbook (id) and lists its problems. " + Self.rules,
                          kind: .read, input: ActionSpec.args(["id": Self.id, "runbook": Self.runbook])) { a in
            await link.run { _, done in
                let b: Runbook
                if let v = a.values["runbook"] {
                    do { b = try Runbook.draft(v) } catch { done(.notAllowed(Self.why(error))); return }
                } else {
                    guard let found = Self.find(a.string("id")) else { done(Self.unknown(a.string("id"))); return }
                    b = found
                }
                let problems = b.validate(agents: PROJECTS_CFG.runtime.runbookAgents)
                done(.ok(summary: problems.isEmpty ? "✓ Valid: \(b.steps.map(\.name).joined(separator: " → "))." : Self.text(problems),
                         data: .object(["valid": .bool(problems.isEmpty), "problems": JSONValue(encoding: problems) ?? .array([])])))
            }
        }
    }

    private var create: ActionSpec {
        let link = link, undo = undo
        return ActionSpec(id: "runbook.create", title: "New runbook", help: "Makes a runbook. It refuses a runbook with problems and saves nothing. " + Self.rules,
                          kind: .change, input: ActionSpec.args(["runbook": Self.runbook], required: ["runbook"])) { a in
            await link.run { _, done in
                guard let v = a.values["runbook"] else { done(.notAllowed("Give the runbook.")); return }
                let b: Runbook
                do { b = try Runbook.draft(v) } catch { done(.notAllowed(Self.why(error))); return }
                guard Self.find(b.id) == nil else { done(.notAllowed("There is a runbook with the id \(b.id) already. Use runbook.update.")); return }
                if let refused = Self.refusal(b) { done(refused); return }
                undo.change("New \(b.name)") { $0.runtime.runbooks.append(b) }
                done(.ok(summary: "\(b.name) is saved (id \(b.id)).", data: JSONValue(encoding: b)))
            }
        }
    }

    private var update: ActionSpec {
        let link = link, undo = undo
        return ActionSpec(id: "runbook.update", title: "Change runbook",
                          help: "Changes a runbook. Give `runbook` (the full runbook) or `patch`: a list of {op: add, step, after?} (after: a step id, \"\" for the start; "
                            + "no after: the end), {op: remove, step: id}, {op: move, step: id, after}, {op: set, step: id, name?, agent?, prompt?, pauseBefore?, review?} "
                            + "(review null removes it), {op: rename, name}. It refuses a result with problems and saves nothing. " + Self.rules,
                          kind: .change, input: Self.updateInput) { a in
            await link.run { _, done in
                guard let old = Self.find(a.string("id")) else { done(Self.unknown(a.string("id"))); return }
                var b = old
                do {
                    if let v = a.values["runbook"] {
                        b = try Runbook.draft(v)
                        b.id = old.id
                    } else if let ops = a.values["patch"]?.array {
                        for op in ops { try b.apply(op.string.map { try JSONValue(parsing: $0) } ?? op) }
                    } else { done(.notAllowed("Give `runbook` or `patch`.")); return }
                } catch { done(.notAllowed(Self.why(error))); return }
                guard b != old else { done(.ok(summary: "\(b.name) did not change.")); return }
                if let refused = Self.refusal(b) { done(refused); return }
                undo.change("Change \(old.name)") { c in
                    if let i = c.runtime.runbooks.firstIndex(where: { $0.id == old.id }) { c.runtime.runbooks[i] = b }
                }
                done(.ok(summary: "\(b.name) is saved: \(b.steps.map(\.name).joined(separator: " → ")).", data: JSONValue(encoding: b)))
            }
        }
    }

    private var delete: ActionSpec {
        let link = link, undo = undo, book = book
        return ActionSpec(id: "runbook.delete", title: "Delete runbook", help: "Deletes a runbook. The projects that use it go back to Ship. "
                            + "It refuses the last runbook, and a runbook of an open run or of a queue entry. runbook.undo brings it back.",
                          kind: .outward, input: ActionSpec.args(["id": Self.id], required: ["id"])) { a in
            await link.run { d, done in
                guard let b = Self.find(a.string("id")) else { done(Self.unknown(a.string("id"))); return }
                if let why = Self.deleteRefusal(b, book: book, queue: d.queue) { done(.notAllowed(why)); return }
                undo.change("Delete \(b.name)") { $0.removeRunbook(b.id) }
                done(.ok(summary: "\(b.name) is deleted."))
            }
        }
    }

    private var setDefault: ActionSpec {
        let link = link, undo = undo
        return ActionSpec(id: "runbook.setDefault", title: "Set default runbook", help: "Sets the runbook that a start of an item of the project uses.",
                          kind: .change, input: ActionSpec.args(["project": ItemActions.project, "id": Self.id], required: ["project", "id"])) { a in
            await link.run { d, done in
                guard let snap = d.projectStore.snapshot(a.string("project") ?? "") else {
                    done(.notAllowed("OverSire has no loaded project \(a.string("project") ?? "").")); return
                }
                guard let b = Self.find(a.string("id")) else { done(Self.unknown(a.string("id"))); return }
                let key = snap.summary.identifier
                undo.change("Default of \(key)") { $0.setRunbook(b.id, for: key) }
                done(.ok(summary: "\(key) uses \(b.name)."))
            }
        }
    }

    private var undoLast: ActionSpec {
        let link = link, undo = undo
        return ActionSpec(id: "runbook.undo", title: "Undo runbook change", help: "Reverts the last runbook change of the editor or of the assistant.",
                          kind: .change) { _ in
            await link.run { _, done in
                guard let label = undo.undo() else { done(.notAllowed("There is no runbook change to undo.")); return }
                done(.ok(summary: "Undid: \(label)."))
            }
        }
    }

    // MARK: Runs

    private var start: ActionSpec {
        let link = link, runtime = runtime, book = book
        return ActionSpec(id: "runbook.start", title: "Run runbook", help: "Starts a runbook run on the item, on the sessions machine. "
                            + "`id`: the runbook (default: the default of the project). `at`: the first step; the steps before are skipped.",
                          kind: .outward, input: ActionSpec.args(["key": ItemActions.key, "id": Self.id, "at": ("string", "A step id.")], required: ["key"]),
                          capability: .runbooks) { a in
            typealias Picked = (book: Runbook, item: Item, summary: ProjectSummary)
            let picked: Result<Picked, ActionError> = await link.main(.failure(ActionError("The app is closing."))) { d, done in
                guard let key = a.string("key")?.uppercased(), let f = d.projectStore.item(key: key) else {
                    done(.failure(ActionError("OverSire has no loaded item \(a.string("key") ?? "")."))); return
                }
                if let r = book.run(for: key), r.state.isOpen {
                    done(.failure(ActionError("\(key) has an open run of \(r.runbook.name). Stop it first."))); return
                }
                let id = a.string("id")
                guard let b = id.map({ Self.find($0) }) ?? PROJECTS_CFG.runbook(for: f.snap.summary.identifier) else {
                    done(.failure(ActionError(Self.unknown(id).summary))); return
                }
                if let at = a.string("at"), b.step(at) == nil { done(.failure(ActionError("\(b.name) has no step \(at)."))); return }
                done(.success((b, f.item, f.snap.summary)))
            }
            guard case .success(let p) = picked else {
                if case .failure(let e) = picked { return .notAllowed(e.text) }
                return .failed("The app is closing.")
            }
            var starter = RunbookStarter()
            starter.runtime = runtime
            do {
                let r = try await starter.start(p.book, item: p.item, in: p.summary, at: a.string("at"))
                await link.run { _, done in book.apply(r); done(.ok(summary: "")) }
                return .ok(summary: Self.line(r), data: r.brief)
            } catch { return .failed(Self.why(error)) }
        }
    }

    private var status: ActionSpec {
        let link = link, runtime = runtime, book = book
        return ActionSpec(id: "runbook.status", title: "Runbook run", help: "Reads the last runbook run of an item: its state, the current step, and each step with its rounds, verdict and note.",
                          kind: .read, input: ActionSpec.args(["key": ItemActions.key], required: ["key"]), capability: .runbooks) { a in
            guard let key = a.string("key")?.uppercased(), !key.isEmpty else { return .notAllowed("Give the key of an item, for example OVERSIRE-12.") }
            if let rt = runtime(), let r = (try? await rt.runbookRuns(item: key, open: false))?.max(by: { $0.started < $1.started }) {
                await link.run { _, done in book.apply(r); done(.ok(summary: "")) }
            }
            return await link.run { _, done in
                guard let r = book.run(for: key) else { done(.notAllowed("\(key) has no runbook run.")); return }
                done(.ok(summary: Self.line(r), data: r.brief))
            }
        }
    }

    private func runAction(_ act: RunbookAction) -> ActionSpec {
        let (title, help, kind): (String, String, ActionKind) = switch act {
        case .approve: ("Approve step", "Approves the gate of the run of the item: the step that waits starts.", .change)
        case .pause: ("Pause runbook", "Pauses the run of the item. The live step goes on; the next step does not start.", .change)
        case .resume: ("Resume runbook", "Resumes a paused run. After the round limit it runs one more fix and review round.", .change)
        case .stop: ("Stop runbook", "Stops the run of the item for good. The live step session stays open.", .outward)
        }
        return runSpec("runbook.\(act.rawValue)", title, help, kind) { _, rt, r, _ in try await rt.act(act, on: r.id) }
    }

    private var retry: ActionSpec {
        runSpec("runbook.retry", "Retry step", "Runs the step again in a new session. `step`: default the current step.", .change, step: true) { _, rt, r, s in
            try await rt.act(.retry, step: s, on: r.id)
        }
    }

    private var skip: ActionSpec {
        runSpec("runbook.skip", "Skip step", "Skips the step and goes on with the next one. `step`: default the current step.", .change, step: true) { _, rt, r, s in
            try await rt.act(.skip, step: s, on: r.id)
        }
    }

    private var markDone: ActionSpec {
        runSpec("runbook.markDone", "Mark step done", "Ends the step for the agent, as `oversire step done` does. `verdict`: pass or gaps for a review, "
                + "done for the other steps, blocked to pause the run. `note`: one line.", .change, step: true,
                extra: ["verdict": ("string", "pass, gaps, done or blocked."), "note": ("string", "One line.")]) { a, rt, r, s in
            let review = r.runbook.step(s)?.review != nil
            let word = a.string("verdict")?.lowercased() ?? (review ? "" : "done")
            guard let v = StepDone.Verdict(rawValue: word), v != .skipped else {
                throw ActionError(review ? "Give the verdict of the review: pass, gaps or blocked." : "The verdict must be done or blocked.")
            }
            if review ? v == .done : [.pass, .gaps].contains(v) {
                throw ActionError(review ? "A review ends with pass, gaps or blocked." : "Only a review ends with pass or gaps.")
            }
            return try await rt.act(.done(StepDone(verdict: v, note: a.string("note"))), step: s, on: r.id)
        }
    }

    /// An action on the open run of the `key` item. `step`: the action takes a step, default the current one.
    private func runSpec(_ id: String, _ title: String, _ help: String, _ kind: ActionKind, step: Bool = false,
                         extra: [String: (String, String)] = [:],
                         _ body: @escaping @Sendable (ActionArgs, any RunbookRunning, RunbookRun, String) async throws -> RunbookRun) -> ActionSpec {
        let link = link, runtime = runtime, book = book
        var props: [String: (String, String)] = ["key": ItemActions.key]
        if step { props["step"] = ("string", "A step id. Default: the current step.") }
        props.merge(extra) { a, _ in a }
        return ActionSpec(id: id, title: title, help: help, kind: kind, input: ActionSpec.args(props, required: ["key"]), capability: .runbooks) { a in
            guard let key = a.string("key")?.uppercased(), !key.isEmpty else { return .notAllowed("Give the key of an item, for example OVERSIRE-12.") }
            let run: RunbookRun? = await link.main(nil) { _, done in done(book.run(for: key)) }
            guard let r = run, r.state.isOpen else { return .notAllowed("\(key) has no open runbook run.") }
            guard let rt = runtime(), rt.capabilities.contains(.runbooks) else { return .notAllowed(SessionStartError.noRunbooks.localizedDescription) }
            let s = a.string("step") ?? r.current ?? ""
            if step, r.runbook.step(s) == nil { return .notAllowed("\(r.runbook.name) has no step \(s.isEmpty ? "that runs now" : s).") }
            do {
                let next = try await body(a, rt, r, s)
                await link.run { _, done in book.apply(next); done(.ok(summary: "")) }
                return .ok(summary: Self.line(next), data: next.brief)
            } catch let e as ActionError {
                return .notAllowed(e.text)
            } catch { return .failed(Self.why(error)) }
        }
    }

    // MARK: Parts

    /// The patch ops are objects, not the string items of ActionSpec.args.
    private static var updateInput: JSONValue {
        var o = ActionSpec.args(["id": id, "runbook": runbook, "patch": ("array", "The changes, in order.")], required: ["id"]).object ?? [:]
        var props = o["properties"]?.object ?? [:]
        var patch = props["patch"]?.object ?? [:]
        patch["items"] = .object(["type": .string("object")])
        props["patch"] = .object(patch)
        o["properties"] = .object(props)
        return .object(o)
    }

    private static func find(_ id: String?) -> Runbook? { id.flatMap { PROJECTS_CFG.runtime.runbook($0.lowercased()) } }

    static func unknown(_ id: String?) -> ActionResult {
        .notAllowed("There is no runbook \(id ?? ""). The runbooks: \(PROJECTS_CFG.runtime.runbooks.map(\.id).joined(separator: ", ")).")
    }

    private static func refusal(_ b: Runbook) -> ActionResult? {
        let problems = b.validate(agents: PROJECTS_CFG.runtime.runbookAgents)
        return problems.isEmpty ? nil : .notAllowed("\(b.name.isEmpty ? b.id : b.name) has problems. Nothing is saved.\n" + text(problems))
    }

    private static func text(_ problems: [RunbookProblem]) -> String { problems.map { "! \($0.text)" }.joined(separator: "\n") }

    /// "Ship on OVERSIRE-349: Implement (step 1 of 3), working."
    static func line(_ r: RunbookRun) -> String {
        let step = r.current.flatMap(r.runbook.step).map { s in " \(s.name) (step \(r.position ?? 0) of \(r.runbook.steps.count))," } ?? ""
        let state = r.current.flatMap(r.last)?.state.rawValue
        let word = r.state == .running ? state ?? "running" : r.state == .gate ? "waits for your approval" : r.state.rawValue
        return "\(r.runbook.name) on \(r.item.key):\(step) \(word)." + (r.reason.map { " \($0)" } ?? "")
    }

    static func why(_ e: Error) -> String {
        switch e {
        case let r as RunbookRefusal: return ([r.message] + r.problems.map { "! \($0.text)" }).joined(separator: "\n")
        case let p as ProviderError: return p.message
        case let d as DecodingError:
            switch d {
            case .keyNotFound(let k, let c): return "The runbook has no \((c.codingPath.map(\.stringValue) + [k.stringValue]).joined(separator: "."))."
            case .typeMismatch(_, let c), .valueNotFound(_, let c), .dataCorrupted(let c):
                return "The runbook JSON is not valid at \(c.codingPath.map(\.stringValue).joined(separator: "."))."
            @unknown default: return "The runbook JSON is not valid."
            }
        case let a as ActionError: return a.text
        default: return e.localizedDescription
        }
    }
}

extension RunbookActions {
    /// Why `b` cannot go: the last runbook, or a runbook of an open run or of a queue entry. The editor asks the same.
    static func deleteRefusal(_ b: Runbook, book: RunbookBook, queue: WorkQueue) -> String? {
        guard PROJECTS_CFG.runtime.runbooks.count > 1 else { return "\(b.name) is the last runbook." }
        if let r = book.open.first(where: { $0.runbook.id == b.id }) { return "\(r.item.key) has an open run of \(b.name). Stop the run first." }
        if let e = queue.lanes.flatMap(\.entries).first(where: { $0.runbook == b.id }) { return "\(e.key) waits in the queue with \(b.name)." }
        return nil
    }
}

extension ProjectsConfig {
    /// Removes the runbook. The projects that use it go back to Ship.
    mutating func removeRunbook(_ id: String) {
        runtime.runbooks.removeAll { $0.id == id }
        for (k, l) in settings where l.runbook == id { settings[k]?.runbook = nil }
    }
}

/// A refusal with a reason for the user.
struct ActionError: Error, Sendable {
    let text: String
    init(_ text: String) { self.text = text }
}

extension Runbook {
    /// A runbook from the JSON of an action. A missing id comes from the name.
    static func draft(_ v: JSONValue) throws -> Runbook {
        let v = try v.string.map { try JSONValue(parsing: $0) } ?? v
        guard var o = v.object else { throw ActionError("The runbook must be a JSON object.") }
        if o["id"]?.string?.isEmpty ?? true { o["id"] = .string(slug(o["name"]?.string ?? "")) }
        o["steps"] = .array((o["steps"]?.array ?? []).map(RunbookStep.filled))
        return try JSONDecoder().decode(Runbook.self, from: Data(JSONValue.object(o).text.utf8))
    }

    /// "Plan & Refine" → "plan-refine".
    static func slug(_ name: String) -> String {
        name.lowercased().split { !("a"..."z").contains($0) && !("0"..."9").contains($0) }.joined(separator: "-")
    }

    /// One op of runbook.update.
    mutating func apply(_ op: JSONValue) throws {
        let step = op["step"]
        func at(_ id: String) throws -> Int {
            guard let i = index(of: id) else { throw ActionError("\(name) has no step \(id).") }
            return i
        }
        func after() throws -> Int {
            guard let a = op["after"]?.string else { return steps.count }
            return a.isEmpty ? 0 : try at(a) + 1
        }
        switch op["op"]?.string {
        case "add":
            guard let v = step else { throw ActionError("An add needs `step`.") }
            let s = try JSONDecoder().decode(RunbookStep.self, from: Data(RunbookStep.filled(v).text.utf8))
            steps.insert(s, at: try after())
        case "remove":
            steps.remove(at: try at(step?.string ?? ""))
        case "move":
            let s = steps.remove(at: try at(step?.string ?? ""))
            steps.insert(s, at: min(try after(), steps.count))
        case "set":
            let i = try at(step?.string ?? "")
            if let v = op["name"]?.string { steps[i].name = v }
            if let v = op["agent"]?.string { steps[i].agent = v }
            if let v = op["prompt"]?.string { steps[i].prompt = v }
            if let v = op["pauseBefore"]?.bool { steps[i].pauseBefore = v ? true : nil }
            if let v = op["review"] {
                steps[i].review = v == .null ? nil : try JSONDecoder().decode(RunbookStep.Review.self, from: Data(v.text.utf8))
            }
        case "rename":
            guard let v = op["name"]?.string else { throw ActionError("A rename needs `name`.") }
            name = v
        default:
            throw ActionError("The op must be add, remove, move, set or rename.")
        }
    }
}

extension RunbookStep {
    /// A step object with an id from its name when it has none.
    fileprivate static func filled(_ v: JSONValue) -> JSONValue {
        guard var o = v.object else { return v }
        if o["id"]?.string?.isEmpty ?? true { o["id"] = .string(Runbook.slug(o["name"]?.string ?? "")) }
        return .object(o)
    }
}

extension RunbookRun {
    /// The compact JSON of runbook.status: no prompts, no launch specs.
    var brief: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id.rawValue), "key": .string(item.key), "runbook": .string(runbook.name),
                                      "state": .string(state.rawValue), "machine": .string(machine.rawValue)]
        if let current { o["current"] = .string(current) }
        if let reason { o["reason"] = .string(reason) }
        o["steps"] = .array(runbook.steps.map { s in
            var x: [String: JSONValue] = ["id": .string(s.id), "name": .string(s.name), "agent": .string(s.agent)]
            let rounds = self.rounds(of: s.id)
            x["state"] = .string(rounds.last?.state.rawValue ?? "waits")
            if rounds.count > 1 { x["rounds"] = .int(rounds.count) }
            if let n = rounds.last?.note { x["note"] = .string(n) }
            if let a = rounds.last?.started { x["minutes"] = .int(Int(((rounds.last?.ended ?? Date()).timeIntervalSince(a)) / 60)) }
            return .object(x)
        })
        return .object(o)
    }
}
