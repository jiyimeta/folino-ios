#!/usr/bin/env bash
# Build FolinoReaderJNI for each enabled Android ABI and stage .so files
# (plus Swift runtime stubs) into Android/FolinoReaderAndroid/src/main/jniLibs/,
# and the swift-java-generated Java bindings into src/main/java-generated/.
#
# The Swift JNI target lives in the Reader feature package: FolinoReaderJNI →
# Domain (shared playback-cursor scroll-follow logic). PKG_PATH points at
# Packages/Features/Reader while ROOT is the repo root (used only for the
# Android module's jniLibs / java-generated destinations).
set -euo pipefail

: "${TOOLCHAINS:=org.swift.632202605101a}"
export TOOLCHAINS
export FOLINO_ANDROID=1

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PKG_PATH="$ROOT/Packages/Features/Reader"
JNI_DIR="$ROOT/Android/FolinoReaderAndroid/src/main/jniLibs"
SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle"
RUNTIME_BASE="$SDK_BUNDLE/swift-android/swift-resources/usr/lib"

# Locate the NDK so we can also stage libc++_shared.so per ABI (Swift runtime
# depends on it but it's an NDK artifact). Honour ANDROID_NDK_HOME if set, else
# auto-discover the newest under $ANDROID_HOME/ndk/.
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
TARGETS=(
    "aarch64-unknown-linux-android28:arm64-v8a:swift-aarch64:aarch64-linux-android"
    "x86_64-unknown-linux-android28:x86_64:swift-x86_64:x86_64-linux-android"
)

# Allow restricting to a subset of ABIs for faster local iteration.
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
    echo "==> Building libFolinoReaderJNI.so for $abi ($triple)"
    swift build --package-path "$PKG_PATH" \
                --product FolinoReaderJNI \
                --swift-sdk "$triple" \
                -c release

    src_so="$PKG_PATH/.build/$triple/release/libFolinoReaderJNI.so"
    dst_dir="$JNI_DIR/$abi"
    rm -rf "$dst_dir"
    mkdir -p "$dst_dir"
    cp "$src_so" "$dst_dir/"

    # swift-java's SwiftJava runtime ships as its own .so; stage it so the JNI
    # library can resolve symbols at load time.
    cp "$PKG_PATH/.build/$triple/release/libSwiftJava.so" "$dst_dir/"

    echo "==> Staging Swift runtime stubs into $dst_dir"
    runtime_src="$RUNTIME_BASE/$arch/android"
    if [[ ! -d "$runtime_src" ]]; then
        echo "error: Swift runtime not found at $runtime_src" >&2
        exit 1
    fi
    for so in "$runtime_src"/*.so; do
        name="$(basename "$so")"
        case "$name" in
            libTesting.so|libXCTest.so|lib_Testing_Foundation.so|lib_TestingInterop.so)
                continue
                ;;
        esac
        cp -L "$so" "$dst_dir/"
    done

    ndk_libcxx="$NDK_LIB_BASE/$ndk_triple/libc++_shared.so"
    if [[ -f "$ndk_libcxx" ]]; then
        cp -L "$ndk_libcxx" "$dst_dir/"
    else
        echo "error: libc++_shared.so not found at $ndk_libcxx" >&2
        exit 1
    fi
done

# Stage swift-java-generated Java bindings. SwiftPM keys the plugin-output dir
# by the lowercased package identity ("reader"), not the on-disk dir name.
pkg_id="$(basename "$PKG_PATH" | tr '[:upper:]' '[:lower:]')"
GEN_JAVA_SRC="$PKG_PATH/.build/plugins/outputs/$pkg_id/FolinoReaderJNI/destination/JExtractSwiftPlugin/src/generated/java"
GEN_JAVA_DST="$ROOT/Android/FolinoReaderAndroid/src/main/java-generated"
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
echo "Done. libFolinoReaderJNI.so + libSwiftJava.so + runtime staged under:"
echo "  $JNI_DIR/{arm64-v8a,x86_64}/"
