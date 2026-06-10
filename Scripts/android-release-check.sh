#!/usr/bin/env bash
# Deterministic pre-release gate: verify every expected native lib is packaged in
# the APK, for every ABI. Catches a missing/un-staged libFolino*JNI.so BEFORE the
# app is ever run (the failure otherwise only surfaces at runtime on score-open).
#
# Usage:
#   Scripts/android-release-check.sh [path/to/app.apk]
# With no arg, builds Android/app :app:assembleDebug and checks the resulting APK.
# Exits non-zero (and prints which lib/ABI is missing) if anything is absent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

# Source of truth — see docs/superpowers/specs/2026-06-10-android-release-crash-defenses-design.md
ABIS=("arm64-v8a" "x86_64")
EXPECTED_LIBS=(
    "libFolinoLibraryJNI.so"
    "libFolinoReaderJNI.so"
    "libFolinoSettingsJNI.so"
    "libFolinoSoundfontJNI.so"
    "libSwiftJava.so"
)

APK="${1:-}"
if [[ -z "$APK" ]]; then
    echo "==> No APK given; building :app:assembleDebug"
    PATH="/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH" \
        "$ROOT/Android/gradlew" -p "$ROOT/Android" :app:assembleDebug --no-daemon
    APK="$ROOT/Android/app/build/outputs/apk/debug/app-debug.apk"
fi

if [[ ! -f "$APK" ]]; then
    echo "error: APK not found: $APK" >&2
    exit 2
fi
echo "==> Checking native libs in: $APK"

# One listing of all packaged lib/ entries.
LIBS_IN_APK="$(unzip -Z1 "$APK" 'lib/*' 2>/dev/null || true)"

missing=0
for abi in "${ABIS[@]}"; do
    for lib in "${EXPECTED_LIBS[@]}"; do
        if ! grep -qx "lib/$abi/$lib" <<<"$LIBS_IN_APK"; then
            echo "MISSING: lib/$abi/$lib"
            missing=1
        fi
    done
done

if [[ "$missing" -ne 0 ]]; then
    echo "FAIL: one or more expected native libs are not packaged."
    exit 1
fi
echo "PASS: all expected native libs present for ${ABIS[*]}."
