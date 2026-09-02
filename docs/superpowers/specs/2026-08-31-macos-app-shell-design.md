# Mac App Shell (Sub-project Ⅲb) — Design

**Date:** 2026-08-31
**Status:** Approved direction. Implementation plan follows.
**Parent:** `docs/superpowers/specs/2026-08-31-macos-app-design.md` (umbrella, §9 sub-project Ⅲb)
**Depends on:** Ⅲa — `docs/superpowers/plans/2026-08-31-macos-package-enablement.md`, merged to `main` as `2a00781b`.

Ⅲa made every folino package below `Reader` compile for macOS. Ⅲb is the first sub-project that produces a **running Mac app**: a target, a window model, the macOS form of `Library` and `Reader`, and `Infrastructure.Audio` un-gated. Editing UI (palette, inspector, mixer, command search, key map) is sub-project Ⅳ and is deliberately absent here.

---

## 1. What is actually left, measured

The umbrella spec sized Ⅲb from file counts that nobody had verified against a compiler. Measured this session:

| Target | `.swift` files | Files touching iOS-only API | Shape of the work |
| --- | --- | --- | --- |
| `Features/Reader` (`Reader` target) | 131 | **26** | Annotation 4 (PencilKit), PiP 4 (AVKit), `Screens/` 13, `Views/` 2, `Hints/` 2, other 1 |
| `Features/Library` | — | 14 touch iOS-only API, but only **6 files / 10 sites** carry `EditMode`, which is the sole thing Ⅲa could not gate | chrome split, not a port |
| `App/` | 26 | 8 | three-way directory split |
| `Infrastructure/Audio` | 9 | 7 gated by Ⅲa, but the real non-portable surface is **two `#if` islands in one file plus one adapter** | un-gate, don't abstract |

Two of those numbers correct earlier estimates and matter to the plan:

- **`Infrastructure/Audio` is far smaller than "seven files" suggests.** `LivePlaybackController.swift` is 522 lines and its only macOS blockers are the `AVAudioSession` ambient demote in `releaseEngine` (:257) and `appIconArtwork`'s `UIImage(named:)` (:474). `MPNowPlayingInfoCenter`, `MPRemoteCommandCenter` and `MPMediaItemArtwork` all exist on macOS. The four `+LoopBounds` / `+Preview` / `+Reload` / `+Transpose` extensions contain no platform-specific code at all — they were gated only because Ⅲa gated the seven wholesale. `LiveScoreAudioExporter.swift` likewise contains none: `.hostManaged` means it never touches a session.
- **Reader's platform-neutral half is already clean.** `ReaderViewModel` and all twelve of its extensions import only Domain, PDFKit, ScoreUI, SheetMusicCore, UtilityCore and CoreGraphics. The platform-specific surface is exactly the `Screens/` layer.

A build-derived count is not a substitute for a static census here: `swift build` stops at the first module-import failure (`InkStrokePencilKitBridge.swift:3: no such module 'UIKit'`), so it under-reports. Both were run; the static census is the number to plan against.

---

## 2. Target and source layout

### 2.1 A second app target in the same project

Add `FolinoMac` to `project.yml`: `platform: macOS`, deployment target 15.0, **bundle identifier `com.KeyNumber.Folino` — the same one the iOS app ships**. Sub-project Ⅶ's iOS↔Mac universal purchase requires it, and it is also why the Mac app belongs in this project rather than a sibling one.

### 2.2 `App/` splits three ways

| Directory | Contents | Compiled by |
| --- | --- | --- |
| `App/Shared/` | `AppBootstrap` + its three extensions, `AppPaths`, `EditableReaderScreen`, `NavigationStateStore`, `ProcessScoreEditHistoryStore`, `ReviewPromptCoordinator`, `VersionHistoryPresenter`, `DomainError+LocalizedError`, `EdwinFontLoader`, `DrainBannerComposer`/`DrainBannerView`, the share-duplicate types | `Folino`, `FolinoMac`, `FolinoScreenshot` |
| `App/iOS/` | `FolinoApp`, `AppShellView`, `PictureInPictureOptOutMigration`, `UIKitInstalledAppChecker`, `LiveVocalTunerHandoff` | `Folino`, `FolinoScreenshot` |
| `App/Mac/` | `FolinoMacApp`, `MacShellView`, the menu-command and panel skeleton | `FolinoMac` |

