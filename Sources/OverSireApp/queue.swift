import Cocoa
import OverSireCore

// ─── Work queue ──────────────────────────────────────────────────────────────
// Items wait in one lane per project. The first item with no open blocker starts in Orca when a slot is free
// and its start condition holds.

extension QueueEntry.Condition {
    var label: String {
        switch self {
        case .slot: return "When a slot frees"
        case .ciPassed: return "After the one above passes CI"
        case .done: return "After the one above is done"
        case .tonight: return "Tonight from 22:00"
        }
    }
}

// What the queue needs to know about the world. A struct of closures, so the selftest can fake it.
struct QueueWorld {
    var busy: (QueueLane) -> Int
    var slots: (QueueLane) -> Int
    var ciPassed: (String) -> Bool
    var done: (String) -> Bool
    var now: Date
    var blockers: (String) -> [String]? = { _ in [] }   // open blockers of a key; nil while the relations load
    var areas: (String) -> [String] = { _ in [] }       // code areas of a key (cloud)
    var busyAreas: (QueueLane) -> [String: String] = { _ in [:] }   // area → the key that runs in it (cloud)
    var sharable: (QueueLane, String) -> Bool = { _, _ in false }   // a feature area that two items can hold (cloud)
}

// Why the queue skips an entry.
enum QueueHold: Equatable {
    case waits(on: [String])
    case area(String, runs: String)
    case unknown

    var isArea: Bool { if case .area = self { return true } else { return false } }

    var reason: String {
        switch self {
        case .waits(let keys): return "⏸ Waits on " + keys.joined(separator: ", ")
        case .area(let a, let k): return "⊘ Area busy: \(a) · \(k) runs"
        case .unknown: return "Reads the relations…"
        }
    }
}

// One lane on the Queue board: Running, Up next, Waits and Held. Pure.
struct QueueBoard: Equatable {
    struct Card: Equatable {
        var key: String
        var areas: [String] = []
        var note: String? = nil
        var clash: String? = nil   // the other card and the area that they share
    }

    var running: [Card] = []
    var free = 0                   // free slots
    var next: [Card] = []          // in start order
    var waits: [Card] = []
    var held: [Card] = []

    /// `held`: the keys and holds of the cloud work orders of this lane. A draft orders the lane and changes the areas.
    init(lane: QueueLane, running: [String], slots: Int, holds: [String: QueueHold], held: [(key: String, hold: WorkOrderHold?)] = [],
         areas: (String) -> [String], kind: (String) -> AreaKind, draft: PlanDraft? = nil) {
        func a(_ k: String) -> [String] { draft.map { $0.areas(of: k, base: areas(k)) } ?? areas(k) }
        let keys = draft.map { $0.order(lane.entries.map(\.key)) } ?? lane.entries.map(\.key)
        self.running = running.sorted().map { Card(key: $0, areas: a($0)) }
        free = max(0, slots - running.count)
        for k in keys {
            guard let h = holds[k] else { next.append(Card(key: k, areas: a(k))); continue }
            waits.append(Card(key: k, areas: a(k), note: Self.note(h)))
        }
        self.held = held.map { Card(key: $0.key, areas: $0.hold?.areas ?? [], note: $0.hold.flatMap(Self.note)) }
        // Cards that run at the same time and share an area.
        let plan = PlanBoard(cards: self.running.map { .init(key: $0.key, areas: $0.areas, running: true) } + next.map { .init(key: $0.key, areas: $0.areas) },
                             slots: slots)
        let clashes = plan.clashes(kind: kind)
        for i in self.running.indices { self.running[i].clash = clashes[self.running[i].key].map { "\($0.other) (\($0.area))" } }
        for i in next.indices { next[i].clash = clashes[next[i].key].map { "\($0.other) (\($0.area))" } }
    }

    var isEmpty: Bool { running.isEmpty && next.isEmpty && waits.isEmpty && held.isEmpty }

    static func note(_ h: QueueHold) -> String {
        switch h {
        case .waits(let keys): return "⏸ Waits for " + keys.joined(separator: ", ")
        case .area(_, let k): return "⊘ Area used by \(k)"
        case .unknown: return "Reads the relations…"
        }
    }

