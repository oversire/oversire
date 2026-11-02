import Cocoa
import OverSireCore

// ─── --uishots: reviews ──────────────────────────────────────────────────────
// Sample reviews on two machines (OVERSIRE-371, OVERSIRE-372). The app does not link the test kit,
// so the samples go straight into REVIEWS, with no daemon reads.

extension UIShots {
    /// review:list, changes, split, wrap, plan, submit, approve, merge, conflict or empty.
    /// The file panel (OVERSIRE-386): files (list view), search, filters (one repo, no changed files), pending (the popover) and hover.
    func reviewState(_ scene: String, in w: AppWindow) {
        Self.seedReviews(empty: scene == "empty")
        guard let code = REVIEWS.review("FRITZ-17", kind: .code).flatMap({ REVIEWS.desk($0) }),
              let plan = REVIEWS.review("OVERSIRE-349", kind: .plan).flatMap({ REVIEWS.desk($0) }) else {
            w.router.go(.work(.review))
            return
        }
        code.split = scene == "split"
        code.wrap = scene == "wrap"
        code.view = scene == "files" ? .list : .tree
        if scene == "search" { code.filter.query = "review" }
        if scene == "filters" {
            code.filter.repo = "oversire"
            code.filter.hidden = [.changed]
        }
        code.pick = scene == "changes" ? LinePick(repo: "oversire", path: "Sources/OverSireApp/review_tab.swift", side: .new, line: 41).click(43, side: .new, shift: true) : nil
        plan.block = scene == "plan" ? "risks" : nil
        switch scene {
        case "changes", "split", "wrap", "files", "search", "filters": w.router.go(.item("FRITZ-17", .changes))
        case "pending", "hover":
            w.router.go(.item("FRITZ-17", .changes))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard let root = w.window?.contentView else { return }
                if scene == "hover" {
                    (Self.find(root) { $0 is DiffLineBox && $0.frame.height > 0 && $0.visibleRect.height > 0 } as? DiffLineBox)?.showPlus()
                } else {
                    (Self.find(root) { ($0 as? Chiplet)?.onClick != nil && ($0.accessibilityLabel() ?? "").contains("pending") } as? Chiplet)?.onClick?()
                }
            }
        case "plan": w.router.go(.item("OVERSIRE-349", .plan))
        case "submit", "approve", "merge":
            w.router.go(.item("FRITZ-17", .changes))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if scene == "merge" {
                    ReviewMergeSheet(desk: code) {}.present(over: w.window)
                } else {
                    ReviewSubmitSheet(desk: code, verdict: scene == "approve" ? .approve : .requestChanges) { _ in }.present(over: w.window)
                }
            }
        case "conflict":
            w.router.go(.work(.review))
            if let s = REVIEWS.review("SLING-88", kind: .code), let d = REVIEWS.desk(s) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { ReviewMergeSheet(desk: d) {}.present(over: w.window) }
            }
        default: w.router.go(.work(.review))
        }
    }

    /// The sample rows and desks. They replace the rows of the last scene.
    static func seedReviews(empty: Bool = false) {
        REVIEWS.reads = false
        guard !empty else {
            REVIEWS.set([:])
            return
        }
        let now = Date()
        func ago(_ m: Double) -> Date { now.addingTimeInterval(-m * 60) }
        let tab = "Sources/OverSireApp/review_tab.swift"

        // FRITZ-17: code, round 1 answered, the agent handed off again. Two repos; the base of cli moved.
        let oversire = ReviewRepo(name: "oversire", branch: "fritz-17", base: "main", ahead: 3, added: 214, removed: 38, files: 3,
                                  commits: [ReviewCommit(sha: "4f1c2a9e", subject: "Review tab: group rows and counts"),
                                            ReviewCommit(sha: "9b7d01c3", subject: "Review tab: arrows move between rows"),
                                            ReviewCommit(sha: "c0ffee12", subject: "Answer review round 1")])
        let cli = ReviewRepo(name: "cli", branch: "fritz-17", base: "main", ahead: 1, behind: 2, added: 41, removed: 6, files: 1, merge: .rebase,
                             commits: [ReviewCommit(sha: "77aa31b0", subject: "review: list route")])
        let fritz = ReviewSummary(key: "FRITZ-17", kind: .code, title: "Review gate for agent work", machine: "mba", state: .ready, round: 1,
                                  pending: 1, root: "/Users/ada/src/oversire-workspace", group: "/Users/ada/src/oversire-workspace/.wt/fritz-17",
                                  repos: [oversire, cli], subitems: ["FRITZ-18", "FRITZ-19"],
                                  session: ReviewSession(id: "s_1", state: .idle, harness: "claude", canSend: true),
                                  note: "Fixed both comments of round 1. Tests pass.", readyAt: ago(14), updatedAt: ago(12))
        let files = [
            ReviewFile(repo: "oversire", path: tab, status: .added, added: 180, removed: 0),
            ReviewFile(repo: "oversire", path: "Sources/OverSireApp/work_page.swift", status: .modified, added: 22, removed: 30, viewed: true),
            ReviewFile(repo: "oversire", path: "Sources/OverSireApp/status_icon.swift", status: .modified, added: 12, removed: 8),
            ReviewFile(repo: "oversire", path: "Sources/OverSireApp/review_list.swift", status: .deleted, added: 0, removed: 64),
            ReviewFile(repo: "oversire", path: "Sources/OverSireCore/Review.swift", status: .added, added: 96, removed: 0),
            ReviewFile(repo: "oversire", path: "Tests/OverSireAppTests/ReviewTabTests.swift", status: .added, added: 58, removed: 0),
            ReviewFile(repo: "oversire", path: "docs/reviews.md", status: .modified, added: 14, removed: 2),
            ReviewFile(repo: "cli", path: "review/routes.go", status: .modified, added: 41, removed: 6),
            ReviewFile(repo: "cli", path: "review/routes_test.go", status: .added, added: 33, removed: 0),
            ReviewFile(repo: "cli", path: "server/old_review.go", status: .deleted, added: 0, removed: 21),
        ]
        let comments = [
            ReviewComment(id: "c_00000001", key: "FRITZ-17", round: 1, state: .answered,
                          anchor: .code(repo: "oversire", path: tab, line: 22, side: .new), text: "Use the Okabe-Ito orange here, not red.",
                          reply: "Changed to Palette.warn, with the ◆ glyph.", createdAt: ago(80), answeredAt: ago(15)),
            ReviewComment(id: "c_00000002", key: "FRITZ-17", round: 1, state: .answered,
                          anchor: .code(repo: "oversire", path: tab, line: 36, from: 34, side: .new), text: "Say how many commits the base has.",
                          reply: "The rebase line now shows the count.", createdAt: ago(79), answeredAt: ago(15)),
            ReviewComment(id: "c_00000003", key: "FRITZ-17", round: 2, state: .pending,
                          anchor: .code(repo: "oversire", path: tab, line: 30, side: .new), excerpt: "    init(_ r: ReviewRepo) {",
                          text: "Add a doc comment: this is the merge of one repo, not the review.", createdAt: ago(3)),
        ]
        let rounds = [ReviewRound(n: 1, verdict: .requestChanges, count: 2, submittedAt: ago(78), delivery: .sent, session: "s_1",
                                  deliveredAt: ago(78), answeredAt: ago(15))]
        let diff = FileDiff(repo: "oversire", path: tab, status: .added, hunks: [
            DiffHunk(oldStart: 18, oldLines: 9, newStart: 18, newLines: 12, header: "struct ReviewMark: Hashable {", lines: [
                DiffLine(kind: .ctx, old: 18, new: 18, text: "    }"),
                DiffLine(kind: .ctx, old: 19, new: 19, text: ""),
                DiffLine(kind: .ctx, old: 20, new: 20, text: "    init(_ s: ReviewSummary) {"),
                DiffLine(kind: .ctx, old: 21, new: 21, text: "        switch s.state {"),
                DiffLine(kind: .del, old: 22, text: "        case .ready: self.init(\"◆\", Palette.bad, \"Your turn\")"),
                DiffLine(kind: .add, new: 22, text: "        case .ready: self.init(\"◆\", Palette.warn, \"Your turn\")"),
                DiffLine(kind: .ctx, old: 23, new: 23, text: "        case .waiting: self.init(\"●\", Palette.run, \"Agent working\")"),
                DiffLine(kind: .ctx, old: 24, new: 24, text: "        case .conflict: self.init(\"✕\", Palette.bad, \"Conflict\")"),
                DiffLine(kind: .ctx, old: 25, new: 25, text: "        case .merged: self.init(\"✓\", Palette.ok, \"Merged\")"),
                DiffLine(kind: .ctx, old: 26, new: 26, text: "        }"),
            ]),
            DiffHunk(oldStart: 28, oldLines: 6, newStart: 28, newLines: 16, header: "struct ReviewMark: Hashable {", lines: [
                DiffLine(kind: .ctx, old: 28, new: 28, text: ""),
                DiffLine(kind: .add, new: 29, text: "    /// The merge of a repo into its base."),
                DiffLine(kind: .add, new: 30, text: "    init(_ r: ReviewRepo) {"),
                DiffLine(kind: .add, new: 31, text: "        switch r.merge {"),
                DiffLine(kind: .add, new: 32, text: "        case .fastForward: self.init(\"✓\", Palette.ok, \"\\(r.base) fast-forward\")"),
                DiffLine(kind: .del, old: 29, text: "        case .rebase: self.init(\"▲\", Palette.warn, \"base moved\")"),
                DiffLine(kind: .add, new: 33, text: "        case .rebase: self.init(\"▲\", Palette.warn, \"\\(r.base) moved \\(r.behind)\")"),
                DiffLine(kind: .add, new: 34, text: "        case .conflict: self.init(\"✕\", Palette.bad, \"Conflict with \\(r.base)\")"),
                DiffLine(kind: .add, new: 35, text: "        }"),
                DiffLine(kind: .add, new: 36, text: "    }"),
                DiffLine(kind: .ctx, old: 30, new: 37, text: ""),
                DiffLine(kind: .ctx, old: 31, new: 38, text: "    func view(size: CGFloat = 12.5) -> NSTextField {"),
                DiffLine(kind: .del, old: 32, text: "        NSTextField.text(glyph, size: size, color: color)"),
                DiffLine(kind: .add, new: 39, text: "        let f = NSTextField.text(glyph, size: size, weight: .bold, color: color)"),
                DiffLine(kind: .add, new: 40, text: "        f.setAccessibilityLabel(word) // The word reads the state, so color is never the only signal. A long line shows the wrap toggle."),
                DiffLine(kind: .add, new: 41, text: "        return f"),
                DiffLine(kind: .ctx, old: 33, new: 42, text: "    }"),
                DiffLine(kind: .add, new: 43, text: ""),
            ]),
        ])
        let fritzDesk = ReviewDesk(detail: ReviewDetail(summary: fritz, files: files, comments: comments, rounds: rounds), diffs: [diff])

        // OVERSIRE-349: a plan, version 2, with one answered round.
        let plan = ReviewSummary(key: "OVERSIRE-349", kind: .plan, title: "Runbooks: steps with gates", machine: "mba", state: .ready, round: 1,
                                 root: "/Users/ada/src/oversire-workspace", subitems: ["OVERSIRE-350", "OVERSIRE-351", "OVERSIRE-352"],
                                 session: ReviewSession(state: .ended, harness: "claude", canSend: false),
                                 note: "Split the editor into its own sub-item.", readyAt: ago(40), updatedAt: ago(40))
        let doc = PlanDoc(key: "OVERSIRE-349", version: 2, title: "Runbooks", blocks: [
            PlanBlock(id: "goal", heading: "Goal", markdown: "Run the work of an item as **steps**: plan, implement, review. A gate stops the run until you say go."),
            PlanBlock(id: "steps", heading: "Steps", markdown: "1. The daemon keeps each run in `<data>/runbooks/<run>.json`.\n2. Each step is a keyed session.\n3. An agent ends its step with `oversire step done`."),
            PlanBlock(id: "risks", heading: "Risks", markdown: "A daemon restart in a step. The run must find its session again, or mark the step *failed*."),
        ], subitems: [PlanSubitem(key: "OVERSIRE-350", title: "Engine and routes"), PlanSubitem(key: "OVERSIRE-351", title: "Runbook tab"),
                      PlanSubitem(title: "Runbook editor in Settings")])
        let planComments = [ReviewComment(id: "c_00000010", key: "OVERSIRE-349", round: 1, state: .answered, anchor: .plan(block: "steps"),
                                          text: "Name the file of each run.", reply: "Added the path.", createdAt: ago(120), answeredAt: ago(41))]
        let planDesk = ReviewDesk(detail: ReviewDetail(summary: plan, comments: planComments,
                                                       rounds: [ReviewRound(n: 1, verdict: .requestChanges, count: 1, submittedAt: ago(110), delivery: .newSession,
                                                                            deliveredAt: ago(110), answeredAt: ago(41))], plan: doc))

        // The other groups: the agent works on a round, and a conflict.
        let waiting = ReviewSummary(key: "TOWERTAIL-2", kind: .code, title: "Import the tower list", machine: "mini", state: .waiting, round: 2,
                                    unanswered: 3, root: "/Users/ada/src/towertail",
                                    repos: [ReviewRepo(name: "towertail", branch: "towertail-2", base: "main", ahead: 4, added: 96, removed: 12, files: 5)],
                                    session: ReviewSession(id: "s_9", state: .working, harness: "codex", canSend: true), readyAt: ago(30), updatedAt: ago(5))
        let conflict = ReviewSummary(key: "SLING-88", kind: .code, title: "Retry the S3 upload", machine: "mini", state: .conflict, round: 1,
                                     root: "/Users/ada/src/sling", group: "/Users/ada/src/sling/.wt/sling-88",
                                     repos: [ReviewRepo(name: "sling-cli", branch: "sling-88", base: "main", ahead: 2, behind: 5, added: 30, removed: 4, files: 2,
                                                        merge: .conflict, conflictFiles: ["core/s3.go"]),
                                             ReviewRepo(name: "sling-docs", branch: "sling-88", base: "main", ahead: 1, added: 8, files: 1)],
                                     readyAt: ago(200), updatedAt: ago(60))
        let older = ReviewSummary(key: "FRITZ-12", kind: .code, title: "Menu bar count of reviews", machine: "mini", state: .ready,
                                  root: "/Users/ada/src/oversire", repos: [ReviewRepo(name: "oversire", branch: "fritz-12", base: "main", ahead: 1, added: 9, removed: 2, files: 1)],
                                  session: ReviewSession(state: .ended, canSend: false), note: "One file. The count shows in the label.", readyAt: ago(300), updatedAt: ago(300))
        REVIEWS.set([
            "mba": ReviewsPage(reviews: [fritz, plan], notPushed: [NotPushed(root: "/Users/ada/src/oversire", repo: "oversire", base: "main", ahead: 4)]),
            "mini": ReviewsPage(reviews: [waiting, conflict, older]),
        ])
        for d in [fritzDesk, planDesk, ReviewDesk(detail: ReviewDetail(summary: conflict)), ReviewDesk(detail: ReviewDetail(summary: older))] { REVIEWS.put(d) }
    }
}
