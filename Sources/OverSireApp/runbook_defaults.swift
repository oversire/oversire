import OverSireCore

/// The two runbooks of a new config, Plan and Ship (OVERSIRE-373), and their prompts. The user can edit them.
/// Each runbook ends at the review gate: the agent runs `oversire review ready`, and the user reviews in Work › Review.
extension Runbook {
    static let planID = "plan"
    static let shipID = "ship"
    static let strongAgent = "claude-max"
    /// The ids before OVERSIRE-373. A config or a queue entry that names one gets the new runbook.
    static let aliases = ["full": shipID, "small": shipID, "plan-only": planID]

    enum Prompt {
        static let planFile = ".oversire/plans/{key}.md"
        static let planReady = "oversire review ready --key {key} --kind plan --plan \(planFile) --note \"<one line>\""
        static let codeReady = "oversire review ready --key {key} --kind code --note \"<one line>\""

        static let plan = "Plan {key} ({url}). Do not write code. Ask me with AskUserQuestion when a decision is mine. "
            + "Write the plan to \(planFile), with a ## heading for each part: logic flow, files and interfaces, test plan, order. "
            + "For a sizeable item, make sub-items in a sensible order, each with the same detail, and set the \"blocked by\" relations. "
            + "Post the plan as a comment on {key}. Then run {done} --verdict done --note \"<one line>\"."
        static let reviewPlan = "Review the plan of {key} and of its sub-items (round {round}). Notes so far: {notes}. "
            + "Check the logic flow, the files and interfaces, the test plan and the order. Do not change the items. "
            + "Post one comment on {key} with the gaps, item by item. When there are no gaps, run \(planReady), then {done} --verdict pass. "
            + "Else run {done} --verdict gaps. Give --note \"<one line>\" to {done}."
        static let planFixes = "Read the last review comment on {key}. Change \(planFile) and the items so that each gap is closed. "
            + "Post a comment with what changed. Then run \(planReady), and {done} --verdict done --note \"<one line>\"."
        static let implement = "Implement {key} ({url}) in worktree group {group}. Read the item, its sub-items and their comments. "
            + "Work the sub-items in the plan order, one after the other, in the same group. For each sub-item, start one sub-agent "
            + "with the sub-item key and the group, and wait for it to finish before the next one. After each sub-item: run the tests, "
            + "commit with an \"Item: <sub-item key>\" line, set the sub-item to Needs Review. Do not merge. "
            + "Use AskUserQuestion when a decision is mine. Then run {done} --verdict done --note \"<one line>\"."
        static let review = "Read {key}, its sub-items and the comments. Check the work in {group} against the spec, item by item. "
            + "Check that UI work matches the artifact design of the item. Run the tests. Post one comment on {key} with the gaps. "
            + "When there are no gaps, run \(codeReady), then {done} --verdict pass. Else run {done} --verdict gaps. Give --note \"<one line>\" to {done}."
        static let fixes = "Read the last review comment on {key}. Fix each gap in {group}. Make sure that the tests pass. Commit. "
            + "Do not merge: hand off for review. Run \(codeReady), then {done} --verdict done --note \"<one line>\"."
    }

    /// Plan and Ship. A step of claude-max uses `base` when the config has no claude-max agent.
    static func defaults(agents: Set<String>, base: String) -> [Runbook] {
        let strong = agents.contains(strongAgent) ? strongAgent : base
        return [
            Runbook(id: planID, name: "Plan", steps: [
                RunbookStep(id: "plan", name: "Plan", agent: strong, prompt: Prompt.plan),
                RunbookStep(id: "review-plan", name: "Review Plan", agent: base, prompt: Prompt.reviewPlan, review: .init(fix: "plan-fixes")),
                RunbookStep(id: "plan-fixes", name: "Implement Plan Fixes", agent: strong, prompt: Prompt.planFixes),
            ]),
            Runbook(id: shipID, name: "Ship", steps: [
                RunbookStep(id: "implement", name: "Implement", agent: base, prompt: Prompt.implement),
                RunbookStep(id: "review", name: "Review Implementation", agent: strong, prompt: Prompt.review, review: .init(fix: "fixes")),
                RunbookStep(id: "fixes", name: "Implement Fixes", agent: strong, prompt: Prompt.fixes),
            ]),
        ]
    }

    /// Plan, a gate, then Ship, as one runbook. The sample of `--uishots` and of the tests: one run with all steps.
    static func planAndShip(_ rt: RuntimeConfig) -> Runbook {
        let books = rt.defaultRunbooks
        var steps = books.flatMap(\.steps)
        if let i = steps.firstIndex(where: { $0.id == "implement" }) { steps[i].pauseBefore = true }
        return Runbook(id: "plan-ship", name: "Plan and Ship", steps: steps)
    }

