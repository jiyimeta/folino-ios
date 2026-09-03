#!/usr/bin/env bash
# Asserts that the BUILT Mac app carries the App Sandbox entitlements, not merely that project.yml says it should.
#
# project.yml is regenerated on every xcodegen run and is edited by several parallel sessions, so a dropped
# CODE_SIGN_ENTITLEMENTS is a live risk. Without this gate it would surface at App Store upload — the slowest
# possible place to find it.
#
# Run from anywhere; it locates the repo root relative to itself.
set -euo pipefail

cd "$(dirname "$0")/.."

DERIVED="$(mktemp -d)"
trap 'rm -rf "$DERIVED"' EXIT

xcodebuild \
  -project Folino.xcodeproj \
  -scheme FolinoMac \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation \
  build >/dev/null

APP="$DERIVED/Build/Products/Debug/folino.app"
[ -d "$APP" ] || { echo "FAIL: $APP was not produced"; exit 1; }

# `--entitlements :-` emits the legacy blob-header format, which is not parseable plist. `--xml` is.
ENTITLEMENTS="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null)"

status=0
for key in \
  com.apple.security.app-sandbox \
  com.apple.security.files.user-selected.read-write \
  com.apple.security.network.client
do
  if printf '%s' "$ENTITLEMENTS" | grep -q "<key>$key</key>"; then
    echo "ok   $key"
  else
    echo "FAIL $key is missing from the built app"
    status=1
  fi
done

exit "$status"
