import Cocoa
import OverSireCore

// ─── --uishots: a part that did not load (OVERSIRE-462) ──────────────────────

extension UIShots {
    /// run:log-failed: the Log card of a run, and GitHub gives no log. The countdown to the next try runs.
    /// planner:failed: the Planner card of OVERSIRE-82 with no relations, try 2 of 3.
    /// planner:stale: the same card, and a new read failed. The old relations show.
    func refreshState(_ scene: String, in w: AppWindow) {
        switch scene {
        case "run:log-failed":
            RunPage.source = FailedLogRun()
            JobLogs.shared.raw = { _, _ in nil }
            w.router.go(.run(repo: "oversire/oversire", id: "9001"))
        case "planner:failed", "planner:stale":
            let key = "OVERSIRE-82"
            let error = "Plane did not answer."
            func rel(_ kind: RelationKind, _ k: String) -> ItemRelation? {
                projectStore.item(key: k).flatMap { $0.item.ref(in: $0.snap.summary.ref) }.map { ItemRelation(kind: kind, item: $0) }
            }
            if scene == "planner:failed" {
                projectStore.relations.seed(key, read: Read(error: error, tries: 2))
            } else {
                let old = [rel(.blockedBy, "OVERSIRE-67"), rel(.blocks, "OVERSIRE-88")].compactMap { $0 }
                projectStore.relations.seed(key, read: Read(value: old, at: Date().addingTimeInterval(-4 * 60), error: error, tries: 1))
            }
            w.router.go(.item(key, .overview))
        default:
            print("UISHOTS no refresh scene \(scene)")
        }
    }

    /// One failed run with two jobs. The log of the failed job never comes.
    struct FailedLogRun: RunSource {
        func run(_ repo: String, id: String) async -> Run? {
            Run(id: id, name: "CI", displayTitle: "Keep the diff after a failed read", status: "completed", conclusion: "failure", headBranch: "oversire-462",
                headSha: "fdfb5d4a1c2", event: "push", url: "https://github.com/\(repo)/actions/runs/\(id)", updatedAt: "2026-11-12T14:06:00Z",
                createdAt: "2026-11-12T14:00:00Z", startedAt: "2026-11-12T14:00:00Z", number: 412, workflowName: "CI", actorLogin: "fritz")
        }

        func jobs(_ repo: String, runId: String) async -> [Job]? {
            [Job(id: "1", name: "build", status: "completed", conclusion: "success", url: "https://github.com/\(repo)/actions/runs/\(runId)/job/1",
                 startedAt: "2026-11-12T14:00:00Z", completedAt: "2026-11-12T14:03:00Z", runnerName: nil, steps: nil),
             Job(id: "2", name: "test", status: "completed", conclusion: "failure", url: "https://github.com/\(repo)/actions/runs/\(runId)/job/2",
                 startedAt: "2026-11-12T14:00:00Z", completedAt: "2026-11-12T14:05:00Z", runnerName: nil, steps: nil)]
        }
    }
}
