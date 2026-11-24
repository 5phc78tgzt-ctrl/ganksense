#!/usr/bin/env bash
# curl installer: downloads the zip, verifies its checksum, installs into /applications or ~/applications, opens it.
# curl downloads carry no quarantine flag, so gatekeeper accepts the ad-hoc signed app; the flag is cleared anyway.
# publish the copy that package.sh writes to dist/: it has the release url and checksum baked in.
# everything runs inside main(), called on the last line, so a truncated download runs nothing.
set -euo pipefail

APP_NAME="ganksense"
BUNDLE_ID="app.ganksense.ganksense"
RELEASE_URL=""      # baked in by package.sh
RELEASE_SHA256=""   # set by scripts/package.sh

: "${GANKSENSE_URL:=}"
: "${GANKSENSE_SHA256:=}"
: "${GANKSENSE_ZIP:=}"
: "${GANKSENSE_DIR:=}"
: "${GANKSENSE_NO_OPEN:=}"

# colour only on a terminal, and never when NO_COLOR is set (https://no-color.org).
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  TTY=1
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  GOLD=$'\033[38;2;200;170;110m'; PALE=$'\033[38;2;240;230;210m'; BRONZE=$'\033[38;2;120;90;40m'
  TEAL=$'\033[38;2;10;200;185m'; RED=$'\033[38;2;232;64;87m'; MUTED=$'\033[38;2;160;155;140m'
else
  TTY=0; RESET=""; BOLD=""; DIM=""; GOLD=""; PALE=""; BRONZE=""; TEAL=""; RED=""; MUTED=""
fi

banner() {
  local cols
  cols="$(tput cols 2>/dev/null || echo 80)"
  printf '\n'
  if [ "$TTY" = 1 ] && [ "$cols" -ge 80 ]; then
    # gold gradient top to bottom, like the hud's frames.
    local shades=(
      $'\033[38;2;240;230;210m' $'\033[38;2;228;210;170m' $'\033[38;2;214;190;140m'
      $'\033[38;2;200;170;110m' $'\033[38;2;165;130;75m' $'\033[38;2;120;90;40m'
    )
    local lines=(
      ' ██████╗  █████╗ ███╗   ██╗██╗  ██╗███████╗███████╗███╗   ██╗███████╗███████╗'
      '██╔════╝ ██╔══██╗████╗  ██║██║ ██╔╝██╔════╝██╔════╝████╗  ██║██╔════╝██╔════╝'
      '██║  ███╗███████║██╔██╗ ██║█████╔╝ ███████╗█████╗  ██╔██╗ ██║███████╗█████╗  '
      '██║   ██║██╔══██║██║╚██╗██║██╔═██╗ ╚════██║██╔══╝  ██║╚██╗██║╚════██║██╔══╝  '
      '╚██████╔╝██║  ██║██║ ╚████║██║  ██╗███████║███████╗██║ ╚████║███████║███████╗'
      ' ╚═════╝ ╚═╝  ╚═╝╚═╝  ╚═══╝╚═╝  ╚═╝╚══════╝╚══════╝╚═╝  ╚═══╝╚══════╝╚══════╝'
    )
    local i
    for i in 0 1 2 3 4 5; do printf '  %s%s%s\n' "${shades[$i]}" "${lines[$i]}" "$RESET"; done
    printf '\n  %s◆%s %sthe quiet scout for your League games%s\n\n' "$TEAL" "$RESET" "$MUTED" "$RESET"
  else
    printf '  %s%s◆ ganksense%s  %sthe quiet scout for your League games%s\n\n' "$BOLD" "$GOLD" "$RESET" "$MUTED" "$RESET"
  fi
}

# step lines: a hollow marker while it runs, a teal check when done, a red cross on failure.
CURRENT=""
step() {
  CURRENT="$*"
  if [ "$TTY" = 1 ]; then printf '  %s○%s %s' "$BRONZE" "$RESET" "$CURRENT"; else printf '  - %s\n' "$CURRENT"; fi
}
ok() {
  local detail="${1:-}"
  detail="${detail/#$HOME/~}"
  if [ "$TTY" = 1 ]; then
    printf '\r\033[K  %s✓%s %s' "$TEAL" "$RESET" "$CURRENT"
    [ -n "$detail" ] && printf '  %s%s%s' "$MUTED" "$detail" "$RESET"
    printf '\n'
  elif [ -n "$detail" ]; then
    printf '    %s\n' "$detail"
  fi
  CURRENT=""
}
fail() {
  if [ "$TTY" = 1 ] && [ -n "$CURRENT" ]; then printf '\r\033[K  %s✗%s %s\n' "$RED" "$RESET" "$CURRENT" >&2; fi
  printf '\n  %s%serror%s %s\n\n' "$BOLD" "$RED" "$RESET" "$*" >&2
  exit 1
}

