import Cocoa

// ─── Work queue ──────────────────────────────────────────────────────────────
// Items wait in one lane per project. The first item of a lane starts in Orca when a slot is free
// and its start condition holds.

struct QueueEntry: Codable, Equatable {
    enum Condition: String, Codable, CaseIterable {
        case slot, ciPassed, done, tonight
        var label: String {
            switch self {
            case .slot: return "When a slot frees"
            case .ciPassed: return "After the one above passes CI"
            case .done: return "After the one above is done"
            case .tonight: return "Tonight from 22:00"
            }
        }
    }
    enum Source: String, Codable { case you, label, assignee }

    let key: String
    var title: String
    var condition = Condition.slot
    var added: Date
    var source = Source.you
}

struct QueueLane: Codable, Equatable {
    let project: String               // project ref key
    var identifier: String
    var entries: [QueueEntry] = []
    var lastStarted: String?          // "the one above" of the first entry
    var error: String?                // why the lane cannot start
}

// What the queue needs to know about the world. A struct of closures, so the selftest can fake it.
struct QueueWorld {
    var busy: (QueueLane) -> Int
    var slots: (QueueLane) -> Int
    var ciPassed: (String) -> Bool
    var done: (String) -> Bool
    var now: Date
}

final class WorkQueue {
    static let changed = Notification.Name("WorkQueueChanged")

    private(set) var lanes: [QueueLane] = []
    private var seen: Set<String> = []       // keys added by a Plane trigger once; a removal stays removed
    private var released: Set<String> = []   // agents that hold no slot, for example after an approved "looks done"
    private let path: String
    private let store: ProjectStore
    private let agents: AgentIndex

    init(path: String, store: ProjectStore, agents: AgentIndex) {
        self.path = path
        self.store = store
        self.agents = agents
        load()
    }

    var count: Int { lanes.reduce(0) { $0 + $1.entries.count } }
    func contains(_ key: String) -> Bool { lanes.contains { $0.entries.contains { $0.key == key.uppercased() } } }
    func lane(_ project: String) -> QueueLane? { lanes.first { $0.project == project } }

    // The first item of each lane.
    func upNext(store: ProjectStore) -> [QueueEntry] { lanes.compactMap(\.entries.first) }

    // MARK: Edits

    func add(_ item: ProjectItem, snap: ProjectSnapshot, source: QueueEntry.Source = .you) {
        let key = item.key.uppercased()
        guard !contains(key) else { return }
        let pk = snap.summary.ref.key
        if !lanes.contains(where: { $0.project == pk }) {
            lanes.append(QueueLane(project: pk, identifier: snap.summary.identifier))
        }
        lanes[lanes.firstIndex { $0.project == pk }!].entries.append(QueueEntry(key: key, title: item.title, added: Date(), source: source))
        seen.insert(key)
        save()
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

    // Agents of the lane that hold a slot: starting, working or waiting, and not released.
    func busy(_ lane: QueueLane) -> Int {
        let prefix = lane.identifier.uppercased() + "-"
        var n = 0
        for (k, a) in agents.agents where k.hasPrefix(prefix) && !released.contains(k) {
            if a.phase == .starting || a.phase == .working || a.phase == .waiting { n += 1 }
        }
        return n
    }

    // The entry of the lane that may start now, if any. Pure, for the selftest.
    static func due(_ lane: QueueLane, world: QueueWorld) -> QueueEntry? {
        guard let first = lane.entries.first, world.busy(lane) < world.slots(lane) else { return nil }
        switch first.condition {
        case .slot: return first
        case .ciPassed: return lane.lastStarted.map(world.ciPassed) ?? true ? first : nil
        case .done: return lane.lastStarted.map(world.done) ?? true ? first : nil
        case .tonight:
            let h = Calendar.current.component(.hour, from: world.now)
            return h >= 22 || h < 6 ? first : nil
        }
    }

    // Adds items from Plane triggers, then starts what is due. Call it after each data change.
    func tick(workstreams: WorkstreamIndex) {
        absorbTriggers()
        guard AGENTS.autoStart, agents.ready != nil else { return }
        let world = QueueWorld(
            busy: { [unowned self] in self.busy($0) },
            slots: { AGENTS.slots($0.project) },
            ciPassed: { workstreams.stream($0)?.ci?.word == Tone.ok.word },
            done: { [unowned self] k in self.isDone(k) },
            now: Date())
        for lane in lanes {
            if let e = WorkQueue.due(lane, world: world) { start(e.key, project: lane.project, anchor: nil) }
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
                lanes[li].error = "Choose an Orca workspace for \(snap.summary.identifier): use Start now once."
                save()
                return
            }
        } else {
            agents.start(item, root: root) { _ in }
        }
        lanes[li].entries.removeAll { $0.key == key }
        lanes[li].lastStarted = key
        lanes[li].error = nil
        released.remove(key)
        save()
    }

    private func isDone(_ key: String) -> Bool {
        guard let (_, snap, item) = store.item(key: key) else { return false }
        return snap.option(item.statusOptionId)?.category == .done
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

    private struct Saved: Codable { var lanes: [QueueLane]; var seen: [String] }

    private func load() {
        guard let d = FileManager.default.contents(atPath: path), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        lanes = s.lanes
        seen = Set(s.seen)
    }

    private func save() {
        lanes.removeAll { $0.entries.isEmpty && $0.lastStarted == nil && $0.error == nil }
        if let d = try? JSONEncoder().encode(Saved(lanes: lanes, seen: Array(seen.suffix(2000)))) {
            try? d.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
        publish()
    }

    private func publish() { NotificationCenter.default.post(name: WorkQueue.changed, object: self) }
}
