import Foundation
import OverSireCore
import OverSireAI
import OverSireAssistant

// The people and search actions of the assistant.
struct PeopleActions {
    let link: ActionLink
    let people: AppPeople

    var specs: [ActionSpec] {
        let link = link, people = people
        return [
            ActionSpec(id: "people.list", title: "People", help: "Lists the people of a project, or of all projects: tracker members, code host collaborators and the owner of the group machines. Use the ids with item.assign.",
                       kind: .read, input: ActionSpec.args(["project": ItemActions.project])) { a in
                var ref: ProjectRef?
                if let p = a.string("project"), !p.isEmpty {
                    ref = await MainActor.run { link.data?.projectStore.snapshot(p)?.summary.ref }
                    guard ref != nil else { return .notAllowed("OverSire has no loaded project \(p).") }
                }
                let list = await people.details(for: ref)
                return .ok(summary: "\(list.count) people.", data: JSONValue(encoding: list))
            },
            ActionSpec(id: "people.get", title: "Person", help: "Reads one person: name, login, email when a source has it, the sources and the machines.",
                       kind: .read, input: ActionSpec.args(["id": ("string", "The person id from people.list."), "login": ("string", "Or the login.")])) { a in
                guard let p = try? await people.person(PersonRef(id: a.string("id") ?? "", name: "", login: a.string("login"))) else {
                    return .notAllowed("No person \(a.string("id") ?? a.string("login") ?? "").")
                }
                return .ok(summary: p.name, data: JSONValue(encoding: p))
            },
            ActionSpec(id: "search.all", title: "Search", help: "Searches items, pull requests, CI runs and agent sessions for the text. The results come grouped by source.",
                       kind: .read, input: ActionSpec.args(["query": ("string", "The text."), "limit": ("integer", "Results for each source, at most 25. Default 10.")],
                                                           required: ["query"])) { a in
                guard let q = a.string("query")?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return .notAllowed("The query is empty.") }
                return await Search(link: link, query: q, limit: min(25, max(1, a.int("limit") ?? 10))).run()
            },
        ]
    }
}

/// One query across the trackers, the code hosts, the local runs and the sessions.
struct Search {
    let link: ActionLink
    let query: String
    let limit: Int

    func run() async -> ActionResult {
        let local = await link.main(Local()) { d, done in done(self.local(d)) }
        var items = local.items
        for (account, projects) in local.trackers {
            guard let t = await MainActor.run(body: { ENV.provider(account) }) as? any ItemSearching,
                  let found = try? await t.search(query, in: projects, limit: limit) else { continue }
            for i in found where !items.contains(where: { $0["key"]?.string == i.key }) {
                items.append(["key": .string(i.key), "title": .string(i.title)])
            }
        }
        var prs = local.prs
        for owner in local.owners {
            guard let h = await MainActor.run(body: { REPO_CLIENT.accounts.codeHost(owner: owner) }) as? any ChangeSearching,
                  let found = try? await h.search(query, limit: limit) else { continue }
            for p in found where !prs.contains(where: { $0["url"]?.string == p.url }) {
                prs.append(["number": .int(p.number), "title": .string(p.title), "state": .string(p.state), "url": .string(p.url)])
            }
        }
        let groups: [String: [[String: JSONValue]]] = ["items": Array(items.prefix(limit)), "prs": Array(prs.prefix(limit)), "runs": local.runs, "sessions": local.sessions]
        let n = groups.values.map(\.count).reduce(0, +)
        return .ok(summary: "\(n) result\(n == 1 ? "" : "s") for \"\(query)\".", data: .object(groups.mapValues { .array($0.map(JSONValue.object)) }))
    }

    struct Local {
        var items: [[String: JSONValue]] = []
        var prs: [[String: JSONValue]] = []
        var runs: [[String: JSONValue]] = []
        var sessions: [[String: JSONValue]] = []
        var trackers: [(AccountID, [ProjectRef])] = []
        var owners: [String] = []
    }

    private func local(_ d: AppData) -> Local {
        func hit(_ s: String?) -> Bool { s?.localizedCaseInsensitiveContains(query) == true }
        var l = Local()
        let snaps = d.projectStore.snapshots.values.sorted { $0.summary.identifier < $1.summary.identifier }
        for s in snaps {
            for i in s.items where l.items.count < limit && (hit(i.key) || hit(i.title)) {
                l.items.append(["key": .string(i.key), "title": .string(i.title), "status": .string(s.statusName(i.statusOptionId) ?? "")])
            }
        }
        l.trackers = Dictionary(grouping: snaps.map(\.summary.ref)) { $0.account }.map { ($0.key, $0.value) }
        for (repo, list) in d.prGrouped {
            for p in list where l.prs.count < limit && (hit(p.title) || hit(p.headRefName) || hit("#\(p.number)")) {
                l.prs.append(["repo": .string(repo), "number": .int(p.number), "title": .string(p.title), "state": .string(p.state), "url": .string(p.url)])
            }
        }
        l.owners = Array(Set(d.prGrouped.map { repoOwner($0.0) })).sorted()
        for (repo, list) in d.grouped {
            for r in list where l.runs.count < limit && (hit(r.displayTitle) || hit(r.headBranch) || hit(r.workflowName) || hit(r.name)) {
                l.runs.append(["repo": .string(repo), "id": .string(r.id), "title": .string(r.displayTitle), "branch": .string(r.headBranch),
                               "status": .string(r.conclusion ?? r.status)])
            }
        }
        for (key, s) in d.agentIndex.agents.sorted(by: { $0.key < $1.key }) where l.sessions.count < limit && (hit(key) || hit(s.prompt) || hit(s.message) || hit(s.repo)) {
            l.sessions.append(["key": .string(key), "agent": .string(s.agent.rawValue), "phase": .string("\(s.phase)"), "repo": .string(s.repo)])
        }
        return l
    }
}
