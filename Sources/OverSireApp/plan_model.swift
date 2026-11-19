import Cocoa
import OverSireCore

/// The place to show on the plan: a segment, and a key or an epic in it.
struct PlanFocus: Equatable {
    var segment: PlanView.Segment
    var key: String?
    var epic: EpicID?
}

/// The toolbar state of the Plan tab. The page keeps it, so a new build does not lose it.
final class PlanControls {
    private static let segmentKey = "planSegment"

    /// Stored in UserDefaults. A shot keeps it in memory.
    var segment: PlanView.Segment = UIShots.shooting ? .summary
        : PlanView.Segment(rawValue: UserDefaults.standard.string(forKey: PlanControls.segmentKey) ?? "") ?? .summary {
        didSet { if !UIShots.shooting { UserDefaults.standard.set(segment.rawValue, forKey: Self.segmentKey) } }
    }
    var folded: Set<EpicID> = []
    var mode: PlanMapMode = .all
    var critical = true
    var zoom: PlanGanttModel.Zoom = .days
    var timelinePlace: PlanGanttPlace?
    var focus: PlanFocus?
    /// The north star editor: open, and the text that is not saved.
    var editingNorthStar = false
    var northStarDraft: String?

    var hash: Int { PageRow.hash([segment.rawValue, folded.map(\.rawValue).sorted(), mode.rawValue, critical, zoom.rawValue, focus?.key, focus?.epic?.rawValue, editingNorthStar]) }
}

/// The plan of one project, built from the store on each page build.
struct PlanModel {
    let snap: ProjectSnapshot
    let graph: PlanGraph
    let schedule: PlanSchedule
    let lanes: PlanLanes
    let summary: PlanSummary
    /// Nil on the first visit.
    let away: PlanAway?
    let since: Date?
    let vision: String?
    let today: Date
    let signals: PlanSignals
    let keys: [String]
    let progress: (loaded: Int, total: Int, failed: Int)
    let gists: [String: String]
    let fingerprint: Int

    var ident: String { snap.summary.identifier }

    static func build(data: AppData, snap: ProjectSnapshot, controls: PlanControls, today: Date = Date()) -> PlanModel {
        let store = data.projectStore
        let storeKey = snap.summary.ref.storeKey
        var signals = PlanSignals()
        for i in snap.items where i.epicId != nil && !snap.isFinished(i) {
            let k = i.key.uppercased()
            if let q = data.questions.open(key: i.key).first { signals.input[k] = q.question.items.first?.text ?? "" }
            guard let a = data.agentIndex.agent(k) else { continue }
            if a.needsInput {
                signals.input[k] = signals.input[k] ?? AgentSession.question(in: a.message) ?? ""
            } else if a.phase == .starting || a.phase == .working {
                signals.working[k] = a.agent.rawValue
            }
        }
        let relations = store.relations.byKey
        let graph = PlanGraph.build(snap, epics: snap.epics ?? [], relations: relations, signals: signals, today: today)
        let schedule = PlanSchedule.build(graph)
        let lanes = PlanLanes.build(snap, graph: graph, schedule: schedule, today: today)
        let summary = PlanSummary.build(snap, graph: graph, schedule: schedule, lanes: lanes, today: today)
        let since = PlanVisits.shared.since(snap.summary.identifier)
        let away = since.map { PlanAway.build(snap, summary: summary, schedule: schedule, graph: graph, since: $0) }
        let keys = store.planKeys(storeKey)
        let vision = data.memory.vision(of: snap.summary.ref)?.text
        var gists: [String: String] = [:]
        for k in graph.order { if let g = data.itemSummaries.summary(k)?.gist { gists[k] = g } }
        let progress = store.relations.progress(keys)
        let day = Calendar.current.startOfDay(for: today)
        let print = PageRow.hash([snap.items, snap.epics, snap.statusOptions, snap.index?.count, keys.map { relations[$0.uppercased()] },
                                  signals.working, signals.input, vision, since, day, gists, progress.loaded, progress.total, controls.hash])
        return PlanModel(snap: snap, graph: graph, schedule: schedule, lanes: lanes, summary: summary, away: away, since: since,
                         vision: vision, today: today, signals: signals, keys: keys, progress: progress, gists: gists, fingerprint: print)
    }

    // MARK: Text

    func epic(_ id: EpicID) -> Epic? { graph.epics.first { $0.id == id } }

    func name(_ id: EpicID) -> String { epic(id)?.title ?? id.rawValue }

    func title(_ key: String) -> String { graph.nodes[key.uppercased()]?.title ?? snap.items.first { $0.key == key }?.title ?? key }

    /// The gist of the item summary, else the title.
    func stepText(_ key: String) -> String { gists[key.uppercased()] ?? title(key) }

    func rollup(_ id: EpicID) -> EpicRollup? { epic(id).map { snap.rollup($0, now: today) } }

    /// "Nov 30" for a plan day.
    func date(_ day: PlanDay) -> String {
        EpicBoard.day(Calendar.current.date(byAdding: .day, value: day, to: Calendar.current.startOfDay(for: today)) ?? today)
    }

    /// The last day of the open work. `end` is the first day after it.
    func endText(_ end: PlanDay?) -> String? { end.map { date($0 - 1) } }

    /// The first sentence of the epic goal, as plain text.
    func status(_ id: EpicID) -> String? {
        guard let goal = epic(id)?.goal else { return nil }
        let line = goal.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
        let plain = line.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "-*> ").union(.whitespaces))
        guard !plain.isEmpty else { return nil }
        if let r = plain.range(of: ". ") { return String(plain[..<r.lowerBound]) + "." }
        return plain
    }

    /// The short state text of a step and its color: "● working · claude", "▲ needs your answer", "⏸ waits for 432".
    func state(_ key: String) -> (text: String, color: NSColor) {
        guard let n = graph.nodes[key.uppercased()] else { return ("", Palette.dim) }
        switch n.state {
        case .done: return ("✓ done", Palette.ok)
        case .working: return ("● working" + (signals.working[n.key].map { " · " + $0 } ?? ""), Palette.run)
        case .input: return ("▲ needs your answer", Palette.warn)
        default: break
        }
        if n.hasOpenBlocker { return ("⏸ waits for " + (n.blockers + n.external).map(short).joined(separator: ", "), Palette.mut) }
        return n.state == .nospec ? ("◌ no spec", Palette.mut) : ("○ ready", Palette.mut)
    }

    /// The number of a key in this project, else the full key.
    func short(_ key: String) -> String {
        let prefix = ident.uppercased() + "-"
        return key.uppercased().hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
    }

    /// "Approval checks" → "approval checks" in a sentence. "CI checks" stays.
    static func inline(_ title: String) -> String {
        let word = title.prefix { $0 != " " }
        guard let first = word.first, word.count < 2 || !word.dropFirst().first!.isUppercase else { return title }
        return first.lowercased() + title.dropFirst()
    }

    var openCount: Int { graph.order.filter { graph.nodes[$0]?.isOpen == true }.count }

    var openEpics: Int { graph.epics.filter { !$0.state.isClosed }.count }
}
