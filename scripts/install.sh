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

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

app_pids() { pgrep -f "/$APP_NAME\.app/Contents/MacOS/$APP_NAME\$" || true; }

quit_running() {
  [ -n "$(app_pids)" ] || return 0
  info "Quitting the running $APP_NAME"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -n "$(app_pids)" ] || return 0; sleep 0.3; done
  # shellcheck disable=SC2046
  kill $(app_pids) 2>/dev/null || true
}

main() {
  bold "Installing $APP_NAME"

  [ "$(uname -s)" = "Darwin" ] || fail "$APP_NAME is a macOS app."
  local major
  major="$(sw_vers -productVersion | cut -d. -f1)"
  [ "$major" -ge 26 ] || fail "$APP_NAME needs macOS 26 or later (this Mac runs $(sw_vers -productVersion))."
  [ "$(uname -m)" = "arm64" ] || fail "$APP_NAME currently supports Apple Silicon Macs only."

  local tmp
  tmp="$(mktemp -d -t ganksense-install)"
  # shellcheck disable=SC2064
  trap "rm -rf '$tmp'" EXIT
  local zip="$tmp/$APP_NAME.zip" expected="${GANKSENSE_SHA256:-$RELEASE_SHA256}"

  if [ -n "${GANKSENSE_ZIP:-}" ]; then
    [ -f "$GANKSENSE_ZIP" ] || fail "No zip at $GANKSENSE_ZIP"
    cp "$GANKSENSE_ZIP" "$zip"
    if [ -z "$expected" ] && [ -f "$GANKSENSE_ZIP.sha256" ]; then expected="$(cut -d' ' -f1 < "$GANKSENSE_ZIP.sha256")"; fi
    info "Using local $GANKSENSE_ZIP"
  else
    local url="${GANKSENSE_URL:-$RELEASE_URL}"
    [ -n "$url" ] || fail "This install script has no release URL. Use the copy from the website (or set GANKSENSE_URL)."
    info "Downloading $url"
    curl -fL --progress-bar --proto '=https' --tlsv1.2 -o "$zip" "$url" || fail "Download failed."
  fi

  [ -n "$expected" ] || fail "No SHA-256 to check the download against (set GANKSENSE_SHA256). Not installing."
  local actual
  actual="$(shasum -a 256 "$zip" | cut -d' ' -f1)"
  [ "$expected" = "$actual" ] || fail "Checksum mismatch (expected $expected, got $actual). Not installing."
  info "Checksum OK"

  ditto -x -k "$zip" "$tmp/out" || fail "Couldn't unpack the zip."
  local new_app="$tmp/out/$APP_NAME.app"
  [ -d "$new_app" ] || fail "The zip doesn't contain $APP_NAME.app."
  codesign --verify --deep --strict "$new_app" 2>/dev/null || fail "The app's signature is broken. Not installing."
  [ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$new_app/Contents/Info.plist" 2>/dev/null)" = "$BUNDLE_ID" ] \
    || fail "The zip doesn't contain the expected app. Not installing."

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

  # copy next to the installed app first, then swap, so a failed copy leaves the previous install in place.
  rm -rf "${dest:?}.new"
  ditto "$new_app" "$dest.new"
  rm -rf "${dest:?}"
  mv "$dest.new" "$dest"
  xattr -dr com.apple.quarantine "$dest" 2>/dev/null || true

  local version
  version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$dest/Contents/Info.plist" 2>/dev/null || echo '?')"
  bold "Installed $APP_NAME $version to $dest"

  if [ "${GANKSENSE_NO_OPEN:-0}" != "1" ]; then
    open "$dest"
    info "It lives in your menu bar. To remove it later:"
    info "  curl -fsSL https://ganksense.app/uninstall.sh | bash"
  fi
}

main "$@"
