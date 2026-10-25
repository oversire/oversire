# Automations

When you use OverSire on two or more Macs of one group, only one app runs the automatic actions. The other apps show the results. Thus two Macs do not start the same agent, write the same Plane comment or pay for the same AI job (OVERSIRE-319).

## What is an automatic action

- **Auto start** of the queue (Settings › Agents).
- **Enhance vague items**: the auto start of Enhance on a new intake item.
- **Cleanup**: the automatic removal of done worktrees.
- **Plane write-back**: the status, the session comment and the PR links that OverSire writes to Plane.
- **AI jobs**: item summaries, the CI failure reason, the CI digest and the session status.

An action that you start with a click runs on the Mac where you click. A click is never an automatic action.

## The lease

The home daemon of the group (Settings › Machines, the HOME chip) keeps the lease `automations`. The home daemon keeps it also when the group has a cloud.

1. Each app asks the home daemon for the lease at the start and each 30 s. The time limit of the lease is 90 s.
2. The first app gets the lease. It is the owner. The other apps get the name of the owner.
3. Each automatic action asks the owner first. An app that is not the owner does nothing. The owner stops 10 s before the end of its lease, so that a late renew does not overlap a new owner.
4. A Mac that sleeps or quits gives the lease back. The next app that asks gets it.
5. When the owner does not renew, the lease ends after 90 s. Then another app gets it.

An action that started before a change of the owner runs to its end.

The daemon routes are in the README of the CLI (section "Leases").

## Settings › Machines › Automations

The last row of the My machines card tells which Mac runs the automations. The row shows only when the group has two or more machines.

| Pill | Button | Meaning |
|---|---|---|
| Run on this Mac | | This app is the owner. |
| Run on mbp | Run them here | The app on mbp is the owner. **Run them here** takes the lease to this Mac. |
| Paused · home offline | Retry | The app cannot reach the home daemon. No app runs the automations, so that two Macs do not do the same work. They start again when the home is online. **Retry** asks the home daemon now. |

Before the first read of the group, the automations also wait. A Mac with no group (one machine) is always the owner.

## Shared results

The owner writes the AI results to the synced store, collection `ai-outputs` (`AIOutput` in `Contract/schema/store.json`). There is one record for each kind and subject:

| Kind | Subject | Body |
|---|---|---|
| `item-summary` | the item key | the summary, with the hash of the item text |
| `ci-explanation` | the run | the failure reason |
| `ci-digest` | `today` | the digest of the day |
| `session-status` | the item key | the status of its session |

The other apps read the records. When the hash of the text agrees, they make no AI call. A dismiss of the digest stays on the Mac where you dismiss it.

## Start keys

The queue and the ▶ start send the start key `work:<KEY>`. Enhance sends `enhance:<KEY>`. The daemon keeps at most one live session for each key. Thus two apps that start one item get one session, also during a change of the owner.

The Intake row of an Enhance run shows the machine of the session when it is not this Mac, for example **Enhancing on mbp · 2m**. Each app reads the same session from the daemon.
