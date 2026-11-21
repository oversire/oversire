# Events

Each change in the work of an item makes one row in the `events` table of the home daemon (OVERSIRE-377). The Status recap and the Timeline tab of the item page read these rows.

## Rules for each change

When you add or change a feature, add its events in the same change.

- A new action of a human, an agent, the system or a provider needs an event kind. Add the kind to `Contract/schema/event-kinds.json` first, with the fixture `Contract/fixtures/event/<kind>.json`.
- Each row has `item`, `actorType` and `actor`. Set `parentItem` when you know it.
- The id is `<source>:<native id>`. A poll and a webhook of the same change give the same id.
- Prompt text and `payload` are private. Only `summary` leaves the home daemon.
- A new provider adapter maps its activity to rows. See `docs/adding-a-provider.md`.
- A new runtime driver gives session, turn and wait rows. See `docs/adding-a-runtime.md` in the `oversire/cli` repo.
- Fold tool calls into `turn.ended`. Do not write one row for each tool call.
- A kind that is not in the catalog fails `ContractTests`, the conformance suites and `scripts/event-kinds-check.sh` in the cli repo.

## The table

The table is SQLite, in `<data>/events.db` of each daemon. The home daemon holds all the rows of the group.

| Column | Use |
|---|---|
| `seq` | The order on this daemon. A reader pages with `after`. |
| `id` | `<source>:<native id>`. Unique. The daemon drops a repeat. |
| `at` | The time of the change. `seen_at` is the time that the daemon wrote the row. |
| `kind` | A kind of the catalog. |
| `item`, `parent_item` | The item key, for example `OVERSIRE-380`, and its parent. |
| `project`, `repo`, `machine`, `provider` | The place of the change. |
| `session`, `corr` | The agent session. `corr` joins a start row and its end row, for example `turn.started` and `turn.ended`. |
| `actor_type`, `actor`, `on_behalf`, `via` | Who did it (`human`, `agent`, `system`, `provider`), and through which program. |
| `summary` | One short line. |
| `payload` | Small JSON. Its fields are in the catalog. |
| `private` | The summary holds prompt text. |

The table `item_links` keeps the parent of each item. The app sends the links from the tracker (`POST /v1/events/links`). A row with no `parent_item` gets the parent from this table.

An `epic.*` row has the epic as its `parent_item`. The key of the epic is `Epic.eventKey`: the tracker key of the epic, else `EPIC-` and 12 hex characters of a SHA-256 of the project and the epic id. A links update does not change the `parent_item` of an `epic.*` row. The app writes `epic.updated` when it changes an epic. An epic update with a health writes `epic.updated` with the fields `health` and `note`. A health change from the poll writes `epic.updated` with the fields `health`. The poll writes the other `epic.*` rows. A change from an `oversire` command (an app call) names the agent as the actor. `tree=1` on the key of an epic gives the epic rows of all its items.

## The kinds

`Contract/schema/event-kinds.json` holds the catalog. A star marks a private kind.

| Domain | Kinds |
|---|---|
| agent | `session.started`, `session.ended`, `turn.started`, `turn.ended`, `turn.interrupted`, `wait.started`, `wait.ended`, `context.compacted`, `subagent.ended`, `review.ready`, `groom.applied`, `groom.undone`, `sweep.applied`, `worker.started`, `worker.answered`, `worker.nudged`, `worker.escalated`, `worker.done` |
| human | `prompt.submitted`*, `question.answered`, `review.submitted`, `review.approved`, `review.viewed`, `review.unviewed`, `item.shipped`, `plan.started`, `item.state_changed`, `item.areas_set`, `item.viewed`, `item.favorited`, `item.unfavorited`, `project.settings_changed` |
| git | `worktree.added`, `worktree.removed`, `git.commit`, `git.rebase`, `git.reset`, `git.merge`, `git.push` |
| ci | `ci.queued`, `ci.started`, `ci.completed`, `ci.rerun`, `ci.cancelled`, `ci.dispatched`, `ci.approved` |
| codehost | `pr.opened`, `pr.updated`, `pr.merged`, `pr.closed`, `release.published` |
| tracker | `item.created`, `item.updated`, `comment.created`, `item.link_added`, `item.attachment_added`, `intake.created`, `intake.accepted`, `intake.declined`, `intake.snoozed`, `intake.duplicated`, `intake.deleted`, `intake.updated`, `epic.created`, `epic.item_added`, `epic.item_removed`, `epic.closed`, `epic.updated`, `vendor.call` |
| system | `queue.picked`, `queue.held`, `runbook.step_started`, `runbook.step_ended`, `job.ran`, `automation.ran`, `item.state_changed` (actor `parent-guard`, payload `reason: open-sub-items`) |

