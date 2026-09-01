---
name: app-store-screenshots
description: Use when capturing, re-capturing, or debugging Folino's App Store screenshots — Scripts/capture-screenshots.sh, fastlane/screenshots, a ScreenshotScene, ScreenshotSetup/ScreenshotSharedState, the simctl broker, or "スクショを撮り直して". Covers the per-locale/per-device runs, why the delivered pixels come from the compositor rather than drawHierarchy, and the traps that have shipped broken shots before.
---

# App Store screenshots

```sh
Scripts/capture-screenshots.sh                          # 5 locales x iPhone + iPad
Scripts/capture-screenshots.sh --locales en             # one language
Scripts/capture-screenshots.sh --devices iphone --locales en,ja
Scripts/capture-screenshots.sh --scenes NoteEditing      # one scene, leaving the other PNGs alone
Scripts/capture-screenshots.sh --verbose                 # print the test's output, including why it failed
```

While iterating on one shot, narrow all three: `--devices iphone --locales en --scenes NoteEditing` is about twenty
seconds of capture rather than eight scenes across five languages.

Output lands in `fastlane/screenshots/<App Store locale>/<order>_<alias>_<scene>.png` (deliver-compatible,
gitignored). `fastlane deliver` consumes that directory at upload time.

The script builds once per device, then runs `FolinoScreenshotTests/CaptureScreenshotsTests` once per language. That
one hosted unit test captures **every** scene in a single app process: it swaps each `ScreenshotScene` into the host
app's window and settles it by drawing with `drawHierarchy` until two consecutive frames are pixel-identical, instead
of sleeping. A language needs its own run because much of the Feature packages resolves strings with
`String(localized:)` at call time, which reads the *process* language — `-testLanguage` is the only thing that moves
it.

**The delivered pixels come from the simulator's compositor, not from `drawHierarchy`.** `drawHierarchy` draws the
app's own layer tree, which cannot include backdrop blur: a material / `glassEffect` is composited by the render
server from a backdrop it captures separately, so glass came out tinted but transparent, with whatever was behind it
sharp. Small controls survived that; the note-editing pad did not. So the script runs a watcher that answers the
test's per-scene marker files with `xcrun simctl io <udid> screenshot` — the real frame, blur and all, and already
exactly the App Store pixel size. The handshake is files (`fastlane/screenshots/.broker/<scene>.request` →
`.png` → `.done`) because a test bundle runs inside the simulator and cannot call `simctl`, while the script cannot
call into a running test. Running the test from Xcode instead skips all of it: no broker directory, so it falls back
to the in-process render.

The shared mechanics (`TrueScaleInner`, `ScreenshotSceneFrame`, `ScreenshotCaptureSession`) live in the
`swift-screenshot-kit` package, which VocalTuner uses too; only the scenes, the locale table and the destination pins
are per-repo.

Notes for anyone touching this:

- **Scenes lay the app UI out at the real device size** (440x956 / 1032x1376) via `ScreenshotSceneFrame` and scale the
  raster into the marketing thumbnail, so controls read at true proportions. Marketing chrome is drawn at full output
  resolution. `PiPScene` is the deliberate exception — it's a drawing, not app UI; see the comment on its `body`.
- **Scenes share one process now**, so anything a scene writes to `UserDefaults` or a singleton is still live for the
  next one. `ScreenshotSharedState.reset()` clears the keys scenes disagree about between captures; add to it when a
  new scene pins a global.
- **Anything that can appear on first run must be suppressed.** `ScreenshotSetup.ensure()` retires every
  `ReaderFeatureHint` and the page-tap coach mark — one of those bubbles landed on top of a score in the first run
  after the hints shipped.
- **`\.screenshotIdiom` must be installed by app code**, and is — in `ScreenshotScene.view`. ScreenshotKit is linked
  separately into the app and the test bundle, so an environment value written on the test side keys a different entry
  than the scene reads; that silently framed the iPad deliverables with the iPhone layout.
- **A compositor frame is only as good as the moment it is taken.** Right after launch the render server hasn't
  produced the backdrop a glass surface samples, and until it does every material renders as a flat dark slab —
  which held still long enough to pass a stability check and shipped one screenshot with a black status band. The two
  halves are split on purpose: `capture_stable` rules out *motion* only (two byte-identical grabs), and the stale
  compositor is caught app-side, where the session nudges the compositor and asks twice — two answers agree only once
  the frame is fresh. Don't fold one into the other.
- **A `simctl io` grab can hang forever.** Every grab is bounded by perl's `alarm` (macOS ships no `timeout`), a
  truncated file is discarded rather than delivered, and the watcher marks a request `.done` only with a frame in
  hand — answering without one made the app read a file that wasn't there and fail the whole run.
- **A scene the app can't be driven into needs a switch.** `NoteEditingScene` has to be in an edit session with a
  note selected, and the harness draws scenes rather than tapping them — so `ReaderScreenshotEditing`
  (`readerAutoEditMeasure`) opens the session, and the Editor's own `editorPadVisible` opens the pad. Both are read
  from `UserDefaults`, both no-ops without the key, and both belong in `ScreenshotSharedState.reset()`.
- The `#Preview`s on each scene still work and match what gets captured — use them (or the Xcode MCP `RenderPreview`
  with the `FolinoScreenshot` scheme active) to iterate on layout. They render in-process, so glass looks flat there.
