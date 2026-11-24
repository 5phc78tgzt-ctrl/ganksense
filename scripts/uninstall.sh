#!/usr/bin/env bash
# removes the app; --purge also deletes settings, game history and caches.
# everything runs inside main(), called on the last line, so a truncated download runs nothing.
set -euo pipefail

APP_NAME="ganksense"
BUNDLE_ID="app.ganksense.ganksense"

# colour only on a terminal, and never when NO_COLOR is set (https://no-color.org).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  GOLD=$'\033[38;2;200;170;110m'; PALE=$'\033[38;2;240;230;210m'; BRONZE=$'\033[38;2;120;90;40m'
  TEAL=$'\033[38;2;10;200;185m'; MUTED=$'\033[38;2;160;155;140m'
else
  RESET=""; BOLD=""; DIM=""; GOLD=""; PALE=""; BRONZE=""; TEAL=""; MUTED=""
fi

tidy() { local d="$1"; printf '%s' "${d/#$HOME/~}"; }
done_line() {
  printf '  %s✓%s %s' "$TEAL" "$RESET" "$1"
  [ -n "${2:-}" ] && printf '  %s%s%s' "$MUTED" "$(tidy "$2")" "$RESET"
  printf '\n'
}
skip_line() {
  printf '  %s–%s %s%s%s' "$BRONZE" "$RESET" "$MUTED" "$1" "$RESET"
  [ -n "${2:-}" ] && printf '  %s%s%s' "$DIM" "$2" "$RESET"
  printf '\n'
}

app_pids() { pgrep -f "/$APP_NAME\.app/Contents/MacOS/$APP_NAME\$" || true; }

main() {
  local purge="${GANKSENSE_PURGE:-0}"
  [ "${1:-}" = "--purge" ] && purge=1

  printf '\n  %s◆%s %s%s%s%s %s·%s %suninstall%s\n\n' "$GOLD" "$RESET" "$BOLD" "$PALE" "$APP_NAME" "$RESET" \
    "$BRONZE" "$RESET" "$GOLD" "$RESET"

  if [ -n "$(app_pids)" ]; then
    osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(app_pids)" ] || break; sleep 0.3; done
    # shellcheck disable=SC2046
    kill $(app_pids) 2>/dev/null || true
    done_line "Quit $APP_NAME"
  fi

  local removed=0 dir
  for dir in "${GANKSENSE_DIR:-}" /Applications "$HOME/Applications"; do
    [ -n "$dir" ] && [ -d "$dir/$APP_NAME.app" ] || continue
    rm -rf "${dir:?}/$APP_NAME.app"
    done_line "Removed the app" "$dir/$APP_NAME.app"
    removed=1
  done
  [ "$removed" = 1 ] || skip_line "$APP_NAME.app wasn't in /Applications or ~/Applications"

  if [ "$purge" = "1" ]; then
    rm -rf "$HOME/Library/Application Support/$APP_NAME" "$HOME/Library/Caches/$APP_NAME"
    rm -rf "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/Preferences/$BUNDLE_ID.plist"
    done_line "Deleted settings, game history and caches"
    printf '\n  %sAll gone. GG.%s\n\n' "$PALE" "$RESET"
  else
    skip_line "Kept settings and game history" "~/Library/Application Support/$APP_NAME"
    printf '\n  %sDone. Run with %s--purge%s%s to delete your settings and history too:%s\n' \
      "$PALE" "$GOLD" "$RESET" "$PALE" "$RESET"
    printf '  %scurl -fsSL https://ganksense.app/uninstall.sh | bash -s -- --purge%s\n\n' "$MUTED" "$RESET"
  fi
}

main "$@"
