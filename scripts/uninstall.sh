#!/usr/bin/env bash
# removes the app; --purge also deletes settings, game history and caches.
# everything runs inside main(), called on the last line, so a truncated download runs nothing.
set -euo pipefail

APP_NAME="ganksense"
BUNDLE_ID="app.ganksense.ganksense"

app_pids() { pgrep -f "/$APP_NAME\.app/Contents/MacOS/$APP_NAME\$" || true; }

main() {
  local purge="${GANKSENSE_PURGE:-0}"
  [ "${1:-}" = "--purge" ] && purge=1

  if [ -n "$(app_pids)" ]; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(app_pids)" ] || break; sleep 0.3; done
    # shellcheck disable=SC2046
    kill $(app_pids) 2>/dev/null || true
  fi

  local removed=0 dir
  for dir in "${GANKSENSE_DIR:-}" /Applications "$HOME/Applications"; do
    [ -n "$dir" ] && [ -d "$dir/$APP_NAME.app" ] || continue
    rm -rf "${dir:?}/$APP_NAME.app"
    echo "Removed $dir/$APP_NAME.app"
    removed=1
  done
  [ "$removed" = 1 ] || echo "$APP_NAME.app wasn't found in /Applications or ~/Applications."

  if [ "$purge" = "1" ]; then
    rm -rf "$HOME/Library/Application Support/$APP_NAME" "$HOME/Library/Caches/$APP_NAME"
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    echo "Deleted settings, game history and caches."
  else
    echo "Kept settings and game history in ~/Library/Application Support/$APP_NAME (run with --purge to delete)."
  fi
}

main "$@"
