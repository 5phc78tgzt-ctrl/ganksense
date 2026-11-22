#!/usr/bin/env bash
# builds a release app and zips it for the curl installer into dist/: the zip (release asset), its checksum,
# install.sh (with the release url and checksum baked in; host this one) and uninstall.sh.
# use a per-version release url, not a latest one: the baked-in checksum only matches this exact zip.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/bundle.sh release
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' dist/ganksense.app/Contents/Info.plist)"

rm -f dist/ganksense.zip dist/ganksense.zip.sha256
# ditto keeps symlinks, permissions and the signature intact (plain zip can break the signature).
ditto -c -k --sequesterRsrc --keepParent dist/ganksense.app dist/ganksense.zip
(cd dist && shasum -a 256 ganksense.zip > ganksense.zip.sha256)

SHA="$(cut -d' ' -f1 dist/ganksense.zip.sha256)"
URL="${GANKSENSE_RELEASE_URL:-}"
sed -e "s|^RELEASE_URL=\"\"|RELEASE_URL=\"$URL\"|" -e "s|^RELEASE_SHA256=\"\"|RELEASE_SHA256=\"$SHA\"|" \
  scripts/install.sh > dist/install.sh
cp scripts/uninstall.sh dist/uninstall.sh
chmod +x dist/install.sh dist/uninstall.sh
[ -n "$URL" ] || echo "warning: GANKSENSE_RELEASE_URL not set; dist/install.sh only works with GANKSENSE_URL or GANKSENSE_ZIP" >&2

echo "Packaged ganksense $VERSION ($(uname -m)):"
echo "  dist/ganksense.zip  $(du -h dist/ganksense.zip | cut -f1)"
echo "  sha256 $(cut -d' ' -f1 dist/ganksense.zip.sha256)"
