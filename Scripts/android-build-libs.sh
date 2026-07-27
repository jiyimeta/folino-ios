#!/usr/bin/env bash
# Build FolinoSettingsJNI for each enabled Android ABI and stage .so files
# (plus Swift runtime stubs) into Android/FolinoSettingsAndroid/src/main/jniLibs/.
#
# The Swift JNI target lives in the Settings feature package, not the repo
# root: FolinoSettingsJNI → SettingsLogic → Domain → SheetMusicCore (+ Wirelet).
# So PKG_PATH points at Packages/Features/Settings while ROOT is the repo root
# (used only for the Android module's jniLibs / java-generated destinations).
set -euo pipefail

# Use the open-source swift.org toolchain paired with the Android SDK.
# Prepend it to PATH so plain `swift` resolves to it — the swiftly shim on
# some hosts ignores TOOLCHAINS, and Apple's Xcode swiftc produces
# incompatible swiftmodules.
TOOLCHAIN_BIN="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin"
if [[ -d "$TOOLCHAIN_BIN" ]]; then
    export PATH="$TOOLCHAIN_BIN:$PATH"
fi
export FOLINO_ANDROID=1

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PKG_PATH="$ROOT/Packages/Features/Settings"
JNI_DIR="$ROOT/Android/FolinoSettingsAndroid/src/main/jniLibs"
SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.3-RELEASE_android.artifactbundle"

# Actual layout (Swift 6.3.3 Android SDK):
#   $SDK_BUNDLE/swift-android/swift-resources/usr/lib/swift-<arch>/android/libswiftCore.so
# The plan-assumed path ($SDK_BUNDLE/swift-android/sysroot/usr/lib/<arch>)
# does not exist in this release; use swift-resources instead.
RUNTIME_BASE="$SDK_BUNDLE/swift-android/swift-resources/usr/lib"

# Locate the NDK so we can also stage libc++_shared.so per ABI. The Swift
# runtime depends on it but it's an NDK artifact, not part of the Swift
# Android SDK. Honour ANDROID_NDK_HOME if set, else auto-discover under
# $ANDROID_HOME/ndk/<version>/ (pick the newest version present).
if [[ -z "${ANDROID_NDK_HOME:-}" ]]; then
    sdk_root="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
    if [[ -d "$sdk_root/ndk" ]]; then
        ANDROID_NDK_HOME="$(ls -d "$sdk_root"/ndk/*/ 2>/dev/null | sort -V | tail -1 | sed 's:/$::')"
    fi
fi
if [[ -z "${ANDROID_NDK_HOME:-}" || ! -d "$ANDROID_NDK_HOME" ]]; then
    echo "error: could not locate Android NDK; set ANDROID_NDK_HOME" >&2
    exit 1
fi
NDK_LIB_BASE="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/darwin-x86_64/sysroot/usr/lib"

mkdir -p "$JNI_DIR"

# Each entry: "<triple>:<abi>:<swift-arch-dir>:<ndk-triple>"
# Bash 3.2 (macOS default) doesn't support declare -A; use a plain array of colon-delimited tuples.
TARGETS=(
    "aarch64-unknown-linux-android28:arm64-v8a:swift-aarch64:aarch64-linux-android"
    "x86_64-unknown-linux-android28:x86_64:swift-x86_64:x86_64-linux-android"
)

# Allow restricting to a subset of ABIs for faster local iteration.
# Comma-separated list of ABI names (e.g. "arm64-v8a", "x86_64",
# "arm64-v8a,x86_64"). Default is all supported ABIs.
FOLINO_ANDROID_ABIS="${FOLINO_ANDROID_ABIS:-arm64-v8a,x86_64}"
filtered=()
for entry in "${TARGETS[@]}"; do
    rest="${entry#*:}"
    abi="${rest%%:*}"
    if [[ ",${FOLINO_ANDROID_ABIS}," == *",${abi},"* ]]; then
        filtered+=("$entry")
    fi