`LiveVocalTunerHandoff` is iOS-only because the hand-off contract with VocalTuner is a URL-scheme + App Group arrangement between two iOS apps (`project_open_score_companion`); nothing about it is settled on macOS.

### 2.3 No `Packages/AppCore`

Lifting the shared half of `App/` into an SPM package was considered and rejected. It would force `public` onto wiring types that are `internal` today, against the repo's "`public` is a decision, not a default" rule, for a package whose only two consumers are two targets in one project. Target-level source sharing already has a precedent here: `FolinoScreenshot` compiles `App/` sources with excludes (`project.yml:183-199`), and the scheme comment at `project.yml:280-286` treats that second compilation as a feature — an API removal in `App/` shows up as a compile error rather than as a broken screenshot run. `FolinoMac` inherits exactly that property.

### 2.4 Divergence is expressed as paired files, not `#if` jungles

Where a `App/Shared` file needs genuinely different behavior per platform, extract the divergent part into a **pair of same-named types** — `App/iOS/AudioStackFactory.swift` and `App/Mac/AudioStackFactory.swift`, each building what its platform's bootstrap injects. Reserve `#if` for one-liners. This is the same judgement Ⅲa's plan recorded when it put `AppBootstrap`'s concrete audio construction out of scope and left it to Ⅲb.

### 2.5 `module-architecture.md` is revised, not violated

The current rule reads "App/ is the only place that wires Infrastructure adapters into Feature view models." It becomes:

> The composition root is `App/` — `App/Shared` plus one platform shell per app target. These app targets remain the only place Infrastructure adapters are wired into Feature view models.

The rule's intent (no Feature ever composes Infrastructure) is unchanged; only the pretense of a single root file goes.

### 2.6 The Mac target needs a build gate on day one

`Scripts/build-macos-packages.sh` gates the packages with `swift build`. The Mac app target is invisible to it, so it can rot silently between sessions. A sibling `Scripts/build-macos-app.sh` (an `xcodebuild -scheme FolinoMac` build) lands with M0 and is run at the end of every later milestone.

---

## 3. The window model

> **SUPERSEDED 2026-09-01** by `2026-09-01-macos-library-window-redesign-design.md`. The whole of §3 described a
> `NavigationSplitView` shell whose sidebar hosted the iOS `LibraryRootScreen`. That arrangement is unshippable: a
> `NavigationStack` push inside a `NavigationSplitView` sidebar renders bottom-anchored on macOS 26.4.1, so every
> Library screen the Mac reached was blank. Read the new document instead; what remains true here is the
> `MacWindowScore` value type and the single score `WindowGroup`.

### 3.1 One `WindowGroup`, presenting a score

The umbrella spec already decided this in §5.3: "standard macOS window tabbing. **One window = library sidebar (collapsible) + score tabs**."

```
WindowGroup(for: ScoreItemID.self) { $scoreID in
    MacShellView(scoreID: $scoreID)
}
```

`ScoreItemID` is `Codable` (it rides on Domain's `ScoreItem`), so SwiftUI's own scene restoration works without a second mechanism.

`MacShellView` is a `NavigationSplitView`: the sidebar hosts `LibraryRootScreen` — which already owns its own `NavigationStack` and already runs in a sidebar column, that being exactly how `AppShellView.sidebar` uses it — and the detail column hosts the Reader or a `ContentUnavailableView`. §2.1's "the score fills the window, every panel closed" is `columnVisibility = .detailOnly` on open, the same gesture `AppShellView` performs on iPad.

### 3.2 Opening reuses the window; tabs are offered

Selecting a row in the sidebar sets **the current window's** detail (window-local `@State`, seeded from the group's presented value). "Open in New Tab" calls `openWindow(value:)`. Because every window comes from one `WindowGroup`, AppKit's automatic tabbing supplies ⌘T, tab drag-out and Merge All Windows for free.

**Amended after implementation: this said "double-clicking", and double-click is measured unreachable.** A SwiftUI tap gesture on a row and `List(selection:)` cannot coexist on macOS. Measured against a bare `List(selection:)` control in the same run, every gesture form — `.onTapGesture`, `.onTapGesture(count: 2)`, `.simultaneousGesture(TapGesture(count: 2))` and `.highPriorityGesture(TapGesture(count: 2))`, attached to the row content or to the whole row — leaves the selection permanently EMPTY, not merely unable to multi-select. Each of those forms fired its own open action in the same run, so the events do reach SwiftUI; they never reach the `NSTableView` underneath, because the gesture claims the click first.

