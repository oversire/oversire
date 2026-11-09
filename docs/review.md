# Review gate

An agent ends a task with commits in its worktree group. It does not merge. You review the diff in OverSire from any of your Macs, comment in batches, and merge on the machine of the session (OVERSIRE-365). A plan gets the same gate before the code starts.

The daemon of the session machine does the work: it computes the diff, keeps the comments and the rounds, sends each round to the agent, and merges. The app reads it over `/v1` on loopback or Tailscale. The daemon never pushes. The routes and the commands are in the README of the CLI, section "Reviews". The wire bodies are in `Contract/schema/review.json`.

## The flow

1. The agent commits in `.wt/<KEY>/` and runs `oversire review ready --note "<one line>"`. For a plan, it runs `oversire review ready --key <KEY> --kind plan --plan .oversire/plans/<KEY>.md`.
2. The daemon sends `review.ready`. The group shows in Work › Review.
3. You open it. You add comments to a pending batch. Nothing goes to the agent yet.
4. You click **Submit review** and pick a verdict:
   - **Request changes** sends the batch as one prompt to the session of the key. This is one round.
   - **Approve** on code opens the Merge sheet. **Approve** on a plan sets the item and its sub-items to Todo.
5. The agent answers each comment with `oversire review reply <id>`, fixes the code or the plan, and runs `oversire review ready` again. The next round starts.

## Work › Review

The Review tab of the Work page has these groups:

| Group | What it holds |
|---|---|
| Plans to approve | Plans that wait for you. |
| Code to review | Groups that wait for you. |
| Waiting for the agent | Rounds that went to the agent and have no answer yet. |
| Conflict | Merges that stopped on a conflict. |
| Merged, not pushed | Base branches with local commits that the remote does not have. Push them yourself. |

The Status card of an item shows a base that is not pushed only when its commits name the item or a sub-item. A commit names an item in its message (`(OVERSIRE-383)` or the trailer `Item: KEY`), or the base reflog names a merged branch such as `oversire-383`.

Each row shows the key, the title, the machine, the round, the number of pending comments, the repositories with their `+added −removed`, and the merge mode. The glyph and the word tell the state, not only the color.

## Code review

The Changes page of an item shows the files of each repository of the group: added, modified, deleted and renamed files, and the files that are not committed yet.

- Click a line, or drag over lines, to add a comment. The comment goes to the pending batch.
- Mark a file as viewed. The mark stays until the file changes.
- A binary file and a very large diff show a note in place of the lines.

### Folds

The diff shows each change with 3 lines of context above and below. A fold row hides each other run of unchanged lines. The fold row shows `@@ −a,b +c,d @@ fn` of the lines below it and the number of hidden lines. `fn` is the last line above that starts with a letter, `_` or `$` (the default rule of git).

| Button | Lines that open | Line that stays in place |
|---|---|---|
| Show 20 lines below | The first 20 hidden lines | The line above the fold |
| Show 20 lines above | The last 20 hidden lines | The line below the fold |
| Show all N lines | All hidden lines | The line below the fold, or the line above the last fold |
| Unfold | All hidden lines of a fold of 20 lines or fewer | The line below the fold |

The top fold has no "below" button and the bottom fold has no "above" button. On a fold row, Return does the first button. The open lines stay open until the review changes. **Full file** in the header shows all lines. When you turn it off, the lines that you opened stay open.

An older daemon gives only the changed hunks. Then the fold rows have no buttons, Full file is off, and the hint tells you to update `oversire` on that machine.

### Large view and file switch

- ⇧⌘M or the arrows at the right of the header show the diff in a large view over the page. Esc, a click outside the card, or ⇧⌘M again closes it. The large view closes when you leave the page.
- In the large view the header shows `‹ path ▾ n / m ›`. ‹ › and ⌥⇧↑ / ⌥⇧↓ go to the previous or the next file, in the order of the file panel.
- ⌘P, or a click on the path, opens the file switch. Type to filter, ↑ ↓ to move, Return to open, Esc to close.
- In a comment field, the arrows and Esc go to the field.

### Steps through the changes

- ⌥↓ and ⌥↑, or the ˄ ˅ buttons in the header, go to the next or the previous change. A change is a run of added and removed lines.
- The counter between the buttons shows `2 / 4`. With no current change it shows the number of changes, or "No changes".
- Past the last change of a file, ⌥↓ opens the next file of the file panel at its first change. Before the first change, ⌥↑ opens the previous file at its last change. A file with no changes is a stop too.
- At the end of the review the app beeps, and the counter shows "Last change" or "First change". VoiceOver reads "This is the last change of the review."
- The current change has a 3 px blue bar at the left and a stronger fill. A new file has no current change.

### Ruler

- A 12 pt bar at the right of the diff shows where each change is in the file. Green is an added change, orange is a removed change, and half and half is both. The current change has an outline.
- The gray thumb shows the part of the file that is on the screen.
- A click on a mark goes to its change. A click on other space scrolls the diff to that point.
- Each mark is a button for VoiceOver, with the label "Go to change 2: 1 added, 1 removed". The tooltip shows the same text.

## Plan review

The Plan page shows the plan in blocks, one block for each `##` heading, and the sub-items that the plan proposes. Comment on a block. Approve sets the item and its sub-items to Todo, so that the queue can take them.

## Rounds and delivery

A round goes to the session of the key:

| Session | Delivery |
|---|---|
| Idle | The prompt goes at once (`sent`). |
| Working | The prompt waits for the end of the turn (`queued`). |
| Ended, or none | A new session starts in the same place: the group for code, the project root for a plan (`newSession`). |

A second batch waits behind the first. When a delivery fails, the round shows the error, and the comments stay with the round. A round also repeats each comment of an earlier round that went to the agent and has no answer, for example when the session ended in the round.

The code session has the start key `work:<KEY>`. The plan session has the start key `plan:<KEY>`. Thus plan comments go to the Plan session and code comments go to the work session.

**Post to tracker** in the Submit sheet also posts the round as a comment on the item.

## Merge

The Merge sheet shows the merge mode of each repository:

| Mode | Meaning |
|---|---|
| Fast-forward | The base did not move. The daemon moves the base branch to the branch of the group. |
| Rebase | The base moved, and `git merge-tree` finds no conflict. The daemon rebases the branch, then fast-forwards. |
| Conflict | The rebase has conflicts. **Fix with agent** sends the conflict files to the session. The agent rebases and runs `oversire review ready` again. |

The merge is all or none: when one repository fails, the daemon merges none. The repositories merge in the order of `review.order` in the daemon config, for example `["agent-binder", "oversire", "cloud", "cli"]`. A repository that is not in the list merges after them, in alphabetic order. **Remove the group** removes the worktrees and the links of `.wt/<KEY>/` after the merge. A file that is not a link, for example `.wt/<KEY>/.claude/`, keeps the folder: the merge is done, and OverSire tells you that the group stays. OverSire then sets the item to Done. The daemon never pushes: the base branch shows under "Merged, not pushed".

## Two Macs

The comments and the rounds live on the daemon of the session machine. Each Mac in "My machines" sees the same reviews, the same pending batch and the same rounds. A Mac with no access to the daemon (no Tailscale) sees no reviews of that machine.
