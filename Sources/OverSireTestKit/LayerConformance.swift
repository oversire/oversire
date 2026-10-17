import Foundation
import OverSireCore

public enum TrackerConformance {
    /// Writes one item and one comment in the first open project.
    public static func run(make: @Sendable () async throws -> any Tracker) async -> ConformanceReport {
        var r = ConformanceReport()
        guard let t = await r.step("make", make),
              let projects = await r.step("projects", { try await t.projects() }) else { return r }
        guard let p = projects.first(where: { !$0.closed })?.ref else {
            r.expect(false, "no open project")
            return r
        }
        if let statuses = await r.step("statuses", { try await t.statuses(p) }) {
            let cats = Set(statuses.map(\.category))
            r.expect(cats.contains(.done) && cats.count > 1, "the statuses map to \(cats.map(\.rawValue).sorted()), with no done and open split")
        }
        let title = "Conformance item"
        guard let ref = await r.step("create", { try await t.create(ItemDraft(title: title, bodyMarkdown: "Made by the conformance suite."), in: p) })
        else { return r }
        r.expect(t.keyFormat.keys(in: "Fix \(ref.key) now") == [ref.key.uppercased()], "the key format does not find \(ref.key)")
        r.expect(t.keyFormat.key(inBranch: "feature/\(ref.key.lowercased())-fix") == ref.key.uppercased(), "no key in a branch name")
        if let list = await r.step("items", { try await t.items(p, since: nil, limit: 50) }) {
            r.expect(list.contains { $0.id == ref.id }, "items does not list the new item")
            r.expect(list.map(\.activityAt) == list.map(\.activityAt).sorted(by: >), "items are not newest first")
        }
        if let one = await r.step("items limit 1", { try await t.items(p, since: nil, limit: 1) }) {
            r.expect(one.count <= 1, "items gave \(one.count) items for limit 1")
        }
        if let d = await r.step("detail", { try await t.detail(ref) }) {
            r.expect(d.item.title == title && d.item.key == ref.key, "detail gave \(d.item.key) \(d.item.title)")
        }
        _ = await r.step("update", { try await t.update(ref, ItemPatch(title: title + " 2")) })
        if let d = await r.step("detail after update", { try await t.detail(ref) }) {
            r.expect(d.item.title == title + " 2", "update did not change the title")
        }
        _ = await r.step("comment", { try await t.comment(ref, markdown: "Conformance comment") })
        if let cs = await r.step("comments", { try await t.comments(ref) }) {
            r.expect(cs.contains { $0.body?.contains("Conformance comment") == true }, "comments does not list the new comment")
        }
        r.merge(await settings(t, project: p))
        return r
    }

    /// Reads the project settings. Writes nothing: it sends an empty patch and one field that the adapter cannot write.
    public static func settings(_ t: any Tracker, project p: ProjectRef) async -> ConformanceReport {
        var r = ConformanceReport()
        guard let reader = t as? any ProjectSettingsReading else { return r }
        if let s = await r.step("settings", { try await reader.settings(p) }) {
            r.expect(!s.name.isEmpty, "settings gave no name")
            r.expect(!s.statuses.isEmpty, "settings gave no statuses")
            r.expect(s.readOnlyFeatures.isSubset(of: Set(s.features.keys)), "a read-only feature is not in features")
        }
        guard let editor = t as? any ProjectSettingsEditing else { return r }
        _ = await r.step("update with an empty patch", { try await editor.update(p, ProjectSettingsPatch()) })
        let patches: [(ProjectSettingsField, ProjectSettingsPatch)] = [
            (.name, ProjectSettingsPatch(name: "x")), (.description, ProjectSettingsPatch(description: "x")),
            (.lead, ProjectSettingsPatch(lead: .some(nil))), (.visibility, ProjectSettingsPatch(visibility: .private)),
            (.features, ProjectSettingsPatch(features: [:])), (.labels, ProjectSettingsPatch(newLabels: [])),
        ]
        if let (field, patch) = patches.first(where: { !editor.editableSettings.contains($0.0) }) {
            await r.expectError("update \(field.rawValue), which is not editable", { $0 == .unsupported(.projectSettingsEdit) }) {
                try await editor.update(p, patch)
            }
        }
        return r
    }
}