So the Mac has no row gesture at all. **Selecting exactly one row is what opens it** — the Mail / Notes shape, and the same muscle memory an iPad user brings. Selecting more than one is a bulk selection: the detail shows "N selected" and the bulk actions come from the selection's context menu and ⌫.

**A consequence, not a separate preference: nothing auto-collapses the sidebar.** Opening a score used to set `columnVisibility = .detailOnly`; with selection driving the detail that would hide the list on the first click and make ⌘-clicking a second row impossible, so multi-selection would be structurally unreachable. The sidebar is the user's to collapse (⌘0), and it behaves the same however a score was opened — including after an import, so there is no special case to remember.

**A second consequence, recorded as a known cost rather than a defect: multi-selecting tears down the reader.** When the selection crosses 1→2 the detail swaps `MacReaderRootScreen` for the count view, so SwiftUI unmounts the reader and its `onDisappear` runs — `endAnnotationSessionIfNeeded()`, a flush of pending ink, then `releaseEngine()`. Nothing is lost from the document: the ink is flushed before the engine goes. What is lost is session state — scroll position, magnification, and **playback**, so ⌘-clicking a second row while a score is playing stops the music. Dropping back to one row rebuilds the reader from scratch (the detail is keyed `.id(item.id)`, so a fresh `ReaderViewModel`). The alternative is to keep the reader mounted behind the count view and merely cover it, which costs a live engine and a live annotation session for a selection the user is about to act on; that trade is open.

This is the MuseScore 4 complaint (§5.3) inverted: MuseScore forces a new window; folino defaults to reuse and offers tabs.

### 3.3 Why not a separate library window

A `Window("Library")` plus a `WindowGroup(for:)` cannot tab together — distinct scene types get distinct tabbing identities — so the free system tabbing that §5.3 asks for would die. Structurally it also recreates MuseScore 4's Home-window / score-window split, which is the thing §5.3 exists to reject. And a score window with no collapsible sidebar weakens "the library is the truth": the library should always be one ⌘0 away, in every window.

### 3.4 What else the scene graph carries at this stage

- A `Settings` scene. The `Settings` package builds for macOS as of Ⅲa, and its sheet becomes the standard ⌘, window.
- A `.commands {}` skeleton: File ▸ Open / Import, View ▸ display modes. Everything else in §2.2's key map is Ⅳ.
- **Restoration is not unified.** `NavigationStateStore` stays iOS-only; the Mac relies on `WindowGroup(for:)`. Two per-platform mechanisms are fine; one hybrid is not.

---

## 4. Library's macOS form

> **SUPERSEDED 2026-09-01** by `2026-09-01-macos-library-window-redesign-design.md`. §4.1's finding — the selection
> state is already neutral, only the chrome is iOS — still holds and is reused. What is superseded is where that
> selection lives and what a click does: selection moved into a separate library browser window, and selecting a row
> no longer opens it. §4.4's "verify `.onMove` on a macOS List" also survives.

### 4.1 The selection *state* is already neutral; only the *mode* is iOS

`ScoreListView.swift:83` is already `List(selection: $selectedIDs)` over a `Set<ScoreItemID>`. `EditMode` exists solely to gate the iOS bulk-select **chrome**: the Select / Cancel toolbar button (:121-135), `BulkActionBar` in a `safeAreaInset` (:66-79), row-tap-toggles-selection, and the selection-count title.

The ten sites: `ScoreListScreen.swift:14`, `ScoreListView.swift:41,65,184`, `RecentlyDeletedScreen.swift:12`, `RecentlyDeletedView.swift:17,30`, `PlaylistDetailView.swift:22,82`, `NewScoreSheet.swift:69`. The last is `.environment(\.editMode, .constant(.active))` — affordance-level, the same shape as Editor's Ⅲa sites, already covered by `activeEditModeCompat()`.

### 4.2 The change

