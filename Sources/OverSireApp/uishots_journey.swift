import Cocoa
import OverSireCore

// ─── --uishots: the item journey ─────────────────────────────────────────────
// The sample rows of journey_sample.swift go straight into JOURNAL and RECAPS, with no daemon reads and no AI.

extension UIShots {
    /// journey:full, folded, noai or timeline, cut, real, tip-mark, tip-bar, tip-cut.
    func journeyState(_ scene: String, in w: AppWindow) {
        let now = Date()
        let rows = JourneySample.rows(now: now, folded: scene == "folded")
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
}
