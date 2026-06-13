# Android-Sharable Library Pilot — Result (archived)

> **STATUS: NOT ADOPTED — superseded.** This documents the result of an
> early (2026-05-21) experimental pilot that shared `LibraryLogic` Swift
> code with a Jetpack Compose UI through a **hand-written JNI bridge** plus
> a manual `withObservationTracking` loop in a bespoke `CBridge.swift`.
>
> **The hand-rolled JNI approach described here is no longer used.** The
> project moved to **`swift-wirelet`** for the JNI layer — generated
> `@WireletObservable` / `@WireletProvided` bridges and their `@WireFormat`
> wire projections (see the repo `CLAUDE.md` "iOS / Android parity"
> section). The Observation → Compose propagation bug that this pilot hit
> (and worked around) is handled by swift-wirelet's generated bridge, so
> the manual `refresh()`-after-mutation workaround below does not exist in
> the shipping Android code.
>
> Kept only as historical record of what the pilot proved and the
> gotchas it surfaced. The pilot's scaffold code (the `Android/` Gradle
> project, `CBridge.swift`, `library_logic_bridge.cpp`, the
> `build-library-logic.sh` script) lived only on the deleted
> `android-share-library-pilot` branch and was not merged. The companion
> implementation plan is `2026-05-21-android-share-library-pilot.md`; the
> design spec is `docs/superpowers/specs/2026-05-21-android-share-architecture-design.md`.

---

## Pilot result (2026-05-21)

The pilot achieved its primary goal: **the same Swift `LibraryLogic` source
builds for Android via the Swift Android Workgroup toolchain and is
consumed by a Jetpack Compose UI through a hand-written JNI bridge**.

### What worked

- Swift Android SDK `swift-6.3.2-RELEASE_android` produces
  `libLibraryLogic.so` for both `arm64-v8a` and `x86_64` ABIs (5.2 MB each).
- The Swift runtime (`libswiftCore.so`, `libswiftObservation.so`,
  `libFoundation.so`, …) and NDK `libc++_shared.so` bundle cleanly into
  the APK; `LibraryLogic.so` loads on the emulator without any
  `UnsatisfiedLinkError`.
- `@MainActor` works under the Android Swift runtime — `MainActor.assumeIsolated`
  from JNI entry points behaves correctly.
- `@Observable` and `withObservationTracking` exist in the SDK and compile;
  the Observation runtime is present and functional in the read direction.
- The instrumentation smoke test (`LibraryStoreHandleSmokeTest`) passes,
  exercising create → setSearchText → close through JNI.
- The Compose UI shows the 5 in-memory stub scores driven by Swift state.
- Live search filters the list (when triggered via the workaround below).

### What didn't work (yet)

- **Observation → JNI callback bridge does not propagate**. The
  `withObservationTracking { _ = listStore.displayedItems } onChange: { ... }`
  loop set up in `CBridge.swift` does not invoke the Kotlin
  `LibraryStoreHandle.onChanged()` after `searchQuery` mutations. The spec
  flagged this exact risk ("withObservationTracking re-arm interacts poorly
  with JNI callbacks"). The mitigation suggested there — diff/debounce in
  the bridge — was not investigated further in this pilot. Likely root
  causes to chase in a follow-up: `Task { @MainActor in ... }` may dispatch
  the C callback on a thread that has no JVM attachment, or
  `withObservationTracking`'s onChange may not re-arm because the closure
  capture lifecycle interacts with the boxed JNI context.

  **Workaround in place (pilot only)**: `LibraryStoreHandle.setSearchText`
  called `refresh()` directly after each `nativeSetSearchText`, bypassing
  the observation bridge. This workaround is gone in the shipping code —
  swift-wirelet's generated bridge replaced the manual loop.

### Implications for follow-on work

- The pilot validated the **architectural premise** of this work: a
  Swift-Android shared `LibraryLogic` can drive a Compose UI. The
  Observation → Compose bridge bug was real but bounded — the spec's Plan B
  ("hand-rolled callback-registration wrapper inside `LibraryLogic`")
  was the conceptual ancestor of what `swift-wirelet` now generates.
- The pilot also left the **Domain layer** in a cleaner state than
  before: `CGFloat` and `LocalizedError` no longer live in Domain, and
  Apple-only APIs in `LibraryLogic` are guarded with `#if !os(Android)`.
  This portability work is the part of the pilot that endured.

### Files of interest (on the now-deleted pilot branch)

These paths existed only on `android-share-library-pilot` and were never
merged; listed for archaeological reference:

- `Android/app/src/main/cpp/library_logic_bridge.cpp` — C++ JNI glue
- `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryStoreHandle.kt`
- `Android/app/src/main/kotlin/com/keynumber/folino/ui/library/LibraryScreen.kt`
- `Android/scripts/build-library-logic.sh` — drove the Swift Android
  toolchain and bundled the Swift runtime + libc++_shared into `jniLibs/<abi>/`
- `Packages/Features/Library/Sources/LibraryLogic/Android/CBridge.swift`
- `Packages/Features/Library/Sources/LibraryLogic/Android/Stubs/`