- `selectedIDs: Set<ScoreItemID>` stays the one shared truth, at screen scope, as today.
- `@Binding var editMode: EditMode` in the views becomes `isSelecting: Bool`. On iOS the screen derives `EditMode` from it inside `#if os(iOS)` chrome — the Select button, the `.environment(\.editMode)`, `BulkActionBar`.
- **macOS has no mode.** `List(selection:)` multi-selects natively with ⌘/⇧-click; bulk actions come from the selection's context menu (and, in Ⅳ, from the menu bar); ⌫ deletes the selection.
- No abstract `SelectionMode` protocol. The difference between the platforms is chrome, not structure — **fork the chrome, keep one list.**

### 4.3 Ripple

The six files above, plus `ScoreListRow` (its `isEditing:` parameter becomes `isSelecting`, iOS-only), `BulkActionBar`, the selection-title modifier, and `ScoreListView.swift:118`'s `if #available(iOS 26, *)` → `if #available(iOS 26, macOS 26, *)` (owed by Ⅲa's out-of-scope list). The bulk *actions* on `LibraryViewModel` are already selection-set-based and need nothing. Tag and playlist sidebar lists are untouched.

### 4.4 One thing to verify on a real Mac before designing around it

`PlaylistDetailView`'s manual reorder uses `.onMove`, whose behavior on a macOS `List` with no edit mode is **unverified** — Ⅲa's plan flagged the same question. The likely answer is that drag-reorder works once selection is enabled. Verify before choosing the affordance; do not design a Mac reorder control on an assumption.

---

## 5. Reader's macOS form

### 5.1 The AppKit host lives inside the existing `Reader` target

Behind file-scope `#if os(macOS)`, in a new `Screens/Mac/` directory. Not a new target: that would force `public` across `ReaderViewModel` and its twelve extensions, a large access-control regression for no isolation benefit. Not a new package: a sibling Feature package would need a Feature → Feature edge, which is forbidden. The manifest gains `.macOS(.v15)`, matching every other package.

### 5.2 The seam

**The view model and its sub-models are shared as-is; each platform owns its root screen and containers.** `ReaderViewModel` + 12 extensions are already platform-neutral. Two members need small gates: `ReaderPiPSession` (report unsupported on macOS, gate the AVKit coordinator) and nothing else. `EditableReaderScreen`'s closure seam is UIKit-free, moves to `App/Shared` intact, and on macOS its editing-chrome builders return no-ops until Ⅳ.

### 5.3 A separate `MacReaderRootScreen`, not `#if` inside the 828-line one

Half of `ReaderRootScreen` is iOS physics: status-bar and cutout-tier plumbing, `hostingAppearance(.light)` (:318-334), the idle timer (:421), the PiP host (:253), pop-gesture restoration (:314). A ~250-line `MacReaderRootScreen` composing the same view model is cheaper and clearer than threading `#if` through that file.

### 5.4 What is ported, from where

Every source below is in **swift-sheet-music's example app**, not its library — `Examples/Apple/SheetMusicExample/macOS/`. Same author, compatible licence, so copying is allowed; it is reference code, not API.

| ssm example file | Role in folino | Lines |
| --- | --- | --- |
| `MagnifyingPDFScrollView.swift` | **Page mode** — the re-engraved page deck on `NSScrollView.allowsMagnification` | 167 |
| `MagnifyingScoreScrollView.swift` | Horizontal mode | 444 |
| `VerticalScoreContainer.swift` | Vertical mode — **pure SwiftUI, no AppKit host** | 127 |
| `OriginalPDFView.swift` | The imported **original PDF** with a cursor overlay — distinct from the page deck above | 132 |

**Copy into folino now; do not upstream mid-Ⅲb.** Several of these arguably belong in ssm proper by the engine-boundary rule, but each upstreaming triggers an ssm local-pin → verify → release cycle and entangles Ⅲb with Ⅱ's release. Record the note; let Ⅱ or Ⅳ lift the scroll host upstream when VocalTuner needs it.

### 5.5 Display modes in scope

**Page (the Mac default, per umbrella §3) and Vertical. Horizontal is scheduled last inside Ⅲb and, if the budget runs out, becomes a `PARITY(macos)` row handed to Ⅳ.**

Vertical is 127 lines of pure SwiftUI in the reference — the cheapest possible "a score renders" smoke test, available before the `NSScrollView` port lands. Page is the default mode; a Mac reader missing its default is a placeholder, not a milestone. Horizontal carries the sticky leading pane and its bracket geometry — the most intricate port for the least-used mode, and therefore the right thing to cut first.

PDF-origin library items display through the `OriginalPDFView` port.

