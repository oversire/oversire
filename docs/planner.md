# The Planner

The Planner orders the queue lanes. Two items that change the same code area then do not run at the same time. The Planner is paid: it needs OverSire Cloud. The Plan page, the area tags and the queue gate work without the cloud.

## Terms

- **Area.** A named part of the code, for example `contract` or `queue-page`. An item has up to 6 areas (`ItemAreas.maxAreas`).
- **Kind.** Each area is `core` or `feature`. A core area is always serial. A feature area is serial, or two items can share it (`PlannerSettings.sharedFeature`). An unknown kind acts as core.
- **Catalog.** The areas of a project (`AreaCatalog`), with glob rules that map paths to areas. User rules win, then learned rules, then graph rules. A proposed area does not match a path before you accept it.
- **Claim.** The areas of a running item (`AreaClaim`). The hub writes it. Changed paths grow the claim. When another item holds the area, the claim is blocked and the next work order of the item waits.
- **Overlap count.** For each pair of items in the same column: 3 for a shared core area, 1 for a shared feature area. Only Now and Next count.

## Glob rules

- `*` matches in one part of a path.
- `**/` matches any number of parts.
- `?` matches one character.

## The board

The Plan page shows each queue lane as three columns:

- **Now**: runs at the same time, up to `slots` items. Running items fill Now first.
- **Next**: starts when a slot frees.
- **Later**: waits.

A card that shares an area with another card in its column gets a red border and the line `▲ Same area as KEY (area)`. A held card shows `⏸ Waits for KEY (area)`.

## The plan change

The Planner writes one open suggestion for each lane, with a `plan` proposal (`PlanDraft`):

- `order`: move an item after another item, or to the start (`after` is null).
- `relations`: add or remove a `blockedBy`, `blocks` or `relatesTo` relation in the tracker.
- `areas`: add or remove an area on an item.

Each line has a reason. Review the change on the Plan page, in the Inbox (Suggestions) or on the item page. Clear a line to keep it out. `SuggestionEdit.drop` names the lines by index: first the order lines, then the relations lines, then the areas lines. The hub then writes the areas, the lane order and the relations, in that sequence.

The hub checks each line before it writes the suggestion. It drops a line that makes a cycle, names an unknown item, moves a running item, or makes the overlap count higher.

## Triggers

`PlannerSettings.mode`:

- `off`: no runs.
- `hourly`: at most one run each hour. A held item gets a run at once.
- `live`: a run on each trigger (item created, done or reopened, a queue change, a PR merged, a CI failure).

## Signals from the Mac

The app sends two signals when it has a cloud account. Only paths leave the Mac, never file text.

- **Changed paths** (`ChangedPaths`). Every 120 s, for each running session with a checkout: `git diff --name-only` against the merge base with the default branch, plus the untracked files. The app sends a set only when it changed. The runner sends the same data as a `paths` message for its own work orders.
- **Area candidates** (`AreaCandidates`). Once a day, for each project repo: the import graph of the Swift, Go and TS/JS files. Hubs are the top 5% of the nodes by importers. Clusters are groups of files that import each other. The hub turns them into proposed areas.

## Settings

Settings › Agents and queue › Intake and planner, for each project:

- Planner: Off, Hourly or Live.
- Feature areas: One at a time, or Allow two at once.
- Areas: the catalog. Set the kind, edit the rules, accept or dismiss a proposed area, add an area, or scan the imports.

The slot count is the same as the slot chip on the Queue page. The default is 3.
