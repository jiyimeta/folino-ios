# Reader Android — MVP Design

**Date:** 2026-06-02
**Branch:** `reader-android` (Folino), feature branch on the `swift-sheet-music` dev clone
**Status:** Design — pending review

## Goal

Bring the Reader feature to Android as a minimal but real "read and listen"
experience, reusing the rendering and audio that `swift-sheet-music` already
ships for Android. Mirror the pattern that Library and Settings established for
Android support, and respect the iOS/Android parity principle: share logic with
iOS rather than reimplementing it, and follow Android UI idioms for placement.

## Scope

### In scope (MVP)

- A single **vertically scrolling** score view with pan and pinch-zoom.
- **Play / pause** of the score audio.
- **Playback cursor** highlight that follows the audio and auto-scrolls into view.
- **Seek** via a standard Android slider bound to current/total time.
- Opening a score that already exists in the Library (`filesDir/Scores/<id>.mscz`).

### Out of scope (deferred to later phases)

- The three iOS layout modes (vertical / horizontal / paged) — MVP is vertical
  only. The Swift `LayoutBridge` currently flattens all systems into one page,
  which matches a single vertical scroll; multi-page pagination is deferred.
- Playback inspector, per-staff mixer (mute / solo / volume / program).
- A-B loop marking and loop highlight.
- Clef overrides, staff visibility toggles, staff-size adjustment.
- Picture-in-Picture.
- Per-score Reader preferences persistence.
- MuseScoreGeneral high-quality soundfont opt-in / download. MVP ships a basic
  GM soundfont bundled as an asset.
- Score metadata editing and share/export.

## Background (current state)

- **iOS Reader** (`Packages/Features/Reader`) splits cleanly into rendering
  (`SheetMusicUI`: `ScoreView` + `SheetMusicLayoutApple` + scroll host) and
  business logic that flows through Domain protocols (`PlaybackController`,
  `ScoreLibraryRepository`, `ScoreFileGateway`, `MuseScoreGeneralProvider`,
  `ScoreShareService`). None of it has Android gates or wire types yet.
- **`swift-sheet-music` already supports Android** and solves the two hardest
  problems:
  - **Rendering:** the Swift JNI layer (`SheetMusicAndroidJNI`) computes a
    layout and serializes it to a `DrawProgram` binary wire format (a display
    list of `moveTo` / `lineTo` / `cubicTo` / `stroke` / `fillRect` / `glyph` /
    `text` / `setColor` commands, magic `SMDP`, version 4). Android replays the
    commands onto a Compose `Canvas`.
  - **Audio:** `sheet-music-audio-android` exposes `AndroidPlaybackEngine`
    (FluidSynth + Oboe) plus a Media3 `EnginePlayer` adapter and an
    `AudioViewModel`. Cursor and loop frames are resolved back through JNI.
- The `swift-sheet-music` **example app** (`Examples/Android/`) is a complete
  working render + play app, but its rendering Compose code lives inside the
  *example app module*, not a publishable library. The audio code is already a
  reusable library module.
- **Library / Settings Android** establish the repeatable scaffold:
  `Android/Folino<Feature>Android/` Gradle modules, `Android/settings.gradle.kts`
  wiring, and `:app` navigation. Library persists imported scores at
  `filesDir/Scores/<id>.mscz` and the `LibraryAndroidStore` exposes
  `ScoreRowWire` rows (carrying the score `id`).

## Key decisions (resolved during brainstorming)

1. **MVP slice:** render + play + cursor-follow + seek. (Not render-only; not
   full parity.)
2. **Reuse mechanism:** *promote* the example's rendering Compose code into a
   reusable `swift-sheet-music` Android library module, then consume it from
   Folino — do not copy/fork the example into Folino. (Parity: share, don't
   reimplement.)
3. **Dependency source:** `mavenLocal`. The `swift-sheet-music` Android modules
   are published with `publishToMavenLocal` from the dev clone; Folino consumes
   them through `mavenLocal()` (already in Folino's `dependencyResolution`
   repositories). No `includeBuild` path coupling.
4. **Folino UI placement:** a new `:FolinoReaderAndroid` Gradle module, for
   consistency with `:FolinoLibraryAndroid` / `:FolinoSettingsAndroid`. Unlike
   those, it is **Kotlin-only** (no JNI / wirelet) for the MVP, because the MVP
   needs no Folino-specific Swift logic.
