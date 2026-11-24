# shared look for the dev scripts (bundle.sh, package.sh): gold header, one line per step with a spinner while it
# runs, a teal check when done, a red cross and the step's output when it fails. source it, don't run it.
# install.sh and uninstall.sh are fetched alone with curl, so they carry their own copy of this.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ] && [ "${TERM:-}" != "dumb" ]; then
  TTY=1
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  GOLD=$'\033[38;2;200;170;110m'; PALE=$'\033[38;2;240;230;210m'; BRONZE=$'\033[38;2;120;90;40m'
  TEAL=$'\033[38;2;10;200;185m'; RED=$'\033[38;2;232;64;87m'; MUTED=$'\033[38;2;160;155;140m'
else
  TTY=0; RESET=""; BOLD=""; DIM=""; GOLD=""; PALE=""; BRONZE=""; TEAL=""; RED=""; MUTED=""
fi

# header "bundle" "release": ◆ ganksense · bundle  release
header() {
  printf '\n  %s◆%s %s%sganksense%s %s·%s %s%s%s' "$GOLD" "$RESET" "$BOLD" "$PALE" "$RESET" "$BRONZE" "$RESET" "$GOLD" "$1" "$RESET"
  [ -n "${2:-}" ] && printf '  %s%s%s' "$MUTED" "$2" "$RESET"
  printf '\n\n'
}

_tidy() { local d="$1"; d="${d/#$HOME/~}"; printf '%s' "$d"; }

done_line() { # done_line "label" ["detail"]
  printf '  %s✓%s %s' "$TEAL" "$RESET" "$1"
  [ -n "${2:-}" ] && printf '  %s%s%s' "$MUTED" "$(_tidy "$2")" "$RESET"
  printf '\n'
}

warn_line() { printf '  %s!%s %s\n' "$GOLD" "$RESET" "$*" >&2; }

die() { printf '\n  %s%serror%s %s\n\n' "$BOLD" "$RED" "$RESET" "$*" >&2; exit 1; }

# run "label" cmd args...: runs the command quietly with a spinner; on failure shows the last of its output and exits.
# with no terminal it just runs the command with its output, so ci logs stay complete.
run() {
  local label="$1"; shift
  if [ "$TTY" != 1 ]; then
    printf '  - %s\n' "$label"
    "$@" || die "$label failed."
    return 0
  fi
  local log start pid frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0 status
  log="$(mktemp -t ganksense-step)"
  start=$SECONDS
  "$@" >"$log" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    printf '\r  %s%s%s %s %s%ss%s' "$GOLD" "${frames:$((i % 10)):1}" "$RESET" "$label" "$DIM" "$((SECONDS - start))" "$RESET"
    i=$((i + 1))
    sleep 0.08
  done
  status=0
  wait "$pid" || status=$?
  if [ "$status" -ne 0 ]; then
    printf '\r\033[K  %s✗%s %s\n\n' "$RED" "$RESET" "$label"
    tail -n 40 "$log" | sed 's/^/    /'
    rm -f "$log"
    die "$label failed."
  fi
  printf '\r\033[K'
  done_line "$label" "$( [ $((SECONDS - start)) -gt 0 ] && echo "$((SECONDS - start))s" )"
  rm -f "$log"
}