    static func note(_ h: WorkOrderHold) -> String? {
        if !h.blockers.isEmpty { return "⏸ Waits for " + h.blockers.map(\.key).joined(separator: ", ") }
        if !h.areas.isEmpty { return "⊘ Area busy: " + h.areas.joined(separator: ", ") }
        return nil
    }

    /// The Now, Next and Later board of the Planner, with the draft applied.
    static func plan(lane: QueueLane, running: [String], areas: (String) -> [String], slots: Int, draft: PlanDraft?) -> PlanBoard {
        let keys = draft.map { $0.order(lane.entries.map(\.key)) } ?? lane.entries.map(\.key)
        func a(_ k: String) -> [String] { draft.map { $0.areas(of: k, base: areas(k)) } ?? areas(k) }
        let cards = running.sorted().map { PlanBoard.Card(key: $0, areas: a($0), running: true) } + keys.map { PlanBoard.Card(key: $0, areas: a($0)) }
        return PlanBoard(cards: cards, slots: slots)
    }
}

extension QueueLane {
    struct Pick {
        var entry: QueueEntry?            // the entry to start now
        var next: String?                 // the first entry with no hold
        var holds: [String: QueueHold]    // key → hold
    }

    /// The first entry with no open blocker and no busy area starts when a slot is free and its condition holds.
    /// The condition keeps the lane order: a later entry does not pass the next entry because of it. Pure.
    func pick(state: QueueLaneState?, world: QueueWorld) -> Pick {
        var p = Pick(holds: [:])
        let busyAreas = world.busyAreas(self)
        for e in entries {
            if let hold = Self.hold(e.key, world: world, busyAreas: busyAreas.filter { !world.sharable(self, $0.key) }) { p.holds[e.key] = hold; continue }
            if p.next == nil { p.next = e.key }
        }
        guard let first = entries.first(where: { $0.key == p.next }), world.busy(self) < world.slots(self) else { return p }
        let above = state?.lastStarted
        let holds: Bool
        switch first.condition {
        case .slot: holds = true
        case .ciPassed: holds = above.map(world.ciPassed) ?? true
        case .done: holds = above.map(world.done) ?? true
        case .tonight:
            let h = Calendar.current.component(.hour, from: world.now)
            holds = h >= 22 || h < 6
        }
        if holds { p.entry = first }
        return p
    }

    private static func hold(_ key: String, world: QueueWorld, busyAreas: [String: String]) -> QueueHold? {
        guard let open = world.blockers(key) else { return .unknown }
        if !open.isEmpty { return .waits(on: open) }
        for a in world.areas(key) { if let k = busyAreas[a], k != key { return .area(a, runs: k) } }
        return nil
    }
}

final class WorkQueue {
    static let changed = Notification.Name("WorkQueueChanged")

    private(set) var lanes: [QueueLane] = []
    private(set) var states: [String: QueueLaneState] = [:]   // by project
    private var seen: Set<String> = []       // keys added by a Plane trigger once; a removal stays removed
    private var released: Set<String> = []   // agents that hold no slot, for example after an approved "looks done"
    private let writes: StoreWrites
    private var saved: [String: QueueLane] = [:]
    private var savedStates: [String: QueueLaneState] = [:]
    private var savedSeen: Set<String> = []
    private let store: ProjectStore
    private let agents: AgentIndex
    private var observer: NSObjectProtocol?
    /// The area book with a cloud account, else nil.
    var areaBook: () -> ItemAreaBook? = { nil }
    var planner: () -> PlannerBook? = { nil }

    init(writes: StoreWrites, store: ProjectStore, agents: AgentIndex) {
        self.writes = writes
        self.store = store
        self.agents = agents
        load()
        observer = NotificationCenter.default.addObserver(forName: StoreWrites.remoteChanged, object: writes, queue: .main) { [weak self] n in
            guard let c = n.userInfo?["collection"] as? String, [QueueLane.collection, QueueTrigger.collection].contains(c) else { return }
            self?.load()
        }
    }

