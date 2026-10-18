import Cocoa
import OverSireCore

// ─── Cloud AI ────────────────────────────────────────────────────────────────
// Jobs, suggestions and the runner. The cloud runs them. Without a cloud account, each row only tells what it does.

/// The Cloud AI records in the store. The hub writes them.
struct CloudAIRecords {
    var jobs: [AIJob] = []
    var suggestions: [Suggestion] = []
    var orders: [WorkOrder] = []
    var runners: [RunnerState] = []
    var sessions: [RunnerSession] = []
    /// The hub writes it. Nil until the first sync.
    var billing: BillingState?

    static func load(_ w: StoreWrites) -> CloudAIRecords {
        CloudAIRecords(jobs: w.load(AIJob.self), suggestions: w.load(Suggestion.self), orders: w.load(WorkOrder.self),
                       runners: UIShots.cloud == true ? UIShots.runners : w.load(RunnerState.self),
                       sessions: UIShots.cloud == true ? UIShots.runnerSessions : w.load(RunnerSession.self), billing: w.load(BillingState.self).first ?? UIShots.billing)
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
        let orders = waiting == 0 ? "No work orders" : "\(waiting) waiting"
        guard !runners.isEmpty else { return orders }
        let online = runners.filter(\.online).count
        return "\(online) of \(runners.count) runner\(runners.count == 1 ? "" : "s") online · " + orders
    }
    var creditsStatus: String? {
        guard let b = billing else { return nil }
        let balance = "\(Self.usd(b.balanceMicroUSD)) balance"
        guard b.grantMicroUSD > 0 else { return balance }
        return "\(Self.usd(b.grantLeftMicroUSD)) grant left · \(balance)" + (b.notice80Sent ? " · 80% used" : "")
    }

    static func usd(_ micro: Int) -> String { String(format: "%@$%.2f", micro < 0 ? "−" : "", Double(abs(micro)) / 1_000_000) }
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
            ("Runner", "terminal", "A runner does the work orders of accepted suggestions.", records?.runnerStatus),
        ]
        for (title, symbol, note, status) in rows {
            let glyph = Glyph(symbol, color: Palette.dim, size: 13)
            glyph.widthAnchor.constraint(equalToConstant: 18).isActive = true
            var views: [NSView] = [glyph, TwoLine(title, note), Spacer()]
            if let status { views.append(NSTextField.text(status, size: 12, color: Palette.dim)) }
            card.add(Row(views, height: 52, label: [title, note, status].compactMap { $0 }.joined(separator: ". ")))
        }
        if records != nil { card.add(RunnerSetupRow()) }
        if let credits = records?.creditsStatus {
            let warn = records?.billing?.notice80Sent == true
            let glyph = Glyph(warn ? "exclamationmark.triangle" : "creditcard", color: warn ? Palette.warn : Palette.dim, size: 13)
            glyph.widthAnchor.constraint(equalToConstant: 18).isActive = true
            let usage = ActionButton("Usage") { CloudAICard.openConsole() }
            card.add(Row([glyph, TwoLine("Credits", credits), Spacer(), usage], height: 52, label: "Credits. \(credits)"))
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

    /// The Usage tab of the console. Top-ups and the plan are there.
    static func openConsole() {
        guard !RELAY.workerURL.isEmpty, let url = URL(string: RELAY.workerURL + "/console") else { return }
        NSWorkspace.shared.open(url)
    }
}

extension Page {
    /// Nil without a cloud account.
    var cloudAIRecords: CloudAIRecords? { hasCloud ? .load(STORE_WRITES) : nil }

    var hasCloud: Bool { UIShots.cloud ?? data.relay.canRun }

    /// The sequence suggestion card. Accept and Dismiss write the decision through the store.
    func suggestionCard(_ s: Suggestion, draft: SequenceDraft) -> NSView {
        let book = data.suggestions
        let device = RELAY.deviceID.isEmpty ? nil : RELAY.deviceID
        return SequenceSuggestionCard(s, draft: draft, store: data.projectStore,
                                      accept: { [weak self] drop in book.accept(s.id, drop: drop, by: device); self?.reload() },
                                      dismiss: { [weak self] in book.dismiss(s.id, by: device); self?.reload() },
                                      open: { [weak self] k in self?.go(.item(k, .overview)) })
    }
}
