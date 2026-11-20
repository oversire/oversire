import Cocoa
import OverSireCore
import OverSireAssistant

// The settings action. Only a client uses it, through a member call (OVERSIRE-529).
// The source app checks the hash of the section, changes the config and writes the event.
struct SettingsActions {
    let link: ActionLink
    var desk: () -> EventDesk = { EVENTS }
    /// What a section needs after a change, for example the repo list or the poll timer.
    var after: @MainActor (SettingsSection) -> Void = { s in
        guard let app = NSApp.delegate as? GHActionsBar else { return }
        switch s {
        case .repos: app.applyRepoSelection()
        case .projects: app.applyProjectSelection()
        case .ci: app.refresh(force: true, completion: nil)
        case .linking, .agents, .aiJobs, .sessions: break
        }
    }

    var specs: [ActionSpec] {
        let link = link, desk = desk, after = after
        return [
            ActionSpec(id: "settings.patch", title: "Change a shared setting",
                       help: "Sets one section of the shared settings of this Mac, for a client app. The accounts and the AI keys stay on this Mac.",
                       kind: .settings,
                       input: ActionSpec.args(["section": ("string", "repos, ci, projects, linking, agents, aiJobs or sessions."),
                                               "value": ("object", "The new body of the section."),
                                               "baseHash": ("string", "The hash of the section that the client saw.")],
                                              required: ["section", "value", "baseHash"])) { a in
                guard case .member(let from, _) = a.caller else { return .notAllowed("Only a client app changes the shared settings.") }
                guard let section = a.string("section").flatMap(SettingsSection.init(rawValue:)) else { return .notAllowed("Unknown section.") }
                guard let value = a["value"], value.object != nil else { return .notAllowed("Give the new value of the section.") }
                let base = a.string("baseHash") ?? ""
                return await link.run { _, done in
                    MainActor.assumeIsolated {
                        let old = homeSettings(from: currentConfig())
                        guard old.hashes[section.rawValue] == base else {
                            done(.failed("Changed on \(desk().machine()). Look again.")); return
                        }
                        var new = old
                        do { try new.set(section, from: value) } catch {
                            done(.notAllowed("The value of \(section.title) is not valid.")); return
                        }
                        let keys = new.keys(of: section, since: old)
                        guard !keys.isEmpty else { done(.ok(summary: "\(section.title) settings did not change.")); return }
                        var c = currentConfig()
                        apply(new, to: &c)
                        adoptShared(c)
                        saveConfig()
                        ChangeBus.shared.post(.config(.event))
                        after(section)
                        let actor = a.caller.actor
                        desk().action(.settingsChanged, item: nil, verb: "settings", "\(section.title) settings changed from \(from)",
                                      payload: ["section": .string(section.rawValue), "keys": .array(keys.map(JSONValue.string)), "from": .string(from)],
                                      actorType: actor.type, actor: actor.name, via: actor.via)
                        done(.ok(summary: "\(section.title) settings saved on \(desk().machine())."))
                    }
                }
            },
        ]
    }
}