    var count: Int { lanes.reduce(0) { $0 + $1.entries.count } }
    func contains(_ key: String) -> Bool { lanes.contains { $0.entries.contains { $0.key == key.uppercased() } } }
    func lane(_ project: String) -> QueueLane? { lanes.first { $0.project == project } }
    func state(_ project: String) -> QueueLaneState? { states[project] }

    // The first item of each lane.
    func upNext(store: ProjectStore) -> [QueueEntry] { lanes.compactMap(\.entries.first) }

    // MARK: Edits

    func add(_ item: Item, snap: ProjectSnapshot, source: QueueEntry.Source = .you) {
        let key = item.key.uppercased()
        guard !contains(key) else { return }
        let pk = snap.summary.ref.storeKey
        if !lanes.contains(where: { $0.project == pk }) {
            lanes.append(QueueLane(project: pk, identifier: snap.summary.identifier))
        }
        lanes[lanes.firstIndex { $0.project == pk }!].entries.append(QueueEntry(key: key, title: item.title, added: Date(), source: source))
        seen.insert(key)
        save()
    }

    /// Adds the item of a key to the lane of its project. False when no tracked project has the key.
    @discardableResult
    func add(key: String) -> Bool {
        guard let f = store.item(key: key) else { return false }
        add(f.item, snap: f.snap)
        return true
    }

    func remove(_ key: String) {
        for i in lanes.indices { lanes[i].entries.removeAll { $0.key == key.uppercased() } }
        save()
    }

    func move(_ key: String, by delta: Int) {
        for i in lanes.indices {
            guard let at = lanes[i].entries.firstIndex(where: { $0.key == key }) else { continue }
            let to = at + delta
            guard lanes[i].entries.indices.contains(to) else { return }
            lanes[i].entries.swapAt(at, to)
            save()
            return
        }
    }

    func set(_ c: QueueEntry.Condition, for key: String) {
        for i in lanes.indices {
            if let at = lanes[i].entries.firstIndex(where: { $0.key == key }) { lanes[i].entries[at].condition = c }
        }
        save()
    }

    func reorder(_ project: String, keys: [String]) {
        guard let i = lanes.firstIndex(where: { $0.project == project }) else { return }
        let old = lanes[i].entries
        lanes[i].entries = keys.compactMap { k in old.first { $0.key == k } } + old.filter { !keys.contains($0.key) }
        save()
    }

    // The agent of the key holds no slot now.
    func release(_ key: String) {
        released.insert(key.uppercased())
        publish()
    }

    // MARK: Ticks

    // Agents of the lane that hold a slot and are not released. A background command holds its slot,
    // "Blocked on you" and "Session done" free it.
    func busy(_ lane: QueueLane) -> Int { running(lane).count }

    func running(_ lane: QueueLane) -> [String] {
        let prefix = lane.identifier.uppercased() + "-"
        return agents.agents.filter { k, a in
            k.hasPrefix(prefix) && !released.contains(k) && (a.phase == .starting || agents.state(k)?.holdsSlot == true)
        }.map(\.key)
    }

    /// The agents of the lane that left their slot, the newest first. A free slot names them.
    func left(_ lane: QueueLane) -> [(key: String, state: SessionState, at: Date)] {
        let prefix = lane.identifier.uppercased() + "-"
        let run = Set(running(lane))
        return agents.agents.compactMap { k, a -> (key: String, state: SessionState, at: Date)? in
            guard k.hasPrefix(prefix), !run.contains(k), let st = agents.state(k) else { return nil }
            return (k, st, a.since)
        }.sorted { $0.at > $1.at }
    }

    func world(workstreams: WorkstreamIndex?) -> QueueWorld {
        QueueWorld(
            busy: { [unowned self] in self.busy($0) },
            slots: { AGENTS.slots($0.project) },
            ciPassed: { k in workstreams?.stream(k)?.ci?.word == Tone.ok.word },
            done: { [unowned self] k in self.store.isDone(key: k) },
            now: Date(),
            blockers: { [unowned self] k in
                let rel = self.store.relations
                // A failed load does not hold the item for ever. The item page shows the error.
                guard rel.supports(k), rel.relations(k) != nil || rel.errors[k.uppercased()] == nil else { return [] }
                return rel.relations(k) == nil ? nil : self.store.blockers(of: k)
            },
            areas: { [unowned self] k in self.areaBook()?.areas(key: k) ?? [] },
            busyAreas: { [unowned self] lane in self.areaBook()?.busy(running: self.running(lane)) ?? [:] },
            sharable: { [unowned self] lane, a in self.planner()?.sharable(a, project: lane.project) ?? false })
    }

