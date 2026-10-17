#!/bin/bash
# Makes the PNG files and AppIcon.icns from the SVG masters in this folder.
# Needs rsvg-convert (brew install librsvg). Without it, qlmanage is the fallback.
set -euo pipefail
cd "$(dirname "$0")"

render() { # svg width height out
  if command -v rsvg-convert >/dev/null; then
    rsvg-convert -w "$2" -h "$3" "$1" -o "$4"
  else
    local tmp; tmp=$(mktemp -d)
    qlmanage -t -s "$2" -o "$tmp" "$1" >/dev/null
    mv "$tmp/$(basename "$1").png" "$4"; rmdir "$tmp"
  fi
}

# App icon. The 16 px and 32 px sizes use the heavier small variant.
rm -rf AppIcon.iconset && mkdir AppIcon.iconset
for s in 16 32 128 256 512; do
  src=AppIcon.svg; [ $s -le 32 ] && src=AppIcon-small.svg
  render $src $s $s AppIcon.iconset/icon_${s}x${s}.png
  src=AppIcon.svg; [ $s -le 16 ] && src=AppIcon-small.svg
  render $src $((s*2)) $((s*2)) AppIcon.iconset/icon_${s}x${s}@2x.png
done
iconutil -c icns AppIcon.iconset -o AppIcon.icns
render AppIcon.svg 1024 1024 AppIcon.png
rm -rf AppIcon.iconset

render OrgAvatar.svg 500 500 org-avatar.png

# Social preview for each repo (1280 × 640).
social() { # repo tagline
  cat > "social-$1.svg" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="1280" height="640" viewBox="0 0 1280 640">
  <defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#1b1e25"/><stop offset="1" stop-color="#0f1115"/></linearGradient></defs>
  <rect width="1280" height="640" fill="url(#bg)"/>
  <g transform="translate(90 154) scale(3.32)">
    <g fill="none" stroke-width="9" transform="rotate(-80 50 50)">
      <circle cx="50" cy="50" r="27" stroke="#b98ad6" stroke-dasharray="51 6.5"/>
      <circle cx="50" cy="50" r="27" stroke="#5aaee8" stroke-dasharray="0 57.5 51 200"/>
      <circle cx="50" cy="50" r="27" stroke="#e9a21a" stroke-dasharray="0 115 51 200"/>
    </g>
    <circle cx="50" cy="50" r="12" fill="#1fb386"/>
  </g>
  <g font-family="Helvetica Neue, Helvetica, Arial, sans-serif">
    <text x="480" y="262" font-size="38" fill="#a6aab3">oversire /</text>
    <text x="476" y="356" font-size="92" font-weight="bold" fill="#e9eaee">$1</text>
    <text x="480" y="420" font-size="32" fill="#a6aab3">$2</text>
  </g>
</svg>
SVG
  render "social-$1.svg" 1280 640 "social-$1.png"
}
social oversire "Your CI, PRs, tracker and agents in one menu bar light."
social agent-binder "Drive coding agent CLIs from Swift."
social cloud "Live events and AI for OverSire."
