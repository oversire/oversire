import Foundation
import OverSireCore

/// Starts a runbook run on the sessions machine. The run keeps a copy of the runbook and of the resolved agents.
struct RunbookStarter {
    var runtime: () -> (any RunbookRunning)? = { ENV.runtime as? any RunbookRunning }
    var root: (ProjectSummary) -> String? = { PROJECTS_CFG.orcaRoot($0) }
    var cfg: () -> ProjectsConfig = { PROJECTS_CFG }

    /// The body of the start. Each agent of the steps resolves as a Work start of the item: the command name is the item key.
    func request(_ book: Runbook, item: Item, in summary: ProjectSummary, at step: String? = nil) throws -> RunbookStart {
        guard let repo = root(summary), !repo.isEmpty else { throw SessionStartError.noRoot(summary.identifier) }
        let rt = cfg().runtime
        let problems = book.validate(agents: rt.runbookAgents)
        guard problems.isEmpty else { throw RunbookRefusal(message: "\(book.name) has problems.", problems: problems) }
        var agents: [String: AgentLaunchSpec] = [:]
        for name in Set(book.steps.map(\.agent)) { agents[name] = try spec(name, key: item.key, title: item.title) }
        let ref = ItemRef(project: summary.ref, id: item.id, key: item.key, url: URL(string: item.url) ?? URL(string: "about:blank")!)
        return RunbookStart(item: ref, title: item.title, repo: repo, runbook: book, agents: agents, startAt: step)
    }

    /// One agent as a start of the item resolves it. A step patch of a run uses it too.
    func spec(_ name: String, key: String, title: String) throws -> AgentLaunchSpec {
        let rt = cfg().runtime
        let l = rt.launch(name, name: key, key: key, title: title)
        let command: String
        do { command = try rt.command(for: name).resolve(name: key, key: key, title: title) } catch {
            throw SessionStartError.badCommand(String(describing: error))
        }
        return l.spec(command: command)
    }

    func start(_ book: Runbook, item: Item, in summary: ProjectSummary, at step: String? = nil) async throws -> RunbookRun {
        let s = try request(book, item: item, in: summary, at: step)
        guard let rt = runtime() else { throw SessionStartError.noRuntime }
        guard rt.capabilities.contains(.runbooks) else { throw SessionStartError.noRunbooks }
        for name in Set(book.steps.map(\.agent)).sorted() {
            if let why = cfg().runtime.launch(name, name: item.key, key: item.key, title: item.title).refusal(on: rt.account.id) {
                throw SessionStartError.runsOn(why)
            }
        }
        let run = try await rt.startRunbook(s)
        await MainActor.run { RUNBOOKS.apply(run) }
        return run
    }
}
