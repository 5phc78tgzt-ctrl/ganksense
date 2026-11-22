#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

CFG="${1:-debug}"
swift build -c "$CFG"
BIN_DIR="$(swift build -c "$CFG" --show-bin-path)"

APP=dist/ganksense.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_DIR/ganksense" "$APP/Contents/MacOS/ganksense"
cp Resources/Info.plist "$APP/Contents/Info.plist"

for b in "$BIN_DIR"/*.bundle; do
  [ -e "$b" ] && cp -R "$b" "$APP/Contents/Resources/"
done

# liquid glass icon: actool compiles the icon composer bundle into Assets.car. Resources/AppIcon.icns is a flat
# full size render of that icon, kept as the fallback; re-render it by hand when the .icon changes.
XCODE_DEV="${XCODE_DEV:-/Applications/Xcode.app/Contents/Developer}"
if DEVELOPER_DIR="$XCODE_DEV" xcrun --find actool >/dev/null 2>&1; then
  # actool resolves relative paths against the input, so everything is absolute
  if ! out=$(DEVELOPER_DIR="$XCODE_DEV" xcrun actool "$PWD/Resources/Icon/AppIcon.icon" \
      --compile "$PWD/$APP/Contents/Resources" \
      --platform macosx --target-device mac --minimum-deployment-target 26.0 \
      --app-icon AppIcon --output-partial-info-plist "$PWD/$APP/icon-partial.plist" 2>&1); then
    echo "$out" >&2
    echo "error: actool failed to compile Resources/Icon/AppIcon.icon" >&2
    exit 1
  fi
  rm -f "$APP/icon-partial.plist"
else
  echo "warning: actool not found (needs xcode at $XCODE_DEV, override with XCODE_DEV=...)." >&2
  echo "warning: bundling the flat Resources/AppIcon.icns only, no liquid glass icon." >&2
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --deep -s - "$APP"
echo "Built $APP ($CFG)"