done
if [[ ${#filtered[@]} -eq 0 ]]; then
    echo "error: FOLINO_ANDROID_ABIS='${FOLINO_ANDROID_ABIS}' matched no known ABIs" >&2
    exit 1
fi
TARGETS=("${filtered[@]}")
echo "==> Building ABIs: ${FOLINO_ANDROID_ABIS}"

for entry in "${TARGETS[@]}"; do
    triple="${entry%%:*}"
    rest="${entry#*:}"
    abi="${rest%%:*}"
    rest="${rest#*:}"
    arch="${rest%%:*}"
    ndk_triple="${rest#*:}"

    echo
    echo "==> Building libFolinoSettingsJNI.so for $abi ($triple)"
    swift build --package-path "$PKG_PATH" \
                --product FolinoSettingsJNI \
                --swift-sdk "$triple" \
                -c release

    src_so="$PKG_PATH/.build/$triple/release/libFolinoSettingsJNI.so"
    dst_dir="$JNI_DIR/$abi"
    # Clean stale artifacts (e.g. a previous run's .so under an old product
    # name, or runtime .so files that were renamed/removed in an SDK update)
    # so APK stays lean and there are no surprises.
    rm -rf "$dst_dir"
    mkdir -p "$dst_dir"
    cp "$src_so" "$dst_dir/"

    # swift-java's SwiftJava runtime ships as its own .so; stage it so the
    # JNI library can resolve symbols at load time.
    cp "$PKG_PATH/.build/$triple/release/libSwiftJava.so" "$dst_dir/"

    echo "==> Staging Swift runtime stubs into $dst_dir"
    runtime_src="$RUNTIME_BASE/$arch/android"
    if [[ ! -d "$runtime_src" ]]; then
        echo "error: Swift runtime not found at $runtime_src" >&2
        echo "      Re-derive the path from your installed Swift Android SDK." >&2
        exit 1
    fi
    # Copy every runtime .so produced by the SDK *except* the
    # test/XCTest-only ones. libFolinoSettingsJNI.so transitively pulls
    # libswift_StringProcessing.so, lib_FoundationICU.so, etc. — listing
    # them by hand is fragile. Excluding the test libs keeps the APK lean.
    for so in "$runtime_src"/*.so; do
        name="$(basename "$so")"
        case "$name" in
            libTesting.so|libXCTest.so|lib_Testing_Foundation.so|lib_TestingInterop.so)
                continue
                ;;
        esac
        cp -L "$so" "$dst_dir/"
    done

    # libswiftCore.so links against libc++_shared.so (NDK C++ runtime),
    # which is NOT staged by the Swift Android SDK. Pull it from the NDK.
    ndk_libcxx="$NDK_LIB_BASE/$ndk_triple/libc++_shared.so"
    if [[ -f "$ndk_libcxx" ]]; then
        cp -L "$ndk_libcxx" "$dst_dir/"
    else
        echo "error: libc++_shared.so not found at $ndk_libcxx" >&2
        exit 1
    fi
done

# Stage swift-java-generated Java bindings into the Android module's
# sources. We copy rather than referencing the SwiftPM plugin output
# directly so the Android Gradle Plugin sees stable input paths under
# version control conventions, and so editor / lint tooling resolves
# imports without needing to know about .build/plugins/.../.
#
# SwiftPM keys the plugin-output directory by the *lowercased package
# identity*, not the on-disk directory name. The package directory here is
# "Settings" (capital S) but the plugin output lands under
# .build/plugins/outputs/settings/... — so lowercase the basename. (SSM's
# script could use $(basename "$ROOT") verbatim only because its repo dir
# "swift-sheet-music" was already lowercase.)
pkg_id="$(basename "$PKG_PATH" | tr '[:upper:]' '[:lower:]')"
GEN_JAVA_SRC="$PKG_PATH/.build/plugins/outputs/$pkg_id/FolinoSettingsJNI/destination/JExtractSwiftPlugin/src/generated/java"
GEN_JAVA_DST="$ROOT/Android/FolinoSettingsAndroid/src/main/java-generated"
if [[ -d "$GEN_JAVA_SRC" ]]; then
    echo
    echo "==> Staging generated Java bindings → $GEN_JAVA_DST"
    rm -rf "$GEN_JAVA_DST"
    mkdir -p "$GEN_JAVA_DST"
    cp -R "$GEN_JAVA_SRC"/. "$GEN_JAVA_DST/"
else
    echo "warning: generated Java bindings not found at $GEN_JAVA_SRC" >&2
    echo "         did the build complete cleanly?" >&2
fi

echo
echo "Done. libFolinoSettingsJNI.so + libSwiftJava.so + runtime staged under:"
echo "  $JNI_DIR/{arm64-v8a,x86_64}/"
