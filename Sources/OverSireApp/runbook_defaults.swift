import OverSireCore

/// The three runbooks of a new config, and their prompts. The user can edit them.
extension Runbook {
    static let fullID = "full"
    static let strongAgent = "claude-max"

    enum Prompt {
        static let plan = "Plan {key} ({url}) in worktree group {worktree}. Ask me with AskUserQuestion when a decision is mine. Make the item detailed: logic flow, files and interfaces, test plan. For a sizeable item, make sub-items in a sensible order, each with the same detail, and set the \"blocked by\" relations. Post a plan comment on {key}. Then run {done} --verdict done --note \"<one line>\"."
        static let reviewPlan = "Review the plan of {key} and of its sub-items (round {round}). Notes so far: {notes}. Check the logic flow, the files and interfaces, the test plan and the order. Do not change the items. Post one comment on {key} with the gaps, item by item. Then run {done} --verdict pass when there are no gaps, else {done} --verdict gaps, with --note \"<one line>\"."
        static let planFixes = "Read the last review comment on {key}. Change the items so that each gap is closed. Post a comment with what changed. Then run {done} --verdict done --note \"<one line>\"."
        static let implement = "Implement {key} ({url}) in worktree group {worktree}. Read the item, its sub-items and their comments. Work the sub-items in the plan order. For each sub-item, start one sub-agent with the sub-item key and the worktree, and wait for it to finish before the next one. After each sub-item: run the tests, commit, set the sub-item to Done. Use AskUserQuestion when a decision is mine. Then run {done} --verdict done --note \"<one line>\"."
        static let review = "Read {key}, its sub-items and the comments. Check the work in {worktree} against the spec, item by item. Check that UI work matches the artifact design of the item. Run the tests. Post one comment on {key} with the gaps. Then run {done} --verdict pass or {done} --verdict gaps, with --note \"<one line>\"."
        static let fixes = "Read the last review comment on {key}. Fix each gap in {worktree}. Make sure that the tests pass. Commit. Do not merge: hand off for review. Then run {done} --verdict done --note \"<one line>\"."
    }

    /// Full, Small and Plan only. A step of claude-max uses `base` when the config has no claude-max agent.
    static func defaults(agents: Set<String>, base: String) -> [Runbook] {
        let strong = agents.contains(strongAgent) ? strongAgent : base
        let plan = RunbookStep(id: "plan", name: "Plan & Refine", agent: strong, prompt: Prompt.plan)
        let reviewPlan = RunbookStep(id: "review-plan", name: "Review Plan", agent: base, prompt: Prompt.reviewPlan,
                                     review: .init(fix: "plan-fixes"))
        let planFixes = RunbookStep(id: "plan-fixes", name: "Implement Plan Fixes", agent: strong, prompt: Prompt.planFixes)
        let review = RunbookStep(id: "review", name: "Review Implementation", agent: strong, prompt: Prompt.review,
                                 review: .init(fix: "fixes"))
        let fixes = RunbookStep(id: "fixes", name: "Implement Fixes", agent: strong, prompt: Prompt.fixes)
        return [
            Runbook(id: fullID, name: "Full", steps: [
                plan, reviewPlan, planFixes,
                RunbookStep(id: "implement", name: "Implement", agent: base, prompt: Prompt.implement, pauseBefore: true),
                review, fixes,
            ]),
            Runbook(id: "small", name: "Small", steps: [
                RunbookStep(id: "implement", name: "Implement", agent: base, prompt: Prompt.implement), review, fixes,
            ]),
            Runbook(id: "plan-only", name: "Plan only", steps: [plan, reviewPlan, planFixes]),
        ]
    }
}

extension RuntimeConfig {
    /// The names that a runbook step can name: the agents of the Start menu.
    var runbookAgents: Set<String> { Set(startAgents) }

    var defaultRunbooks: [Runbook] { Runbook.defaults(agents: runbookAgents, base: agent) }

    func runbook(_ id: String) -> Runbook? { runbooks.first { $0.id == id } }
}
