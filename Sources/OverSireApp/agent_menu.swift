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

    private(set) var lists: [String: Entry] = [:]
    private var loading: Set<String> = []
    private let daemon: () -> MachineRuntime?
    private let local: @Sendable (String) async -> [AgentModel]

    init(daemon: @escaping () -> MachineRuntime? = { ENV.runtime as? MachineRuntime },
         local: @escaping @Sendable (String) async -> [AgentModel] = { cli in
             ((try? await LocalCLI.shared.runtime.models(Harness(cli))) ?? []).map {
                 AgentModel(id: $0.id, name: $0.name, description: $0.description, isDefault: $0.isDefault)
             }
         }) {
        self.daemon = daemon
        self.local = local
    }

    /// UI shots and tests set the lists with no call.
    func seed(_ l: [String: Entry]) { lists = l }

    /// Loads the list of a CLI once. `again` reads it again, for example after a machine change.
    func load(_ cli: String, again: Bool = false) {
        guard !cli.isEmpty, again || lists[cli] == nil, !loading.contains(cli) else { return }
        loading.insert(cli)
        let rt = daemon(), local = local
        Task {
            var reason: String?
            var models: [AgentModel] = []
            if let rt {
                do {
                    let m = try await rt.models(agent: cli)
                    models = m.models
                    if m.source != "wire" || models.isEmpty { reason = m.reason ?? "\(rt.machine) gives no models for \(cli)." }
                } catch {
                    reason = "\(rt.machine) cannot list the models: \((error as? ProviderError)?.message ?? error.localizedDescription)"
                }
            } else {
                reason = "No OverSire daemon runs on the sessions machine."
            }
            if reason != nil {
                models = await local(cli)
                reason! += models.isEmpty ? "" : " The list is from this Mac."
            }
            let entry = Entry(models: models.filter { $0.id != "default" }, warning: reason)
            await MainActor.run {
                self.loading.remove(cli)
                self.lists[cli] = entry
                NotificationCenter.default.post(name: Self.changed, object: self)
            }
        }
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
    static func build(into menu: NSMenu, picked: String?, standard: String, pick: @escaping (String) -> Void) {
        let r = PROJECTS_CFG.runtime, book = AgentModelBook.shared
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
                if a == standard {
                    t.append(NSAttributedString(string: "   default", attributes: [
                        .font: NSFont.systemFont(ofSize: 10.5, weight: .medium), .foregroundColor: NSColor.tertiaryLabelColor,
                    ]))
                }
                mi.attributedTitle = t
                mi.state = a == picked ? .on : .off
                mi.toolTip = book.warning(p) ?? (p.cli == nil ? "No base CLI. Only a terminal runtime (Orca) can start it." : nil)
                mi.setAccessibilityLabel([a, book.detail(p), a == standard ? "default" : nil].compactMap { $0 }.joined(separator: ", "))
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