5. **No `FolinoReaderJNI` Swift target for the MVP.** Rendering, audio, and
   score parsing are all provided by the `swift-sheet-music` Android libraries.
   The Folino-specific Reader business logic (preferences, mixer orchestration)
   that *would* warrant a JNI bridge is out of scope. When those parity features
   are built later, that is when a `FolinoReaderJNI` target (mirroring
   `FolinoLibraryJNI`) gets introduced.

## Architecture

Two repositories, two phases.

### Phase A — `swift-sheet-music` (dev clone, feature branch)

Promote the rendering Compose/Kotlin code trapped in the example into a new
publishable Android library module **`sheet-music-compose-android`**
(`io.github.jiyimeta:sheet-music-compose-android`).

**Extracted (essentially as-is):**

- `draw/model/*` — `DrawCommand`, `DrawProgram`, `EncodablePage`, `FontID`.
- `draw/DrawProgramReader` — the `SMDP` wire decoder.
- `cursor/CursorFrame`, `cursor/LoopHighlightFrame` decoders.
- `ScoreCanvas` drawing logic (command replay, `pxPerMM` scaling, pan/zoom
  transform).
- Cursor / loop overlay rendering.

**Abstracted coupling points:**

- **Fonts** → a `FontProvider` interface. Bravura (SMuFL) and Edwin (text) are
  bundled as **library assets** of `sheet-music-compose-android` with a default
  asset-backed `FontProvider`, so consumers get rendering fonts for free; an app
  may override.
- **Overlay colors** → parameters (defaults preserve the MuseScore blue cursor
  and amber loop highlight).
- **Score source / page size** → the score bytes and page dimensions are passed
  in by the consumer rather than read from a hardcoded asset.

**Not extracted (stays example-specific):** the example's transport / mixer /
loop-selection / export UI compositions, its notification setup, and its
hardcoded `test.mscz` asset.

**Audio:** no extraction needed. `sheet-music-audio-android`
(`AndroidPlaybackEngine`, `EnginePlayer`, `AudioViewModel`,
`SoundfontResolver`/`MetronomeClickProvider` interfaces) is already reusable.
Folino provides its own `SoundfontResolver` implementation.

**Publishing:** mirror the existing `SheetMusicAndroid` module's `maven-publish`
config. Add `include(":SheetMusicComposeAndroid")` to `Android/settings.gradle.kts`.
Publish all three Android modules (`sheet-music-android`,
`sheet-music-audio-android`, `sheet-music-compose-android`) to mavenLocal at a
matching version. The `.so` artifacts must be built from the same
`swift-sheet-music` commit Folino's iOS build pins, using the documented Android
Swift cross-compile toolchain.

**Validation for Phase A:** point the existing example app at the new module
(replace the example's local rendering code with a dependency on
`sheet-music-compose-android`) and confirm it still renders and plays with no
visual regression.

### Phase B — Folino (`reader-android` worktree)

1. **New module `Android/FolinoReaderAndroid/`** (Kotlin-only):
   - `build.gradle.kts` depending on `sheet-music-compose-android` and
     `sheet-music-audio-android` (from mavenLocal) plus the Compose/Media3
     dependencies the Reader UI needs.
   - `ReaderScreen` Compose UI: a `Scaffold` with a back arrow, the scrolling
     `ScoreCanvas` with the playback-cursor overlay, and a bottom transport bar
     (play/pause + seek slider) following Android idioms.
   - A small `ReaderViewModel` (Android `androidx.lifecycle.ViewModel`) that
     loads the `.mscz` bytes, drives the sheet-music `ScoreViewModel` load →
     layout pipeline, owns the `AudioViewModel`/engine binding, and exposes the
     observable state the screen renders.
   - `FolinoSoundfontResolver` implementing `sheet-music-audio-android`'s
     `SoundfontResolver`, materializing the bundled GM `.sf2`.
   - Bundled assets: the GM soundfont (reuse the one Folino already ships under
     `App/Resources/Soundfonts/`) and a metronome click if needed.

2. **`Android/settings.gradle.kts`:** `include(":FolinoReaderAndroid")`.

