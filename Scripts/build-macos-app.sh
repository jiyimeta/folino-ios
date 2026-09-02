#!/usr/bin/env bash
# Builds the macOS app target. The package gate (build-macos-packages.sh) cannot see this target, so without this
# script the Mac composition root can break silently between sessions.
#
# Run from anywhere; it locates the repo root relative to itself.
set -euo pipefail

cd "$(dirname "$0")/.."

xcodebuild \
  -project Folino.xcodeproj \
  -scheme FolinoMac \
  -destination 'platform=macOS' \
  -skipPackagePluginValidation \
  build
