#!/usr/bin/env bash
# builds dist/ganksense.app: swift build, app bundle layout, liquid glass icon, ad-hoc signature.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=lib/style.sh
. scripts/lib/style.sh

CFG="${1:-debug}"
APP=dist/ganksense.app
[ -n "${GANKSENSE_NESTED:-}" ] || header "bundle" "$CFG"

run "Compiling ($CFG)" swift build -c "$CFG"
BIN_DIR="$(swift build -c "$CFG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ganksense" "$APP/Contents/MacOS/ganksense"
cp Resources/Info.plist "$APP/Contents/Info.plist"
for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done
done_line "Assembling the app bundle"

# liquid glass icon: actool compiles the icon composer bundle into Assets.car. Resources/AppIcon.icns is a flat
# full size render of that icon, kept as the fallback; re-render it by hand when the .icon changes.
XCODE_DEV="${XCODE_DEV:-/Applications/Xcode.app/Contents/Developer}"
if DEVELOPER_DIR="$XCODE_DEV" xcrun --find actool >/dev/null 2>&1; then
  # actool resolves relative paths against the input, so everything is absolute
  run "Compiling the liquid glass icon" env DEVELOPER_DIR="$XCODE_DEV" xcrun actool "$PWD/Resources/Icon/AppIcon.icon" \
      --compile "$PWD/$APP/Contents/Resources" \
      --platform macosx --target-device mac --minimum-deployment-target 26.0 \
      --app-icon AppIcon --output-partial-info-plist "$PWD/$APP/icon-partial.plist"
  rm -f "$APP/icon-partial.plist"
else
  warn_line "actool not found (needs Xcode at $XCODE_DEV, override with XCODE_DEV=...)."
  warn_line "Bundling the flat Resources/AppIcon.icns only, no liquid glass icon."
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

run "Signing (ad hoc)" codesign --force --deep -s - "$APP"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo '?')"
SIZE="$(du -sh "$APP" | cut -f1 | tr -d ' ')"
if [ -z "${GANKSENSE_NESTED:-}" ]; then
  printf '\n  %s%s%s %s%s%s  %s%s · %s%s\n\n' "$BOLD$PALE" "$APP" "$RESET" "$GOLD" "$VERSION" "$RESET" "$MUTED" "$CFG" "$SIZE" "$RESET"
fi