3. **`Android/app/build.gradle.kts`:** `implementation(project(":FolinoReaderAndroid"))`.

4. **Navigation (`MainActivity.kt`):** replace `ReaderStubScreen` with the real
   Reader. The Library → Reader route currently passes only the title; extend it
   to pass the score **`id`** (and title for the app bar). The Reader resolves
   the file as `filesDir/Scores/<id>.mscz`.

### Data flow (Phase B runtime)

```
LibraryScreen row tap (ScoreRowWire.id, title)
  → nav "reader/{id}/{title}"
    → ReaderScreen
        → ReaderViewModel.load(id)
            read filesDir/Scores/<id>.mscz bytes
            sheet-music ScoreHandle.load(bytes)         (JNI parse → handle)
            nativeInstallSMuFLMetrics(...) once
            nativeComputeLayout(handle, wMM, hMM)        (JNI → DrawProgram bytes)
            DrawProgramReader.decode → DrawProgram
        → ScoreCanvas renders DrawProgram (FontProvider from compose lib)
        → AudioViewModel.preparePlayback(handle)         (engine renders MIDI)
        → play/pause → EnginePlayer → AndroidPlaybackEngine
        → engine currentCursor flow → nativeCursorFrame(handle, cursor)
              → CursorFrame → overlay rect + auto-scroll
        → seek slider ↔ currentTimeSeconds / totalTimeSeconds
```

## Error handling

- **Missing / unreadable file:** if `filesDir/Scores/<id>.mscz` is absent or
  unreadable, show an error state in `ReaderScreen` (not a crash); offer back.
- **Parse failure:** `ScoreHandle.load` returns a null/zero handle on failure —
  surface a "could not open score" state.
- **Layout wire version mismatch:** `DrawProgramReader` fails fast on a bad
  magic/version; treat as a load error with a clear message (indicates a
  module/`.so` version skew — a developer-facing condition).
- **Engine / soundfont failure:** if the engine can't prepare (e.g. missing
  soundfont), keep the score rendered and disable the transport, rather than
  failing the whole screen.

## Testing & verification

- **Phase A:** rebuild the `swift-sheet-music` example against the new
  `sheet-music-compose-android` module; launch and confirm no rendering
  regression (single page renders, pan/zoom works, cursor follows during play).
- **Phase B:** build Folino Android, `installDebug`, and launch via `adb`
  (Android changes are install+launch-complete per project workflow). Open an
  existing Library score and verify: it renders, scrolls, zooms; play/pause
  works; the cursor follows and auto-scrolls; the seek slider scrubs.
- Any pure-logic helpers added on the Folino side (e.g. id → file path
  resolution) get small unit tests; the heavy rendering/audio paths are covered
  by the manual launch verification since they depend on native `.so`s.

## Risks

- **Toolchain / version skew:** the three Android `.so`-bearing modules must be
  built from the same `swift-sheet-music` commit and published at a matching
  mavenLocal version, or the wire formats drift. The Android Swift cross-compile
  toolchain is finicky (documented workarounds exist in project memory). This is
  the main execution risk and lands mostly in Phase A.
- **Font/soundfont bundling size:** Bravura + Edwin live in the compose library;
  the GM soundfont is bundled in Folino. Acceptable for an MVP; revisit if APK
  size matters.
- **Extraction churn in `swift-sheet-music`:** promoting example code into a
  library is the bulk of Phase A and touches another repository. Kept minimal by
  extracting only the rendering/codec/overlay code and parameterizing fonts and
  colors.
- **Single-page layout:** the current `LayoutBridge` emits one flattened page.
  Fine for vertical scroll MVP; multi-page and the other layout modes are
  explicitly deferred.

## Parity notes

- **Logic shared, not reimplemented:** rendering, audio, score parsing, cursor
  resolution all come from shared Swift in `swift-sheet-music`. No iOS Reader
  business logic is duplicated in Kotlin for the MVP. The future
  preferences/mixer parity work is where shared Folino logic (a `FolinoReaderJNI`
  bridge) gets introduced.
- **UI placement follows Android idioms:** standard Material `Scaffold` + back
  arrow, a bottom transport bar with a slider seek (not the iOS drag-delta
  `SeekBar`), Compose scrolling. Content shown stays at iOS parity (the same
  rendered score, the same playback).
