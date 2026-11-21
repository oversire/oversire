import Foundation
import OverSireCore
import OverSireSync

/// Gives the watches of the home daemon to the interest poller.
/// Main thread only. Only the app that leads (the source of the mirror) polls. It polls only repos that it tracks.
final class CIWatchFeed {
    private let poller: InterestPoller
    private let tracked: () -> [String]
    private let leads: () -> Bool

    init(poller: InterestPoller, tracked: @escaping () -> [String], leads: @escaping () -> Bool) {
        self.poller = poller
        self.tracked = tracked
        self.leads = leads
    }

    /// A frame of a daemon. A frame of a member daemon, or of an app that does not lead, does nothing.
    func received(_ frame: CIFrame, fromHome: Bool) {
        guard fromHome, frame.event == CIFrame.watches else { return }
        apply(frame.watches)
    }

    /// The full list of the home daemon. The poller gets the watches of the tracked repos, with the spelling of the app.
    func apply(_ watches: [CIWatch]) {
        guard leads() else { return }
        let byLower = Dictionary(tracked().map { ($0.lowercased(), $0) }, uniquingKeysWith: { a, _ in a })
        let mine = watches.compactMap { w -> CIWatch? in
            guard let repo = byLower[w.repo.lowercased()] else { return nil }
            var w = w
            w.repo = repo
            return w
        }
        Task { await poller.setWatches(mine) }
    }
}
