#!/usr/bin/env bash
# Build FolinoLibraryJNI for each enabled Android ABI and stage .so files
# (plus Swift runtime + libc++_shared.so) into
# Android/FolinoLibraryAndroid/src/main/jniLibs/.
set -euo pipefail

: "${TOOLCHAINS:=org.swift.632202605101a}"
export TOOLCHAINS
export FOLINO_ANDROID=1

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PKG_PATH="$ROOT/Packages/Features/Library"
JNI_DIR="$ROOT/Android/FolinoLibraryAndroid/src/main/jniLibs"
SDK_BUNDLE="$HOME/Library/org.swift.swiftpm/swift-sdks/swift-6.3.2-RELEASE_android.artifactbundle"
RUNTIME_BASE="$SDK_BUNDLE/swift-android/swift-resources/usr/lib"

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

TARGETS=(
    "aarch64-unknown-linux-android28:arm64-v8a:swift-aarch64:aarch64-linux-android"
    "x86_64-unknown-linux-android28:x86_64:swift-x86_64:x86_64-linux-android"
)
FOLINO_ANDROID_ABIS="${FOLINO_ANDROID_ABIS:-arm64-v8a,x86_64}"
filtered=()
for entry in "${TARGETS[@]}"; do
    rest="${entry#*:}"; abi="${rest%%:*}"
    [[ ",${FOLINO_ANDROID_ABIS}," == *",${abi},"* ]] && filtered+=("$entry")
done
TARGETS=("${filtered[@]}")

for entry in "${TARGETS[@]}"; do
    triple="${entry%%:*}"; rest="${entry#*:}"
    abi="${rest%%:*}"; rest="${rest#*:}"
    arch="${rest%%:*}"; ndk_triple="${rest#*:}"

    echo "==> Building libFolinoLibraryJNI.so for $abi ($triple)"
    swift build --package-path "$PKG_PATH" \
                --product FolinoLibraryJNI \
                --swift-sdk "$triple" \
                -c release

    src_so="$PKG_PATH/.build/$triple/release/libFolinoLibraryJNI.so"
    dst_dir="$JNI_DIR/$abi"
    rm -rf "$dst_dir"; mkdir -p "$dst_dir"
    cp "$src_so" "$dst_dir/"

    runtime_src="$RUNTIME_BASE/$arch/android"
    [[ -d "$runtime_src" ]] || { echo "error: Swift runtime not found at $runtime_src" >&2; exit 1; }
    for so in "$runtime_src"/*.so; do
        name="$(basename "$so")"
        case "$name" in
            libTesting.so|libXCTest.so|lib_Testing_Foundation.so|lib_TestingInterop.so) continue ;;
        esac
        cp -L "$so" "$dst_dir/"
    done

    ndk_libcxx="$NDK_LIB_BASE/$ndk_triple/libc++_shared.so"
    [[ -f "$ndk_libcxx" ]] && cp -L "$ndk_libcxx" "$dst_dir/" || { echo "error: libc++_shared.so not found at $ndk_libcxx" >&2; exit 1; }
done

echo "Done. libFolinoLibraryJNI.so + runtime staged under $JNI_DIR/{arm64-v8a,x86_64}/"