### 5.6 Annotations: input deferred to Ⅴ, display included here

Umbrella §7.3 already establishes that macOS has no `PKCanvasView` and that the Mac annotation canvas is sub-project Ⅴ. But `PKDrawing(data:)` and `imageFromRect` are macOS 10.15+, and a Mac that silently hides ink authored on an iPad breaks §1's one-library promise in the worst way — the data looks lost. `StaticInkLayer`'s technique ports with a `UIImage` → `NSImage` alias.

If it slips, it must slip **loudly**: a `PARITY(macos)` row plus a visible hint that the score carries annotations. Never silent absence.

### 5.7 Gated off on macOS in Ⅲb

PiP (4 files, AVKit), PencilKit input (4 files), `ScoreScrollHost` and the iOS containers, `ReaderPinchCommit`, `ReaderDeviceDefaults`' UIKit probes, `TempoBeatGlyph`'s rasterizer. Each gets a `PARITY(macos)` marker following Ⅲa's grammar — continuation lines indented **two or more** spaces (`Scripts/parity-report.py:50`), marker placed **outside** any `#if os(iOS)` block.

---

## 6. Audio on macOS

### 6.1 Un-gate; do not abstract

- **`LivePlaybackController` + its four extensions:** drop the file-scope `#if os(iOS)`; keep two `#if` islands — the session demote in `releaseEngine` (:257, iOS only; on macOS teardown alone suffices) and `appIconArtwork` (:474, `UIImage(named:)` → `NSApp.applicationIconImage`, wrapped for `MPMediaItemArtwork`).
- **`LiveScoreAudioExporter`:** un-gate wholesale. Verify one offline render on a Mac.
- **`OutputRouteDisconnectWatcher`:** the one genuine adapter split. Keep the type name and the `onDisconnect` contract; give it two bodies in one file — iOS keeps `AVAudioSession.routeChangeNotification`, macOS observes CoreAudio's `kAudioHardwarePropertyDefaultOutputDevice` plus the device list. No protocol: a third implementation will never exist.

A full "neutral core + session adapters" extraction was considered and rejected — the session adapter would have one meaningful method on iOS and none on macOS, and the session lifecycle genuinely lives inside ssm's `PlaybackEngine(audioSessionPolicy:)`, not in folino.

### 6.2 `AVAudioEngineConfigurationChange` is Ⅱ's, not Ⅲb's

Umbrella §5.4 identifies that ssm has never subscribed to it and that fixing it helps iOS too. **Do not add a folino-side observer.** A second observer racing the engine's own teardown is exactly the failure documented in `reference_audio_engine_pitfalls`. Ⅲb's playback milestone works without it; device-switch-during-playback robustness arrives with the Ⅱ-pinned ssm release. This paragraph exists so nobody helpfully adds it later.

### 6.3 One thing to verify before writing the Mac audio stack

That `PlaybackEngine(audioSessionPolicy:)` compiles on macOS in ssm 2.3.1 — its `PlaybackEngine+AudioSession` bodies are iOS-gated, and the initializer parameter is expected to exist and be inert (the ssm macOS example builds without passing it, using the default).

---

## 7. Risks this design commits to handling

### 7.1 Firebase target wiring — settle it in M1, not in Ⅷ

`AppBootstrap.start()` calls `FirebaseCrashReporter.configure` (:88) and `FirebaseAnalyticsClient.make` (:177) unconditionally, so the Mac hits Firebase on its first boot.

**Verified:** `FirebaseAnalytics.xcframework` at the pinned 11.15.0 ships a `macos-arm64_x86_64` slice, and Crashlytics is a source target. Neither is a platform blocker — correcting an assumption that they were.

What remains genuinely undecided, and must be decided in M1: how a Mac app sharing `com.KeyNumber.Folino` is registered in the Firebase console, whether it shares `GoogleService-Info.plist`, and whether the Crashlytics `upload-symbols` post-build script (`project.yml:110`, which is also why the iOS target sets `ENABLE_USER_SCRIPT_SANDBOXING: NO` at `project.yml:106`) is attached to `FolinoMac`. Until that is settled, `FolinoMac` composes `NoopAnalytics` / `NoopCrashReporter` — both already exist and are already the nil-fallbacks at `AppBootstrap.swift:107,125`.

### 7.2 The Reader's light pin becomes a real bug on macOS — M3, not polish

