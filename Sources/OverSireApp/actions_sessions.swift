import Foundation
import OverSireCore
import OverSireAI
import OverSireAssistant

// The agent session actions: AgentIndex, StatusJob, QuestionHub and Cleaner.
struct SessionActions {
    let link: ActionLink

    var specs: [ActionSpec] {
        let link = link
        let key = ItemActions.key
        return [
            ActionSpec(id: "session.start", title: "Start session", help: "Starts a coding agent session for the item in an Orca workspace. `root` is the workspace path; without it the saved workspace of the project is used.",
                       kind: .outward, input: ActionSpec.args(["key": key, "agent": ("string", "The agent CLI, for example claude or codex. Empty: the project default."),
                                                               "root": ("string", "The Orca workspace path."), "machine": ("string", "Another machine of the group. Use order.start for it.")],
                                                              required: ["key"]), capability: .sessionInput) { a in
                await link.item(a) { d, f, done in
                    if let m = a.string("machine"), !m.isEmpty, m != Host.current().localizedName {
                        done(.notAllowed("session.start runs on this Mac. Use order.start for \(m).")); return
                    }
                    let pk = f.snap.summary.ref.storeKey
                    guard let root = a.string("root").flatMap({ $0.isEmpty ? nil : $0 }) ?? PROJECTS_CFG.orca.roots[pk].flatMap({ $0.isEmpty ? nil : $0 }) else {
                        done(.notAllowed("\(f.snap.summary.identifier) has no saved Orca workspace. Give `root`.")); return
                    }
                    if a.string("root") != nil, PROJECTS_CFG.orca.roots[pk]?.isEmpty ?? true {
                        PROJECTS_CFG.orca.roots[pk] = root
                        saveConfig()
                    }
                    d.agentIndex.start(f.item, root: root, agent: a.string("agent").flatMap { $0.isEmpty ? nil : $0 }) { r in
                        switch r {
                        case .success(let l) where l.reused:
                            done(.notAllowed("\(f.item.key) has a live session on \(d.agentIndex.place) already, so no new session started. OverSire shows that session. Stop it to start a new one."))
                        case .success: done(.ok(summary: "A session for \(f.item.key) starts in \((root as NSString).lastPathComponent)."))
                        case .failure(let e): done(.failed(e.message))
                        }
                    }
                }
            },
            ActionSpec(id: "session.send", title: "Send to session", help: "Types the text into the agent terminal of the item and presses Return.", kind: .outward,
                       input: ActionSpec.args(["key": key, "text": ("string", "The text.")], required: ["key", "text"]), capability: .sessionInput) { a in
                await link.item(a) { d, f, done in
                    guard let text = a.string("text"), !text.isEmpty else { done(.notAllowed("The text is empty.")); return }
                    guard d.agentIndex.agent(f.item.key) != nil else { done(.notAllowed("\(f.item.key) has no session.")); return }
                    d.agentIndex.send(f.item.key, text: text) { e in done(e.map { .failed($0.message) } ?? .ok(summary: "Sent to the session of \(f.item.key).")) }
                }
            },
            ActionSpec(id: "session.reveal", title: "Show terminal", help: "Shows the agent terminal of the item in Orca.", kind: .change,
                       input: ActionSpec.args(["key": key, "card": ("string", "An Orca card id, in place of a key.")]), capability: .reveal) { a in
                await link.run { d, done in
                    if let card = a.string("card") {
                        d.agentIndex.reveal(card: card) { done($0.map { .failed("Orca cannot show the worktree: \($0.message)") } ?? .ok(summary: "Orca shows the worktree.")) }
                        return
                    }
                    guard let k = a.string("key"), d.agentIndex.agent(k) != nil else { done(.notAllowed("Give the key of an item with a session.")); return }
                    d.agentIndex.reveal(k) { done($0.map { .failed("Orca cannot show the terminal: \($0.message)") } ?? .ok(summary: "Orca shows the terminal of \(k.uppercased()).")) }
                }
            },
            ActionSpec(id: "session.history", title: "Session history", help: "Reads the turns of the agent session of the item: the first prompt, earlier turns and the last turn.",
                       kind: .read, input: ActionSpec.args(["key": key], required: ["key"]), capability: .sessionHistory) { a in
                await link.item(a) { d, f, done in
                    d.agentIndex.history(f.item.key) { r in
                        switch r {
                        case .success(let digest): done(.ok(summary: "\(digest.turns) turns.", data: JSONValue(encoding: digest)))
                        case .failure(let e): done(.failed(e.message))
                        }
                    }
                }
            },
            ActionSpec(id: "session.tail", title: "Session screen", help: "Reads the last lines of the agent terminal of the item.", kind: .read,
                       input: ActionSpec.args(["key": key, "lines": ("integer", "The number of lines, at most 200. Default 40.")], required: ["key"]),
                       capability: .sessionTail) { a in
                await link.item(a) { d, f, done in
                    guard d.agentIndex.agent(f.item.key) != nil else { done(.notAllowed("\(f.item.key) has no session.")); return }
                    d.agentIndex.tail(f.item.key, lines: min(200, max(1, a.int("lines") ?? 40))) { lines in
                        done(.ok(summary: lines.isEmpty ? "The screen is empty." : lines.joined(separator: "\n")))
                    }
                }
            },
            ActionSpec(id: "question.answer", title: "Answer question", help: "Answers an open agent question. `answers` maps each question item id to an option label, a list of labels, or free text. With one item, `answer` is enough.",
                       kind: .change, input: ActionSpec.args(["id": ("string", "The question id."), "answers": ("object", "Item id → label, labels or text."),
                                                              "answer": ("string", "The answer of a question with one item."), "note": ("string", "A note for the agent.")],
                                                             required: ["id"]), capability: .questions) { a in
                await link.run { d, done in
                    guard let id = a.string("id"), let e = d.questions.entries.first(where: { $0.question.id.rawValue == id }) else {
                        done(.notAllowed("No open question \(a.string("id") ?? "").")); return
                    }
                    guard e.question.answerable else { done(.notAllowed("This question takes no answer here. Open the session.")); return }
                    var items: [QuestionAnswer.Item] = []
                    for q in e.question.items {
                        let v = a["answers"]?[q.id] ?? (e.question.items.count == 1 ? a["answer"] : nil)
                        let labels = v?.array?.compactMap(\.string) ?? v?.string.map { [$0] } ?? []
                        let known = labels.filter { l in q.options.contains { $0.label == l } }
                        let other = labels.filter { l in !q.options.contains { $0.label == l } }.joined(separator: "\n")
                        guard !labels.isEmpty else { done(.notAllowed("Give an answer for item \(q.id): \(q.text)")); return }
                        guard other.isEmpty || q.allowsOther || q.kind == .free else {
                            done(.notAllowed("Item \(q.id) takes only: \(q.options.map(\.label).joined(separator: ", "))."))
                            return
                        }
                        items.append(QuestionAnswer.Item(id: q.id, choices: known, other: other.isEmpty ? nil : other))
                    }
                    d.questions.answer(e.question.id, QuestionAnswer(question: e.question.id, items: items, note: a.string("note"))) { why in
                        done(why.map { .failed("The answer did not reach the session: \($0)") } ?? .ok(summary: "The answer is sent."))
                    }
                }
            },
            ActionSpec(id: "question.dismiss", title: "Dismiss question", help: "Hides an open question in OverSire. The agent still waits.", kind: .change,
                       input: ActionSpec.args(["id": ("string", "The question id.")], required: ["id"]), capability: .questions) { a in
                await link.run { d, done in
                    guard let id = a.string("id") else { done(.notAllowed("Give the question id.")); return }
                    d.questions.dismiss(QuestionID(rawValue: id))
                    done(.ok(summary: "The question is hidden."))
                }
            },
            status("status.approve", "Approve result", "Accepts the end-of-turn result of the session. A stuck session gets its nudge.") { $0.approve($1, done: $2) },
            status("status.ask", "Ask the agent", "Asks the agent to go on with the open steps of a result that is not finished.") { $0.ask($1, done: $2) },
            status("status.hold", "Hold result", "Keeps the result open for later.") { $0.hold($1); $2(nil) },
            status("status.markBlocked", "Mark blocked", "Marks the session as not finished: it waits for the developer.") { $0.markBlocked($1); $2(nil) },
            status("status.snooze", "Snooze result", "Hides the result for one day.") { $0.snooze($1); $2(nil) },
            ActionSpec(id: "worktree.remove", title: "Remove worktree", help: "Removes the finished worktrees of the item: orca worktree rm, plus merged branches. `force` also removes worktrees with changes that are not in the base branch. `lines` limits the cleanup lines.",
                       kind: .outward, input: ActionSpec.args(["key": key, "force": ("boolean", "Remove also the lines that are not safe."),
                                                               "lines": ("array", "Cleanup line ids. Empty: all lines.")], required: ["key"]),
                       capability: .removeWorkspace) { a in
                await link.run { d, done in
                    guard let k = a.string("key")?.uppercased() else { done(.notAllowed("Give the item key.")); return }
                    let only = Set(a.list("lines"))
                    let lines = d.cleaner.lines(k, data: d).filter {
                        $0.removable && $0.kind != .group && ($0.safe || a.bool("force") == true) && (only.isEmpty || only.contains($0.id))
                    }
                    guard !lines.isEmpty else { done(.notAllowed("\(k) has nothing to remove\(a.bool("force") == true ? "" : " that is safe").")); return }
                    d.cleaner.run(lines, key: k, data: d) { errors in
                        done(errors.isEmpty ? .ok(summary: "Removed \(lines.count) thing\(lines.count == 1 ? "" : "s") of \(k).") : .failed(errors.joined(separator: "\n")))
                    }
                }
            },
        ]
    }

    private func status(_ id: String, _ title: String, _ help: String, _ op: @escaping (StatusJob, String, @escaping (ProviderError?) -> Void) -> Void) -> ActionSpec {
        let link = link
        return ActionSpec(id: id, title: title, help: help + " Give the item key or the status id.", kind: .change,
                          input: ActionSpec.args(["key": ItemActions.key, "id": ("string", "The status id.")])) { a in
            await link.run { d, done in
                guard let s = a.string("id").flatMap({ id in d.statusJob.statuses.first { $0.id == id } }) ?? a.string("key").flatMap({ d.statusJob.status($0) }) else {
                    done(.notAllowed("No session result for \(a.string("key") ?? a.string("id") ?? "it").")); return
                }
                op(d.statusJob, s.id) { err in
                    done(err.map { .failed("Could not send to the session of \(s.key): \($0.message)") } ?? .ok(summary: "\(title): \(s.key)."))
                }
            }
        }
    }
}

extension JSONValue {
    /// Any Encodable value as JSON. nil when it does not encode.
    init?<T: Encodable>(encoding v: T) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(v), let j = try? JSONDecoder().decode(JSONValue.self, from: data) else { return nil }
        self = j
    }
}
