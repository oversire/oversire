# Contributing to OverSire

Thanks for your interest! OverSire is intentionally small: native Swift, zero dependencies beyond macOS and the `gh` CLI. Contributions that keep it that way are very welcome.

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

- **Keep it lean.** No external packages, no frameworks beyond AppKit, UserNotifications and Network. The code is one Swift package (`Package.swift`). `OverSireCore` holds the domain types and the provider protocols. Each vendor adapter is a target in `Sources/Providers/`. `Sources/OverSireApp` holds the AppKit UI: `main.swift` for the app delegate, plus one file per tab, settings page, and the project data layer. Repo picking is in `repo_catalog.swift` and `actions_settings.swift`. The cloud client is in `relay.swift` and `cloud_settings.swift`. The server is in the private `oversire/cloud` repo.
- **Security matters.** The app shells out to `gh` only via hardcoded trusted paths with an allowlisted environment, and validates all repo input. Don't weaken these.
- **Accessibility matters.** Status is never conveyed by colour alone (we use the Okabe-Ito palette plus shape/text signals). New UI should follow the same rule and stay keyboard-navigable.
- **No telemetry, no GitHub tokens.** GitHub auth goes through the `gh` CLI. OverSire keeps the Plane tokens, the AI key, the cloud device token and the webhook secret in the Keychain. Secrets go to `gh` on stdin, never in argv.

## Submitting changes

1. Fork the repo and create a branch.
2. Make your change and verify it builds (`./build.sh`), passes `swift test` and `OverSire.app/Contents/MacOS/oversire --selftest`, and runs.
3. Update the README if behaviour or configuration changed.
4. Open a pull request with a clear description of what and why.

## Releases

Each push to `main` by the owner starts `.github/workflows/release.yml`. The workflow builds a universal binary, signs it with the Developer ID, notarizes it, and publishes `OverSire.zip` to a new GitHub release. The tag is the last tag with the patch number plus one. For a minor or major release, set the higher version in `Info.plist`.

The signing secrets are in the `release` environment, which accepts the `main` branch only. Workflows from other people and from forks cannot use them.

## App icon

`AppIcon.svg` is the source of `AppIcon.icns`. After you change the SVG, make the icon again (this needs `brew install librsvg`):

```bash
mkdir -p AppIcon.iconset
for s in 16 32 128 256 512; do
  rsvg-convert -w $s -h $s AppIcon.svg -o AppIcon.iconset/icon_${s}x${s}.png
  rsvg-convert -w $((s*2)) -h $((s*2)) AppIcon.svg -o AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
```

## Reporting bugs

Open a GitHub issue with your macOS version, `gh --version` output, and steps to reproduce. Screenshots help — but please use demo data, not your real repo names.
