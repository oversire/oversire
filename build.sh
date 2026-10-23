#!/bin/bash
set -e
cd "$(dirname "$0")"
echo "Building OverSire..."
# Remember where the running or installed copy lives, so the restart opens it.
RUNNING_APP="$(ps -axo comm= | sed -n 's#^\(.*\.app\)/Contents/MacOS/oversire$#\1#p' | head -1)"
if [ -z "$RUNNING_APP" ]; then
  for a in /Applications/OverSire.app "$HOME/Applications/OverSire.app"; do [ -d "$a" ] && RUNNING_APP="$a" && break; done
fi
mkdir -p OverSire.app/Contents/MacOS
cp Info.plist OverSire.app/Contents/Info.plist
# VERSION overrides the version in Info.plist (CI sets it from the release tag).
# Local builds get a "-dev" suffix, so the auto-updater never replaces them.
if [ -n "$VERSION" ]; then
  plutil -replace CFBundleVersion -string "$VERSION" OverSire.app/Contents/Info.plist
  plutil -replace CFBundleShortVersionString -string "$VERSION" OverSire.app/Contents/Info.plist
else
  plutil -replace CFBundleShortVersionString -string "$(plutil -extract CFBundleShortVersionString raw Info.plist)-dev" OverSire.app/Contents/Info.plist
fi
# ARCHS="arm64 x86_64" builds a universal binary. The default is this Mac's arch.
BINS=()
for arch in ${ARCHS:-$(uname -m)}; do
  swift build -c release --triple "$arch-apple-macosx13.0" -Xswiftc -Osize --product oversire
  BINS+=(".build/$arch-apple-macosx/release/oversire")
done
lipo -create "${BINS[@]}" -output OverSire.app/Contents/MacOS/oversire
# brand/AppIcon.icns comes from brand/AppIcon.svg. Run brand/make.sh to make it again.
mkdir -p OverSire.app/Contents/Resources
cp brand/AppIcon.icns OverSire.app/Contents/Resources/AppIcon.icns
# Markdown rendering: markdown-it and highlight.js. See assets/markdown/README.md.
rm -rf OverSire.app/Contents/Resources/markdown
cp -R assets/markdown OverSire.app/Contents/Resources/markdown
strip OverSire.app/Contents/MacOS/oversire
# A real identity keeps Keychain "Always Allow" valid across rebuilds. Ad-hoc ("-") is the fallback.
IDENTITY="${CODESIGN_IDENTITY:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
echo "Signing with: ${IDENTITY:-ad-hoc}"
if [ -z "$IDENTITY" ] || [ "$IDENTITY" = "-" ]; then
  codesign --force --deep --sign - --timestamp=none OverSire.app
else
  # Notarization needs the hardened runtime and a secure timestamp. RELEASE=1 adds the timestamp.
  TS=--timestamp=none; [ "$RELEASE" = 1 ] && TS=--timestamp
  codesign --force --deep --options runtime $TS --sign "$IDENTITY" OverSire.app
fi
codesign --verify --deep --strict OverSire.app
echo "Done. $(ls -lh OverSire.app/Contents/MacOS/oversire | awk '{print $5}') binary"
# CI and release builds only package the app. NO_RESTART=1 does the same locally.
if [ -n "$CI" ] || [ "$RELEASE" = 1 ] || [ "$NO_RESTART" = 1 ]; then exit 0; fi
# The daemon binary is also named oversire. Stop only the app.
pkill -f '\.app/Contents/MacOS/oversire( |$)' 2>/dev/null && sleep 0.5 || true
DEST="$PWD/OverSire.app"
# Refresh an installed copy only if it is a real directory with our bundle id.
# rsync --delete on the wrong target removes an unrelated app.
if [ -n "$RUNNING_APP" ] && [ "$RUNNING_APP" != "$DEST" ] && [ -d "$RUNNING_APP" ] && [ ! -L "$RUNNING_APP" ] &&
   [[ "$(defaults read "$RUNNING_APP/Contents/Info" CFBundleIdentifier 2>/dev/null)" =~ ^com\.oversire\.app$ ]]; then
  rsync -a --delete OverSire.app/ "$RUNNING_APP/"
  DEST="$RUNNING_APP"
fi
open "$DEST"
echo "Restarted: $DEST"
