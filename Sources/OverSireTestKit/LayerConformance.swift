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
            r.expect(Set(list.map(\.id)).count == list.count, "items gives one id more than one time")
        }
        if let one = await r.step("items limit 1", { try await t.items(p, since: nil, limit: 1) }) {
            r.expect(one.count <= 1, "items gave \(one.count) items for limit 1")
        }
        if let s = t as? any ItemSearching, t.capabilities.contains(.itemSearch),
           let hits = await r.step("search", { try await s.search(title, in: [p], limit: 10) }) {
            r.expect(hits.count <= 10, "search gave \(hits.count) items for limit 10")
            r.expect(hits.contains { $0.id == ref.id }, "search for \"\(title)\" does not find \(ref.key)")
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
        r.merge(await relations(t, item: ref, project: p))
        r.merge(await attachments(t, item: ref))
        r.merge(await intakeAndAttachments(t, project: p))
        return r
    }

    /// Makes one intake item, attaches one small file, then deletes the intake item.
    public static func intakeAndAttachments(_ t: any Tracker, project p: ProjectRef) async -> ConformanceReport {
        var r = ConformanceReport()
        guard let maker = t as? any IntakeCreating, t.capabilities.contains(.intakeCreate) else { return r }
        guard let made = await r.step("createIntake", { try await maker.createIntake(ItemDraft(title: "Conformance intake"), in: p) })
        else { return r }
        r.expect(!made.item.key.isEmpty && t.keyFormat.keys(in: made.item.key) == [made.item.key.uppercased()],
                 "createIntake gave the key \(made.item.key)")
        r.expect(made.intake.workItemId == made.item.id, "the intake item names another work item")
        if let up = t as? any AttachmentUploading, t.capabilities.contains(.attachments) {
            let file = AttachmentUpload(name: "conformance.txt", mimeType: "text/plain", data: Data("conformance".utf8))
            if let id = await r.step("attach", { try await up.attach(file, to: made.item) }) {
                r.expect(!id.isEmpty, "attach gave no id")
            }
        }
        _ = await r.step("delete the intake item", { try await maker.triage(made.intake, in: p, .delete) })
        return r
    }

    /// Lists the files of an item and asks for the link of the first one. Read only.
    public static func attachments(_ t: any Tracker, item ref: ItemRef) async -> ConformanceReport {
        var r = ConformanceReport()
        guard let rd = t as? any AttachmentReading, t.capabilities.contains(.attachmentsRead),
              let list = await r.step("attachments", { try await rd.attachments(of: ref) }) else { return r }
        r.expect(Set(list.map(\.id)).count == list.count, "attachments gives one id more than one time")
        r.expect(list.allSatisfy { !$0.name.isEmpty && $0.size >= 0 && !$0.mimeType.isEmpty }, "an attachment has no name, size or type")
        r.expect(list.map(\.createdAt) == list.map(\.createdAt).sorted(), "attachments are not oldest first")
        if let a = list.first, let u = await r.step("attachmentURL", { try await rd.attachmentURL(a, of: ref) }) {
            r.expect(u.scheme == "https" || u.isFileURL, "the link of \(a.name) is \(u)")
        }
        return r
    }

    /// Adds one blockedBy relation from `item` to a second new item, reads it from both sides, then removes it.
    public static func relations(_ t: any Tracker, item ref: ItemRef, project p: ProjectRef) async -> ConformanceReport {
        var r = ConformanceReport()
        guard let rm = t as? any RelationManaging, t.capabilities.contains(.relations) else { return r }
        guard let other = await r.step("create blocker", { try await t.create(ItemDraft(title: "Conformance blocker"), in: p) })
        else { return r }
        let rel = ItemRelation(kind: .blockedBy, item: other)
        _ = await r.step("relations add", { try await rm.apply(RelationPatch(add: [rel]), to: ref) })
        if let list = await r.step("relations", { try await rm.relations(of: ref) }) {
            r.expect(list.contains { $0.kind == .blockedBy && $0.item.id == other.id }, "relations does not list the new blocker")
        }
        if let back = await r.step("relations of the blocker", { try await rm.relations(of: other) }) {
            r.expect(back.contains { $0.kind == .blocks && $0.item.id == ref.id }, "the blocker does not list blocks \(ref.key)")
        }
        _ = await r.step("relations remove", { try await rm.apply(RelationPatch(remove: [rel]), to: ref) })
        if let list = await r.step("relations after remove", { try await rm.relations(of: ref) }) {
            r.expect(!list.contains { $0.item.id == other.id }, "remove did not remove the blocker")
        }
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
        if let cl = h as? any CollaboratorListing, h.capabilities.contains(.collaborators),
           let people = await r.step("collaborators", { try await cl.collaborators(repo) }) {
            r.expect(!people.isEmpty, "collaborators of \(repo.path) gave no person")
            r.expect(people.allSatisfy { !$0.id.isEmpty }, "a collaborator has no id")
        }
        guard let c = changes.first, let url = URL(string: c.url) else { return r }
        let ref = ChangeRef(repo: repo, number: c.number, url: url)
        if let cs = h as? any ChangeSearching, h.capabilities.contains(.changeSearch),
           let hits = await r.step("search", { try await cs.search(c.title, limit: 5) }) {
            r.expect(hits.count <= 5, "search gave \(hits.count) changes for limit 5")
            r.expect(!hits.isEmpty, "search for \"\(c.title)\" gave no change")
        }
        if h.capabilities.contains(.changeActions) {
            _ = await r.step("perform comment", { try await h.perform(.comment("Conformance comment"), on: ref) })
        } else {
            await r.expectError("perform without changeActions", { $0 == .unsupported(.changeActions) }) {
                try await h.perform(.comment("x"), on: ref)
            }
        }
        if let bd = h as? any BranchDeleting, let heads = await r.step("changes of head", { try await bd.changes(repo, head: c.headRefName) }) {
            r.expect(heads.contains { $0.number == c.number }, "changes of head \(c.headRefName) do not list #\(c.number)")
            r.expect(heads.allSatisfy { $0.headRefName == c.headRefName }, "changes of head list an other head")
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
        if let hf = rt as? any HostFileWriting {
            let file = HostFile(name: "conformance.txt", data: Data("hello".utf8))
            if let paths = await r.step("writeFiles", { try await hf.writeFiles([file], workspacePath: repo, dir: "/tmp/oversire/conformance") { _, _ in } }) {
                r.expect(paths.count == 1, "writeFiles gave \(paths.count) paths for 1 file")
            }
        }
        if let io = rt as? any SessionIO {
            _ = await r.step("close", { try await io.close(s) })
        }
        if let rm = rt as? any WorkspaceRemoving, let ws = try? await rt.workspaces(), let card = ws.first(where: { $0.id == l.card }) {
            r.expect(card.kind != .main, "the launch card \(l.card) is a main checkout")
            _ = await r.step("remove", { try await rm.remove(card, force: true, runHooks: false) })
            if let after = await r.step("workspaces after remove", { try await rt.workspaces() }) {
                r.expect(!after.contains { $0.id == l.card }, "workspaces still lists the removed card \(l.card)")
            }
        }
        return r
    }
}

