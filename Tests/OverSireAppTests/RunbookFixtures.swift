import OverSireCore
@testable import OverSireApp

extension Runbook {
    /// Full, Small and Plan only: the defaults before OVERSIRE-373. The editor and action tests use them as user runbooks.
    static func oldDefaults(agents: Set<String>, base: String) -> [Runbook] {
        let strong = agents.contains(strongAgent) ? strongAgent : base
        let p = oldPrompts
        let plan = RunbookStep(id: "plan", name: "Plan & Refine", agent: strong, prompt: p["plan"]!)
        let reviewPlan = RunbookStep(id: "review-plan", name: "Review Plan", agent: base, prompt: p["review-plan"]!, review: .init(fix: "plan-fixes"))
        let planFixes = RunbookStep(id: "plan-fixes", name: "Implement Plan Fixes", agent: strong, prompt: p["plan-fixes"]!)
        let review = RunbookStep(id: "review", name: "Review Implementation", agent: strong, prompt: p["review"]!, review: .init(fix: "fixes"))
        let fixes = RunbookStep(id: "fixes", name: "Implement Fixes", agent: strong, prompt: p["fixes"]!)
        return [
            Runbook(id: "full", name: "Full", steps: [
                plan, reviewPlan, planFixes,
                RunbookStep(id: "implement", name: "Implement", agent: base, prompt: p["implement"]!, pauseBefore: true), review, fixes,
            ]),
            Runbook(id: "small", name: "Small", steps: [RunbookStep(id: "implement", name: "Implement", agent: base, prompt: p["implement"]!), review, fixes]),
            Runbook(id: "plan-only", name: "Plan only", steps: [plan, reviewPlan, planFixes]),
        ]
    }
}

extension RuntimeConfig {
    var oldRunbooks: [Runbook] { Runbook.oldDefaults(agents: runbookAgents, base: agent) }
}