app_pids() { pgrep -f "/$APP_NAME\.app/Contents/MacOS/$APP_NAME\$" || true; }

quit_running() {
  [ -n "$(app_pids)" ] || return 0
  step "Quitting the running $APP_NAME"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(app_pids)" ] || { ok; return 0; }; sleep 0.3; done
  # shellcheck disable=SC2046
  kill $(app_pids) 2>/dev/null || true
  ok
}

main() {
  banner

  step "Checking this Mac"
  [ "$(uname -s)" = "Darwin" ] || fail "$APP_NAME is a macOS app."
  local os major
  os="$(sw_vers -productVersion)"
  major="$(echo "$os" | cut -d. -f1)"
  [ "$major" -ge 26 ] || fail "$APP_NAME needs macOS 26 or later (this Mac runs $os)."
  [ "$(uname -m)" = "arm64" ] || fail "$APP_NAME currently supports Apple Silicon Macs only."
  ok "macOS $os · Apple Silicon"

  local tmp
  tmp="$(mktemp -d -t ganksense-install)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  local zip="$tmp/$APP_NAME.zip" expected="${GANKSENSE_SHA256:-$RELEASE_SHA256}"

  if [ -n "${GANKSENSE_ZIP:-}" ]; then
    step "Using a local zip"
    [ -f "$GANKSENSE_ZIP" ] || fail "No zip at $GANKSENSE_ZIP"
    cp "$GANKSENSE_ZIP" "$zip"
    if [ -z "$expected" ] && [ -f "$GANKSENSE_ZIP.sha256" ]; then expected="$(cut -d' ' -f1 < "$GANKSENSE_ZIP.sha256")"; fi
    ok "$GANKSENSE_ZIP"
  else
    local url="${GANKSENSE_URL:-$RELEASE_URL}"
    [ -n "$url" ] || fail "This install script has no release URL. Use the copy from the website (or set GANKSENSE_URL)."
    # curl draws its own progress bar on the next line, so this step prints whole.
    printf '  %s↓%s Downloading %s%s%s\n' "$GOLD" "$RESET" "$MUTED" "$url" "$RESET"
    curl -fL --progress-bar --proto '=https' --tlsv1.2 -o "$zip" "$url" || fail "Download failed."
  fi

  step "Verifying checksum"
  [ -n "$expected" ] || fail "No SHA-256 to check the download against (set GANKSENSE_SHA256). Not installing."
  local actual
  actual="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
  [ "$expected" = "$actual" ] || fail "Checksum mismatch (expected $expected, got $actual). Not installing."
  ok "sha256 ${actual:0:12}…"

  step "Checking the app's signature"
  ditto -x -k "$zip" "$tmp/out" || fail "Couldn't unpack the zip."
  local new_app="$tmp/out/$APP_NAME.app"
  [ -d "$new_app" ] || fail "The zip doesn't contain $APP_NAME.app."
  codesign --verify --deep --strict "$new_app" 2>/dev/null || fail "The app's signature is broken. Not installing."
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$new_app/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ] \
    || fail "The zip doesn't contain the expected app. Not installing."
  ok

  local dest_dir
  if [ -n "${GANKSENSE_DIR:-}" ]; then
    dest_dir="$GANKSENSE_DIR"
  elif [ -w /Applications ]; then
    dest_dir="/Applications"
  else
    dest_dir="$HOME/Applications"
  fi
  mkdir -p "$dest_dir"
  local dest="$dest_dir/$APP_NAME.app"

  quit_running

  step "Installing"
  # copy next to the installed app first, then swap, so a failed copy leaves the previous install in place.
  rm -rf "${dest:?}.new"
  ditto "$new_app" "$dest.new"
  rm -rf "${dest:?}"
  mv "$dest.new" "$dest"
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true
  ok "$dest"

  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dest/Contents/Info.plist" 2>/dev/null || echo '?')"
  printf '\n  %s%s%s %s%s%s is ready.\n' "$BOLD$PALE" "$APP_NAME" "$RESET" "$GOLD" "$version" "$RESET"

  if [ "${GANKSENSE_NO_OPEN:-0}" != "1" ]; then
    open "$dest"
    printf '  %sLook for the eye in your menu bar.%s\n' "$MUTED" "$RESET"
    printf '\n  %sTo remove it later:%s\n' "$DIM" "$RESET"
    printf '  %scurl -fsSL https://ganksense.app/uninstall.sh | bash%s\n' "$MUTED" "$RESET"
  fi
  printf '\n'
}

main "$@"
