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
# only exists on 27.0. Name and OS are kept apart because the framebuffer grabs below need the device's UDID, and
# `simctl io booted` can't be used to find it: more than one simulator is usually booted.
IPHONE_NAME='iPhone 17 Pro Max'
IPHONE_OS='26.5'
IPAD_NAME='iPad Pro 13-inch (M5)'
IPAD_OS='27.0'
IPHONE_DESTINATION="platform=iOS Simulator,name=$IPHONE_NAME,OS=$IPHONE_OS"
IPAD_DESTINATION="platform=iOS Simulator,name=$IPAD_NAME,OS=$IPAD_OS"

# Handshake directory for the framebuffer grabs (see `watch_broker`). Its mere existence is what puts the capture
# test into compositor mode, so it is created per run and removed afterwards — running the test from Xcode, with no
# script around it, then still produces (blur-less) in-process renders rather than hanging on a watcher that is not
# there.
BROKER_DIR="$REPO_ROOT/fastlane/screenshots/.broker"

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

# UDID of the simulator pinned by name + runtime, booted or not. `simctl io` needs it: the deliverables are taken
# from a specific device, and "booted" is ambiguous whenever a second simulator happens to be running.
device_udid() {
  local name="$1" os="$2"
  xcrun simctl list devices --json \
    | python3 "$REPO_ROOT/Scripts/simctl-device-udid.py" "$name" "$os"
}

# One framebuffer grab, repeated until THREE consecutive captures are byte-identical, so a frame caught before the
# compositor has caught up is never delivered.
#
# Three, spaced generously, and not two: the app settles on its own rasterization, which is drawn from its layer tree
# and therefore says nothing about the render server. Right after launch that server has not yet produced the
# backdrop a glass surface samples, and while it hasn't, every material on screen renders as a flat dark slab — a
# state that holds still long enough for two quick grabs to agree on it. It cost one delivered screenshot with a
# black status band and grey chrome before this loop was widened.
capture_stable() {
  local udid="$1" out="$2" attempt matches
  matches=0
  xcrun simctl io "$udid" screenshot --type=png "$out.a" > /dev/null 2>&1 || true
  for attempt in 1 2 3 4 5 6 7 8; do
    sleep 0.6
    xcrun simctl io "$udid" screenshot --type=png "$out.b" > /dev/null 2>&1 || true
    if [[ -s "$out.b" ]]; then
      if cmp -s "$out.a" "$out.b"; then
        matches=$((matches + 1))
        if [[ $matches -ge 2 ]]; then
          mv "$out.b" "$out"
          rm -f "$out.a"
          return 0
        fi
      else
        matches=0
      fi
      mv "$out.b" "$out.a"
    fi
  done
  # Never settled (a live animation, or a simulator that is still booting): deliver the last frame and let the test's
  # own resemblance check decide whether it is usable.
  if [[ -s "$out.a" ]]; then
    mv "$out.a" "$out"
  fi
}

# The host half of the capture handshake. The test bundle runs INSIDE the simulator and cannot invoke `simctl`, and
# this script cannot call into a running test — so the two meet in the filesystem: the app writes `<scene>.request`,
# this answers with `<scene>.png` and renames the request to `<scene>.done`. The rename is last, so the app never
# reads a half-written PNG. Runs in the background for the length of one device's language loop.
watch_broker() {
  local udid="$1" request scene
  # No `set -e` in here: a grab that fails because the simulator is still coming up is routine, and the loop has to
  # outlive it — dying silently would leave the app waiting for an answer that never comes.
  set +e
  shopt -s nullglob
  while [[ -d "$BROKER_DIR" ]]; do
    for request in "$BROKER_DIR"/*.request; do
      scene="$(basename "$request" .request)"
      capture_stable "$udid" "$BROKER_DIR/$scene.png"
      # Tolerated: an app that gave up waiting deletes its own marker, and renaming what is no longer there must not
      # take the watcher down with it — the next scene still needs answering.
      mv "$request" "$BROKER_DIR/$scene.done" 2> /dev/null || true
      echo "    [frame] $(date +%H:%M:%S) $scene"
    done
    sleep 0.15
  done
}

capture_device() {
  local device="$1" destination="$2" name="$3" os="$4"

  echo "==> Building $SCHEME for $device"
  xcodebuild build-for-testing \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -destination "$destination" \
    -skipPackagePluginValidation \
    -onlyUsePackageVersionsFromResolvedFile \
    -quiet

  # Arm the framebuffer watcher for this device's whole language loop. Without it the capture test falls back to its
  # in-process rasterization, which draws the app's own layer tree and so renders every glass surface unblurred.
  local udid
  udid="$(device_udid "$name" "$os")"
  rm -rf "$BROKER_DIR"
  mkdir -p "$BROKER_DIR"
  watch_broker "$udid" &
  local watcher=$!
  trap 'kill "$watcher" 2> /dev/null || true; rm -rf "$BROKER_DIR"' RETURN

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
    iphone) capture_device iPhone "$IPHONE_DESTINATION" "$IPHONE_NAME" "$IPHONE_OS" ;;
    ipad) capture_device iPad "$IPAD_DESTINATION" "$IPAD_NAME" "$IPAD_OS" ;;
    *)
      echo "unknown device: $device (expected iphone or ipad)" >&2
      exit 2
      ;;
  esac
done

echo "==> Done. $(find "$REPO_ROOT/fastlane/screenshots" -name '*.png' | wc -l | tr -d ' ') PNGs under fastlane/screenshots/"
