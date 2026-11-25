import Foundation
import OverSireCore
import OverSireSync

// ─── Notices ─────────────────────────────────────────────────────────────────
// The text of each macOS notification. The title is "<symbol> <event> · <KEY or repo>": the symbol is a shape,
// so color is never the only signal. The subtitle names the thing. The body gives the detail, the most important line first.

/// One macOS notification. `NoticeCenter` posts it.
struct Notice: Equatable {
    enum Level: Equatable { case passive, active, timeSensitive }

    var id: String
    var title: String
    var subtitle = ""
    var body = ""
    /// The stack: the project store key, the repo, or "oversire" for the app.
    var thread: String
    var level: Level = .active
    var category: NoticeCategory?
    var target = NoticeTarget()

    static let appThread = "oversire"
}

/// What the actions of a notice act on.
struct NoticeTarget: Equatable {
    var key: String?
    var itemId: String?
    var project: String?
    var question: String?
    var repo: String?
    var run: String?
    var version: String?
    var request: String?
}

/// The action set of a notice.
enum NoticeCategory: Equatable {
    case item, comment, assigned, open, intake, agentWaiting, agentDone, runbook, ciFailed, problem, update, join
    /// `options` is empty when the question does not fit the buttons.
    case question(options: [String], approve: Bool, reply: Bool)

    var id: String {
        switch self {
        case .item: return "item"
        case .comment: return "comment"
        case .assigned: return "assigned"
        case .open: return "open"
        case .intake: return "intake"
        case .agentWaiting: return "agent-waiting"
        case .agentDone: return "agent-done"
        case .runbook: return "runbook"
        case .ciFailed: return "ci-failed"
        case .problem: return "problem"
        case .update: return "update"
        case .join: return UserJoinNotifier.category
        case .question: return "question"
        }
    }
}

/// What happened to an intake item.
enum IntakeLine: Equatable {
    case new, changed, accepted(key: String), declined
}

// MARK: - Tracker