`ReaderRootScreen.swift:318-334` deliberately pins the Reader light: white paper, ink resolved against light traits, chrome tuned to match. Ⅲa made `HostingAppearance` a **no-op on macOS**. Left alone, a Mac in dark mode gets dark chrome floating over white paper — precisely the failure that comment documents.

The Mac equivalent (an `NSAppearance` on the hosting view, or a scene-scoped `.preferredColorScheme` — the Mac reader window has none of the iOS pop-animation concern that forced the hosting-VC route) belongs in **M3's definition of done**.

### 7.3 App Group semantics differ on macOS

The container is team-ID-prefixed and no Share Extension exists there. `AppGroupPaths.container()`-dependent features — the share drain, shared-soundfont reconciliation, playlist index publishing — already tolerate `nil`, but the Mac bootstrap should **not schedule them at all** rather than lean on nil-tolerance. Degrade by design, not by accident.

### 7.4 `.onMove` on a macOS `List`

See §4.4. Verify before designing.

---

## 8. Milestones

Each milestone ends green on both the iOS build and `Scripts/build-macos-app.sh`, and lands as its own commit.

| | Milestone | Pass condition |
| --- | --- | --- |
| **M0** | Target + layout scaffolding: `FolinoMac` in `project.yml`, `App/` three-way split, `module-architecture.md` revision, `Scripts/build-macos-app.sh` | `FolinoMac` builds and shows an empty window; `Folino` **and** `FolinoScreenshot` still build |
| **M1** | Shell boots: Mac `AppBootstrap` composition (audio slots nil, Firebase per §7.1), `WindowGroup(for:)` + split view + `Settings` scene + command skeleton | Launch → empty library window; ⌘T opens a tab; relaunch restores windows |
| **M2** | Library visible, read-only: the §4 state split, list renders, File ▸ Open and drag-and-drop import | Importing an `.mscz` shows a row that survives relaunch; selecting the row fills the detail with a placeholder (double-click is measured impossible — see §3.2) |
| **M3** | Score renders: `MacReaderRootScreen`, Vertical then Page, PDF originals, read-only ink, §7.2's appearance fix | A score engraves vector-sharp at any magnification in both modes; iOS Reader behavior unchanged (existing tests green) |
| **M4** | Playback: the §6 un-gating, the Mac route watcher, transport UI, space to play/pause | Audible playback with a moving cursor on the default device; unplugging headphones pauses; Now Playing reflects state |
| **M5** | Library operations: multi-select and bulk actions, Recently Deleted, playlists (reorder verified per §4.4), tags | Every Library capability is reachable on Mac or recorded as a deliberate `PARITY(macos)` row |
| **M6** | Chrome finish: the per-screen semantic toolbar-placement migration Ⅲa deferred (`.cancellationAction` / `.confirmationAction` — what actually earns Esc / Return on a Mac sheet); Horizontal mode if budget allows | Each migrated screen's iOS appearance verified unchanged by preview; Horizontal either ships or is a `PARITY(macos)` row |

**On "the shortest path to something visible is Reader"** (recorded in project memory): half right. Reader is Ⅲb's largest work item, not its shortest path — every package below Library already builds, and a Reader with an empty library has nothing to open. The kernel of truth is that Reader's Mac render is cheaper than it looks, which is why Library's **bulk-select** work is staged after playback (M5) rather than front-loaded.

---

## 9. Out of scope

- Editing UI of any kind — palette, inspector, mixer, piano, drum pad, command registry, command search, key map. That is Ⅳ.
- Annotation **input** on macOS. Ⅴ. (Display is in scope; §5.6.)
- The `.folino` container format. Ⅴ.
- App Sandbox, security-scoped bookmarks, signing, notarization, a Mac release lane, Mac screenshots. Ⅷ.
- Cloud sync. macOS needs it to *ship*, not to *build* (umbrella §1); the seam is a Domain protocol and SP2 drops in at the composition root.
- `AVAudioEngineConfigurationChange`. Ⅱ (§6.2).
- Upstreaming the ported AppKit views to ssm. Ⅱ or Ⅳ (§5.4).

---

## 10. Documents this sub-project revises

- `docs/engineering/module-architecture.md` — the composition-root rule (§2.5).
- `docs/engineering/ios-android-parity.md` — regenerated as markers land; never hand-edited.
