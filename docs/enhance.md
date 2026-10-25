# Enhance

Enhance gives an intake item or a ticket a better description. A coding agent reads the code and the related items, asks you what the code cannot tell, and writes a new description. You check what goes to Plane.

## Flow

1. Click **Enhance** on an intake row, in the intake detail, or on the item page. "Enhance vague items" (Settings › Agents) starts it for a new intake item with a short note.
2. OverSire sends one `sessionStart` order to the daemon of the sessions machine (Settings › Machines › Run sessions on). The order starts `claude` in place, in the main checkout of the project, with the Enhance prompt. "Enhance in a scratch worktree" uses `.wt/enhance-<key>` instead.
3. The order has the start key `enhance:<KEY>`, for example `enhance:OVERSIRE-317`. The daemon keeps at most one live session for each key. A second app that starts the same key gets the same session.
4. The row shows the pill **Enhancing on mbp · 2m**. The session is a normal agent session: open it in Orca to look.
5. The agent asks with the `AskUserQuestion` tool, at most 4 questions in one round. The questions show on the Enhance panel and in the session. Answer in either place.
6. The agent ends with one message. The result is one fenced code block with the info string `oversire-result` and one JSON object: `verdict`, `description`, `priority`, `labels`, `relations` and `findings`.
7. OverSire reads the last message with `sessionHistory` and shows the review. Select the lines to apply. **Accept** or **Accept and queue** (intake), or **Apply to KEY** (ticket), writes them to Plane. Then OverSire stops the session.

## States

| Pill | Meaning |
|---|---|
| Enhancing on mbp · 2m | The agent works. The time counts only the work, not the wait for an answer. |
| 2 questions | The agent waits for an answer. |
| Enhanced · High | The result is ready to review. The word is the verdict, for example **Reproduced** or **Duplicate of TREBI-388**. |
| Written | OverSire wrote the result to Plane. **Written and accepted**: it also accepted the intake item. |
| Enhance failed | The session ended with no result, did not show in 3 min, or worked 30 min with no result. The panel has **Try again**, **Open in Orca** and **Dismiss**. |

**Try again** stops the old session first. The stop frees the key, so the new start makes a new session. **Dismiss** also stops the session.

When the agent ends with no `oversire-result` block, OverSire tries the last JSON object in the message. Else the panel shows the text of the agent.

## Two apps

Each app finds a live Enhance session by its key in the daemon session list. An app that did not start the run, or an app that opened again during a run, shows the same pill and the same review. The Enhance sessions do not show as the work agent of the item.

## Daemon version

Enhance needs a daemon with the capability `sessionKey` (OVERSIRE-318). With an older daemon, a start shows "Update the daemon on <machine> to use Enhance." At its first start, the new daemon closes the terminals of the old Enhance workers and the `oversire-coordinator` terminal, and deletes `workers.json`.

## The prompt

`Contract/prompts/enhance.md` holds the default prompt. Settings › Agents can change it. A saved prompt from before version 3 asks for the old worker flow. OverSire replaces it with the default. A saved prompt with no `oversire-result` block gets a warning on the settings page.
