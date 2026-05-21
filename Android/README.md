# folino — Android pilot

Experimental scaffold for sharing Folino's iOS `LibraryLogic` Swift code
with a Jetpack Compose Android UI via the Swift Android toolchain.

Pilot scope: Library list + live search only. In-memory stub data.

## Prerequisites

- Swift Android Workgroup SDK installed, `SWIFT_ANDROID_HOME` exported.
- Android SDK + NDK r26+.
- JDK 17.

## Build

1. `./scripts/build-library-logic.sh` — compiles LibraryLogic to
   `app/src/main/jniLibs/<abi>/libLibraryLogic.so`.
2. `./gradlew :app:assembleDebug` — builds the Android app.
3. `./gradlew :app:installDebug` — installs on the connected emulator
   or device.

See `docs/superpowers/specs/2026-05-21-android-share-architecture-design.md`
for the pilot's design and success criteria.
