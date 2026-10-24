# Contributing to OverSire

Thanks for your interest! OverSire is intentionally small: native Swift, one Swift package (SwiftTerm, for the live terminal), and no other dependencies beyond macOS and the `gh` CLI. Contributions that keep it that way are very welcome.

## Getting started

```bash
git clone https://github.com/oversire/oversire.git
cd oversire
./build.sh
open OverSire.app
```

Requires macOS 13+ and Xcode Command Line Tools (`xcode-select --install`).

The build signs with the first "Developer ID Application" identity in your keychain. If there is none, it uses an ad-hoc signature. With an ad-hoc signature, the Keychain asks again for the saved secrets after each rebuild. To select an identity, set `CODESIGN_IDENTITY`:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

## Guidelines

- **Keep it lean.** No external packages, no frameworks beyond AppKit, UserNotifications and Network. The code is one Swift package (`Package.swift`). `OverSireCore` holds the domain types and the provider protocols. Each vendor adapter is a target in `Sources/Providers/`. `Sources/OverSireApp` holds the AppKit UI: `main.swift` for the app delegate, plus one file per tab, settings page, and the project data layer. Repo picking is in `repo_catalog.swift` and `actions_settings.swift`. The live sync is in `live_sync.swift`, and the cloud settings are in `cloud_settings.swift`.
- **Security matters.** The app shells out to `gh` only via hardcoded trusted paths with an allowlisted environment, and validates all repo input. Don't weaken these.
- **Accessibility matters.** Status is never conveyed by colour alone (we use the Okabe-Ito palette plus shape/text signals). New UI should follow the same rule and stay keyboard-navigable.
- **No telemetry, no GitHub tokens.** GitHub auth goes through the `gh` CLI. OverSire keeps the Plane tokens, the AI key, the cloud device token and the webhook secret in the Keychain. Secrets go to `gh` on stdin, never in argv.

## Adding a provider

OverSire talks to each vendor through an adapter: a tracker, a code host, a CI provider or an agent runtime. To add a vendor, follow [docs/adding-a-provider.md](docs/adding-a-provider.md). Each layer has a template in `Sources/Providers/` that builds as it is.

## Open core

This repo is the full app under the MIT license. The paid cloud (the webhook relay, the hosted sync and the billing) is in the private `oversire/cloud` repo. That repo has its own guide for webhook adapters. A provider in this repo must work without the cloud: it polls.

## Submitting changes

1. Fork the repo and create a branch.
2. Make your change and verify it builds (`./build.sh`), passes `swift test` and `OverSire.app/Contents/MacOS/oversire --selftest`, and runs.
3. Update the README if behaviour or configuration changed.
4. Open a pull request with a clear description of what and why.

## Releases

Each push to `main` by the owner starts `.github/workflows/release.yml`. The workflow builds a universal binary, signs it with the Developer ID, notarizes it, and publishes `OverSire.zip` to a new GitHub release. The tag is the last tag with the patch number plus one. For a minor or major release, set the higher version in `Info.plist`.

The signing secrets are in the `release` environment, which accepts the `main` branch only. Workflows from other people and from forks cannot use them.

## App icon

The SVG masters are in `brand/`:

- `AppIcon.svg`: the app icon ("Status lens"). `AppIcon-small.svg` is a heavier variant for 16 px and 32 px.
- `MenuBarIcon.svg`: the menu bar template. `Sources/OverSireApp/status_icon.swift` draws the same shape in code. Keep the two the same.
- `OrgAvatar.svg`: the GitHub org avatar.

After you change an SVG, run `brand/make.sh`. It makes `AppIcon.icns`, `AppIcon.png`, `org-avatar.png` and the social previews `social-<repo>.png` (1280 × 640). It needs `rsvg-convert` (`brew install librsvg`) and `iconutil`.

GitHub has no API for the org avatar or the social preview. Upload them in the browser: the org profile settings, and Settings › General › Social preview of each repo.

## Reporting bugs

Open a GitHub issue with your macOS version, `gh --version` output, and steps to reproduce. Screenshots help — but please use demo data, not your real repo names.