extension Notice {
    /// The net change of one item in its window. Nil when the changes cancel.
    static func item(_ net: ItemNet, item: Item?, itemId: String, in snap: ProjectSnapshot, zone: TimeZone = .current) -> Notice? {
        guard !net.isEmpty else { return nil }
        let key = item?.key ?? snap.summary.title
        let me = snap.me?.lowercased()
        let toMe = me != nil && net.assigned.contains { $0.lowercased() == me }
        let status = net.status
        let comments = net.comments

        // The parts in headline order. The first is the headline; the others add a line to the body.
        var parts: [(title: String, body: String, level: Level, category: NoticeCategory, line: String?)] = []
        var mentionQuotesComment = false
        if net.mention {
            let comment = comments?.last ?? (net.added ? nil : item?.lastComment)
            mentionQuotesComment = comment != nil
            let who = comment != nil ? comment?.author : item?.author
            let text = quote(comment != nil ? comment?.body : item?.body)
            parts.append((who.map { "@ \($0) mentioned you · \(key)" } ?? "@ Mentioned you · \(key)", text ?? "", .active, .comment, nil))
        }
        if toMe {
            parts.append(("→ Assigned to you · \(key)", facts(item, by: item?.updatedBy, in: snap), .active, .assigned, "Assigned to you."))
        }
        if case let (n, last)? = comments {
            let title = n == 1 ? "💬 \(last.author ?? "New comment") · \(key)" : "💬 \(n) comments · \(key)"
            let line = n == 1 ? (mentionQuotesComment ? nil : "New comment by \(last.author ?? "someone").") : "\(n) new comments."
            parts.append((title, quote(last.body) ?? (n == 1 ? "New comment." : ""), .active, .comment, line))
        }
        let from = status?.from, to = status?.to
        let now = [to.map { "Now \($0)." }, from.map { "Was \($0)." }].compactMap { $0 }.joined(separator: " ")
        switch net.move {
        case .none:
            if let status {
                if status.from != status.to {
                    parts.append(("→ \(to ?? "None") · \(key)", "Was \(from ?? "none").", .active, .item, now))
                } else {
                    let body = status.steps == 1 ? "Set again." : "Changed and set back. No net change."
                    parts.append(("→ \(to ?? "None") · \(key)", body, .passive, .item, nil))
                }
            }
        case .closed:
            parts.append(("✓ \(to ?? "Closed") · \(key)", from.map { "Was \($0)." } ?? "", .active, .item, now.isEmpty ? "Closed." : now))
        case .reopened:
            let body = [to.map { "\($0)." }, from.map { "Was \($0)." }].compactMap { $0 }.joined(separator: " ")
            parts.append(("↺ Reopened · \(key)", body, .active, .item, "Reopened." + (to.map { " Now \($0)." } ?? "")))
        case .closedAgain:
            let body = [net.reopenedAt.map { "Reopened at \(clock($0, zone: zone))" }, net.closedAt.map { "closed at \(clock($0, zone: zone))" }]
                .compactMap { $0 }.joined(separator: ", ")
            parts.append(("✓ \(to ?? "Closed") again · \(key)", body + ". No net change.", .passive, .item, nil))
        case .reopenedAgain:
            let body = [net.closedAt.map { "Closed at \(clock($0, zone: zone))" }, net.reopenedAt.map { "reopened at \(clock($0, zone: zone))" }]
                .compactMap { $0 }.joined(separator: ", ")
            parts.append(("↺ \(to ?? "Open") again · \(key)", body + ". No net change.", .passive, .item, nil))
        }
        if net.added {
            parts.append(("＋ New item · \(key)", facts(item, by: item?.author, in: snap), .active, .item, "New item."))
        }
        if net.removed {
            parts.append(("✕ Removed · \(key)", "It is no longer in the project.", .passive, .item, "Removed."))
        }
        let others = net.assigned.filter { $0.lowercased() != me }.map { "Assigned \($0)" } + net.unassigned.map { "Unassigned \($0)" }
        let fields = net.fields.map { "\($0.name): \($0.from ?? "none") → \($0.to ?? "none")" } + (others.isEmpty ? [] : [others.joined(separator: ", ")])
        if !fields.isEmpty {
            let count = net.fields.count + (others.isEmpty ? 0 : 1)
            let name = net.fields.first?.name ?? "Assignees"
            let lines = fields.joined(separator: "\n")
            parts.append((count == 1 ? "✎ \(name) · \(key)" : "✎ \(count) fields · \(key)", lines, .passive, .item, lines))
        }
        guard let head = parts.first else { return nil }
        let body = ([head.body] + parts.dropFirst().compactMap { $0.line }).filter { !$0.isEmpty }.joined(separator: "\n")
        let project = snap.summary.ref.storeKey
        return Notice(id: "project:\(itemId)", title: head.title, subtitle: item?.title ?? "Work item", body: body, thread: project,
                      level: head.level, category: head.category, target: NoticeTarget(key: item?.key, itemId: itemId, project: project))
    }