public enum QuestionChannelConformance {
    /// Reads the open questions of `sessions` twice, answers the first answerable one twice,
    /// and checks the form questions and the questions that are not answerable. The channel must have at least one answerable question.
    public static func run(sessions: [SessionRef], make: @Sendable () async throws -> any QuestionChannel) async -> ConformanceReport {
        var r = ConformanceReport()
        guard let ch = await r.step("make", make) else { return r }
        r.merge(ProviderConformance.capabilities(ch))
        r.expect(ch.capabilities.contains(.questions), "a QuestionChannel needs the capability questions")
        guard let first = await r.step("openQuestions", { try await ch.openQuestions(in: sessions) }),
              let second = await r.step("openQuestions again", { try await ch.openQuestions(in: sessions) }) else { return r }
        r.expect(first.map(\.id) == second.map(\.id), "two reads give other ids: \(first.map(\.id)) and \(second.map(\.id))")
        r.expect(Set(first.map(\.id)).count == first.count, "a read has two questions with the same id")
        for q in first {
            r.expect(sessions.contains(q.session), "question \(q.id) is for a session that was not asked for")
            r.expect(!q.items.isEmpty, "question \(q.id) has no items")
        }

        for q in first where q.via == .form {
            r.expect(q.answerable, "form question \(q.id) is not answerable")
        }
        for q in first where !q.answerable {
            do {
                _ = try await ch.answer(q, answer(for: q))
                r.expect(false, "answer on question \(q.id) that is not answerable did not throw")
            } catch let e as QuestionError {
                r.expect(e == .notAnswerable, "answer on question \(q.id) threw \(e)")
            } catch {
                r.expect(false, "answer on question \(q.id) threw \(error), not QuestionError.notAnswerable")
            }
        }

        guard let q = first.first(where: \.answerable) else {
            r.expect(false, "no answerable question to test")
            return r
        }
        let a = answer(for: q)
        r.expect((try? q.validate(a)) != nil, "the sample answer does not fit question \(q.id)")
        if let res = await r.step("answer", { try await ch.answer(q, a) }) {
            r.expect(res == .sent, "answer gave \(res), not sent")
        }
        if let res = await r.step("answer again", { try await ch.answer(q, a) }) {
            r.expect(res == .sent || res == .alreadyAnswered, "a repeated answer gave \(res)")
        }
        if let after = await r.step("openQuestions after the answer", { try await ch.openQuestions(in: sessions) }) {
            r.expect(!after.contains { $0.id == q.id }, "question \(q.id) is still open after the answer")
        }
        let missing = SessionQuestion(id: QuestionID(rawValue: q.id.rawValue + "-missing"), session: q.session, origin: q.origin,
                                      items: q.items, via: q.via, askedAt: q.askedAt)
        if let res = await r.step("answer a question that is not open", { try await ch.answer(missing, answer(for: missing)) }) {
            r.expect(res == .alreadyAnswered || res == .gone, "answer on a question that is not open gave \(res)")
        }
        return r
    }

    /// A valid answer: the first option of each item, or a short text.
    public static func answer(for q: SessionQuestion) -> QuestionAnswer {
        QuestionAnswer(question: q.id, items: q.items.map { i in
            if let o = i.options.first { return QuestionAnswer.Item(id: i.id, choices: [o.label]) }
            return QuestionAnswer.Item(id: i.id, other: "Conformance answer")
        })
    }
}
