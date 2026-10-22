import Foundation
import OverSireCore
import OverSireSync
import OverSireAI
import OverSireAssistant

// The "My machines" actions. They go to the local daemon through MachinesController.
struct MachineActions {
    let link: ActionLink

    static let machine = ("string", "The machine name.")

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

    private func call(_ id: String, _ title: String, _ help: String, _ props: [String: (String, String)], required: [String],
                      _ op: @escaping (ActionArgs, DaemonClient) async throws -> String?) -> ActionSpec {
        ActionSpec(id: id, title: title, help: help, kind: .settings, input: ActionSpec.args(props, required: required)) { a in
            let failed = await MachinesController.shared.call(title) { try await op(a, $0) }
            return failed.map { .failed($0) } ?? .ok(summary: "\(title): done.")
        }
    }
}
