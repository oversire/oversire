import Cocoa
import OverSireCore
import OverSireSync
import OverSireAI
import OverSireAssistant

// The "My machines" actions. They go to the local daemon through MachinesController.
struct MachineActions {
    let link: ActionLink

    static let machine = ("string", "The machine name.")
    static let session = ("string", "The session id from machine.sessions.")

    var specs: [ActionSpec] {
        [
            ActionSpec(id: "machine.list", title: "Machines", help: "Lists the machines of the group: name, home, last seen, version and live sessions.", kind: .read) { _ in
                await MainActor.run {
                    let s = MachinesController.shared.snapshot
                    guard let g = s.group else {
                        return .ok(summary: s.info.map { "Only this Mac (\($0.machine)) runs a daemon. It is in no group." } ?? "No daemon answers on this Mac.")
                    }
                    let rows: [JSONValue] = g.members.map { m in
                        var o: [String: JSONValue] = ["machine": .string(m.machine.rawValue), "home": .bool(m.machine == g.home),
                                                      "sessions": .int(s.sessions[m.machine.rawValue]?.count ?? 0)]
                        if let v = m.version { o["version"] = .string(v) }
                        if let t = m.lastSeen { o["lastSeen"] = .string(ISO8601DateFormatter().string(from: t)) }
                        return .object(o)
                    }
                    return .ok(summary: "\(g.members.count) machine\(g.members.count == 1 ? "" : "s") in \(g.name).", data: .array(rows))
                }
            },
            remote("machine.sessions", "Machine sessions", "Lists the agent sessions on a machine of the group: id, agent, repo, branch, state and the last message.",
                   .read, [:]) { _, c, _ in
                let list = try await c.sessions().sessions
                return .ok(summary: "\(list.count) session\(list.count == 1 ? "" : "s").", data: JSONValue(encoding: list))
            },
            remote("session.read", "Read session", "Reads an agent session on a machine of the group: its state, prompt, last message and the last screen lines.",
                   .read, ["session": Self.session, "lines": ("integer", "Screen lines, at most 200. Default 40.")], required: ["session"]) { a, c, link in
                let id = a.string("session") ?? ""
                let s = try await c.session(id: id)
                var data: [String: JSONValue] = ["session": JSONValue(encoding: s) ?? .null]
                if let ws = s.workspace, let link {
                    let ref = SessionRef(workspace: WorkspaceRef(account: AccountID(provider: ProviderID(rawValue: s.runtime), id: "local"), id: ws), id: id)
                    let draft = WorkOrderDraft(runtime: ProviderID(rawValue: s.runtime), runner: link.machine, order: .read(ref, lines: min(200, max(1, a.int("lines") ?? 40))))
                    if let lines = try? await Self.wait(RUNNER_DESK.send(draft, on: link), c)?.result?.lines { data["screen"] = .array(lines.map(JSONValue.string)) }
                }
                return .ok(summary: "\(s.harness) on \(s.machine.rawValue): \(s.state.rawValue). \(s.lastMessage ?? "")", data: .object(data))
            },
            remote("session.ask", "Ask session", "Types the text into an agent session on a machine of the group and waits for the reply. With `readOnly` (default), the agent gets the rule to answer only and change no files.",
                   .outward, ["session": Self.session, "text": ("string", "The question."), "timeoutSec": ("integer", "10 to 600. Default 180."),
                              "readOnly": ("boolean", "Default true.")], required: ["session", "text"]) { a, c, _ in
                guard let text = a.string("text"), !text.isEmpty else { return .notAllowed("The text is empty.") }
                do {
                    let r = try await c.ask(session: a.string("session") ?? "", text: text, timeout: TimeInterval(min(600, max(10, a.int("timeoutSec") ?? 180))),
                                            readOnly: a.bool("readOnly") ?? true)
                    return .ok(summary: r.reply ?? "The turn ended with no reply.", data: JSONValue(encoding: r))
                } catch let e as SessionAskError {
                    return .failed([e.message, e.screenTail.map { "Screen:\n" + $0 }].compactMap { $0 }.joined(separator: "\n"))
                }
            },
            remote("order.start", "Start on machine", "Starts an agent session for the item on another machine of the group. `repo` is the repo path on that machine.",
                   .outward, ["key": ItemActions.key, "repo": ("string", "The repo path on the machine."), "agent": ("string", "The agent name. Empty: the project default."),
                              "prompt": ("string", "Empty: the project prompt of the item.")], required: ["key", "repo"]) { a, c, link in
                guard let link else { return .notAllowed("The machine has no link.") }
                guard let repo = a.string("repo"), !repo.isEmpty else { return .notAllowed("Give the repo path on \(link.machine).") }
                let found: (ItemRef, (agent: AgentLaunch, prompt: String))? = await MainActor.run {
                    guard let k = a.string("key"), let f = (NSApp.delegate as? AppData)?.projectStore.item(key: k), let ref = f.item.ref(in: f.snap.summary.ref) else { return nil }
                    return (ref, PROJECTS_CFG.launch(for: f.item, agent: a.string("agent").flatMap { $0.isEmpty ? nil : $0 }))
                }
                guard let (ref, l) = found else { return .notAllowed("No loaded item \(a.string("key") ?? "").") }
                var launch = LaunchRequest(repo: repo, item: ref, agent: AgentName(rawValue: l.agent.cli), prompt: a.string("prompt").flatMap { $0.isEmpty ? nil : $0 } ?? l.prompt)
                launch.apply(AgentLaunch(profile: l.agent.profile, cli: l.agent.cli, model: l.agent.model, effort: l.agent.effort))
                let o = try await RUNNER_DESK.send(WorkOrderDraft(runtime: "oversire", runner: link.machine, order: .start(launch)), on: link)
                return .ok(summary: "Order \(o.id) starts \(ref.key) on \(link.machine). Read it with order.get.", data: .object(["id": .string(o.id)]))
            },
            remote("order.get", "Order state", "Reads the state and the result of a work order on a machine of the group.",
                   .read, ["id": ("string", "The order id.")], required: ["id"]) { a, c, _ in
                let s = try await c.order(id: a.string("id") ?? "")
                return .ok(summary: "The order is \(s.state.rawValue).\(s.result?.error.map { " " + $0 } ?? "")", data: JSONValue(encoding: s))
            },
            remote("question.answerRemote", "Answer on machine", "Answers an agent question on a machine of the group. `answers` maps each question item id to an option label, a list of labels, or text.",
                   .change, ["id": ("string", "The question id."), "answers": ("object", "Item id → label, labels or text."), "note": ("string", "A note for the agent.")],
                   required: ["id", "answers"]) { a, c, _ in
                let items: [QuestionAnswer.Item] = (a["answers"]?.object ?? [:]).sorted { $0.key < $1.key }.map { id, v in
                    QuestionAnswer.Item(id: id, choices: v.array?.compactMap(\.string) ?? [], other: v.string)
                }
                guard !items.isEmpty else { return .notAllowed("Give the answers.") }
                let r = try await c.answer(a.string("id") ?? "", RunnerAnswer(id: a.string("id") ?? "", items: items, note: a.string("note")))
                return .ok(summary: "The answer is sent.", data: JSONValue(encoding: r))
            },
            call("machine.installHooks", "Install hooks", "Installs the session hooks of agent CLIs on this Mac.",
                 ["harnesses": ("array", "Agent CLI names, for example claude and codex.")], required: ["harnesses"]) { a, c in
                _ = try await c.hooks(install: a.list("harnesses")); return nil
            },
            call("machine.remove", "Remove machine", "Removes a machine from the group. Its credential stops.", ["machine": Self.machine], required: ["machine"]) { a, c in
                try await c.remove(a.string("machine") ?? ""); return nil
            },
            call("machine.setHome", "Make home", "Makes a machine the home of the group store.", ["machine": Self.machine], required: ["machine"]) { a, c in
                try await c.setHome(a.string("machine") ?? "").warning
            },
        ]
    }