A reader keeps a row of a kind that it does not know.

The CI writes of the app (`ci.rerun`, `ci.cancel`, `ci.dispatch`, `ci.approve`) go through `CIOps`. A rerun by an agent names the agent in the `ci.rerun` row of the next poll. `ci.cancelled`, `ci.dispatched` and `ci.approved` rows are written at once. The `ci.dispatched` payload has the input keys, never the values. A command from another machine of the group has `via` `cli@<machine>`.

`oversire vendor run` writes one `vendor.call` row for each run of a vendor CLI. The summary has the CLI name, the subcommand words and the exit code, never the args. The app writes no row for a refused call.

`oversire vendor skill` is a read. It writes no row.

A write from an `oversire` command (an app call) names the agent as the actor. This holds for `item.state_changed`, `item.link_added`, `item.attachment_added`, `item.areas_set`, the triage rows `intake.accepted`, `intake.declined`, `intake.snoozed`, `intake.duplicated`, `intake.deleted` and `intake.updated`, and the poll rows `item.created`, `item.updated`, `comment.created` and `intake.created` of that write. The app marks the item until the refresh after the write ends.

## The path

1. **The daemon.** `cli/capture` writes the rows of the hook calls, the session book, the questions, the reviews, the runbook steps and the queue. `cli/gitwatch` reads the reflogs and writes the git rows. A working session in a worktree makes its git rows agent rows.
2. **The app.** `ProviderEvents` (`TrackerEvents`, `ChangeEvents`, `CIEvents`) maps each poll to rows. A poll with no change gives no row. `EventDesk` writes the rows of your actions in the app. `EventSender` keeps the rows until a daemon takes them: the local daemon first, else the home daemon.
3. **The outbox.** A member daemon sends its rows to `POST /v1/events` of the home daemon, in `seq` order, at least once. When the home does not answer, the rows wait and the outbox tries again: 2 s, then twice as long, at most 5 min. The home drops a repeat by its id. The `at` time stays the time of the change.
4. **The spool.** When the daemon does not answer a writer, the writer keeps the rows in `<data>/events.spool`. `oversire ticket applied` is such a writer. A refusal or a server error is not spooled. The daemon reads the spool at the start and each 10 s.
5. **The readers.** `GET /v1/items/{key}/events?tree=1&after=&kinds=&limit=` gives the rows of an item and its sub-items. A new row also goes out as an `event` frame on the daemon socket. The app adds the frame to each open item tree with no new read.

When the home moves to another daemon, the new home copies all rows of the old home (`GET /v1/events/rows`).

## Privacy

- `payload` and a private `summary` stay on the home daemon. Only `summary` of a row that is not private goes to the cloud, the AI recap or another client.
- The AI recap gets the kinds and the summaries. It gets no payload, and `(private)` in place of a private summary.
- A provider row holds no token and no body text. It holds ids, states and a short title.

## Retention

- The rows stay.
- After 90 days, the daemon clears the `payload` of a row, and the `summary` of a private row. It does this at the start and then each day.
- The table keeps the last ProviderEvent hints (`GET /v1/events`) in its own table, `hints`.
