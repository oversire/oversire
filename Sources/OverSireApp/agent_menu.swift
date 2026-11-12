import Cocoa
import AgentBinder
import OverSireCore
import RuntimeDaemon

// The model lists of the agent CLIs. The daemon of the sessions machine comes first.
// When it cannot list, AgentBinder on this Mac gives the list, with a warning.
final class AgentModelBook {
    static let shared = AgentModelBook()
    static let changed = Notification.Name("AgentModelBook.changed")

    struct Entry: Equatable {
        var models: [AgentModel]
        /// Nil: the list is from the sessions machine. Else why it is from this Mac, or empty.
        var warning: String?
    }

    /// CLI → the read of its models. A failed read keeps the list from this Mac, and tries again by itself.
    private var reads: [String: PartReader<Entry>] = [:]
    var lists: [String: Entry] { reads.compactMapValues(\.value) }
    private let daemon: () -> MachineRuntime?
    private let local: @Sendable (String) async -> [AgentModel]
    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void

    init(daemon: @escaping () -> MachineRuntime? = { ENV.runtime as? MachineRuntime },
         local: @escaping @Sendable (String) async -> [AgentModel] = { cli in
             ((try? await LocalCLI.shared.runtime.models(Harness(cli))) ?? []).map {
                 AgentModel(id: $0.id, name: $0.name, description: $0.description, isDefault: $0.isDefault)
             }
         },
         now: @escaping () -> Date = Date.init,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = ChangeBus.mainAfter) {
        self.daemon = daemon
        self.local = local
        self.now = now
        self.schedule = schedule
    }

    /// UI shots and tests set the lists with no call.
    func seed(_ l: [String: Entry]) {
        reads = [:]
        for (cli, e) in l { read(cli).seed(Read(value: e)) }
    }

    /// Loads the list of a CLI once. `again` reads it again, for example after a machine change.
    /// A failed read waits for its retry plan.
    func load(_ cli: String, again: Bool = false) {
        guard !cli.isEmpty else { return }
        read(cli).start(force: again)
    }

    /// The part for the Try again action next to the model list of a CLI.
    func part(_ cli: String) -> PagePart { read(cli).part(id: "models-\(cli)", title: "Models of \(cli)") }

    /// Reads again each list whose last read failed.
    func reloadFailed() {
        for r in reads.values where r.state.didFail { r.start(force: true) }
    }

    /// The read of a CLI. It makes the read when none exists.
    func read(_ cli: String) -> PartReader<Entry> {
        if let r = reads[cli] { return r }
        let r = PartReader<Entry>(
            fetch: { [weak self] in
                guard let self else { throw ProviderError.transport("The model list is gone.") }
                return try await self.fetch(cli)
            },
            now: now, schedule: schedule,
            changed: {
                // Later, so a load inside a handler of the notice does not nest.
                DispatchQueue.main.async { [weak self] in NotificationCenter.default.post(name: Self.changed, object: self) }
            })
        reads[cli] = r
        return r
    }

    /// The daemon answers first. When it fails, the list of this Mac shows with the reason, and the read fails so that the plan runs.
    private func fetch(_ cli: String) async throws -> Entry {
        let rt = await MainActor.run { daemon() }
        var reason: String?
        var models: [AgentModel] = []
        var failure: ProviderError?
        if let rt {
            do {
                let m = try await rt.models(agent: cli)
                models = m.models
                if m.source != "wire" || models.isEmpty { reason = m.reason ?? "\(rt.machine) gives no models for \(cli)." }
            } catch {
                let why = (error as? ProviderError)?.message ?? error.localizedDescription
                reason = "\(rt.machine) cannot list the models: \(why)"
                failure = .transport(reason!)
            }
        } else {
            reason = "No OverSire daemon runs on the sessions machine."
        }
        if reason != nil {
            models = await local(cli)
            reason! += models.isEmpty ? "" : " The list is from this Mac."
        }
        let entry = Entry(models: models.filter { $0.id != "default" }, warning: reason)
        if let failure {
            await MainActor.run { reads[cli]?.set(entry) }
            throw failure
        }
        return entry
    }

