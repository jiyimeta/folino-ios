# Reader Playback Inspector (Android) — Design + Session Handoff

**Date:** 2026-06-03
**Status:** Design APPROVED by user. Not yet specced into a plan / implemented.
**Branch:** none yet — this doc is committed on `main`. Create
`reader-playback-inspector` from `main` before implementing (an earlier
`checkout -b` was interrupted, so the inspector work is unstarted and unbranched).

This doc is a **session-restart handoff**. It captures (A) the broader state of the
Reader-Android effort so a fresh session has full context, (B) environment gotchas
that will bite if not known, and (C) the approved design for the *next* task
(the playback inspector). A fresh session can go straight to `writing-plans` for
section C.

---

## A. Where things stand (completed this session)

The **Reader Android MVP** is done, verified on a Pixel 8a, and merged to `main`:
render (scrolling score) + play/pause + seek + playback-cursor highlight +
auto-scroll-follow. Architecture:

- **swift-sheet-music** (repo `~/Developer/Personal/swift-packages/swift-sheet-music`):
  rendering was extracted from the Android example into a new publishable library
  module **`sheet-music-compose-android`** (DrawProgram→Compose Canvas, `FontProvider`
  with bundled Bravura/Edwin, playback-cursor + loop overlays). Audio is the existing
  `sheet-music-audio-android` (FluidSynth+Oboe, `AndroidPlaybackEngine`). All three
  Android modules publish to **mavenLocal** at version `0.0.0-SNAPSHOT`.
  - This work + a cursor-decode fix + a 16 KB-alignment fix + a swift-java 0.3.0→0.4.0
    bump was committed on `main` and **pushed to origin/main** (`7076180..e08c823`).
- **Folino** (this repo): new Kotlin-only module **`Android/FolinoReaderAndroid/`**
  (`ReaderScreen` + `ReaderViewModel` + audio glue `ReaderAudioViewModel`/
  `ReaderPlaybackService`/`EnginePlayer` + `FolinoSoundfontResolver`, bundled
  `GeneralUser-GS.sf2`). Consumes the sheet-music Android libs via mavenLocal.
  Library→Reader nav routes `reader/{id}/{title}` → `ReaderScreen` (Reader resolves
  `filesDir/Scores/<id>.mscz`).
  - The playback-cursor **auto-scroll keep-in-view math is SHARED with iOS**:
    `Domain.scrollOffsetKeepingInView` (pure, unit-tested). iOS
    `VerticalScoreContainer` calls it directly; Android calls the same Swift via a
    new **`FolinoReaderJNI`** target (swift-java jextract,
    `Scripts/android-build-reader-libs.sh`). This pattern is the template for
    sharing any future Reader logic with Android.
  - Merged to `main` (`bd56b98`); full `:app:assembleDebug` verified; the
    `reader-android` worktree was cleaned up (`cleanup-worktree.sh`).

`main` has since advanced with the user's **Playlists** work (PlaylistsListScreen /
PlaylistDetailScreen + a nav-drawer "Playlists" item). The `reader-playback-inspector`
branch is cut from that latest `main`.

**Parity rule that governs all of this** (see `feedback_ios_android_parity` memory +
CLAUDE.md): logic/behaviour matches iOS and is SHARED (Domain or a Swift→Android JNI
target) — never reimplemented divergently in Kotlin. UI *placement* follows Android
idioms. The user enforces this strictly (corrected a Kotlin reimplementation of the
auto-scroll math mid-session).

---

## B. Environment gotchas (READ before building Android)

The Android build is finicky. Key facts (also in memory `project_android_build_toolchain`,
`project_reader_android_mvp`):

1. **Toolchains:** host Swift / gradle = Xcode default
   (`PATH=/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin:$PATH`).
   Android cross-compile of `.so` = open-source toolchain
   (`PATH=/Library/Developer/Toolchains/swift-6.3.2-RELEASE.xctoolchain/usr/bin:$PATH`).
   Always pass `--no-daemon` to gradle. Don't use compound `cd && …` Bash.
