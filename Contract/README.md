# OverSire wire contract

This folder defines the types that the app (Swift) and the cloud (TypeScript) share.
Each side has its own types. Both sides run the same fixture files in their tests.

## Files

- `schema/*.json`: JSON Schema, draft 2020-12.
  - `refs.json`: `ProviderID`, `AccountID`, `PersonRef`, the refs, `SubjectRef`.
  - `provider-event.json`: `ProviderEvent`, `EventSummary`.
  - `actions.json`: `ItemPatch`, `ChangeAction`, `RunAction`, `LaunchRequest`.
  - `ai-task.json`: `AITask`, `AIInput`, `AIResult`.
  - `account.json`: `AccountConfig`.
- `fixtures/<type>/<case>.json`: sample values. The folder name is the type.

## Tests

Each fixture must decode, encode again and give the same JSON (compare with sorted keys).
Swift: `swift test --filter ContractTests`. TypeScript: the contract test in `oversire/cloud`.

## Version rule

Each schema file has `"x-oversire-schema": 1`. The messages that cross the network
(`ProviderEvent`, `AITask`, `AIResult`) carry the same number in their `schema` field.

- A new optional field is compatible. Keep the number.
- A removed field, a renamed field, a new required field or a changed type is not compatible.
  Increase the number.
- The server must accept the last two numbers.
