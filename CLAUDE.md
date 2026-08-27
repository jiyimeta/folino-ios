# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

Folino is a universal iOS app (iPad + iPhone, Swift 6.3, iOS 18+, bundle id `com.KeyNumber.Folino`). Product specs live in `docs/product/`; the implementation strategy lives in `docs/engineering/module-architecture.md` — read the latter before making structural changes.

The deployment floor is **iOS 18.0** (`project.yml` and every `Package.swift`), so iOS 26-only API cannot be written raw — guard it behind the compat helpers in `Packages/Utility/Sources/UtilityUI/GlassEffectCompat.swift` (or add one there in the same `if #available(iOS 26, *)` shape).

## First-Time Setup

```sh
cp Config/Local.xcconfig.sample Config/Local.xcconfig
# edit Local.xcconfig to set your Apple Developer Team ID

xcodegen generate
open Folino.xcodeproj

# install the pre-commit hook (one-time per clone)
brew install pre-commit swiftlint swiftformat   # if not already installed
pre-commit install
```

(The bundled SoundFonts are committed under `App/Resources/Soundfonts/` — no manual copy step.)

`Config/Local.xcconfig` is gitignored; the team ID never lands in the repo. The generated `Folino.xcodeproj` is also gitignored and must be regenerated whenever `project.yml` changes.

## Git Workflow

**Do not use partial / hunk-level staging** (`git add -p`, `git add --patch`, IDE "stage selected lines"). Always stage whole files.

The pre-commit hook (configured in `.pre-commit-config.yaml`) runs SwiftFormat and `swiftlint --fix` against staged Swift files and writes fixes back to disk. With partial staging, those fixes can land on hunks you intentionally left unstaged, mixing them into the commit and corrupting the split.

To break a working tree into multiple commits:

1. `git stash --keep-index` — sets aside everything that isn't staged.
2. Commit the staged whole files (the hook will fix-and-fail until clean).
3. `git stash pop` — restores the rest, then stage the next batch.

If you have unrelated edits in the same file, use `git stash`, edit again, and commit in passes — never split by hunk.

## Day-to-Day Commands

| Action | Command |
| --- | --- |
| Regenerate Xcode project after editing `project.yml` | `xcodegen generate` |
| Build app (project, simulator) | `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation build` |
| Run app + UI tests | `xcodebuild -project Folino.xcodeproj -scheme Folino -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation test` |
| Test one Swift package in isolation | `xcodebuild test -scheme <Pkg\|Pkg-Package> -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -skipPackagePluginValidation` (run from the package dir) |
| Run a single Swift Testing suite/test | append `-only-testing:<Scheme>/<SuiteName>` to the command above |

`swift test` does **not** work in this repo: the SwiftLint build-tool plugin (applied to every package target) requires a macOS host context that the SwiftPM CLI can't satisfy, so package tests must go through `xcodebuild test` on an iOS Simulator destination. Use **iPhone 17 Pro Max** as the destination — it is the 6.9" device App Store Connect requires for screenshots, so standardizing on it keeps build/test and screenshot runs on one booted simulator (iPhone 16 is not installed). For feature-isolated iteration (SwiftUI previews, fast unit-test loop), open the relevant `Packages/.../Package.swift` directly in Xcode rather than the app project.

## App Store screenshots

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

## Architecture (must respect)

Strict layered SPM modules. **Read `docs/engineering/module-architecture.md` for details** — the rules below are summary only.

```
App ──▶ Features ──┬─▶ Domain ◀── swift-sheet-music
 │                 └─▶ ScoreUI ──▶ Domain
 │                          └────▶ Utility
 └──▶ Infrastructure ─▶ Domain         Utility is reachable from any layer.
```

- **`Packages/Utility/`** — app-agnostic building blocks (`UtilityCore`, `UtilityUI`, `Navigation`).
- **`Packages/Domain/`** — value types + protocols. Foundation-only.
- **`Packages/Infrastructure/`** — concrete adapters (`Persistence`, `CloudSync`, `Soundfonts`, `Audio`, `ScoreFiles`, `CrashReporting`, `Analytics`; plus the Android-gated `FolinoSoundfontJNI` dynamic JNI library, built only when cross-compiling for Android).
- **`Packages/ScoreUI/`** — shared score-aware SwiftUI components reused across Features (e.g. `ShareSubmenu`, `EditScoreInfoSheet`). Depends on Domain + Utility only.
- **`Packages/Features/<Name>/`** — one package per feature (Library, Reader, Editor, ImportExport, Settings). Depends on Domain and the shared `ScoreUI` layer only.
- **`App/`** — composition root. The only place that wires Infrastructure adapters into Feature view models.

