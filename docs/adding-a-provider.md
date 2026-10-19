# Add a provider

A provider is an adapter for one vendor in one layer. OverSire has four layers:

| Layer | Protocol | Example | Template |
|---|---|---|---|
| Tracker | `Tracker` | Plane | `Sources/Providers/TrackerTemplate` |
| Code host | `CodeHost` | GitHub | `Sources/Providers/CodeHostTemplate` |
| CI | `CIProvider` | GitHub Actions | `Sources/Providers/CITemplate` |
| Agent runtime | `AgentRuntime` | Orca | `Sources/Providers/RuntimeTemplate` |

The protocols are in `Sources/OverSireCore`. The app uses only the protocols. Only `Sources/OverSireApp/AppEnvironment.swift` names the concrete adapters.

This guide is for the adapter in the app. The cloud has its own guide for webhooks: `docs/adding-a-provider.md` in the private `oversire/cloud` repo.

## Rules

- An adapter target imports only `OverSireCore` (and `GitHubKit` for a GitHub adapter). It does not import AppKit.
- All calls are `async throws`. All types are `Sendable`.
- All HTTP goes through the `HTTPTransport` that you get. All child processes go through the `CommandRunner` that you get. Do not use `URLSession` or `Process` directly. The tests replace them.
- Map each vendor error to `ProviderError`. A refused token is `.unauthorized`. A 429 is `.rateLimited(retryAfter:)`.
- An adapter must poll. Webhooks are an option on top of the poll.
- Events are hints. An event tells the app what to read again. The app does not show the event data as the truth.

## 1. Make the target

1. Copy the template folder of your layer, for example `Sources/Providers/TrackerTemplate` to `Sources/Providers/TrackerLinear`.
2. Rename the types and the file: `TemplateTracker` to `LinearTracker`.
3. Rename the `ProviderID` extension constant (`trackerTemplate`) to the vendor name, for example `.linear`, and set its value to `"linear"`. The id goes into the config file and into the event ids. Do not change it after a release.
4. Add the target and its test target to `Package.swift`:

```swift
.target(name: "TrackerLinear", dependencies: ["OverSireCore"], path: "Sources/Providers/TrackerLinear"),
.testTarget(name: "TrackerLinearTests", dependencies: ["TrackerLinear", "OverSireTestKit"]),
```

5. Make the folder `Tests/TrackerLinearTests` with one test file. `swift build` fails when a test target has no folder.
6. Run `swift build`. The copy builds before you change a call.

## 2. Fill in the descriptor

The descriptor tells the Providers page how to show the vendor and how to make an adapter.

```swift
public static let descriptor = ProviderDescriptor(
    id: .linear, layer: .tracker, displayName: "Linear", symbol: "checklist",
    fields: [ConfigField(key: "team", label: "Team", kind: .text),
             ConfigField(key: "token", label: "API key", kind: .secret)],
    auth: [.token], docsURL: URL(string: "https://linear.app/developers")
) { config, env in
    guard let token = config.secretKeys.first.flatMap(env.secrets.secret), !token.isEmpty else {
        throw ProviderError.unauthorized
    }
    return LinearTracker(account: config.account, team: config.values["team"] ?? "", token: token, http: env.http)
}
```

- `fields` are the inputs on the Providers page. The page keeps a `.secret` field in the Keychain. `config.secretKeys` holds its key, and `env.secrets` reads it. The other fields are in `config.values`.
- `symbol` is an SF Symbol name.
- `auth` tells the user how to sign in: `.token`, `.cli("gh")`, `.localApp` or `.cloudApp`.
- The template init takes `token: String?` and does not check it. Change the init to match your `make`, as in the example.
- `ConfigField(key:label:kind:required:help:)`: `required` is `true` by default. `help` is the hint under the input. `docsURL` is optional.
- `make` must not do I/O. The app calls it on first use of the account.

## 3. Implement the base protocol

The types are in `Sources/OverSireCore`:

| Types | File |
|---|---|
| `Provider`, `Capability`, `Identity`, `Cursor`, `EventPage`, `PollPolicy` | `Provider/Provider.swift` |
| `ProviderError` | `Provider/Errors.swift` |
| `HTTPTransport`, `CommandRunner`, `SecretReader` | `Provider/IO.swift` |
| `ProviderEvent`, `EventKind`, `SubjectRef` | `Events.swift` |
| `AccountID`, `PersonRef` | `Identity.swift` |
| `ProjectRef`, `ItemRef`, `RepoRef`, `RunRef` and the other refs | `Refs.swift` |
| `Item`, `ItemDetail`, `StatusOption`, `StatusCategory`, `KeyFormat` | `Tracker.swift` |
| `Repo`, `ChangeRequest` | `CodeHost.swift` |
| `Pipeline`, `Run`, `Job`, `Failure` | `CI.swift` |
| `Workspace`, `RuntimeSession`, `LaunchRequest` | `Runtime.swift` |

