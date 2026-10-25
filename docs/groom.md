# Groom

Groom cleans up the intake and the backlog of one project in one session. A coding agent reads all open items and the code. It finds items about the same problem, items that the code already does, and items that are no longer valid. It asks you what the code cannot tell. You select the changes, and OverSire writes them to Plane.

Groom is not a mode of Enhance. Enhance writes a better description for one item. Groom works on the full list. Run Groom first, then Enhance the items that stay vague.

Groom runs on your machine, through your daemon. It is free.

## Flow

1. On the Intake page, select a project tab and click **Groom…**. On the All tab, the button asks for the project first.
2. The start sheet shows:
   - **Scope**: **Intake only**, or **Intake and backlog**. The second finds a new note that repeats an old item.
   - **Label**: only the backlog items with this label. The intake always has all its items.
   - **Stale check**: the agent checks the items older than 7, 14 or 30 days against git log, the PRs that name the key, and the code that the item names.
   - The estimate: the item count, the stale count, the skipped items and the time.
3. **Start Groom** writes the items to one JSON Lines file on the daemon (`POST /v1/files`). Then it starts one session in place, in the main checkout of the project, with the Groom prompt. The start key is `groom:<PROJECT>`, for example `groom:TREBI`. The daemon keeps at most one live session for each key.
4. The panel on the Intake page shows the pill **Grooming on mbp · 6m**. The time counts only the work, not the wait for an answer.
5. The agent asks with the `AskUserQuestion` tool, for example "Merge these 3 items into TREBI-329?". The question cards show on the Groom panel and in the session. Answer in either place.
6. The agent ends with one `oversire-result` block. It holds a list of proposals. Each proposal has a kind, the keys, a reason, the evidence and a confidence (`sure` or `maybe`).
7. The review shows the proposals in groups. OverSire selects the `sure` lines. Select or clear the other lines. Then click **Apply N changes**.

## Kinds

| Kind | What Apply writes to Plane |
|---|---|
| ⇉ Merge | The kept item gets the new description. Each other item gets the comment "Merged into KEY", the duplicate relation and the Cancelled state. |
| ✓ Done | The Done state and a comment with the evidence. |
| ⊘ Obsolete | The Cancelled state and a comment with the reason. |
| ↳ Fold | The parent. The item stays open. |
| ↔ Relate | The relation, for example "blocked by". |
| ✦ Vague | Nothing. **Apply, then Enhance N vague** starts Enhance on these items. |

A merge does not delete or archive an item. The other items stay as Cancelled duplicates.

## Rules

- Nothing goes to Plane before **Apply**.
- Apply writes one item at a time. A failed line stays in the list with its error. **Try again** writes only that line.
- One run holds at most 200 items. With more, select **Intake only** or a label.
- Groom skips an item with a live session, an item in a queue lane and an item in a started state. The review lists them in "Not in this run".
- **Ask again** sends a new turn to the same session. The agent checks its lines and sends a new result.
- The OverSire block in a description stays as it is.

## Undo

**Undo last Groom** puts back the states, descriptions and parents that the last Groom changed. OverSire keeps a journal of the old values for each project. When an item changed after Groom, Undo leaves that item as it is and names it. The comments stay.

## Keys

| Key | Action |
|---|---|
| ↑ ↓ | Move between the lines |
| Space or Return | Select or clear a line |
| → | Open the new description of a merge |
| ⌘↩ | Apply |

## States

| Pill | Meaning |
|---|---|
| Grooming on mbp · 6m | The agent works. |
| 1 question | The agent waits for an answer. |
| Groomed · 6 changes | The result is ready to review. |
| Writing 3 of 6 | Apply writes to Plane. |
| Written 5 of 6 | Apply is done. A ⚠ shape shows when a line failed. |
| Groom failed | The session ended with no result, did not show in 3 min, or worked 60 min with no result. The panel has **Try again**, **Open session** and **Dismiss**. |

## Daemon version

Groom needs a daemon with the capabilities `sessionKey` and `hostFiles`. With an older daemon, a start asks you to update the daemon.

## The prompt

`Contract/prompts/groom.md` holds the default prompt. Settings › Agents › **Edit Groom prompt** can change it. The values `{{project}}`, `{{file}}`, `{{scope}}` and `{{staleDays}}` come from the run. A saved prompt with no `oversire-result` block gets a warning.