2. **Per-worktree native bootstrap.** `.so` + swift-java `java-generated` bindings +
   `.build/checkouts/swift-wirelet` are gitignored and per-worktree. In a fresh
   checkout you must, before the Android app will build:
   - `FOLINO_ANDROID=1 xcrun swift package resolve --package-path Packages/Features/{Library,Settings,Reader}`
   - `Scripts/android-build-libs.sh` (Settings JNI .so + bindings),
     `Scripts/android-build-library-libs.sh` (Library), `Scripts/android-build-reader-libs.sh`
     (Reader), each with the cross-compile toolchain on PATH.
   The **primary worktree** (`/Users/kiichi/Developer/Personal/ios-apps/Folino-iOS`)
   is already bootstrapped and `:app:assembleDebug` builds there — which is why the
   inspector will be built on a branch here rather than a fresh worktree (avoids
   re-bootstrapping ~10 min of native builds).
3. **swiftkit-core coherence:** sheet-music and Folino must use the SAME swift-java
   (0.4.0 / `bb53878`). swiftkit-core `1.0-SNAPSHOT` is published to mavenLocal from
   `Packages/Features/Settings/.build/checkouts/swift-java` (a SwiftPM checkout's own
   `.gradle` lock is read-only; publish from the Folino Settings checkout, not the
   sheet-music one).
4. **wirelet 0.3.2 readonly-CLI trap (IMPORTANT):** Library uses wirelet plugin 0.3.2
   (mavenLocal — added `mavenLocal()` to `Android/settings.gradle.kts`
   pluginManagement; bumped `FolinoLibraryAndroid` plugin to 0.3.2; runtimes published
   from the swift-wirelet dev clone at `~/Developer/Personal/swift-packages/swift-wirelet`
   v0.3.2 via `kotlin/gradlew … publishToMavenLocal -PwireletVersion=0.3.2`). The
   `emit-wirelet-kotlin` CLI is built from the SwiftPM checkout
   `Packages/Features/Library/.build/checkouts/swift-wirelet` which is **read-only**;
   if a stale (pre-`[String]`) CLI binary is cached there, codegen emits a bogus
   `StringCodec` reference and Library won't compile. Fix: `chmod -R u+w` that
   checkout's `.build`, delete the stale build, regenerate — then it correctly emits
   `WireletList.encodeStrings(ids)`. This can recur after a re-resolve.
5. **16 KB pages:** all bundled `.so` must be 16 KB-aligned (Android 15+/Pixel 8a
   warns otherwise). Fixed in sheet-music's audio CMake
   (`target_link_options(... -Wl,-z,max-page-size=16384)`). Verify a built APK with
   `llvm-readelf -l` (LOAD `p_align` must be `0x4000`) and `zipalign -c -P 16`.
6. **Device:** a Pixel 8a is reachable over wireless adb. Android changes are
   install+launch-complete (`:app:installDebug` then `adb shell am start -n
   com.keynumber.folino/.MainActivity`). Gesture/visual checks: capture screenshots
   (`adb exec-out screencap -p`), but a 16 KB compat dialog may steal focus on first
   launch (dismiss "次回から表示しない"). The Library swipe-to-delete is a HARD delete
   now (Recently-Deleted feature) — avoid stray swipes during automated taps.

---

## C. APPROVED DESIGN — Reader Playback Inspector (the next task)

**Goal:** Port the iOS Reader's *playback* inspector to Android: a controls panel for
the per-staff mixer, master volume, tempo, and metronome.

**Scope (MVP) — IN:**
- Per-staff mixer: volume, mute, solo, program (GM instrument).
- Master volume.
- Tempo (playback rate 0.5×–2.0×).
- Metronome on/off.

**Scope — OUT (deferred):**
- The *visual* inspector (staff size / clef overrides / staff visibility) — staff size
  is easy (`ScoreViewOptions.staffSize` already exists; needs a JNI param), but hidden
  staves + clef overrides need new sheet-music Swift/layout work (Score filter/patch
  before layout). Separate future slice.
- A-B loop, per-part program fan-out (MVP is per-staff only), preferences persistence
  (session-only, matching the Reader MVP).

**Why this is cheap:** `AndroidPlaybackEngine` already supports ALL the playback
controls (verified). No sheet-music changes, no new JNI:
- `fun setStaffVolume(staffIndex: Int, volume: Float)` (0..1)
- `fun setStaffMuted(staffIndex: Int, muted: Boolean)`
- `fun setStaffSoloed(staffIndex: Int, soloed: Boolean)`
- `fun setStaffProgram(staffIndex: Int, program: Int)` (GM 0–127)
- `fun setMasterVolume(volume: Float)` (0..1)
- `fun setRate(rate: Float)`
- `fun setMetronomeEnabled(enabled: Boolean)` (+ `setMetronomeVolume(volume: Float)`)
- `val mixerChannels: StateFlow<List<MixerChannel>>` where `MixerChannel` =
  `{ staffIndex, displayName, volume, isMuted, isSoloed, effectiveMute, program: Int? }`
  (program `null` ⇒ drums). The engine holds all semantic state incl. solo/mute
  interaction (`effectiveMute`).

