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

Each row shows the key, the title, the machine, the round, the number of pending comments, the repositories with their `+added −removed`, and the merge mode. The glyph and the word tell the state, not only the color.

## Code review

The Changes page of an item shows the files of each repository of the group: added, modified, deleted and renamed files, and the files that are not committed yet.

- Click a line, or drag over lines, to add a comment. The comment goes to the pending batch.
- Mark a file as viewed. The mark stays until the file changes.
- A binary file and a very large diff show a note in place of the lines.

## Plan review

The Plan page shows the plan in blocks, one block for each `##` heading, and the sub-items that the plan proposes. Comment on a block. Approve sets the item and its sub-items to Todo, so that the queue can take them.

## Rounds and delivery

A round goes to the session of the key:

| Session | Delivery |
|---|---|
| Idle | The prompt goes at once (`sent`). |
| Working | The prompt waits for the end of the turn (`queued`). |
| Ended, or none | A new session starts in the same place: the group for code, the project root for a plan (`newSession`). |

A second batch waits behind the first. When a delivery fails, the round shows the error, and the comments stay with the round.

The code session has the start key `work:<KEY>`. The plan session has the start key `plan:<KEY>`. Thus plan comments go to the Plan session and code comments go to the work session.

**Post to tracker** in the Submit sheet also posts the round as a comment on the item.

## Merge

The Merge sheet shows the merge mode of each repository:

| Mode | Meaning |
|---|---|
| Fast-forward | The base did not move. The daemon moves the base branch to the branch of the group. |
| Rebase | The base moved, and `git merge-tree` finds no conflict. The daemon rebases the branch, then fast-forwards. |
| Conflict | The rebase has conflicts. **Fix with agent** sends the conflict files to the session. The agent rebases and runs `oversire review ready` again. |

The merge is all or none: when one repository fails, the daemon merges none. The repositories merge in the order of `review.order` in the daemon config, for example `["agent-binder", "oversire", "cloud", "cli"]`. A repository that is not in the list merges after them, in alphabetic order. **Remove the group** removes the worktrees and the links of `.wt/<KEY>/` after the merge. OverSire then sets the item to Done. The daemon never pushes: the base branch shows under "Merged, not pushed".

## Two Macs

The comments and the rounds live on the daemon of the session machine. Each Mac in "My machines" sees the same reviews, the same pending batch and the same rounds. A Mac with no access to the daemon (no Tailscale) sees no reviews of that machine.