`parseISO` in `ISODate.swift` reads vendor dates.

Each adapter implements `Provider`:

- `id`, `account`: the account provider must be the `id`.
- `capabilities`: start with an empty set. See step 5.
- `pollPolicy`: the smallest poll interval and the vendor rate limit. For example, Plane allows 3,600 requests an hour.
- `probe()`: read the user of the token. Return `Identity(person:scopes:)`. Throw `.unauthorized` for a refused token.
- `poll(since:)`: return an `EventPage`.

Rules for `poll(since:)`:

- `since` is `nil` on the first poll. Then set a baseline. Give no events, or only recent events.
- The `Cursor` is yours. Put any string in it, for example a date, an ETag or a JSON object. The app stores it and gives it back.
- A `ProviderEvent` needs a `kind` and a `subject`, for example `kind: .item` and `subject: .item(ItemRef(...))`. The subject tells the app what to read again.
- Two polls must not give the same event again. Make each event id stable, for example `"linear-<account>-<item>-<updatedAt>"`.
- Use an ETag or an `updated_since` filter when the vendor has one. A poll with no change must cost little.
- Set `busy: true` when a subject is in progress, for example a running build. The app then polls at the active interval.
- Set `retryAfter` and `budget` from the rate headers when the vendor sends them.

`Sources/Providers/RuntimeOrca/OrcaPoll.swift` is a short example. `Sources/Providers/TrackerPlane/PlanePoll.swift` uses `updated_at` filters.

## 4. Implement the layer protocol

Replace each `throw ProviderError.unsupported(...)` in the template with a vendor call. Map the vendor JSON to the types in `OverSireCore`.

### Tracker

- `keyFormat`: the pattern of the item keys, for example `ENG-12`. `.projectDash` fits most trackers. The app finds keys in branch names and pull request titles with it.
- `projects`, `statuses`, `items`, `detail`, `comments`, `create`, `update`, `comment`.
- Map each vendor status to a `StatusCategory`. The suite needs at least one done status and one open status.
- `items` gives the newest activity first.
- `TrackerConformance` uses the first project that is not closed. It checks these:
  - `create` returns a key that `keyFormat` finds in a title, and in lower case in a branch name.
  - `items` lists the new item, and `items(limit: 1)` gives one item or none.
  - `detail` shows the title from `update`.
  - `comments` contains the body of the new comment.
  - With `RelationManaging`, a new `blockedBy` relation shows on both items (the other item gets `blocks`), and the remove takes it away. `TrackerConformance.relations(_:item:project:)` runs it alone.
  - With `ProjectSettingsReading`, `settings` gives a name and the statuses. With `ProjectSettingsEditing`, an empty patch works and a field that is not in `editableSettings` throws `.unsupported(.projectSettingsEdit)`. This part writes nothing. `TrackerConformance.settings(_:project:)` runs it alone.
- Relations (optional): map the vendor types to `blockedBy`, `blocks` and `relatesTo`. Drop the other types. `apply` adds before it removes. The Planner card, the Queue board and the queue gate read the relations. Relations live only in the tracker.
- Project settings (optional): fill the fields of `ProjectSettings` that the vendor has. Leave the others empty. Put only the features that the vendor has in `features`. Put a feature that you can read but not switch in `readOnlyFeatures`. List the fields that you can write in `editableSettings`. The settings page shows "Edit in <vendor>" for the others. Also set `ProjectSummary.logo` in `projects` when the vendor has a project logo.

### Code host

- `repos`, `changes`, `commitMessage`.
- `perform(_:on:)` merges, closes or approves a change. Without the `changeActions` capability, throw `.unsupported(.changeActions)`.

### CI

- `pipelines`, `runs` (newest first), `run`, `jobs`, `failures`.
- `perform(_:on:)` runs a rerun or a cancel. Throw `.unsupported(.rerun)` or `.unsupported(.cancel)` for an action that you do not support.
- To re-run one job, add `.rerunJob` and conform to `JobRerunning`. On the wire, this is the RunAction `rerun` on a `job` subject.

### Agent runtime

- `environments`, `repos(in:)`, `workspaces`, `sessions`, `launch`.
- A runtime is often a CLI. Call it through the `CommandRunner`.
- A runtime that starts the agent in a terminal uses `LaunchRequest.command` when it is set. The app resolves it from Settings › Agents and queue › Agent commands and quotes each value. When the field is empty or missing, use the default of the agent: `LaunchCommand.defaultFor(agent)`. A runtime that starts the agent over a protocol (no command line) ignores the field.

## 5. Add the capabilities that you support

A capability is an optional feature. Some capabilities need a second protocol:

| Capability | Protocol |
|---|---|
| `.intake` | `IntakeTriaging` |
| `.timeline` | `TimelineReading` |
| `.labels` | `LabelManaging` |
| `.links` | `LinkManaging` |
| `.assets` | `AssetResolving` |
| `.webhooks` | `WebhookManaging` |
| `.logs` | `LogReading` |
| `.rerunJob` | `JobRerunning` |
| `.sessionInput`, `.sessionTail` | `SessionIO` |
| `.reveal` | `Revealing` |
| `.relations` | `RelationManaging` |
| `.projectSettings` | `ProjectSettingsReading` |
| `.projectSettingsEdit` | `ProjectSettingsEditing` |

Add the capability to `capabilities` and conform to the protocol. The suite fails when one is there without the other. The UI hides a feature that no account supports.

## 6. Record fixtures

The tests do not call the vendor. They replay recorded answers from `Tests/<Target>Tests/Fixtures/<adapter>/`.

1. In the test, make the adapter with a `ReplayTransport`. The upstream is a small transport in the test target that calls `URLSession` (see `LiveHTTP` in `Tests/LiveTests/PlaneLiveTests.swift`):

```swift
let http = ReplayTransport(dir: fixtureDir("linear"), upstream: LiveHTTP())
let t = LinearTracker(account: AccountID(provider: .linear, id: "acme"), team: "ENG", token: token, http: http)
```

2. Record once against a test account: `OVERSIRE_RECORD=1 LINEAR_TOKEN=... swift test --filter TrackerLinearTests`.
3. Read the new fixture files. The recorder removes token-like values and JSON fields with a secret name. Make sure that no private data stays.
4. Run `swift test` again without `OVERSIRE_RECORD`. A call with no fixture fails with `no fixture`.

For a CLI, use `ReplayCommandRunner` in the same way. For a small test, `RecordedHTTP` gives answers that you write in the test.

With no test account, write a small `HTTPTransport` in the test target. It keeps the data in memory and answers the JSON calls of the adapter, and a 401 for a bad token. The suites then run against it.

## 7. Run the conformance suite

`OverSireTestKit` has one suite for the base protocol and one suite for each layer. A new adapter must pass both.

```swift
// The closures are @Sendable. Use a static or a free function, not a method of the test case.
static func makeTracker(_ fixtures: String) -> LinearTracker { ... }

func testConformance() async {
    let base = await ProviderConformance.run { scenario in
        // .unauthorized: give the adapter a fixture set with a 401 answer.
        Self.makeTracker(scenario == .normal ? "linear" : "linear-401")
    }
    XCTAssertTrue(base.passed, base.description)
    let layer = await TrackerConformance.run { Self.makeTracker("linear") }
    XCTAssertTrue(layer.passed, layer.description)
}
```

In the `.unauthorized` scenario, `probe()` must throw `ProviderError.unauthorized`. `poll` can throw any error.

- `ProviderConformance.run` checks the probe, two polls, the cursor, the event ids and the refused token.
- `ProviderConformance.capabilities(p)` checks only the capabilities. It does no I/O.
- `TrackerConformance.run`, `CodeHostConformance.run(sha:make:)`, `CIConformance.run(repo:make:)` and `RuntimeConformance.run(repo:make:)` check the layer. The tracker suite writes one item and one comment.
- The report lists each problem. Fix the problems one at a time.

`Tests/OverSireTestKitTests/FakeConformanceTests.swift` runs the suites on the fakes in `OverSireTestKit`. Use it as an example.

To run a suite against the real vendor, add a test to `Tests/LiveTests`. These tests run only with `OVERSIRE_LIVE=1` and the token in the environment.

## 8. Register the adapter

Add the descriptor to the list in `AppEnvironment.init` in `Sources/OverSireApp/AppEnvironment.swift`:

```swift
for d in [PlaneTracker.descriptor, LinearTracker.descriptor, GitHubCodeHost.descriptor, ActionsCI.descriptor, OrcaRuntime.descriptor] {
```

Then add the import of the target at the top of the file, and add the target to the `OverSireApp` dependencies in `Package.swift`. The vendor is now on the Providers page.

## 9. Check

1. `swift build` and `swift test`. For a fast loop, run `swift test --filter TrackerLinearTests`.
2. `.build/debug/oversire --selftest`.
3. This command must give no output. Only the app imports AppKit:

```bash
grep -rl "import Cocoa\|import AppKit" Sources/OverSireCore Sources/OverSireSync Sources/OverSireAI Sources/Providers Sources/OverSireTestKit Sources/GitHubKit
```

4. `./build.sh`, then add an account on the Providers page. The page shows the user from `probe()`.

## Webhooks

Polling is enough for a new adapter. For faster updates, the cloud can take the vendor webhooks and send them to the app. That part is in the private `oversire/cloud` repo. Its guide tells how to add a webhook adapter. On the app side, conform to `WebhookManaging` and add the `.webhooks` capability.