(Source: `~/Developer/Personal/swift-packages/swift-sheet-music/Android/SheetMusicAudioAndroid/src/main/kotlin/io/github/jiyimeta/sheetmusic/audio/AndroidPlaybackEngine.kt`)

**Parity decision (user-approved):** the audio *semantics* are already shared Swift
(the engine), so Android just drives the engine. The *UI mappings* (master-volume
taper, tempo BPM↔multiplier display, slider feel) are treated as UI/UX and implemented
Android-idiomatically — NOT shared via JNI. So **no FolinoReaderJNI changes, no
sheet-music changes** for this slice. (The engine already keeps iOS/Android behaviour
identical for the parts that matter.)

**UI (Android idiom):**
- Add a "mixer/tune" `IconButton` to `ReaderScreen`'s transport bar (e.g.
  `Icons.Default.Tune`). Tapping opens a **`ModalBottomSheet`** (the controls panel).
- Sheet sections:
  - **Master**: volume `Slider` 0–100% → `engine.setMasterVolume(fraction)`.
  - **Tempo**: rate `Slider` 0.5×–2.0× with an "×1.00" readout → `engine.setRate`.
  - **Metronome**: a `Switch` → `engine.setMetronomeEnabled`.
  - **Mixer**: a `LazyColumn` over `mixerChannels`; each row = displayName + volume
    `Slider` (`setStaffVolume`) + mute/solo toggle buttons (`setStaffMuted`/
    `setStaffSoloed`, reflect `effectiveMute`) + a program dropdown of GM names
    (`setStaffProgram`). Drums (`program == null`) show "Drums", program not editable.

**Components (all in `Android/FolinoReaderAndroid/`, Kotlin-only):**
- `PlaybackInspectorSheet.kt` — the `ModalBottomSheet` composable; binds to
  `ReaderAudioViewModel` (reads `mixerChannels`, `currentRate`, `state`; calls
  `audioVm.engine.value?.<setter>()`).
- `GmInstruments.kt` — the 128 General MIDI program names for the program dropdown.
- `ReaderScreen.kt` — add the transport-bar icon + `rememberModalBottomSheetState`
  + show/hide the sheet. (`ReaderScreen` is the existing screen; transport bar is the
  bottomBar `TransportBar`.)

`ReaderAudioViewModel` already exposes `mixerChannels`, `currentRate`, `state`,
`engine`. Add small pass-throughs if cleaner, or call the engine directly from the
sheet.

**Data flow:** UI is a thin reactive binding — read engine StateFlows, write via
engine setters on user interaction. No new state models, no persistence.

**Error/edge handling:** if `engine` is null (service not yet bound) the controls are
disabled; if `mixerChannels` is empty (score not prepared) the mixer list shows
nothing. Drums rows hide the program picker.

**Testing/verification:** `:app:installDebug` → launch → open a Library score → play →
open the inspector → adjust volume/mute/solo/program/tempo/metronome and confirm the
audio changes audibly + the mixer state reflects (mute/solo). Device verification (the
user listens); don't drive audio judgement programmatically.

---

## D. Immediate next steps for the fresh session

1. (Optional) confirm the primary worktree still builds: `:app:assembleDebug` (toolchain
   PATH + `--no-daemon`). If wirelet StringCodec error reappears, apply gotcha B.4.
2. `git checkout -b reader-playback-inspector` (from `main`), then invoke
   **`superpowers:writing-plans`** to turn section C into a bite-sized plan.
3. Implement on that branch (subagent-driven or inline). It's
   Kotlin-only; iterate `:FolinoReaderAndroid:compileDebugKotlin` then `:app:installDebug`.
4. Verify on the Pixel 8a; commit; then ask the user how to integrate (merge to main).

**Open follow-ups (not this task):** visual inspector (needs sheet-music layout work);
sheet-music `main` is pushed but the wirelet 0.3.2 plugin is only on mavenLocal (held
back from GitHub Packages on a write-token issue — the user's wirelet work).
