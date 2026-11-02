import Cocoa
import OverSireCore

// ─── --uishots: the item journey ─────────────────────────────────────────────
// The sample rows of journey_sample.swift go straight into JOURNAL and RECAPS, with no daemon reads and no AI.

extension UIShots {
    /// journey:full, folded, noai or timeline, cut, real, tip-mark, tip-bar, tip-cut,
    /// or an open Timeline row: detail-comment, detail-raw, detail-payload, detail-ci (OVERSIRE-398).
    func journeyState(_ scene: String, in w: AppWindow) {
        let now = Date()
        var rows = JourneySample.rows(now: now, folded: scene == "folded")
        if scene.hasPrefix("detail-") { rows += openRow(scene, now: now) }
        JOURNAL.reads = false
        JOURNAL.lookPath = nil
        JOURNAL.seed(JourneySample.key, rows)
        RECAPS.path = nil
        RECAPS.ai = { nil }
        if scene == "full" {
            let since = JourneySample.since(now: now)
            let fresh = ItemJournal.merge([], rows).filter { $0.at > since && $0.kind != .itemViewed }
            var r = JourneySample.recap(rows: rows)
            r.hash = Recap.hash(fresh)
            RECAPS.put(JourneySample.key, r)
        }
        let timeline = !["full", "folded", "noai"].contains(scene)
        if timeline { TimelineGraphView.preset = TimelineGraphView.Preset(scene: scene) }
        w.router.go(.item(JourneySample.key, timeline ? .activity : .overview))
    }

    /// A comment row with a long Markdown body, and the row that opens first.
    private func openRow(_ scene: String, now: Date) -> [Event] {
        let item = JourneySample.subs[2], id = "5b1f0c2e-8d1a-4f7e-9a51-0c6a3e2f9d10"
        let url = "https://app.plane.so/ocral/browse/\(item)/#comment-\(id)"
        let at = JourneySample.day(3, 14, 2, now)
        let body = """
            ## Review round 1

            Keep the pending comments in **SQLite**. The JSON copy drifts after a crash.

            - `store/pending.go`: drop `writeJSON` and the file lock.
            - `events/outbox.go`: send from the table, not from the file.
            - Add a test for a restart in the middle of a send.

            ```go
            func (s *Store) Pending(ctx context.Context) ([]Comment, error) {
                return s.q.ListPending(ctx)
            }
            ```

            > The daemon owns one store. Two copies give two truths.

            After this change, run `scripts/contract-check.sh` again.
            """
        CommentBook.preset = [item: [Comment(id: id, author: JourneySample.me, createdAt: at, url: url, body: body)]]
        ItemPage.payloadMode = scene == "detail-raw" ? .raw : scene == "detail-payload" ? .payload : .rendered
        ItemPage.presetOpen = scene == "detail-ci" ? "s-ci" : "s-comment"
        let d = EventDraft(id: "s-comment", at: at, kind: .commentCreated, item: item, parentItem: JourneySample.key, project: "oversire",
                           provider: "plane", actorType: .human, actor: JourneySample.me, via: "plane", summary: "## Review round 1",
                           payload: ["comment": .string(id), "url": .string(url)])
        let ciAt = JourneySample.day(3, 15, 21, now)
        let log = "--- FAIL: TestMergePartialFail (0.04s)\n    merge_test.go:88: got 2 rows, want 3: the second send lost the row of the first"
        let ci = EventDraft(id: "s-ci", at: ciAt, kind: .ciCompleted, item: item, parentItem: JourneySample.key, project: "oversire",
                            repo: "oversire/cli", provider: "github", actorType: .provider, actor: "github", via: "poll",
                            summary: "cli test #2243 failed: TestMergePartialFail",
                            payload: ["conclusion": .string("failure"), "run": .int(2243), "url": .string("https://github.com/oversire/cli/actions/runs/2243"),
                                      "failed": .array([.object(["job": .string("go test"), "step": .string("TestMergePartialFail"), "log": .string(log)]),
                                                        .object(["job": .string("go vet"), "step": .string("vet ./events")])]),
                                      "timing": .object(["queued": .int(4), "ran": .int(212)])])
        return [Event(seq: 1000, seenAt: at, draft: d), Event(seq: 1001, seenAt: ciAt, draft: ci)]
    }
}
