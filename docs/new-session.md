# New session

The New session panel starts a coding agent in Orca from one place. Select a project, type or speak a prompt, attach files, and press ⌘↩.

## Flow

1. Press ⌃⌥⌘N in any app, or click the terminal button after Back and Forward in the window toolbar.
2. Select the project. Type to filter the list. ↑ and ↓ move, ↩ selects. The last project is the default.
3. Type the prompt. ↩ adds a new line. Click the mic or press ⌘D to speak.
4. Paste or drop screenshots and files, or click the paperclip (⌘O). Click a thumbnail to see it in Quick Look.
5. Select or clear **Create intake item in KEY**. The panel keeps the last value.
6. Optional: click the agent chip at the bottom left, for example **claude-max · Opus 5.5 · Max**, and pick another agent. The pick applies to this start only.
7. Press ⌘↩ or ⌃↩. OverSire opens a new Orca terminal in the Orca workspace of the project, starts the agent and sends the prompt.

A toast at the bottom right tells the result. It has the links **Show in Orca** and **New session**.

## Agents

An agent is a name, a base CLI, a command, a model and an effort. Examples: `claude`, `claude-max` (Opus 5.5 · Max), `claude-fast` (Sonnet 5.5 · Low). Make them in Settings › Agents and queue › Agents with **Duplicate** or **Add an agent**.

- The chip menu lists the agents under each base CLI, with the model and the effort. **default** marks the default agent, or the agent of the project.
- The model list comes from the daemon of the sessions machine (`GET /v1/agents/{agent}/models`). When the daemon cannot list, the list comes from this Mac and the chip shows a warning mark. The tooltip tells why.
- **Auto** adds no flag: the CLI uses its own default. A CLI with no effort level (opencode, gemini, cursor) shows no effort.
- Orca gets the model and the effort as flags on the command. The `oversire` runtime gets them as fields. When the command has `--model` or `--effort` already, the command wins.
- An agent with no base CLI is "terminal only". Only a terminal runtime (Orca) can start it.
- The Session tab of an item shows the agent, the model and the effort of a session that OverSire started.

## The two routes

| Intake | Result |
|---|---|
| On (the default) | OverSire makes one intake item. The prompt is its description, and the files go on the item. The agent gets the prompt and the item key. |
| Off | No item. The files go to the sessions machine, into a folder that its daemon chooses, and the prompt gets their paths. With no files, the prompt goes to the agent as typed. |

The route with intake off sends the files to the daemon of the sessions machine. Thus it also works on a remote machine. The total size of the files has a limit (10 MB by default). For more, turn on intake.

## Keys

| Key | Action |
|---|---|
| ⌃⌥⌘N | Open the panel from any app, or close it |
| ⌘↩ or ⌃↩ | Start the session |
| ↩ | A new line in the prompt |
| ⌘D | Start or stop dictation |
| ⌘O | Attach files |
| Esc | Close the list, then the dictation, then Quick Look, then the panel |

## Settings

- Settings › General › Quick capture and snap: the shortcut, **Create intake item by default** and **File limit without intake**.
- Settings › Agents and queue › Agents: the agent command, and the two prompt templates **New session prompt (intake)** and **New session prompt (files)**.

Placeholders of the intake template: `{text}` the prompt, `{key}` item key, `{item}` item id, `{intake}` intake id, `{workspace}`, `{project}`. With no files, the template lines that hold `{item}` drop. Placeholders of the files template: `{text}` and `{paths}`, one path on each line. A placeholder in the typed prompt stays as it is.

## Failures

- A project with no Orca workspace shows **Choose folder…**. Start stays off until the project has a folder.
- A file that does not upload to the item after three tries shows in the toast. The terminal still opens.
- When the files do not go to the sessions machine, no terminal opens. The panel shows the error and **Send with intake**.

## Privacy

Dictation is on-device speech to text. No audio is kept or sent. The files go only to the tracker (intake on) or to the sessions machine (intake off).
