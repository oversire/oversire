import Cocoa
import OverSireCore

// ─── --uishots: the Map of the Plan tab ──────────────────────────────────────
// project-plan-map: 421 selected. project-plan-map-tip: the tip of 432, a critical item with blockers and dependents.
// project-plan-map-folded: the planned epics folded.

extension UIShots {
    func planMapScene(_ scene: String, in w: AppWindow) {
        DispatchQueue.main.async {
            guard let page = w.page as? ProjectPage, let snap = self.projectStore.snapshot("OVERSIRE") else { print("UISHOTS no project page"); return }
            let tip = scene.hasSuffix("-tip")
            PlanMapPane.preset = tip ? "OVERSIRE-432" : nil
            if scene.hasSuffix("-folded") {
                page.plan.folded = Set((snap.epics ?? []).filter { $0.state == .planned }.map(\.id))
                PlanSelection.keys["OVERSIRE"] = "OVERSIRE-432"
                PlanMapPane.scrolls["OVERSIRE"] = NSPoint(x: 0, y: 400)
                page.show(plan: .map)
            } else {
                page.show(plan: .map, focus: tip ? "OVERSIRE-432" : "OVERSIRE-421")
            }
        }
    }
}