`swift-sheet-music` is consumed by Domain (model re-export) and Infrastructure (adapters). Features never import it directly.

**Forbidden** (will be flagged in review):

- Feature → Feature (lift shared code into Domain, the shared `ScoreUI` layer, or compose at App).
- Feature → Infrastructure (always go through a Domain protocol).
- Feature → `swift-sheet-music` directly.
- Domain → Infrastructure / Features / App.
- ScoreUI → Feature / Infrastructure / App (ScoreUI sits below Features; Domain + Utility only).
- Utility → anything else in this repo.

### Dependency Injection

Pure constructor injection. No DI library. View models take Domain protocols via `init`. SwiftUI `EnvironmentValues` is reserved for view-tree-scoped concerns (theme, navigation, feature flags) — never used as a service locator for view models.

## Testing

- **New tests use Swift Testing** (`import Testing`, `@Suite`, `@Test`, `#expect`). UI tests still need `import XCTest` for `XCUIApplication`.
- **Feature tests** run against hand-written fakes that implement Domain protocols — no real CloudKit, no real network, no real audio engine.
- **Domain tests** are pure value-type unit tests.
- **Infrastructure tests** can hit real SQLite / tmpdir file I/O. CloudKit, audio, and HTTPS adapters use fakes.

## iOS / Android parity

Folino is becoming cross-platform (iOS/iPadOS native; Android via `swift-wirelet` JNI bridges). Two rules govern how the two platforms relate:

