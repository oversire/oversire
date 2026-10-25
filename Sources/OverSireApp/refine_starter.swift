import Foundation
import OverSireCore

/// What Refine talks about: a pending intake item or a work item. A nil intake body: the start reads it.
enum RefineTarget: Equatable {
    case intake(IntakeItem, key: String, body: String?)
    case item(Item)

    var key: String {
        switch self {
        case .intake(_, let k, _): return k
        case .item(let i): return i.key
        }
    }

    var title: String {
        switch self {
        case .intake(let i, _, _): return i.name
        case .item(let i): return i.title
        }
    }

    var workItemId: String {
        switch self {
        case .intake(let i, _, _): return i.workItemId
        case .item(let i): return i.id
        }
    }

    /// The {text} value: the title, then the body.
    var text: String {
        let body: String
        switch self {
        case .intake(_, _, let b): body = b ?? ""
        case .item(let i): body = i.body ?? ""
        }
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return b.isEmpty ? title : title + "\n\n" + b
    }
}

/// Refine (OVERSIRE-310): an interactive session about an existing item, keyed by its key.
/// The agent asks questions and gives a plan. On approval it writes the item: it accepts an intake item with the same ID.
/// Enhance is different: an agent rewrites the text alone, with no talk.
struct RefineStarter {
    let agents: AgentIndex
    var tracker: (ProjectRef) -> (any OverSireCore.Tracker)? = { ENV.tracker($0.workspace) }
    var root: (ProjectSummary) -> String? = { PROJECTS_CFG.orcaRoot($0) }
    var cfg: () -> ProjectsConfig = { PROJECTS_CFG }

    init(_ agents: AgentIndex) { self.agents = agents }

    /// The session of the key, when one runs. The Refine button then opens it.
    func session(_ key: String) -> AgentSession? {
        agents.agent(key).flatMap { $0.phase == .failed ? nil : $0 }
    }

    static func prompt(_ t: RefineTarget, project: ProjectRef, runtime: RuntimeConfig, files: Bool) -> String {
        var values = ["text": t.text, "key": t.key, "item": t.workItemId, "workspace": project.account.id, "project": project.key ?? project.id]
        switch t {
        case .intake(let i, _, _):
            values["intake"] = i.id
            return SessionPrompt.intake(runtime.sessionIntakePrompt, values: values, files: files)
        case .item:
            return SessionPrompt.intake(runtime.refinePrompt, values: values, files: files)
        }
    }

    /// Opens a terminal in the Orca workspace folder of the project. `done` gets nil, or the reason of a failure.
    func start(_ t: RefineTarget, in summary: ProjectSummary, done: @escaping (String?) -> Void) {
        guard let root = root(summary), !root.isEmpty else { done(SessionStartError.noRoot(summary.identifier).errorDescription); return }
        guard agents.runtime() != nil else { done(SessionStartError.noRuntime.errorDescription); return }
        let cfg = cfg()
        var rt = cfg.runtime
        if let a = cfg.local(summary.identifier).agent, !a.isEmpty { rt.agent = a }
        let name = "refine-" + t.key.lowercased()
        let command: String
        do { command = try rt.command(for: rt.agent).resolve(name: name, key: t.key, title: t.title) } catch {
            done(SessionStartError.badCommand(String(describing: error)).errorDescription)
            return
        }
        let ref = ItemRef(project: summary.ref, id: t.workItemId, key: t.key, url: URL(string: summary.url) ?? URL(string: "about:blank")!)
        let tracker = tracker(summary.ref)
        let note: String? = { if case .item(let i) = t { return i.url }; return nil }()
        // An intake Refine is not the agent of the work item that it makes.
        let startKey: String? = { if case .intake = t { return StartKey.refine(t.key) }; return nil }()
        let agents = agents
        Task {
            var t = t
            if case .intake(let i, let k, nil) = t, let triage = tracker as? any IntakeTriaging {
                t = .intake(i, key: k, body: (try? await triage.intakeDetail(i, in: summary.ref))?.body)
            }
            // An unknown file list keeps the download line.
            var files = true
            if let reader = tracker as? any AttachmentReading, reader.capabilities.contains(.attachmentsRead),
               let list = try? await reader.attachments(of: ref) { files = !list.isEmpty }
            let prompt = Self.prompt(t, project: summary.ref, runtime: rt, files: files)
            DispatchQueue.main.async {
                agents.launch(key: t.key, note: note, root: root, agent: rt.agent, prompt: prompt, command: command, title: name, inPlace: true, startKey: startKey) { r in
                    if case .failure(let e) = r { done(e.message) } else { done(nil) }
                }
            }
        }
    }
}
