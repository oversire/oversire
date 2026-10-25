# OverSire wire contract

This folder defines the types that the app (Swift), the cloud (TypeScript) and the runner (Go) share.
Each side has its own types. Both sides run the same fixture files in their tests.

## Files

- `schema/*.json`: JSON Schema, draft 2020-12.
  - `refs.json`: `ProviderID`, `AccountID`, `PersonRef`, the refs, `SubjectRef`.
  - `provider-event.json`: `ProviderEvent`, `EventSummary`.
  - `actions.json`: `ActionKind`, `ItemPatch`, `ChangeAction`, `RunAction`, `LaunchRequest`, `RelationKind`, `ItemRelation`, `RelationPatch`. Version 2: the relation kind `duplicate`.
  - `ai-task.json`: `AITask`, `AIInput`, `AIResult`, `AIUsage`.
  - `account.json`: `AccountConfig`.
  - `store.json`: the store records, `QueueLaneState` and `StoreOp`. Version 2.
  - `jobs.json`: `Job`, `JobTrigger`, `EventFilter`, `JobRun`. Swift names them `AIJob` and `AIJobRun`.
  - `suggestion.json`: `Suggestion`, `Proposal`.
  - `work-order.json`: `WorkOrder`, `WorkOrderDraft`, `SessionOrder`, `WorkOrderResult`.
  - `memory.json`: `MemoryEntry`, `MemoryDraft`.
  - `billing.json`: `UsageRow`, `LedgerEntry`, `BillingState`. Money is an integer in micro-USD.
  - `ai-endpoint.json`: `AIEndpoint`, `AIRoute`.
  - `assistant.json`: `AssistantThread`, `AssistantMessage`, `AssistantPart`, `ChatEvent`, `ToolSpec`, `ToolCall`, `ToolResult`, `Approval`.
  - `groom.json`: `GroomResult`, `GroomProposal`. The result block of a Groom session. Only the app reads it.
- `fixtures/<type>/<case>.json`: sample values. The folder name is the type.
- `prompts/<taskKind>.md`: the prompt of each AI task kind. `prompts/README.md` has the format.

## Tests

Each fixture must decode, encode again and give the same JSON (compare with sorted keys).
Swift: `swift test --filter ContractTests`. TypeScript: the contract test in `oversire/cloud`.

## Version rule

Each schema file has `"x-oversire-schema"`. It is 1 for most files. `store.json`, `jobs.json`, `suggestion.json`, `daemon.json` and `actions.json` are 2. The messages that cross the network
(`ProviderEvent`, `AITask`, `AIResult`) carry the same number in their `schema` field.

- A new optional field is compatible. Keep the number.
- A removed field, a renamed field, a new required field or a changed type is not compatible.
  Increase the number.
- The server must accept the last two numbers.
