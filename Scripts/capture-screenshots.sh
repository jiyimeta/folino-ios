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
#   Scripts/capture-screenshots.sh --scenes NoteEditing     # one scene, leaving the other PNGs alone
#   Scripts/capture-screenshots.sh --devices ipad --locales en
#   Scripts/capture-screenshots.sh --verbose                # print the test's output, including why it failed
#
# While iterating on one shot, narrow all three: `--devices iphone --locales en --scenes NoteEditing` is about
# twenty seconds of capture rather than eight scenes across five languages.
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
REQUESTED_SCENES=""
VERBOSE=0

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
    --scenes)
      REQUESTED_SCENES="$2"
      shift 2
      ;;
    --verbose)
      # Drops `-quiet` from the test run. Worth knowing about: a capture failure is reported as a thrown error, and
      # `-quiet` prints that a test failed without printing why.
      VERBOSE=1
      shift
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

# One framebuffer grab, bounded in time.
#
# The bound is the point: `xcrun simctl io` occasionally never returns, and the watcher is a single loop — one wedged
# grab and every scene behind it waits forever, which is how two capture runs died mid-language. macOS ships no
# `timeout`, hence perl's alarm. An overrunning grab is abandoned and the caller simply asks again.
grab_frame() {
  local udid="$1" out="$2"
  rm -f "$out"
  perl -e 'alarm shift; exec @ARGV' 20 xcrun simctl io "$udid" screenshot --type=png "$out" > /dev/null 2>&1 || true
  # A grab cut short by the alarm can leave a truncated file behind, which would then be compared, moved and
  # delivered as if it were a frame.
  if [[ ! -s "$out" ]]; then
    rm -f "$out"
    return 1
  fi
}

# A frame, grabbed until two consecutive grabs are byte-identical so nothing caught mid-animation is delivered.
#
# Ruling out MOTION is all this has to do. The other failure — a screen the compositor has not re-composited since
# the scene was swapped in, where every glass surface is still a flat dark slab — holds far too still for a stability
# check to notice, and is caught on the app side instead: it nudges the compositor and asks twice, and two answers
# only agree once the frame is fresh (see `HostCompositorBroker`).
capture_stable() {
  local udid="$1" out="$2" attempt
  grab_frame "$udid" "$out.a"
  for attempt in 1 2 3 4 5 6; do
    sleep 0.4
    if grab_frame "$udid" "$out.b"; then
      if [[ -s "$out.a" ]] && cmp -s "$out.a" "$out.b"; then
        mv "$out.b" "$out"
        rm -f "$out.a"
        return 0
      fi
      mv "$out.b" "$out.a"
    fi
  done
  # Never settled (a live animation, or a simulator that is still booting): deliver the last frame and let the app's
  # own checks decide whether it is usable. Returns non-zero when there is no frame at all, which is what keeps the
  # request unanswered rather than answered with nothing.
  if [[ -s "$out.a" ]]; then
    mv "$out.a" "$out"
    return 0
  fi
  return 1
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
      # Answer ONLY with a frame in hand. Marking a request done without one made the app read a file that wasn't
      # there and fail the whole run; leaving the request alone instead just means the next pass tries again, and the
      # app's own timeout is what bounds the retrying.
      if capture_stable "$udid" "$BROKER_DIR/$scene.png"; then
        # Tolerated: an app that gave up waiting deletes its own marker, and renaming what is no longer there must
        # not take the watcher down with it — the next scene still needs answering.
        mv "$request" "$BROKER_DIR/$scene.done" 2> /dev/null || true
        echo "    [frame] $(date +%H:%M:%S) $scene"
      fi
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
  # Which scenes the capture test should run, one per line. Absent means all of them; see `isRequested` in
  # `CaptureScreenshotsTests`. It rides in the broker directory because a hosted unit test has no other channel a
  # shell script can write to.
  if [[ -n "$REQUESTED_SCENES" ]]; then
    printf '%s\n' "${REQUESTED_SCENES//,/$'\n'}" > "$BROKER_DIR/scenes"
  fi
  watch_broker "$udid" &
  local watcher=$!
  trap 'kill "$watcher" 2> /dev/null || true; rm -rf "$BROKER_DIR"' RETURN

  # `-collect-test-diagnostics never` below is about wall-clock, not output: left on, xcodebuild decides after some
  # runs that it wants a sysdiagnose out of the simulator, then waits ten minutes for one that never arrives — per
  # language, which is most of a full sweep spent on nothing.
  local quiet=(-quiet)
  if [[ "$VERBOSE" == "1" ]]; then
    quiet=()
  fi

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
      -collect-test-diagnostics never \
      ${quiet[@]+"${quiet[@]}"} # bash 3.2 counts an empty array as unbound under `set -u`
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