    /// An action on the daemon of one machine. An offline machine gives a notice with its last-seen time.
    private func remote(_ id: String, _ title: String, _ help: String, _ kind: ActionKind, _ props: [String: (String, String)], required: [String] = [],
                        _ op: @escaping @Sendable (ActionArgs, DaemonClient, MachineLink?) async throws -> ActionResult) -> ActionSpec {
        var props = props
        props["machine"] = Self.machine
        return ActionSpec(id: id, title: title, help: help, kind: kind, input: ActionSpec.args(props, required: ["machine"] + required)) { a in
            let name = a.string("machine") ?? ""
            let reach = await MainActor.run { MachinesController.shared.reach(name) }
            switch reach {
            case .offline(let why): return .ok(summary: why, data: .object(["offline": .bool(true)]), parts: [.notice(code: "machine.offline", text: why)])
            case .daemon(let c, let link):
                do { return try await op(a, c, link) } catch { return .failed("\(title) on \(name): \(DaemonClient.reason(error))") }
            }
        }
    }

    /// Polls the order until it has a result, at most 15 s.
    static func wait(_ o: WorkOrder, _ c: DaemonClient) async -> DaemonOrderState? {
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if let s = try? await c.order(id: o.id), s.result != nil || s.state == .failed { return s }
        }
        return nil
    }

    private func call(_ id: String, _ title: String, _ help: String, _ props: [String: (String, String)], required: [String],
                      _ op: @escaping (ActionArgs, DaemonClient) async throws -> String?) -> ActionSpec {
        ActionSpec(id: id, title: title, help: help, kind: .settings, input: ActionSpec.args(props, required: required)) { a in
            let failed = await MachinesController.shared.call(title) { try await op(a, $0) }
            return failed.map { .failed($0) } ?? .ok(summary: "\(title): done.")
        }
    }
}

extension MachinesController {
    enum Reach {
        /// `link` is nil for this Mac when the hub has no link for it.
        case daemon(DaemonClient, MachineLink?)
        case offline(String)
    }

    /// The daemon of a group machine, or why it does not answer.
    func reach(_ name: String) -> Reach {
        let member = snapshot.group?.members.first { $0.machine.rawValue.caseInsensitiveCompare(name) == .orderedSame }
        let machine = member?.machine.rawValue ?? name
        let link = hub?.links.first { $0.machine == machine }
        let isThis = machine == snapshot.info?.machine.rawValue
        guard member != nil || isThis else { return .offline("\(name) is not in the group.") }
        if !isThis, hub?.isLive(machine) != true {
            return .offline("\(machine) is offline. " + (member?.lastSeen.map { "Last seen \(relativeAgo($0))." } ?? "It was never seen."))
        }
        guard let c = daemon(machine) else { return .offline("\(machine) has no link from this Mac.") }
        return .daemon(c, link)
    }
}
