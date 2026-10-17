import Cocoa
import OverSireCore

// ─── Cloud AI ────────────────────────────────────────────────────────────────
// Jobs, suggestions and the runner. The cloud runs them. Without a cloud account, each row only tells what it does.

/// The Cloud AI records in the store. The hub writes them.
struct CloudAIRecords {
    var jobs: [AIJob] = []
    var suggestions: [Suggestion] = []
    var orders: [WorkOrder] = []

    static func load(_ w: StoreWrites) -> CloudAIRecords {
        CloudAIRecords(jobs: w.load(AIJob.self), suggestions: w.load(Suggestion.self), orders: w.load(WorkOrder.self))
    }

    var jobsStatus: String {
        jobs.isEmpty ? "No jobs" : "\(jobs.filter(\.enabled).count) of \(jobs.count) on"
    }
    var suggestionsStatus: String {
        let open = suggestions.filter { $0.state == .open }.count
        return open == 0 ? "None open" : "\(open) open"
    }
    var runnerStatus: String {
        let waiting = orders.filter { [.queued, .sent, .acked].contains($0.state) }.count
        return waiting == 0 ? "No work orders" : "\(waiting) waiting"
    }
}

final class CloudAICard: NSStackView {
    static let aboutURL = URL(string: "https://github.com/oversire/oversire#cloud-ai")!

    /// `records`: nil without a cloud account.
    init(_ records: CloudAIRecords?) {
        super.init(frame: .zero)
        orientation = .vertical
        alignment = .leading
        spacing = 6
        translatesAutoresizingMaskIntoConstraints = false
        let card = ListCard()
        let rows: [(String, String, String, String?)] = [
            ("Jobs", "clock", "AI jobs on a schedule or on an event. A job only writes suggestions.", records?.jobsStatus),
            ("Suggestions", "lightbulb", "You accept or dismiss each one. Nothing changes before that.", records?.suggestionsStatus),
            ("Runner", "terminal", "This Mac does the work orders of accepted suggestions.", records?.runnerStatus),
        ]
        for (title, symbol, note, status) in rows {
            let glyph = Glyph(symbol, color: Palette.dim, size: 13)
            glyph.widthAnchor.constraint(equalToConstant: 18).isActive = true
            var views: [NSView] = [glyph, TwoLine(title, note), Spacer()]
            if let status { views.append(NSTextField.text(status, size: 12, color: Palette.dim)) }
            card.add(Row(views, height: 52, label: [title, note, status].compactMap { $0 }.joined(separator: ". ")))
        }
        if records == nil {
            let about = ActionButton("About OverSire Cloud") { NSWorkspace.shared.open(CloudAICard.aboutURL) }
            card.add(Row([NSTextField.text("These need OverSire Cloud.", size: 12, color: Palette.dim), Spacer(), about],
                         height: 44, label: "These need OverSire Cloud."))
        }
        addFull(SectionTitle("Cloud AI"))
        addFull(card)
    }
    required init(coder: NSCoder) { fatalError() }
}

extension Page {
    /// Nil without a cloud account.
    var cloudAIRecords: CloudAIRecords? { UIShots.cloud ?? data.relay.canRun ? .load(STORE_WRITES) : nil }
}