public enum CodeHostConformance {
    /// Comments on the first open change when the host has changeActions. `sha`: a commit of the first repo.
    public static func run(sha: String = "abc1234", make: @Sendable () async throws -> any CodeHost) async -> ConformanceReport {
        var r = ConformanceReport()
        guard let h = await r.step("make", make), let repos = await r.step("repos", { try await h.repos() }) else { return r }
        guard let repo = repos.first?.ref else {
            r.expect(false, "no repo")
            return r
        }
        r.expect(repos.allSatisfy { $0.ref.account == h.account }, "a repo has an other account")
        guard let changes = await r.step("changes", { try await h.changes(repo, ChangeFilter(limit: 5)) }) else { return r }
        r.expect(changes.count <= 5, "changes gave \(changes.count) for limit 5")
        _ = await r.step("commitMessage", { try await h.commitMessage(repo, sha: sha) })
        guard let c = changes.first, let url = URL(string: c.url) else { return r }
        let ref = ChangeRef(repo: repo, number: c.number, url: url)
        if h.capabilities.contains(.changeActions) {
            _ = await r.step("perform comment", { try await h.perform(.comment("Conformance comment"), on: ref) })
        } else {
            await r.expectError("perform without changeActions", { $0 == .unsupported(.changeActions) }) {
                try await h.perform(.comment("x"), on: ref)
            }
        }
        return r
    }
}

public enum CIConformance {
    /// Runs each RunAction on the newest run of `repo`.
    public static func run(repo: RepoRef, make: @Sendable () async throws -> any CIProvider) async -> ConformanceReport {
        var r = ConformanceReport()
        guard let ci = await r.step("make", make) else { return r }
        _ = await r.step("pipelines", { try await ci.pipelines(repo) })
        guard let runs = await r.step("runs", { try await ci.runs(RunQuery(repo: repo, limit: 3)) }) else { return r }
        r.expect(runs.count <= 3, "runs gave \(runs.count) for limit 3")
        r.expect(runs.map(\.createdAt) == runs.map(\.createdAt).sorted(by: >), "runs are not newest first")
        guard let newest = runs.first else {
            r.expect(false, "no run in \(repo.path)")
            return r
        }
        let ref = RunRef(account: ci.account, repo: repo, id: newest.id, attempt: newest.attempt ?? 1)
        if let one = await r.step("run", { try await ci.run(ref) }) {
            r.expect(one.id == newest.id, "run gave \(one.id) for \(newest.id)")
            r.expect(RunStatus(rawValue: one.status) != nil, "run status \(one.status) is not a RunStatus")
        }
        let jobs = await r.step("jobs", { try await ci.jobs(ref) }) ?? []
        _ = await r.step("failures", { try await ci.failures(ref) })
        if let logs = ci as? any LogReading, let job = jobs.first {
            if let lines = await r.step("log", { try await logs.log(JobRef(run: ref, id: job.id), lines: 5) }) {
                r.expect(lines.count <= 5, "log gave \(lines.count) lines for 5")
            }
        }
        if let jr = ci as? any JobRerunning, ci.capabilities.contains(.rerunJob), let job = jobs.first {
            _ = await r.step("rerun job", { try await jr.rerun(JobRef(run: ref, id: job.id)) })
        }
        for a in RunAction.allCases {
            let need: Capability = a == .cancel ? .cancel : .rerun
            if ci.capabilities.contains(need) {
                _ = await r.step("perform \(a)", { try await ci.perform(a, on: ref) })
            } else {
                await r.expectError("perform \(a) without \(need.rawValue)", { $0 == .unsupported(need) }) { try await ci.perform(a, on: ref) }
            }
        }
        return r
    }
}

public enum RuntimeConformance {
    /// Launches one session, then uses SessionIO and Revealing when the runtime has them.
    public static func run(repo: String, make: @Sendable () async throws -> any AgentRuntime) async -> ConformanceReport {
        var r = ConformanceReport()
        guard let rt = await r.step("make", make) else { return r }
        if let envs = await r.step("environments", { try await rt.environments() }) {
            r.expect(!envs.isEmpty, "no environment")
        }
        _ = await r.step("repos", { try await rt.repos(in: nil) })
        let req = LaunchRequest(repo: repo, name: "CONFORMANCE-1", agent: .claude, prompt: "Say hello.")
        guard let l = await r.step("launch", { try await rt.launch(req) }) else { return r }
        if let ws = await r.step("workspaces", { try await rt.workspaces() }) {
            r.expect(ws.contains { $0.id == l.card }, "workspaces does not list the card \(l.card)")
        }
        let w = WorkspaceRef(account: rt.account, id: l.card)
        guard let sessions = await r.step("sessions", { try await rt.sessions(w) }) else { return r }
        guard let s = sessions.first(where: { $0.ref.id == l.handle })?.ref else {
            r.expect(false, "sessions does not list the handle \(l.handle)")
            return r
        }
        if let io = rt as? any SessionIO {
            _ = await r.step("send", { try await io.send(s, text: "Conformance input") })
            if let lines = await r.step("tail", { try await io.tail(s, lines: 3) }) {
                r.expect(lines.count <= 3, "tail gave \(lines.count) lines for 3")
            }
        }
        if let rv = rt as? any Revealing {
            _ = await r.step("reveal", { try await rv.reveal(s) })
        }
        if let io = rt as? any SessionIO {
            _ = await r.step("close", { try await io.close(s) })
        }
        return r
    }
}
