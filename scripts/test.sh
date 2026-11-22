#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

DEV="$(xcode-select -p 2>/dev/null || true)"
if [[ "$DEV" == *.app/* ]]; then
  # full xcode finds swift testing by default.
  exec swift test "$@"
fi

F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
L=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
exec swift test "$@" -Xswiftc -F -Xswiftc "$F" -Xlinker -F -Xlinker "$F" \
  -Xlinker -rpath -Xlinker "$F" -Xlinker -rpath -Xlinker "$L"
