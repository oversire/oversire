# Live session

The Session tab of an item window shows the agent session of the item while it runs. The app reads the session through the daemon of the machine that runs it. It never talks to a runtime (Orca, agent-wire) directly. The cloud is not in this path.

```text
OverSire app ──WebSocket /v1/sessions/{id}/stream──▶ daemon of the session's machine ──▶ local runtime
```

The stream route and its frames are in `Contract/schema/session-stream.json` and in the [cli README](https://github.com/oversire/cli#session-stream).

## The cards

| Session | Card | Source |
|---|---|---|
| Orca | **Terminal**, text only | The daemon reads the Orca screen each 1 s. No color. The size is the size of the Orca pane. |
| `oversire` (agent-wire) | **Chat** | The turns of the session: the prompts, the agent answers and the tool calls. |
| A runtime with a live terminal | **Terminal**, live | The bytes of the terminal, drawn by SwiftTerm. |

With no daemon, or when the daemon has no view for the session, the tab shows the last 60 lines of the screen, as before.

### Terminal

- The card starts in view mode. Keys do nothing.
- **Take control** sends the keys to the session. On a live stream, the terminal also takes the size of the card. **Give back** returns the size to the runtime UI.
- The chips show the link (**Live**, **Text only**, **Disconnected**, **Ended**), who has the size, and the size.
- **Pop out** opens the terminal in its own window. Each window has its own stream.
- A lost link connects again with backoff. The pill shows **Disconnected** with the reason until then.

### Chat

- The newest 60 turns show. **Show earlier turns** shows 60 more.
- Tool calls in a row fold into one group. Click a tool to see its input and the start of its result.
- Return sends the text. Shift-Return adds a line. The text goes to the agent as a `sessionSend`.
- **Stop** stops the session after a confirmation. The worktree and the turns stay.
- **Open in a terminal** opens Terminal in the folder of the session (on this Mac only) and copies the harness session id. Resume the session by hand with the agent CLI. OverSire has no resume command, because AgentBinder has no API for it. Stop the chat session before you resume it.

## Runtime state

Settings › Machines › Agent runtimes shows each runtime of each machine: **Live**, **Text only** (with the reason), **Not running** or **Not installed**. **Retry** calls `POST /v1/runtimes/{id}/retry` on the daemon of that machine.

Orca is text only for now. A live Orca terminal needs a pairing between the daemon and Orca (OVERSIRE-283).

## SwiftTerm

SwiftTerm draws the terminal. It is the only external Swift package of the app. Only `OverSireApp` links it. Do not add another package without the approval of the owner.

## Manual check

Do not test with the installed daemon. Run a second daemon in its own folder, with `serve.port` set to a free port (for example 7691) and `serve.tailscale: false`, and start it with `OVERSIRE_DAEMON_HOME=<dir> oversire daemon run`. Then render the real cards against it:

```bash
OVERSIRE_UISHOTS_STREAM=ws://127.0.0.1:7691/v1/sessions/<id>/stream \
  OverSire.app/Contents/MacOS/oversire --uishots <dir> chat:real    # or stream:real for a terminal
```
