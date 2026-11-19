import Cocoa
import OverSireCore

// ─── --uishots: the Plan tab ─────────────────────────────────────────────────
// The data of the design (Map.dc.html) in the OVERSIRE snapshot, in memory only. Today is day 0.
// project-plan-summary: the first visit. project-plan-summary-away: the last visit was 7 days ago.

extension UIShots {
    func planState(_ scene: String, in w: AppWindow) {
        defer { if scene.hasPrefix("project-plan-map") { planMapScene(scene, in: w) } }
        guard let snap = projectStore.snapshot("OVERSIRE") else { print("UISHOTS no OVERSIRE project"); return }
        // Leave the page of a scene before, so its visit ends before the seed.
        w.router.go(.activity)
        let opts = snap.statusOptions
        guard let todo = opts.first(where: { $0.group == "unstarted" }), let backlog = opts.first(where: { $0.group == "backlog" }),
              let doing = opts.first(where: { $0.group == "started" }), let done = opts.first(where: { $0.group == "completed" }) else {
            print("UISHOTS plan: needs the backlog, unstarted, started and completed states"); return
        }
        let cal = Calendar.current, now = Date()
        let today = cal.startOfDay(for: now)
        func date(_ d: Int) -> Date { cal.date(byAdding: .day, value: d, to: today)! }
        func ymd(_ d: Int) -> String {
            let c = cal.dateComponents([.year, .month, .day], from: date(d))
            return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        }
        let ref = snap.summary.ref
        let me = snap.me ?? "Ada"
        func epic(_ id: String, _ title: String, _ state: EpicState, _ goal: String, start: Int? = nil, due: Int? = nil) -> Epic {
            Epic(id: EpicID(rawValue: "plan-" + id), title: title, goal: goal, state: state, nativeState: state.rawValue, lead: me,
                 startDate: start.map(date), targetDate: due.map(date), url: "https://plane.example/ocral/projects/oversire/modules/\(id)",
                 project: ref, createdAt: date(-30), updatedAt: date(-1))
        }
        let epics = [
            epic("rd", "Review desk", .active, "Diff, checks and verdicts work. Left: the changes menu and approval checks.", start: -16, due: -2),
            epic("cs", "Cloud store", .active, "Protocol and local store are done. Next: the hub schema, then sync from the Mac.", start: -16, due: 23),
            epic("rb", "Runbooks v2", .active, "The engine runs. Retries are in work; history and templates follow.", start: -13, due: 16),
            epic("ep", "Epics", .active, "Group tickets for one goal.", start: -9, due: 0),
            epic("mc", "Mobile client", .planned, "See what needs you away from the Mac.", due: 40),
            epic("c2", "Contract v2", .planned, "Clean wire fields before the store ships.", due: 16),
            epic("pl", "Planner cloud", .planned, "Order the queue lanes by code area. Paid."),
            epic("ln", "Linear tracker", .planned, "Teams on Linear can use OverSire."),
            epic("gl", "GitLab host", .planned, "Users on GitLab get PRs and CI."),
        ]
        var items: [Item] = []
        func item(_ n: Int, _ e: String, _ status: StatusOption, _ title: String, start: Int? = nil, days: Int? = nil, updated: Int = -10) {
            var fields: [String: String] = [:]
            if let days {
                fields["Start"] = ymd(start ?? 0)
                fields["Due"] = ymd((start ?? 0) + days - 1)
            }
            let key = "OVERSIRE-\(n)"
            items.append(Item(id: "uishots-plan-\(n)", key: key, title: title, url: "https://plane.example/ocral/browse/\(key)", statusOptionId: status.id,
                              fields: fields, assignees: [me], labels: [], author: me, updatedBy: me, updatedAt: date(updated), activityAt: date(updated),
                              commentCount: 0, lastComment: nil, mentionsMe: false, epicId: EpicID(rawValue: "plan-" + e)))
        }
        let finished: [(String, [String])] = [
            ("rd", ["Diff view", "Check list", "Verdict store", "Review list", "Thread view", "Approve button"]),
            ("cs", ["Store protocol", "Local JSON store"]),
            ("rb", ["Run engine", "Step done command", "Runbook editor"]),
            ("ep", ["Epic model", "Event kinds", "Plane modules", "Store actions", "Epics tab", "Epic page", "Burn-up", "Group by epic",
                    "New epic sheet", "Epic picker", "Close epic"]),
        ]
        var n = 300
        for (e, titles) in finished {
            for t in titles {
                item(n, e, done, t, updated: n % 3 == 0 ? -3 : -12)
                n += 1
            }
        }
        item(425, "rd", doing, "Changes menu", start: -1, days: 2)
        item(421, "rd", doing, "Approval checks", start: -2, days: 1)
        item(426, "rd", todo, "Keyboard review", days: 2)
        item(429, "rd", backlog, "Review docs", days: 1)
        item(431, "cs", todo, "Store schema", days: 2)
        item(432, "cs", todo, "Sync from Mac", days: 3)
        item(433, "cs", todo, "Conflict rules", days: 2)
        item(460, "rb", doing, "Step retries", start: -1, days: 2)
        item(461, "rb", todo, "Run history", days: 2)
        item(462, "rb", backlog, "Runbook templates", days: 2)
        item(435, "mc", todo, "Status feed", days: 3)
        item(436, "mc", backlog, "Push alerts", days: 2)
        item(437, "mc", backlog, "Approve from phone", days: 2)
        item(440, "c2", todo, "Rename fields", days: 2)
        item(441, "c2", todo, "Schema check in CI", days: 1)
        item(470, "pl", backlog, "Area claims API", days: 3)
        item(471, "pl", backlog, "Hub order job", days: 3)
        item(450, "ln", todo, "Linear discovery", days: 1)
        item(451, "ln", backlog, "Linear adapter", days: 4)
        item(452, "ln", backlog, "Linear webhooks", days: 2)
        item(480, "gl", backlog, "GitLab discovery", days: 1)
        projectStore.seed(ProjectSnapshot(summary: snap.summary, statusOptions: opts, items: items, fetchedAt: now, fields: snap.fields,
                                          me: snap.me, meId: snap.meId, index: nil, intake: snap.intake, epics: epics))

        let blocks: [Int: [Int]] = [426: [421], 429: [426], 432: [431, 440], 433: [432], 461: [460], 462: [461], 435: [432], 436: [435],
                                    437: [421], 441: [440], 470: [431], 471: [470], 451: [450], 452: [451]]
        let byKey = Dictionary(items.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        for i in items where !snap.isClosed(i.statusOptionId) {
            let rels = (blocks[Int(i.key.dropFirst(9)) ?? 0] ?? []).compactMap { byKey["OVERSIRE-\($0)"]?.ref(in: ref) }.map { ItemRelation(kind: .blockedBy, item: $0) }
            projectStore.relations.seed(i.key, rels)
        }

        agentIndex.hold = true
        for (key, agent, card) in [("OVERSIRE-425", AgentName.claude, "uishots-plan-a"), ("OVERSIRE-460", AgentName.codex, "uishots-plan-b")] {
            agentIndex.seed(key, AgentSession(phase: .working, since: now.addingTimeInterval(-20 * 60), card: card, paneKey: card + "-p",
                                              agent: agent, repo: "oversire", startedAt: now.addingTimeInterval(-20 * 60)))
        }
        let account = ENV.machines?.sessions?.account ?? AccountID(provider: .daemon, id: "mba")
        let session = SessionRef(workspace: WorkspaceRef(account: account, id: "w-plan"), id: "term-plan")
        let id = QuestionID(rawValue: "daemon:mba:plan")
        let ask = QuestionItem(id: "q1", header: "CI", text: "Count a skipped CI job as green?", why: "A skipped job has no result.", kind: .single,
                               options: [.init(label: "Yes"), .init(label: "No")], allowsOther: true)
        let at = now.addingTimeInterval(-3 * 3600)
        let entries = questions.entries.filter { $0.id != id }
            + [QuestionBoard.Entry(question: SessionQuestion(id: id, session: session, origin: .session, items: [ask], via: .form, askedAt: at),
                                   state: .open, firstSeen: at)]
        questions.seed(entries, keys: [session: "OVERSIRE-421"])

        try? memory.saveVision("One quiet place that shows where all my work stands: CI, pull requests, tickets and agents.", of: ref)
        PlanVisits.shared.seed("OVERSIRE", since: scene.hasSuffix("-away") ? date(-7) : nil)
        w.router.go(.project("OVERSIRE"))
        // project-plan-timeline-days: 426 selected, with its tip. project-plan-timeline-weeks: 432 selected, no tip.
        if scene.hasPrefix("project-plan-timeline") {
            DispatchQueue.main.async {
                guard let page = w.page as? ProjectPage else { print("UISHOTS no project page"); return }
                let weeks = scene.hasSuffix("-weeks")
                page.plan.zoom = weeks ? .weeks : .days
                PlanSelection.keys["OVERSIRE"] = "OVERSIRE-432"
                page.show(plan: .timeline, focus: weeks ? nil : "OVERSIRE-426")
            }
        }
    }
}
