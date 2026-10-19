# Snap Basket

Snap Basket puts screenshots with marks and notes into one intake ticket. An agent can then read the ticket and the images, and find the cause in the code.

## Flow

1. Press ⌃⌥⌘S in any app. The overlay opens on each display.
2. Click a window, or drag an area. Space switches between the window mode and the area mode. Esc cancels.
3. The shot editor opens near the shot. Add marks, a crop and notes.
4. Click **Add to basket** (⌘↩). ⇧⌘↩ adds the shot and starts the next snap.
5. The basket panel shows at the bottom left of the screen. It has one basket for each project.
6. Click **Send ▾** and select a mode.

The send modes:

| Mode | Result |
|---|---|
| Draft ticket with agent (⌘↩ in the panel) | One intake item with the images. Then an Orca terminal opens in the main checkout of the project, with the snap prompt. The agent writes the title and the description. |
| Create item in Plane | One intake item with the images. The panel shows a link to it. |
| Copy as Markdown | The ticket text and the image files go to the pasteboard. Paste them into a chat app. |

The project comes from the window title, else from the last project. A shot for another project than the open basket asks first: add to that basket, or start a new basket.

## Keys

Global (change them in Settings › General › Quick capture and snap):

| Key | Action |
|---|---|
| ⌃⌥⌘S | Take a snap |
| ⌃⌥⌘B | Show or hide the basket panel |

In the shot editor:

| Key | Action |
|---|---|
| Drag on the image | Add a mark. A click adds a 64 × 36 pt mark |
| ↩ | Edit the note of the selected mark, or apply the crop |
| ⌫ | Delete the selected mark |
| Arrows | Move the selected mark or the crop by 1 px. ⇧ moves by 10 px. With no selection, select a mark |
| Tab, ⇧Tab | Go to the next or the previous control |
| C | Start the crop |
| V | Speak a note |
| ⌘Z, ⇧⌘Z | Undo, redo |
| ⌘P | Change the project |
| ⌘↩ | Add to the basket |
| ⇧⌘↩ | Add to the basket and snap again |
| Esc | Close the open field, then cancel the crop, then close the editor |

In the basket panel, the arrows move the panel when the grip has the focus. Esc closes the panel.

## Files

All files stay on the Mac until you send:

```text
~/.config/oversire/captures/<basket-id>/
  basket.json           project, state, shot order, the item after the send
  shot-<id>.json        crop, marks, notes, app and window title
  shot-<id>.png         the full capture
  out/                  the rendered files of the last send
    snap-N.png          the crop with the numbered marks
    snap-N-clean.png    the crop with no marks
    snap-N-mark-M.png   a zoom of a small mark
```

Sent and copied baskets stay for the "Keep history" time (30 days by default). Then OverSire deletes them.

## The ticket

The title is `Snap basket · N shots · <first note>`. The description has one section for each shot: the file names, the size, the app and window title, the note, and each mark as a pixel box from the top-left corner of `snap-N.png`.

## The snap prompt

Change the prompt in Settings › Agents and queue › Agent commands › Snap basket prompt. **Reset** sets the default. The placeholders:

| Placeholder | Value |
|---|---|
| `{key}` | the ticket key, for example `SLING-412` |
| `{item}` | the work item id |
| `{intake}` | the intake id |
| `{count}` | the shot count |
| `{workspace}` | the Plane workspace |
| `{project}` | the project key |
| `{dir}` | the download folder for the images |

The agent mode uses the command of the project agent (Settings › Agents and queue › Agent commands). The project needs an Orca workspace: start any item of the project once.

## Failures

- A failed upload gets 3 more tries. If files still fail, the basket shows as partial. Click **Retry** in Settings › General › Quick capture and snap › Sent baskets.
- A tracker without attachments gives an error line with **Copy as Markdown**.
- The agent mode checks the Orca root, the runtime and the command before it makes the item. An error then makes no item.

## Privacy

- Shots and notes stay on the Mac until you send a basket. OverSire sends them only to your tracker.
- Voice notes use on-device speech recognition only. OverSire keeps the text, not the audio. If the Mac has no on-device model for the language, the voice button shows an error.
- OverSire sends no telemetry.

## Permissions

1. Settings › General › Quick capture and snap shows "Screen Recording is off". Click **Turn on…**.
2. macOS opens System Settings › Privacy & Security › Screen & System Audio Recording. Turn on OverSire.
3. Quit and open OverSire again. macOS applies the permission only after a restart.
4. For voice notes, allow the Microphone and Speech Recognition when macOS asks.