- **Logic / behavior → match iOS exactly, and share the code.** Business logic, domain rules, and persistence semantics (soft-delete representation, file-naming conventions, import flow, the presentation/derivation that maps a score to its displayed fields) must behave identically on both platforms. If a piece of logic would otherwise be duplicated between the iOS and Android paths, refactor it into shared code (Domain, or a shared Android-gated Swift target) and have both platforms call it. Keep Android-specific code to the minimum that *can only* be implemented on Android: the JNI bridge types (`@WireletObservable` / `@WireletProvided` and their wire `@WireFormat` projections), the Kotlin/Room/SQLite persistence backend, Android file I/O (`filesDir`, `content://` document pickers), and the Compose UI. Never reimplement iOS logic a second time as a divergent Android code path — lift it and reuse it.

  This holds for a few lines of pure arithmetic too — "it's too small to share" is not a reason. The one
  thing that legitimately stays Kotlin-side is an input that **only exists on Android** (e.g. a raster
  budget, which has no meaning against iOS's vector `drawPDFPage`).

- **UI / UX placement → Android idioms are preferred.** Button placement, icons, copy/wording, navigation patterns, and screen transitions follow Android conventions (e.g. FAB for the primary action, swipe-to-dismiss + Snackbar undo, gear-icon Settings) rather than mirroring the iOS layout. The *content* shown stays at iOS parity; only the *presentation/placement* adapts to the platform.

### Recording a deliberate one-platform-first gap

When a feature lands on one platform and the other half is deliberately deferred, leave a marker at the point of
divergence — `// PARITY(android): <title> — <what Android still needs>` (or `PARITY(ios)`). `Scripts/parity-report.py`
collects them into `docs/engineering/ios-android-parity.md`, and the `parity-ledger` pre-commit hook fails if that file
drifted, so the ledger cannot rot. Implementing the other half deletes the marker, which deletes the row. Details and
the format are in the ledger itself. Reserve it for real, intended gaps — it is not a TODO list.

### Android builds (pointer)

The Android half lives in `Android/` (Gradle + Compose); the Swift JNI `.so`s are built by `Scripts/android-build-libs.sh` (Settings) and `Scripts/android-build-{library,reader,soundfont}-libs.sh`. Cross-compiling needs the release toolchain first on `PATH` (`PATH="/Library/Developer/Toolchains/swift-6.3.3-RELEASE.xctoolchain/usr/bin:$PATH"`) — the Xcode-bundled Swift is incompatible with the prebuilt Android SDK. Ordering matters: run the Gradle wirelet codegen first, then (re)build the `.so`s, then `assembleDebug` — building `.so`s first in a fresh worktree yields libraries without `JNI_OnLoad` that crash at launch. See the project memory for the detailed gotchas.

## Build-Time Tooling

These plugins run automatically on every `xcodebuild` / Xcode build — no manual invocation:

- **SwiftLintBuildToolPlugin** (`SimplyDanny/SwiftLintPlugins`) — applied to every Package source target and the App target. Config is the repo-root `.swiftlint.yml`.
- **PrepareLicenseList** (`cybozu/LicenseList`) — extracts third-party license texts at App build time. Surface them via `LicenseListView()` from `import LicenseList`.

## Comment style

Reflow comment paragraphs (`//` and `///`) at the SwiftLint `line_length.warning: 120` budget, not 80. Older code may still be wrapped at ~80 — reflow as you touch it. Aim to keep prose paragraphs as a single line up to 120 characters wide; only break for the reasons below.

Preserve as-is (do not reflow across these):
- Directives: `// MARK:`, `// swiftlint:…`, `// swift-format…`, `// sourcery:`.
- Blank comment lines (`//` or `///` with no body) — they mark a paragraph break.
- Markdown structure inside a comment — `- ` / `* ` / numbered list, `# ` headings, `> ` blockquotes, `` ``` `` fences. Each starts a new paragraph.
- Preformatted content — comment bodies that begin with 2+ leading spaces (indented code samples, ASCII tables).
- Decorative dividers like `////…` or `// ====`.

Hyphenated soft breaks (`long-\nrunning`) join back into one word when the next line begins with a letter — `long-running`, not `long- running`.

## Project Constraints

- **Internal feature names never appear in user-facing copy** — `Reader`, `Editor`, `Library`,
  `ImportExport`, `Settings` are developer names that came from `Packages/Features/<Name>/` and mean nothing
  to a user. This matters most in Japanese: write 「楽譜表示中は…」, not 「Reader 表示中は…」. English can
  often keep `Reader`, but prefer "while viewing a score" when in doubt. Internal identifiers (xcstrings
  keys, type names, schemes, bundle ids) stay as they are — this is about strings a user can read.
- **App name is lowercase `folino` for users.** `Folino` is only for type names, the SwiftPM/Xcode scheme name, the project name, and the bundle ID prefix — strictly developer-facing. Anywhere a user can read the brand (Info.plist `CFBundleDisplayName`, navigation titles, alert titles, share-sheet display, marketing copy), it must be lowercase `folino`.
- **Do not propose AudioKit (the third-party library)**. Folino uses AVFoundation directly via `swift-sheet-music`'s `SheetMusicAudio`.
- **No GPL dependencies.** Hard constraint.
- Bumping a SwiftPM dependency means updating both the relevant `Package.swift` AND the `from:` entry under `packages:` in `project.yml` to the same version.
- Localization for `Info.plist` strings goes in `App/Resources/InfoPlist.xcstrings`.

## Autonomous-task ground rules

When the user hands off a long-running task and steps away, default to **proceed without asking** for routine work, and **stop to confirm** only at the boundaries below. The y/n prompts the user actually sees should all be ones where the answer might genuinely be "no".

**Proceed without confirmation:**
- Reading, editing, writing files inside this repo.
- Running builds, tests, previews (`xcodebuild`, `swift test`, `xcrun simctl`, `mcp__xcode__*`).
- Routine git: `add`, `commit`, `checkout`, `switch`, `stash`, `restore`, `fetch`, `pull --ff-only`, status / diff / log / show / blame.
- SwiftLint / SwiftFormat / pre-commit fix-and-restage cycles.
- Bumping a SwiftPM dependency version when the task explicitly asks for it (still update both `Package.swift` and `project.yml`).

**Stop and confirm — these are not auto-approved by `.claude/settings.json` and never should be:**
- Spec / product behavior changes — anything that alters what `docs/product/` describes, user-visible copy, or feature scope.
- Module-architecture changes — new packages, new layer boundaries, anything in `docs/engineering/module-architecture.md`.
- Public API changes to a Domain protocol that ripples across multiple Features.
- Adding, removing, or replacing a SwiftPM dependency (vs. version bump of an existing one).
- Destructive git: `push`, `push --force`, `reset --hard`, `clean -f*`, `branch -D`, `worktree remove`, history rewrites.
- Destructive shell: `rm -rf` of the repo root, `$HOME`, or any worktree.
- GitHub side effects: `gh pr merge`, `gh pr close`, `gh pr edit`, `gh release create/delete`, `gh repo delete/archive`.
- Editing `.claude/settings.json`, `.claude/settings.local.json`, `~/.claude/settings.json`, or this "Autonomous-task ground rules" section — anything that would relax my own auto-approval rules.
- Touching paths outside this repo (`../OtherProject`, other worktrees, `~/Library/...` beyond Xcode DerivedData cleanup that's clearly necessary for the task).

If something falls between these — e.g. a refactor that *might* qualify as architectural — surface the question before doing the work, not after.
