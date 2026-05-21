#!/usr/bin/env bash
# Build LibraryLogic as a shared library (.so) for Android ABIs.
#
# SDK form used: TOOLCHAINS=org.swift.632202605101a swift build --swift-sdk <triple>
#
#   The Swift Android SDK is registered as "swift-6.3.2-RELEASE_android":
#     Verified by: TOOLCHAINS=org.swift.632202605101a swift sdk list
#   The open-source Swift 6.3.2 toolchain is required because the Android SDK's
#   pre-built .swiftmodule files were produced by the swift.org 6.3.2-RELEASE compiler.
#   The Xcode-bundled compiler (swiftlang-6.3.2.1.108) carries the same version number
#   but a different binary module format, causing "compiled module was created by an older
#   version of the compiler" errors.
#   TOOLCHAINS must be set to the CFBundleIdentifier (not the folder name):
#     /Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/Info.plist
#       CFBundleIdentifier = org.swift.632202605101a
#
# Target triples used:
#   arm64-v8a  -> aarch64-unknown-linux-android28
#   x86_64     -> x86_64-unknown-linux-android28
#
# API level 28 is the lowest level the installed swift-6.3.2-RELEASE_android SDK supports.
# The Android app minSdk is 26; using api28 for the Swift layer is safe because the Swift
# runtime itself requires api28+ and the .so will still load on api28+ devices.
#
# Note on platforms[] in Package.swift:
#   LibraryLogic/Package.swift declares platforms: [.iOS(.v26)]. SwiftPM ignores the
#   platforms constraint when cross-compiling with --swift-sdk to a non-Apple target
#   (the platform check is host-side only). The build proceeds normally for Android.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIBRARY_PKG="${REPO_ROOT}/Packages/Features/Library"
JNILIBS="${REPO_ROOT}/Android/app/src/main/jniLibs"

SWIFT_SDK_NAME="swift-6.3.2-RELEASE_android"
# Use the open-source swift-6.3.2-RELEASE toolchain to match the SDK's pre-built modules.
# TOOLCHAINS must be set to the CFBundleIdentifier, not the folder name.
# Found via: cat /Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/Info.plist
export TOOLCHAINS="org.swift.632202605101a"

ABIS=("arm64-v8a" "x86_64")
SWIFT_TARGETS=("aarch64-unknown-linux-android28" "x86_64-unknown-linux-android28")

# Verify the SDK is installed before attempting any build.
if ! swift sdk list 2>/dev/null | grep -q "${SWIFT_SDK_NAME}"; then
    echo "error: Swift SDK '${SWIFT_SDK_NAME}' not found." >&2
    echo "       Install it with: swift sdk install <bundle-url>" >&2
    echo "       Available SDKs:" >&2
    swift sdk list >&2
    exit 1
fi

for i in "${!ABIS[@]}"; do
    abi="${ABIS[$i]}"
    target="${SWIFT_TARGETS[$i]}"
    echo "==> Building LibraryLogic for ${abi} (${target})"
    (
        cd "${LIBRARY_PKG}"
        swift build \
            --product LibraryLogic \
            --swift-sdk "${target}" \
            --configuration debug
    )
    src=$(find "${LIBRARY_PKG}/.build/${target}/debug" -name 'libLibraryLogic.so' | head -1)
    if [[ -z "${src}" ]]; then
        echo "error: libLibraryLogic.so not produced for ${target}" >&2
        exit 1
    fi
    dst_dir="${JNILIBS}/${abi}"
    mkdir -p "${dst_dir}"
    cp "${src}" "${dst_dir}/libLibraryLogic.so"
    echo "    Copied: ${dst_dir}/libLibraryLogic.so ($(du -h "${dst_dir}/libLibraryLogic.so" | cut -f1))"
done

echo "==> Done. .so files at: ${JNILIBS}"
