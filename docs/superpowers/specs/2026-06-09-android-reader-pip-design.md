# Android Reader Picture-in-Picture — Design

- **Date:** 2026-06-09
- **Platform:** Android (Folino cross-platform; iOS already ships PiP)
- **Feature package:** `FolinoReaderAndroid`
- **Status:** Approved design, ready for implementation plan

## Goal

Mirror the iOS Reader Picture-in-Picture feature on Android: while a score is
playing, the user can shrink the Reader into a floating Picture-in-Picture
window that keeps showing the score with the playback cursor following along,
and offers play/pause and ±10s skip controls — all while another app is in the
foreground.

The **content shown** matches iOS (horizontal single-system score + cursor +
auto-scroll + transport controls). The **mechanism and UX placement** follow
Android idioms, per the project's iOS/Android parity rule.

## Critical architectural difference from iOS

iOS PiP is *custom-content* PiP: `ScorePiPFrameRenderer` renders the score +
cursor into `CVPixelBuffer`s every frame and feeds them to an
`AVSampleBufferDisplayLayer` driven by a `CADisplayLink` frame pump, wrapped by
an `AVPictureInPictureController`.

**None of that ports to Android.** Android PiP shrinks the *Activity itself*
into a small window (the YouTube / Maps model). There is no per-frame buffer
rendering, no display layer, no frame pump, no MediaCodec. Instead, when the
Activity enters PiP mode we swap the Compose UI to a minimal "score + cursor"
layout. The existing on-screen rendering path (`ScorePage` +
`PlaybackCursorOverlay` + JNI auto-scroll helpers) is reused verbatim — it just
renders into a smaller window.

This makes the Android implementation substantially simpler than iOS: pure
Kotlin/Compose + a manifest change, no new native (`.so`) symbols.

## What already exists (no work needed)

- **Audio survives PiP.** Playback is owned by `ReaderPlaybackService`
  (a foreground `MediaSessionService`), not the Reader composable. The Activity
  entering/leaving PiP, or being destroyed when the PiP window is closed, does
  not stop playback. `ReaderAudioViewModel` is a client of the service.
- **PiP-enabled setting key.** `SettingsPrefs.pip`
  (`reader.pictureInPicture.enabled` DataStore key, default `false`) already
  exists, mirroring iOS `ReaderGlobalSettingsKey.pictureInPictureEnabled`.
  Read via `prefs.pip: Flow<Boolean>`, written via `prefs.setPip(Boolean)`.
- **Horizontal score rendering + cursor follow.** `ScorePage`,
  `PlaybackCursorOverlay`, and the JNI scroll helpers
  (`nativeMeasureFrame` + `FolinoReaderJNI.nativeHorizontalMeasureScrollOffset`
  for X; `nativeCursorFrame` + `nativeScrollOffsetKeepingInView` for Y) already
  drive the horizontal layout mode in `ReaderScreen.kt`.
- **Playback control API.** Via `audioVm.engine: StateFlow<AndroidPlaybackEngine?>`:
  `play(from:)`, `pause()`, `skip(seconds: Double)` (already clamps to
  `[0, totalTimeSeconds]`). Observable: `state: StateFlow<PlaybackState>`,
  `currentTimeSeconds`, `totalTimeSeconds`, `currentCursor`.

## Architecture

PiP lives entirely inside `FolinoReaderAndroid` + the `app` module's
`MainActivity` / manifest. No Domain protocol, no new shared Swift logic, no new
JNI symbols.

### Components

| Component | Kind | Responsibility |
| --- | --- | --- |
| `AndroidManifest.xml` (app) | change | Add `android:supportsPictureInPicture="true"` and `android:configChanges="screenSize|smallestScreenSize|screenLayout|orientation"` to `MainActivity` so PiP resize does not recreate the Activity. |
| `MainActivity` | change | Track whether PiP should be enterable; wire `setAutoEnterEnabled` (API 31+) / `onUserLeaveHint` (API 26–30 fallback); call `enterPictureInPictureMode(params)`; propagate `onPictureInPictureModeChanged` into Compose; host the RemoteAction `BroadcastReceiver`. |
| `PipController` | new (small class) | Pure-ish helper that builds `PictureInPictureParams` — aspect ratio (clamped), auto-enter flag, RemoteActions list. The params-assembly logic is unit-testable. |
| `ReaderPipContent` | new Composable | Minimal PiP layout: `ScorePage` (horizontal single system) + `PlaybackCursorOverlay` + X/Y auto-scroll only. No toolbar, inspector, status, or gestures. White background. |
| `ReaderScreen` | change | Accept `isInPipMode: Boolean`; render `ReaderPipContent` when true, normal UI when false. Expose a "PiP eligibility" signal (score loaded, horizontal-renderable) up to the Activity. |
| Reader toolbar | change | Add a manual PiP button, visible only when `prefs.pip == true`. Tapping calls into the Activity to `enterPictureInPictureMode`. |
| Settings screen | change | Add the PiP enable/disable toggle if not already surfaced, wired to `prefs.pip` / `prefs.setPip`. (iOS parity.) |