    /// The default prompts before OVERSIRE-373, by step id. A step with one of them gets the new default.
    static let oldPrompts: [String: String] = [
        "plan": "Plan {key} ({url}) in worktree group {worktree}. Ask me with AskUserQuestion when a decision is mine. Make the item detailed: logic flow, files and interfaces, test plan. For a sizeable item, make sub-items in a sensible order, each with the same detail, and set the \"blocked by\" relations. Post a plan comment on {key}. Then run {done} --verdict done --note \"<one line>\".",
        "review-plan": "Review the plan of {key} and of its sub-items (round {round}). Notes so far: {notes}. Check the logic flow, the files and interfaces, the test plan and the order. Do not change the items. Post one comment on {key} with the gaps, item by item. Then run {done} --verdict pass when there are no gaps, else {done} --verdict gaps, with --note \"<one line>\".",
        "plan-fixes": "Read the last review comment on {key}. Change the items so that each gap is closed. Post a comment with what changed. Then run {done} --verdict done --note \"<one line>\".",
        "implement": "Implement {key} ({url}) in worktree group {worktree}. Read the item, its sub-items and their comments. Work the sub-items in the plan order. For each sub-item, start one sub-agent with the sub-item key and the worktree, and wait for it to finish before the next one. After each sub-item: run the tests, commit, set the sub-item to Done. Use AskUserQuestion when a decision is mine. Then run {done} --verdict done --note \"<one line>\".",
        "review": "Read {key}, its sub-items and the comments. Check the work in {worktree} against the spec, item by item. Check that UI work matches the artifact design of the item. Run the tests. Post one comment on {key} with the gaps. Then run {done} --verdict pass or {done} --verdict gaps, with --note \"<one line>\".",
        "fixes": "Read the last review comment on {key}. Fix each gap in {worktree}. Make sure that the tests pass. Commit. Do not merge: hand off for review. Then run {done} --verdict done --note \"<one line>\".",
    ]
}

extension RuntimeConfig {
    /// The names that a runbook step can name: the agents of the Start menu.
    var runbookAgents: Set<String> { Set(startAgents) }

    var defaultRunbooks: [Runbook] { Runbook.defaults(agents: runbookAgents, base: agent) }

    /// An old id (full, small, plan-only) finds its new runbook when the config has no runbook of that id.
    func runbook(_ id: String) -> Runbook? {
        runbooks.first { $0.id == id } ?? Runbook.aliases[id].flatMap { new in runbooks.first { $0.id == new } }
    }

    /// The split of OVERSIRE-373. Full becomes Ship from its implement step on, Plan only becomes Plan.
    /// A Small with the old default steps goes: Ship is the same. Edited steps stay, an old default prompt gets the new one.
    /// Returns a note for the user, or nil when there was nothing to move.
    static func migrate(_ books: [Runbook], defaults: [Runbook]) -> (books: [Runbook], note: String?) {
        let ids = Set(books.map(\.id))
        guard ids.contains(where: { Runbook.aliases[$0] != nil }), !ids.contains(Runbook.planID), !ids.contains(Runbook.shipID) else { return (books, nil) }
        let fresh = Dictionary(uniqueKeysWithValues: defaults.flatMap(\.steps).map { ($0.id, $0.prompt) })
        func renew(_ steps: [RunbookStep]) -> [RunbookStep] {
            steps.map { s in
                var s = s
                if Runbook.oldPrompts[s.id] == s.prompt, let p = fresh[s.id] { s.prompt = p }
                return s
            }
        }
        let oldSmall = ["implement", "review", "fixes"]
        var out: [Runbook] = []
        var moved: [String] = []
        for b in books {
            switch b.id {
            case "full":
                var steps = Array(b.steps.drop { $0.id != "implement" })
                if steps.isEmpty { steps = b.steps }
                steps[0].pauseBefore = nil
                out.append(Runbook(id: Runbook.shipID, name: "Ship", steps: renew(steps)))
                moved.append("Full → Ship")
            case "plan-only":
                out.append(Runbook(id: Runbook.planID, name: "Plan", steps: renew(b.steps)))
                moved.append("Plan only → Plan")
            case "small" where b.steps.map(\.id) == oldSmall && b.steps.allSatisfy({ Runbook.oldPrompts[$0.id] == $0.prompt }):
                moved.append("Small → Ship")
            default:
                out.append(b)
            }
        }
        for d in defaults where !out.contains(where: { $0.id == d.id }) { out.append(d) }
        let first = [Runbook.planID, Runbook.shipID]
        out = out.filter { first.contains($0.id) }.sorted { $0.id == Runbook.planID && $1.id != Runbook.planID } + out.filter { !first.contains($0.id) }
        return (out, "The runbooks are now Plan and Ship: " + moved.joined(separator: ", ")
                + ". Plan ends at the plan review, Ship ends at the code review. Queue entries and projects that named the old runbooks use the new ones.")
    }
}
