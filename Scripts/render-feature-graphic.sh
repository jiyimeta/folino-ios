#!/usr/bin/env bash
#
# render-feature-graphic.sh
#
# Render the Play Store feature graphic via supersampling (SSAA), independently of the device-screenshot
# pipeline:
#   1. Force the emulator display to a wide (landscape-shaped) size via `wm size`, so a 2048px-wide canvas
#      fits the capture window (a 1024px-base render in portrait would be window-clamped).
#   2. Run ONLY FeatureGraphicTest with fgScale=2 -> a TRUE 2x render (2048x1000) per locale.
#   3. Rotate back to PORTRAIT (the device-screenshot suite needs portrait).
#   4. Downsample each 2048x1000 -> the exact 1024x500 store size with sips (high-quality Apple
#      resampling), into the fastlane supply tree. Downsampling a true-2x render anti-aliases the thin
#      staff lines, so they read fine — the whole point of the 2x-then-shrink approach.
#   5. Also drop the ja 2x render (2048x1000) on the Desktop for SNS use.
#
# Requires a booted emulator at emulator-5554 (the dedicated screenshot device). Run from the repo root:
#   Scripts/render-feature-graphic.sh
#
set -euo pipefail

SERIAL="emulator-5554"
APP_DIR="Android"
OUT_ROOT="$APP_DIR/app/build/outputs/connected_android_test_additional_output/debugAndroidTest/connected"
FASTLANE="$APP_DIR/fastlane/metadata/android"
TEST_CLASS="com.keynumber.folino.screenshot.FeatureGraphicTest"
LOCALES=(en-US ja-JP ko-KR zh-CN zh-TW)

restore_display() {
    adb -s "$SERIAL" shell wm size reset || true
}
# Always restore the display, even if the render fails partway.
trap restore_display EXIT

# Force a wide (landscape-shaped) display so the 2048px-wide capture fits the window. This is more
# deterministic than rotating via user_rotation, which a generic test Activity may not honor (a rotated
# run came back clamped to the 1440px portrait width).
echo "==> Setting $SERIAL display to 3120x1440 (wide) for the 2x capture"
adb -s "$SERIAL" shell wm size 3120x1440

echo "==> Rendering $TEST_CLASS at 2x (2048x1000) per locale"
( cd "$APP_DIR" && ANDROID_SERIAL="$SERIAL" ./gradlew :app:connectedDebugAndroidTest \
    "-Pandroid.testInstrumentationRunnerArguments.class=$TEST_CLASS" \
    "-Pandroid.testInstrumentationRunnerArguments.fgScale=2" )

# trap restores the display on exit; do it now too so the device is back before the (host-side) downsample.
restore_display
trap - EXIT

# There is normally exactly one connected-device output dir; take the first.
AVD_DIR="$(find "$OUT_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n 1)"
if [ -z "$AVD_DIR" ]; then
    echo "ERROR: no connected-device output dir under $OUT_ROOT" >&2
    exit 1
fi
echo "==> Output dir: $AVD_DIR"

echo "==> Downsampling 2048x1000 -> 1024x500 into the fastlane tree"
for loc in "${LOCALES[@]}"; do
    src="$AVD_DIR/featureGraphic/$loc.png"
    dst="$FASTLANE/$loc/images/featureGraphic.png"
    if [ ! -f "$src" ]; then
        echo "WARN: missing $src (skipped)" >&2
        continue
    fi
    mkdir -p "$(dirname "$dst")"
    sips -z 500 1024 "$src" --out "$dst" >/dev/null
    echo "    wrote $dst (1024x500)"
done

# SNS: keep the ja render at full 2x on the Desktop.
ja_src="$AVD_DIR/featureGraphic/ja-JP.png"
if [ -f "$ja_src" ]; then
    cp "$ja_src" "$HOME/Desktop/folino-feature-graphic-ja-2x.png"
    echo "==> Wrote $HOME/Desktop/folino-feature-graphic-ja-2x.png (2048x1000, SNS)"
fi

echo "==> Done."