### Source of truth for "can enter PiP"

The Activity decides eligibility, since `enterPictureInPictureMode` and
`onUserLeaveHint` are Activity-level. The condition is:

```
currentRoute startsWith "reader/"   // Reader screen is shown
  AND prefs.pip == true             // user enabled PiP
  AND playbackState == PLAYING      // something is playing (matches iOS autostart gate)
```

Compose state (current route is already tracked via
`nav.currentBackStackEntryAsState()`; playback state from `audioVm.state`) is
surfaced to the Activity through a small shared holder (e.g. a `StateFlow` or a
`mutableStateOf` the Activity reads). The exact plumbing is an implementation-
plan detail.

## Lifecycle / flow

### Entering PiP

- **Auto-enter (Android 12+ / API 31+):** When eligible, set
  `PictureInPictureParams.Builder().setAutoEnterEnabled(true)` on the Activity.
  Pressing Home / switching apps then enters PiP automatically (seamless).
- **Auto-enter fallback (API 26–30):** `setAutoEnterEnabled` is unavailable.
  Override `MainActivity.onUserLeaveHint()`; if eligible, call
  `enterPictureInPictureMode(params)`.
- **Manual:** Reader toolbar PiP button (shown only when `prefs.pip == true`)
  calls `enterPictureInPictureMode(params)` directly.

### In PiP

- `onPictureInPictureModeChanged(isInPictureInPictureMode = true, ...)` flips a
  Compose state → `ReaderScreen` renders `ReaderPipContent`.
- Audio continues (foreground service). `audioVm.currentCursor` keeps emitting;
  the reused auto-scroll keeps the cursor parked near the leading edge.

### Exiting / closing

- Expanding the window → `onPictureInPictureModeChanged(false)` → normal UI
  restored.
- Closing the window (×) → OS stops/destroys the Activity. Playback continues in
  the service. No explicit dismiss handling needed (unlike iOS's
  foreground-return auto-dismiss; the OS manages this on Android).

## PiP window layout & aspect ratio

- Content is **always horizontal single-system**, regardless of the Reader's
  current layout mode (page/vertical). Matches iOS.
- Reuse `ScorePage` + `PlaybackCursorOverlay` + the horizontal auto-scroll JNI
  calls. Cursor parks at the existing leading inset.
- **Aspect ratio:** Android requires a `Rational` within `[1/2.39, 2.39]`.
  Reuse the iOS heuristic (derive from staff count: `6.0 / staffCount`, clamp
  `1.0…6.0`) to get a target, then **clamp into Android's allowed
  `[1/2.39, 2.39]` range** before `setAspectRatio()`. Horizontal scores will
  sit near 2.39:1.
- Background: white (score paper color), same as iOS.

## RemoteActions (in-window controls)

iOS parity: three actions — **play/pause toggle**, **−10s**, **+10s** (fits
Android's typical 3-action limit; verify against
`getMaxNumPictureInPictureActions()`).

- Each is a `RemoteAction(icon, title, contentDescription, PendingIntent)` where
  the `PendingIntent` is a broadcast to a receiver registered by `MainActivity`.
- The receiver maps actions to `engine.play()` / `engine.pause()` /
  `engine.skip(+10.0)` / `engine.skip(-10.0)`. Clamping is already inside
  `skip`.
- play/pause icon reflects state: observe `audioVm.state`; on change, rebuild
  params via `setActions(...)` and call `setPictureInPictureParams(params)` so
  the glyph toggles between play and pause.

## Settings

- Reuse existing `SettingsPrefs.pip` DataStore key. No new key.
- Add the toggle row to the Android Settings screen if not already present,
  wired `prefs.pip` (read) / `prefs.setPip` (write). iOS-parity label/wording,
  Android-idiomatic placement.

## Testing

- **Unit (JVM):** Extract params assembly into `PipController` and test:
  aspect-ratio clamping into `[1/2.39, 2.39]` for various staff counts;
  RemoteActions list composition; auto-enter eligibility predicate
  (route + pipEnabled + playing).
- **Manual (Pixel device, per project policy — Claude runs install + launch):**
  build → installDebug → launch → open a score → play → press Home → confirm
  auto-PiP → in-window play/pause + ±10s → expand to restore → close window and
  confirm audio continues. Also verify API-30-class behavior path
  (`onUserLeaveHint` fallback) if a suitable emulator/device is available.

## Out of scope (YAGNI)

- iOS frame pump / `CVPixelBuffer` / `AVSampleBufferDisplayLayer` / MediaCodec
  frame feeding — not applicable to Android's activity-based PiP.
- A scrub bar inside the PiP window (RemoteAction skip only).
- Special transitions when the score is closed or swapped mid-PiP — deferred to
  OS PiP teardown.
- Sharing the `pipEnabled` DataStore value with iOS via backup import/export.

## Build notes

- No new native symbols → **no `.so` rebuild required**. Pure Kotlin/Compose +
  manifest. (Standard fresh-worktree Android build still applies if building in
  a new worktree: gradle codegen → `.so` staging order, per project memory.)
