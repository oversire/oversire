# AI engines and logs

This page tells how OverSire runs its short AI jobs and how it logs its background jobs.

## AI engines

The AI jobs are short text jobs: the session status, the summary, the CI failure cause, the digest, the queue order, triage and others. Settings › AI sets the engines and their order.

| Engine | What it uses | Setup |
|---|---|---|
| Local CLI (`local-cli`) | An agent CLI on this Mac through AgentBinder, for example `claude` or `codex`. It uses the subscription of that CLI. | Install the CLI and log in. Select it in Settings › AI. |
| API key (`api-key`) | The HTTP API of a vendor, in OpenAI or Anthropic format. | Put the key in Settings › AI. The key goes in the Keychain. |

`AIRouter` tries the engines in the order of the settings. When an engine is not available (no CLI, a usage limit, no key), the router tries the next one. Each skip writes a warning line to the log, except an engine that is not set up.

The Local CLI engine runs each job in a new empty folder. It denies each tool request of the CLI. AgentBinder sends the prompt over the structured protocol of the CLI.

## Logs

Each background job writes one line when it ends. The log stays on this Mac in `~/.config/oversire/logs/`, one JSONL file a day.

| Area | Jobs |
|---|---|
| AI | Each AI job: engine, model, tokens, time, input and output |
| Sessions | The history read of a session |
| Sync | The Plane and GitHub polls |
| Runner | The work orders of the runner |
| Network | Each HTTP request and WebSocket connect: method, path, status, time, host and request id |
| Command | Each child process: the CLI name, the arguments, the exit code and the time |
| UI | Each click, menu action, page change and dialog answer |

The Network, Command and UI areas are records. They open no problem, and the Logs page has a filter for each one.

- **Network.** A failure is a warning with the start of the error body (300 characters). A write that works is an ok line. A read that works is routine. The line has no headers, no body of a request and no query.
- **Request id.** Each daemon request sends a new `X-Request-Id`. The line shows it as `id=…`. The daemon log has the same id, so the two sides join. See `cli/README.md`, section Log.
- **Command.** Each argument is cut to 80 characters, with 12 arguments at most. A failure is a warning with the end of stderr (300 characters). A command that works is routine.
- **UI.** A line names the page and the label of the control. It has no typed text.

- The log removes secrets before it writes a line: the API key of the settings, `Authorization` and `x-api-key` values, and known token formats.
- Settings › Logs › Log settings sets the keep days (7 by default), the AI input and output, and the detail. Normal detail keeps no routine ok line, for example a poll that worked or a read that worked. Debug keeps all lines.
- An adapter or a target with no AppKit writes through `LogSink`. The default is `NoLog`.

### Problems

A problem groups the failures of one job on one host. The key is the area, the job and the host.

- An error opens a problem. The next error of the same key adds to its count.
- 3 warnings in a row open a problem. A warning is a fallback that worked, for example a status from the screen only.
- The next ok line of the key clears the problem.
- Dismiss hides a problem until its next error.
- A problem with no new error for 24 h closes.

An open problem shows an amber ▲ on the menu bar icon, a line in the popover and a count on Settings › Logs. Settings › Notifications › OverSire problems sends a notification when a problem opens. It is off by default.
