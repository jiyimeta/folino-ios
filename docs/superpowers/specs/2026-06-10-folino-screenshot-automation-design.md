# Folino Screenshot Automation (Phase 2) — Design

**Date:** 2026-06-10
**Status:** Approved (brainstorming complete)
**Repo:** Folino-iOS (worktree `.claude/worktrees/screenshot-tooling`, branch `worktree-screenshot-tooling`, off `main`)
**Depends on:** `swift-screenshot-kit` (ScreenshotKit) + `ios-screenshot` CLI, built and dogfooded in VocalTuner (Phase 0/1, merged to VocalTuner `main`).

## Problem

Folino's App Store screenshots are produced manually today (raw device
captures committed under `fastlane/screenshots/<locale>/NN_<device>_<name>.png`,
5 locales: en-US/ja/ko/zh-Hans/zh-Hant). The reusable UITest screenshot
pipeline proven in VocalTuner (`ScreenshotKit` package + `ios-screenshot`
CLI) should now be adopted in Folino, and the screenshots upgraded from raw
captures to framed marketing screenshots (device screen inside a
`ScreenshotFrameView` with a localized title/subtitle).

This is Phase 2 of the screenshot-tooling extraction. It is also the real
test of whether the package's **DI-agnostic** `bootstrap(prepare:)` hook
generalizes: Folino does not use swift-dependencies.

## Goals

- Capture Folino's App Store screenshots via `ios-screenshot` + a Folino
  screenshot app target, with no manual steps beyond authoring scene copy.
- Framed marketing style (title/subtitle over the app screen), an upgrade
  from the current raw captures.
- Reuse the reusable artifacts unchanged; the only Folino-specific work is
  the app glue (target wiring, scenes, fixtures, copy, config).
- Prove the DI-agnostic hook fits an app that injects dependencies by
  constructor injection (no global DI container to swap).

## Non-goals

- PiP screenshot (deferred — requires an active `ReaderPiPSession` /
  AVPictureInPicture session that does not render statically). The other 6
  of Folino's 7 manual screenshots are in scope.
- No change to Folino's production app composition (`AppBootstrap` /
  `AppShellView`) — the screenshot target bypasses them.
- No change to `ScreenshotKit` or `ios-screenshot` themselves (if a genuine
  gap surfaces, it is flagged and handled as a separate change to those
  repos, not folded into Folino).

## Folino architecture (the relevant seams)

- **DI = constructor injection, no swift-dependencies.** `AppBootstrap`
  (`@MainActor @Observable`) builds live services at launch; `ReadyShell`
  (in `AppShellView.swift`) constructs feature view models
  (`LibraryViewModel`, `ReaderViewModel`, …) passing services via `init`.
  View models already accept services as `init` parameters, several with
  test-friendly defaults (`NoopScoreShareService`, optional
  `playbackController`).
- **Existing fakes:** `Packages/Features/Reader/Sources/Reader/PreviewSupport.swift`
  has `PreviewFakeRepository` (`ScoreLibraryRepository`) and
  `PreviewFakeGateway` (`ScoreFileGateway`, returns a synthetic `Score`).
  These are the basis for screenshot fixtures.
- **Screens (6 in scope), all in the Reader/Library packages, all
  init-constructable:**
  - `LibraryRootScreen` (Library package) — needs a repository with ≥1 item.
  - `ReaderRootScreen` (Reader) — needs a loaded fixture `Score`.
  - `PlaybackInspectorScreen` (Reader) — score + playback models
    (mixer/tempo/master-volume/a4/repeat/transpose).
  - `VisualInspectorScreen` (Reader) — score + layout/transpose models.
  - A–B repeat — `PlaybackInspectorScreen` with `RepeatModel.mode = .aB`.
  - Horizontal — Reader in horizontal layout mode
    (`HorizontalScoreContainer`).
- **Languages:** `KNOWN_REGIONS = en ja zh-Hans zh-Hant ko`; development
  language en. Strings are `.xcstrings` per package.
- **No UITest target exists.** `project.yml` defines `Folino`,
  `FolinoShareExtension`, `FolinoTests` (unit, Swift Testing). Packages are
  wired via the top-level `packages:` block + per-target `dependencies`.

## Architecture

Mirror the VocalTuner shape, adapted to Folino's constructor-injection DI.

### 1. ScreenshotKit dependency
Add to `project.yml` `packages:`:
```yaml
  ScreenshotKit:
    url: git@github.com:jiyimeta/swift-screenshot-kit.git
    revision: c583b524966dfb754c7f60b68ebe2dee9728c1b5   # same revision VocalTuner pins
```

### 2. `FolinoScreenshot` app target
A screenshot-dedicated app target compiled with
`-D DISABLE_REMOTE_STORAGE`-equivalent (if Folino has one) **and**
`-D SCREENSHOT_ENABLED`. It links the minimal set needed to render the 6
screens with fixtures — Reader, Library, Domain, ScoreUI, Utility,
swift-sheet-music + ScreenshotKit — and **avoids** Firebase/GRDB live use
(fixtures replace them at runtime; exact link set resolved in the plan,
following whatever the Reader/Library packages transitively require).

