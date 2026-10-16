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

The build signs with the first "Developer ID Application" identity in your keychain. If there is none, it uses an ad-hoc signature. With an ad-hoc signature, the Keychain asks again for the relay secrets after each rebuild. To select an identity, set `CODESIGN_IDENTITY`:

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./build.sh
```

## Guidelines

- **Keep it lean.** No external packages, no frameworks beyond AppKit, UserNotifications and Network. The app is split across Swift files: `main.swift` for the app delegate, plus one file per tab, settings page, and the project data layer. Repo picking is in `repo_catalog.swift` and `actions_settings.swift`. Live updates are in `relay.swift` and `relay_settings.swift`. The Cloudflare Worker is in `worker/`.
- **Security matters.** The app shells out to `gh` only via hardcoded trusted paths with an allowlisted environment, and validates all repo input. Don't weaken these.
- **Accessibility matters.** Status is never conveyed by colour alone (we use the Okabe-Ito palette plus shape/text signals). New UI should follow the same rule and stay keyboard-navigable.
- **No telemetry, no GitHub tokens.** GitHub auth goes through the `gh` CLI, and Cloudflare auth goes through wrangler. The only secrets OverSire keeps are the relay device token and webhook secret. They stay in the Keychain and go to `gh` and `wrangler` on stdin, never in argv.

## Submitting changes

1. Fork the repo and create a branch.
2. Make your change and verify it builds (`./build.sh`), passes `OverSire.app/Contents/MacOS/oversire --selftest`, and runs. For Worker changes, run `npm install && npm test` in `worker/`.
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