    /// "Todo · Priority High · by Ada".
    private static func facts(_ item: Item?, by who: String?, in snap: ProjectSnapshot) -> String {
        let priority = item?.fields["Priority"].flatMap { $0.isEmpty || $0.lowercased() == "none" ? nil : "Priority \($0)" }
        return [snap.statusName(item?.statusOptionId), priority, who.map { "by \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }

    static func intake(_ i: IntakeItem, _ line: IntakeLine, body: String?, in snap: ProjectSnapshot) -> Notice {
        let project = snap.summary.ref.storeKey
        var n = Notice(id: "intake:\(project)|\(i.workItemId)", title: "", subtitle: i.name, thread: project, category: .intake,
                       target: NoticeTarget(itemId: i.workItemId, project: project))
        let name = snap.summary.title
        switch line {
        case .new:
            n.title = "＋ Intake · \(name)"
            n.body = excerpt(body) ?? i.author.map { "From \($0)." } ?? ""
        case .changed:
            n.title = "✎ Intake changed · \(name)"
            n.body = "The name or the priority changed."
            n.level = .passive
        case .accepted(let key):
            n.title = "✓ Intake accepted · \(name)"
            n.body = "Now \(key)."
            n.target.key = key
        case .declined:
            n.title = "✕ Intake declined · \(name)"
            n.body = "Declined or removed in the tracker."
        }
        return n
    }
}

// MARK: - Agents and runbooks

extension Notice {
    /// "Needs your input" or "Agent done" for the session of an item.
    static func agent(_ key: String, _ a: AgentSession, item: Item?, project: ProjectSnapshot?) -> Notice {
        let waiting = a.phase == .waiting
        let k = item?.key ?? key
        let text = waiting ? AgentSession.question(in: a.message) ?? a.message : a.message
        let store = project?.summary.ref.storeKey
        return Notice(id: "agent:" + (item?.id ?? key), title: waiting ? "⏸ Needs your input · \(k)" : "✓ Agent done · \(k)",
                      subtitle: subtitle(a.agent, item), body: excerpt(text, limit: 200) ?? "", thread: store ?? appThread,
                      level: waiting ? .timeSensitive : .active, category: waiting ? .agentWaiting : .agentDone,
                      target: NoticeTarget(key: k, itemId: item?.id, project: store))
    }

    static func question(_ q: SessionQuestion, key: String?, agent: AgentName?, item: Item?, project: ProjectSnapshot?) -> Notice {
        let first = q.items.first
        let fits = q.items.count == 1 && first?.kind == .single && (first?.options.count ?? 0) <= 3
        let reply = first.map { $0.kind == .free || $0.allowsOther } ?? false
        let category = NoticeCategory.question(options: fits ? first?.options.map(\.label) ?? [] : [],
                                               approve: q.items.count == 1 && first?.kind == .approve, reply: reply)
        let store = project?.summary.ref.storeKey
        return Notice(id: "agent:" + (key ?? "question"), title: "? Question · \(key ?? "Session")", subtitle: subtitle(agent, item),
                      body: excerpt(first?.text, limit: 200) ?? "", thread: store ?? appThread, level: .timeSensitive, category: category,
                      target: NoticeTarget(key: key, itemId: item?.id, project: store, question: q.id.rawValue))
    }

    static func runbook(_ r: RunbookRun, _ row: NeedsYou, project: ProjectSnapshot?) -> Notice {
        var subtitle = r.runbook.name
        if let cur = r.current, let pos = r.position {
            subtitle += " · step \(pos) of \(r.runbook.steps.count): \(r.runbook.step(cur)?.name ?? cur)"
        }
        let store = project?.summary.ref.storeKey
        return Notice(id: "runbook:" + row.key, title: "⏸ Runbook waits · \(row.key)", subtitle: subtitle, body: row.reason,
                      thread: store ?? appThread, level: .timeSensitive, category: .runbook,
                      target: NoticeTarget(key: row.key, project: store, run: r.id.rawValue))
    }

    /// "Claude · Item title".
    private static func subtitle(_ agent: AgentName?, _ item: Item?) -> String {
        let name = agent.map { $0.rawValue.prefix(1).uppercased() + $0.rawValue.dropFirst() }
        return [name, item?.title].compactMap { $0 }.joined(separator: " · ")
    }
}

// MARK: - CI

extension Notice {
    static func ciStarted(repo: String, _ run: Run) -> Notice {
        Notice(id: "start-\(run.url)", title: "▶ CI started · \(repo)", subtitle: "\(run.workflowName ?? run.name) · \(run.headBranch)",
               thread: repo, level: .passive, target: NoticeTarget(repo: repo, run: run.id))
    }

    /// `failure`: the first failed job, when its jobs doc is in. `linked`: the item key of the run.
    static func ciEnded(repo: String, _ run: Run, failure: CIFailureView?, linked: String?) -> Notice {
        var n = Notice(id: "end-\(run.url)", title: "", subtitle: ciSubtitle(run, duration: true), thread: repo, category: .open,
                       target: NoticeTarget(key: linked, repo: repo, run: run.id))
        switch run.conclusion ?? "" {
        case "success":
            n.title = "✓ CI passed · \(repo)"
            n.level = .passive
        case "failure", "timed_out", "startup_failure":
            n.title = "✕ CI failed · \(repo)"
            n.category = .ciFailed
            let at = failure.map { f in "Failed at \(f.job)" + (f.step.map { " › \($0)" } ?? "") + "." }
            n.body = [at, linked.map { "Linked to \($0)." }].compactMap { $0 }.joined(separator: " ")
        case "cancelled":
            n.title = "⊘ CI cancelled · \(repo)"
        default:
            n.title = "⊘ CI \((run.conclusion ?? "ended").replacingOccurrences(of: "_", with: " ")) · \(repo)"
            n.level = .passive
        }
        return n
    }

    static func rerunFailed(repo: String, _ run: Run, errors: [String]) -> Notice {
        let refused = errors.contains { $0.contains("403") }
        return Notice(id: "rerun-\(run.url)", title: "✕ Re-run failed · \(repo)", subtitle: ciSubtitle(run, duration: false),
                      body: refused ? "GitHub refused the re-run (HTTP 403). Check the gh login scopes." : errors.joined(separator: "\n"),
                      thread: repo, category: .open, target: NoticeTarget(repo: repo, run: run.id))
    }

    /// "release · main · 4m 12s".
    private static func ciSubtitle(_ run: Run, duration: Bool) -> String {
        let d = duration ? run.durationText : ""
        return [run.workflowName ?? run.name, run.headBranch, d].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - OverSire

extension Notice {
    static func problem(_ p: Problem, zone: TimeZone = .current) -> Notice {
        let name = p.name.prefix(1).uppercased() + p.name.dropFirst()
        let place = p.area == .net ? p.subject : p.host ?? p.subject
        return Notice(id: "problem-" + p.key, title: "⚠ \(name) fails" + (place.map { " · \($0)" } ?? ""),
                      subtitle: "Since \(clock(p.first, zone: zone)) · \(p.count == 1 ? "1 try" : "\(p.count) tries")",
                      body: p.message, thread: appThread, category: .problem)
    }

    static func updateReady(_ v: String) -> Notice {
        // OVERSIRE-603 adds "Install now". Until then the body tells where to install.
        Notice(id: "update-ready-\(v)", title: "⬆ Update ready · OverSire \(v)", body: "Install it from Settings › General.",
               thread: appThread, category: .update, target: NoticeTarget(version: v))
    }

    static func updated(_ v: String) -> Notice {
        Notice(id: "updated-\(v)", title: "✓ Updated · OverSire \(v)", body: "The new version is running.", thread: appThread,
               level: .passive, target: NoticeTarget(version: v))
    }

    static func join(_ r: JoinRequestFrame, group: String) -> Notice {
        Notice(id: ApproveCenter.prefix + r.request, title: "⊕ Join request · \(r.machine)", subtitle: group,
               body: "Code \(r.confirm). Check that the same code shows on \(r.machine).", thread: appThread, level: .timeSensitive,
               category: .join, target: NoticeTarget(request: r.request))
    }
}

// MARK: - Text

extension Notice {
    /// The excerpt in straight quotes.
    static func quote(_ markdown: String?, limit: Int = 180) -> String? {
        excerpt(markdown, limit: limit).map { "\"\($0)\"" }
    }

    /// Markdown as one line of plain text, at most `limit` characters. Nil when no text stays.
    static func excerpt(_ markdown: String?, limit: Int = 180) -> String? {
        guard var t = markdown else { return nil }
        let rules: [(String, String)] = [
            ("```[\\s\\S]*?```", " "),                          // code blocks
            ("!\\[[^\\]]*\\]\\([^)]*\\)", " "),                // images
            ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"),              // links: the text stays
            ("<[^>]+>", " "),                                  // HTML tags
            ("(?m)^\\s{0,3}(#{1,6}|>|[-*+]|\\d+\\.)\\s+", ""), // headings, quotes, list marks
            ("\\*\\*|__|~~|`", ""),
            ("\\s+", " "),
        ]
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        guard t.count > limit else { return t }
        return t.prefix(limit - 1).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// "11:42".
    static func clock(_ d: Date, zone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
