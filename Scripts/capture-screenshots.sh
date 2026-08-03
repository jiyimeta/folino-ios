#!/bin/bash
#
# Capture the App Store screenshots.
#
# Renders every marketing scene through the FolinoScreenshotTests capture test and writes PNGs to
# fastlane/screenshots/<App Store locale>/<order>_<alias>_<scene>.png — the layout `fastlane deliver` consumes.
#
# The app is built once per device, then run once per language: the language has to be a process-level setting
# because a chunk of the Feature packages resolves strings via `String(localized:)` at call time, which reads the
# process language rather than the SwiftUI environment locale. Every scene for a given language is captured in that
# single run.
#
# Usage:
#   Scripts/capture-screenshots.sh                          # everything
#   Scripts/capture-screenshots.sh --devices iphone         # one device
#   Scripts/capture-screenshots.sh --locales en,ja          # a subset of languages
#   Scripts/capture-screenshots.sh --devices ipad --locales en
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$REPO_ROOT/Folino.xcodeproj"
SCHEME="FolinoScreenshot"
TEST_TARGET="FolinoScreenshotTests"

# Simulator pins. Without an explicit OS, xcodebuild resolves OS:latest and the capture silently follows whatever
# newest runtime is installed — shots would then drift between OS releases mid-project. The iPad Pro 13-inch (M5)
# only exists on 27.0.
IPHONE_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro Max,OS=26.5'
IPAD_DESTINATION='platform=iOS Simulator,name=iPad Pro 13-inch (M5),OS=27.0'

# In-app language code : region. The region pins number / date formatting so a run doesn't inherit whatever the
# simulator happens to be set to. The App Store Connect folder name is derived from the language by the capture test
# itself (ScreenshotKitCapture's AppStoreLocale).
LOCALES=(
  "en:US"
  "ja:JP"
  "ko:KR"
  "zh-Hans:CN"
  "zh-Hant:TW"
)

DEVICES="iphone,ipad"
REQUESTED_LOCALES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --devices)
      DEVICES="$2"
      shift 2
      ;;
    --locales)
      REQUESTED_LOCALES="$2"
      shift 2
      ;;
    -h | --help)
      sed -n '3,18p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [[ ! -d "$PROJECT" ]]; then
  echo "==> Folino.xcodeproj missing, generating"
  (cd "$REPO_ROOT" && xcodegen generate)
fi

# `--locales` filters the table above rather than replacing it, so a typo fails loudly instead of silently capturing
# nothing.
selected_locales() {
  if [[ -z "$REQUESTED_LOCALES" ]]; then
    printf '%s\n' "${LOCALES[@]}"
    return
  fi
  local requested language found
  IFS=',' read -ra requested <<< "$REQUESTED_LOCALES"
  for language in "${requested[@]}"; do
    found=""
    for entry in "${LOCALES[@]}"; do
      if [[ "${entry%%:*}" == "$language" ]]; then
        found="$entry"
        break
      fi
    done
    if [[ -z "$found" ]]; then
      echo "unknown locale: $language" >&2
      exit 2
    fi
    printf '%s\n' "$found"
  done
}

capture_device() {
  local device="$1" destination="$2"

  echo "==> Building $SCHEME for $device"
  xcodebuild build-for-testing \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$destination" \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    -quiet

  while IFS= read -r entry; do
    local language="${entry%%:*}" region="${entry##*:}"
    echo "==> Capturing $device / $language"
    xcodebuild test-without-building \
      -project "$PROJECT" \
      -scheme "$SCHEME" \
      -only-testing:"$TEST_TARGET" \
      -destination "$destination" \
      -testLanguage "$language" \
      -testRegion "$region" \
      -quiet
  done < <(selected_locales)
}

for device in ${DEVICES//,/ }; do
  case "$device" in
    iphone) capture_device iPhone "$IPHONE_DESTINATION" ;;
    ipad) capture_device iPad "$IPAD_DESTINATION" ;;
    *)
      echo "unknown device: $device (expected iphone or ipad)" >&2
      exit 2
      ;;
  esac
done

echo "==> Done. $(find "$REPO_ROOT/fastlane/screenshots" -name '*.png' | wc -l | tr -d ' ') PNGs under fastlane/screenshots/"