`@main` dispatch: Folino's `FolinoApp` has no launch-arg handling, so the
screenshot target uses its own root that bypasses `AppBootstrap` /
`AppShellView`. At init it calls
`ScreenshotEnvironment.bootstrap(userDefaults:prepare:)`; because Folino has
no global DI container to swap, the `prepare` closure is essentially empty
(animations-off + any UserDefaults overrides happen inside `bootstrap`
itself). The root reads `ScreenshotEnvironment.requestedSceneID` and renders
the matching scene.

### 3. Scene catalog (`FolinoScreenshot/`)
A `ScreenshotScene` enum with 6 cases and one scene view each. Each scene
view constructs the target screen's view (and view model) with fixture
services and wraps it in `ScreenshotFrameView(title:subtitle:)`:

| id | screen | fixture state |
|---|---|---|
| `01_Library` | `LibraryRootScreen` | repository with a few `ScoreItem`s |
| `02_Reader` | `ReaderRootScreen` | loaded synthetic `Score` |
| `03_PlaybackInspector` | `PlaybackInspectorScreen` | score + playback models |
| `04_VisualInspector` | `VisualInspectorScreen` | score + layout models |
| `05_ABRepeat` | `PlaybackInspectorScreen` | repeat model preset to `.aB` |
| `06_Horizontal` | Reader horizontal layout | score + horizontal layout mode |

The inspector scenes render the inspector views directly with their models
(reproducing the presented state) rather than driving navigation to present
them.

### 4. Fixture layer
Reuse and extend `PreviewSupport`'s fakes. Provide: a populated repository
for Library, a synthetic `Score` for Reader/inspectors, and the playback/
layout models the inspectors need (with A–B and horizontal presets). Keep
fixtures in the `FolinoScreenshot/` target (not in production packages),
extending the package fakes via `@testable import` where internal access is
needed — establishing the same `@testable import` convention used in
VocalTuner.

### 5. Scene copy — `ScreenshotStrings.xcstrings`
A catalog in `FolinoScreenshot/` with `title`/`subtitle` for the 6 scenes ×
5 locales. English drafted in this work; the user reviews and supplies/edits
localized copy (translators). Resolved per `ScreenshotEnvironment`-selected
locale, as in VocalTuner.

### 6. `FolinoUITests` target
A `bundle.ui-testing` target linking `ScreenshotKitUITest`, depending on
`FolinoScreenshot`. A thin `ScreenshotsUITests` calls
`captureScene(id:languages:in:)` once per scene with the 5-language list.

### 7. `.screenshots.yml` (Folino repo root)
```yaml
project: Folino.xcodeproj
scheme: FolinoScreenshot
test_plan: FolinoUITests/ScreenshotsUITests
destinations:
  - { name: "iPhone 17 Pro Max",     alias: "iPhone69" }
  - { name: "iPad Pro 13-inch (M5)", alias: "iPad13" }
locales:
  en: en-US
  ja: ja
  ko: ko
  zh-Hans: zh-Hans
  zh-Hant: zh-Hant
output: fastlane/screenshots
filename: "{order}_{alias}_{scene}"   # 01_iPhone69_Library, matches Folino's convention
options:
  skip_package_plugin_validation: true
  parallel: true
```

## Verification

Narrow languages to `en`/`ja` for the tool-validation run (mirroring the
VocalTuner dogfood), run `ios-screenshot`, and confirm 6 scenes × 2 devices
land as framed PNGs at `fastlane/screenshots/<locale>/01_iPhone69_Library.png`
… with correct device dimensions. Restore the full 5-language list before
finishing. Full 5-language production capture + visual review happens at the
next real release. Folino's existing unit tests must still pass.

## Risks / open considerations

- **Inspector views in isolation.** The playback/visual inspectors are
  normally presented over the Reader. Constructing them standalone with
  fixture models must reproduce a representative populated state; if a view
  cannot be built in isolation, the scene falls back to presenting it over a
  fixture Reader. Resolved during implementation.
- **Minimal-dependency screenshot target.** If the Reader/Library packages
  transitively require Infrastructure (GRDB/Firebase) to even link, the
  screenshot target may have to link them (used only behind fakes at
  runtime). Acceptable; the goal is "no live remote/db at runtime," not
  zero-link.
- **DI-agnostic hook.** This is the first consumer with no global DI
  container. If the empty-`prepare` pattern feels awkward, that is a signal
  to revisit the `ScreenshotKit` API — handled as a separate change to that
  repo, not worked around in Folino.
- **Copy authoring.** Framed screenshots need 6×5 title/subtitle strings;
  English is drafted, localized copy is user/translator supplied. Until
  localized copy lands, non-en locales fall back to the development language.