    /// The display name of a model, else its id.
    func name(_ model: String, cli: String) -> String {
        lists[cli]?.models.first { $0.id == model }?.name ?? model
    }

    /// Why the model of an agent can fail: the list is not from the sessions machine, or it does not hold the model.
    func warning(_ p: AgentProfile) -> String? {
        guard let cli = p.cli, !p.model.isEmpty, let e = lists[cli] else { return nil }
        if !e.models.isEmpty, !e.models.contains(where: { $0.id == p.model }) {
            return "The sessions machine does not list \(p.model). The start still goes." + (e.warning.map { " " + $0 } ?? "")
        }
        return e.warning
    }

    /// "Opus 5.5 · Max", "Auto", "terminal only".
    func detail(_ p: AgentProfile) -> String {
        guard let cli = p.cli else { return "terminal only" }
        var parts = [p.model.isEmpty ? "Auto" : name(p.model, cli: cli)]
        if p.hasEffort, !p.effort.isEmpty { parts.append(AgentProfile.effortName(p.effort)) }
        return parts.joined(separator: " · ")
    }

    /// "claude-max · Opus 5.5 · Max".
    func label(_ agent: String, _ p: AgentProfile) -> String { agent + " · " + detail(p) }
}

// The agent menu of the launch chip and of "Start in Orca with": the agents under each base CLI, then Edit agents….
enum AgentMenu {
    /// `picked` gets a check mark. `standard` gets the "default" mark.
    /// An agent that cannot run on `machine` (Run sessions on) shows dim, with the reason (OVERSIRE-399).
    static func build(into menu: NSMenu, picked: String?, standard: String, machine: String? = nil, pick: @escaping (String) -> Void) {
        let r = PROJECTS_CFG.runtime, book = AgentModelBook.shared
        let on = machine ?? MACHINES.sessions ?? (NSApp?.delegate as? AppData)?.agentPlaces.this ?? ""
        menu.autoenablesItems = false
        for g in r.agentGroups {
            let head = NSMenuItem(title: (g.cli ?? "Other CLIs").uppercased(), action: nil, keyEquivalent: "")
            head.attributedTitle = NSAttributedString(string: head.title, attributes: [
                .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold), .foregroundColor: NSColor.secondaryLabelColor,
            ])
            head.isEnabled = false
            if menu.numberOfItems > 0 { menu.addItem(.separator()) }
            menu.addItem(head)
            for a in g.agents {
                let p = r.profile(a)
                if let c = p.cli, !p.model.isEmpty { book.load(c) }
                let mi = MenuAction(a) { pick(a) }.item
                let t = NSMutableAttributedString(string: a, attributes: [.font: NSFont.menuFont(ofSize: 0)])
                t.append(NSAttributedString(string: "   " + book.detail(p), attributes: [
                    .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                ]))
                let refusal = r.refusal(a, on: on)
                if let list = r.sharedDef(a)?.runsOn ?? r.runsOn[a], refusal != nil {
                    t.append(NSAttributedString(string: " · only on \(list.joined(separator: ", "))", attributes: [
                        .font: NSFont.menuFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                    ]))
                }
                if a == standard {
                    t.append(NSAttributedString(string: "   default", attributes: [
                        .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
                    ]))
                }
                mi.attributedTitle = t
                mi.state = a == picked ? .on : .off
                mi.isEnabled = refusal == nil
                mi.toolTip = refusal ?? book.warning(p) ?? (p.cli == nil ? "No base CLI. Only a terminal runtime (Orca) can start it." : nil)
                mi.setAccessibilityLabel([a, book.detail(p), a == standard ? "default" : nil, refusal].compactMap { $0 }.joined(separator: ", "))
                menu.addItem(mi)
            }
        }
        menu.addItem(.separator())
        menu.addItem(MenuAction("Edit agents…") {
            SettingsPage.commandsOpen = true
            (NSApp.delegate as? GHActionsBar)?.open(.settings(.agents))
        }.item)
    }
}
