# Runbooks

A runbook takes one item from plan to merge in fixed steps (OVERSIRE-349). Each step is a new agent session in the workspace of the item. The daemon of the sessions machine (Settings › Machines › Run sessions on) runs the steps. You answer the questions and approve the gates in Needs you.

The daemon side (routes, the engine, `oversire step done`) is in the README of the CLI, section "Runbooks". The wire bodies are in `Contract/schema/runbook.json`.

## A runbook

A runbook is a list of steps. Each step has:

- an id and a name, for example `review` and "Review Implementation",
- an agent: a name of the Start menu (Settings › Agents),
- a prompt with `{done}`: the agent runs `{done}` to end the step,
- `pauseBefore`: a gate. The run waits for your approval before the step,
- `review`: the step is a review. Its verdict is `pass` or `gaps`. `fix` names the fix step after it, and `rounds` is the fix round limit.

The prompt can use `{key}`, `{url}`, `{title}`, `{item}`, `{workspace}`, `{project}`, `{round}`, `{notes}`, `{worktree}` and `{done}`. `{notes}` holds the notes of the start and the note of each step before.

A new config has three runbooks. You can change them.

| Runbook | Steps |
|---|---|
| Full | Plan & Refine, Review Plan, Implement Plan Fixes, ◆ Implement, Review Implementation, Implement Fixes |
| Small | Implement, Review Implementation, Implement Fixes |
| Plan only | Plan & Refine, Review Plan, Implement Plan Fixes |

◆ is a gate. A step of `claude-max` uses the default agent when the config has no `claude-max`.

## How a run goes

1. You start a run: item page › Start in Orca ▾ › Run <runbook>, or a queue entry with a runbook. The project default has a check mark.
2. The daemon starts the first step in the Orca workspace of the item key. Each step gets a new terminal.
3. The agent does the work and runs `oversire step done --verdict <verdict> --note "<one line>"`. The daemon starts the next step.
4. A review with `gaps` starts its fix step, and then the review again as round 2. A review with `pass` skips its fix step.
5. The run is done after the last step.

A run stops and asks for you in these cases:

| Card in Needs you | Why | Buttons |
|---|---|---|
| ◆ Approve | The next step has a gate. | **Approve** starts the step at once, also when no queue slot is free. **Open item**. |
| ▲ Review gaps | The review still finds gaps after `rounds` fix rounds. | **One more round** runs the fix step and the review again. **Mark pass** skips the review, and the run goes on after the fix step. |
| ! Step ended | The session ended with no verdict, or the start failed. | **Mark done ▾** gives the verdict for the agent. **Retry step** starts a new round. **Open session**. |
| ! Blocked | The agent gave the verdict `blocked`. | **Retry step**, **Open session**. |

A run that you pause has no card. The Runbook tab of the item shows it.

Each card has the item key and the step name. The glyph and the word tell the kind, not only the color. The menu bar dot lights for a run that waits, and the menu bar label says "N runbooks wait". One notification comes for each gate or pause, after the delay of the question notice (Settings › Agents).

A question of a step session shows the step name, for example "Review Implementation · round 2: Keep the rows?".

## The Runbook tab

The item page has a Runbook tab when the item has a run. It shows:

- the state of the run and Approve, Pause, Resume or Stop,
- each step with its rounds, its verdict and its note,
- the live terminal of the current step,
- for a step that did not start: Change prompt… and the agent,
- for the current step: Retry step, Skip step and Mark done ▾.

## The queue

Add to queue asks for the runbook: Run <runbook> or One session. The queue starts a run for an entry with a runbook.

A run holds a queue slot only while a step starts, works or asks. A run at a gate or paused frees its slot. The running card of the lane shows a step bar: a filled square for each done step, a ring on the current step, and "n/N · step name".

## Settings › Agents › Runbooks

The editor shows the runbooks as chips above the step table.

- Change a step in place: the name, the agent, the gate, the review and the prompt. Each change saves at once.
- Move, add and remove steps. Duplicate, rename and delete a runbook.
- The check line under the table lists the problems, for example a prompt with no `{done}`, or a fix step before its review. A runbook with problems saves, but it does not start.
- Settings › Projects sets the default runbook of a project.
- Undo reverts the last change of the editor or of the assistant.

## The assistant

The assistant can read, make, change, check and start runbooks. The actions are `runbook.list`, `get`, `validate`, `create`, `update`, `delete`, `setDefault`, `undo`, `start`, `status`, `approve`, `pause`, `resume`, `stop`, `retry`, `skip` and `markDone`. The assistant sees the open runbook and the open step of the editor.