    // Adds items from Plane triggers, then starts what is due. Call it after each data change.
    func tick(workstreams: WorkstreamIndex) {
        absorbTriggers()
        store.relations.load(lanes.flatMap { $0.entries.map(\.key) })
        guard AGENTS.autoStart, agents.ready != nil else { return }
        let world = world(workstreams: workstreams)
        for lane in lanes {
            if let e = lane.pick(state: states[lane.project], world: world).entry { start(e.key, project: lane.project, anchor: nil) }
        }
    }

    // Starts the entry now. Without a saved Orca workspace and without an anchor, the lane shows an error.
    func start(_ key: String, project: String, anchor: NSView?) {
        guard let li = lanes.firstIndex(where: { $0.project == project }),
              let snap = store.snapshots[project], let item = snap.items.first(where: { $0.key.uppercased() == key }) else { return }
        let root = PROJECTS_CFG.orca.roots[project] ?? ""
        if root.isEmpty {
            if let anchor {
                agents.start(item, snap: snap, anchor: anchor)
            } else {
                setState(project) { $0.error = "Choose an Orca workspace for \(snap.summary.identifier): use Start now once." }
                save()
                return
            }
        } else {
            agents.start(item, root: root) { _ in }
        }
        lanes[li].entries.removeAll { $0.key == key }
        setState(project) {
            $0.lastStarted = key
            $0.error = nil
        }
        released.remove(key)
        save()
    }

    private func setState(_ project: String, _ edit: (inout QueueLaneState) -> Void) {
        var st = states[project] ?? QueueLaneState(project: project, updatedAt: Date())
        edit(&st)
        st.updatedAt = Date()
        states[project] = st
    }

    // Items with the start label or the bot assignee join the lane of their project, once.
    private func absorbTriggers() {
        let label = AGENTS.startLabel.lowercased(), bot = AGENTS.botUser.lowercased()
        guard !label.isEmpty || !bot.isEmpty else { return }
        for (_, snap) in store.snapshots {
            for item in snap.items where !seen.contains(item.key.uppercased()) {
                let byLabel = !label.isEmpty && item.labels.contains { $0.lowercased() == label }
                let byBot = !bot.isEmpty && item.assignees.contains { $0.lowercased() == bot }
                guard byLabel || byBot, agents.agent(item.key) == nil,
                      snap.option(item.statusOptionId)?.category != .done else { continue }
                add(item, snap: snap, source: byLabel ? .label : .assignee)
            }
        }
    }

    // MARK: Store

    private func load() {
        lanes = writes.load(QueueLane.self).sorted { $0.identifier < $1.identifier }
        saved = Dictionary(lanes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        states = Dictionary(writes.load(QueueLaneState.self).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        savedStates = states
        seen = Set(writes.load(QueueTrigger.self).map(\.key))
        savedSeen = seen
    }

    // Writes only the lanes, lane states and trigger keys that changed.
    private func save() {
        lanes.removeAll { l in l.entries.isEmpty && states[l.project].map { $0.lastStarted == nil && $0.error == nil } ?? true }
        let now = Dictionary(lanes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        states = states.filter { now[$0.key] != nil }
        for (id, lane) in now where saved[id] != lane { writes.put(lane) }
        for id in saved.keys where now[id] == nil { writes.delete(QueueLane.self, id: id) }
        for (id, st) in states where savedStates[id] != st { writes.put(st) }
        for id in savedStates.keys where states[id] == nil { writes.delete(QueueLaneState.self, id: id) }
        for key in seen.subtracting(savedSeen) { writes.put(QueueTrigger(key: key, at: Date())) }
        saved = now
        savedStates = states
        savedSeen = seen
        publish()
    }

    private func publish() { NotificationCenter.default.post(name: WorkQueue.changed, object: self) }
}
