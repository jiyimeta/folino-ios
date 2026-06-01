# Reader: score-info & share buttons (with shared `ScoreUI` module)

**Date:** 2026-06-01
**Status:** Design approved, ready for implementation plan

## Context

Moving the transport controls into the bottom-right pill (`ReaderBottomOverlay`)
freed space in the Reader's top-right. We want to surface two more affordances
there: **score info** (composer, title, copyright, …) and **share / export**.

The Reader top-right currently holds one glass pill with two *settings* buttons:
playback settings (`slider.vertical.3`) and display settings (`text.page`),
defined in `ReaderTopOverlay` (`Packages/Features/Reader/Sources/Reader/Screens/ReaderToolbar.swift`).

Both new actions are **occasional**, not frequently pressed while reading. The
user nonetheless chose to keep them always visible (not hidden behind an
overflow menu), grouped so the toolbar does not read as one cluttered row.

The share options and the info sheet must be **identical to Library's** — same
five export formats, same edit-info form. Rather than duplicate that UI, we
**lift the shared components into a new `ScoreUI` module** consumed by both
Library and Reader.

## Goals

- Add a 2+2 grouped-pill toolbar to the Reader top-right: a new "this score"
  pill (info + share) to the left of the existing "settings" pill.
- Reuse Library's share menu and edit-info sheet verbatim by commonizing them.
- Reader gains the same share-export capability as Library (all five formats).
- Reader gains the same view/edit/save score-metadata capability as Library.
- Introduce a sanctioned shared feature-UI layer (`ScoreUI`) and record it in
  `docs/engineering/module-architecture.md`.

## Non-goals

- No new export pipeline or formats. The export logic (`ScoreShareService` /
  `LiveScoreShareService`) already lives in Domain/Infrastructure and is reused
  as-is. The five formats (MuseScore v4, MuseScore v3, PDF, MIDI, M4A) and the
  `isOriginal` flag are unchanged.
- No read-only variant of the info sheet. Reusing Library's sheet means Reader
  also gets edit + save; this is intentional, not a separate view.
- No changes to the bottom transport pill.
- No new metadata fields surfaced (the sheet keeps Library's current set).

## Decisions (from brainstorming)

1. **Layout:** keep all four buttons visible, in two grouped glass pills
   (2 + 2), top-right. Existing settings pill stays right-most; the new "this
   score" pill is added to its left with a gap.
2. **Share scope:** identical to Library — full five-format menu, reusing the
   existing `ScoreShareService`.
3. **Info sheet:** reuse Library's `EditScoreInfoSheet` (edit-capable), not a
   new read-only view.
4. **Sharing strategy:** create a new `ScoreUI` package and move the shared
   share-menu + edit-info components into it; both Library and Reader consume
   it. (Chosen over duplicating into Reader.)

## Architecture

### New layer: `Packages/ScoreUI/`

`ScoreItem`- and `ScoreShareFormat`-aware SwiftUI components cannot live in
Domain (Foundation-only, no SwiftUI) nor in `UtilityUI` (Utility must not depend
on Domain). They are also forbidden to cross Feature→Feature. The arch doc's
existing escape hatches ("lift into Domain, or compose at App") do not cover
shared SwiftUI — this is a genuine gap. We close it with a dedicated shared
feature-UI layer.

```
App ──▶ Features ──▶ ScoreUI ──▶ Domain ◀── swift-sheet-music
                       └──▶ UtilityUI (UtilityCore + UtilityUI)
```

- **Depends on:** `Domain`, `UtilityCore`, `UtilityUI`.
- **Depended on by:** Feature packages (Library, Reader, and later Editor).
- **Must not** depend on any Feature package or on App. `Feature → Feature`
  stays forbidden; `Feature → ScoreUI` is the new allowed edge.

`Packages/ScoreUI/Package.swift` mirrors the Library/Reader package shape
(swift-tools 6.3, iOS v26, SwiftLint plugin, `defaultLocalization: "en"`,
`resources: [.process("Resources")]` for its `.xcstrings`).

### Components moved into `ScoreUI` (lifted from Library)

| Component | From | Notes |
| --- | --- | --- |
| `ShareSubmenu` | `Library/Views/ScoreRowMenu.swift` | Pure UI: `loadFormats` + `onShare` closures. No Library coupling. |
| `EditScoreInfoSheet` | `Library/Views/EditScoreInfoSheet.swift` | Decoupled from `LibraryViewModel` — see below. |
| `EditableScoreInfo` | `LibraryViewModel` | Becomes `public` in `ScoreUI`. |
| Format-label / source-label localization | `Library` `.xcstrings` | Keys move to `ScoreUI` bundle (see Localization). |

`ActivityViewControllerRepresentable` already lives in `UtilityUI` and is reused
through ScoreUI's dependency on it — it does **not** move.

### Decoupling `EditScoreInfoSheet` from the view model

Today the sheet takes `let viewModel: LibraryViewModel` and calls
`viewModel.loadFileMetadata(for:)` (`-> ScoreFileMetadata?`) and
`viewModel.saveMetadata(_:fields:)` (`async`, errors handled internally).

Introduce a small abstraction in `ScoreUI` that both feature view models satisfy:

```swift
@MainActor
public protocol ScoreInfoEditing {
    func loadFileMetadata(for item: ScoreItem) async -> ScoreFileMetadata?
    func saveMetadata(_ item: ScoreItem, fields: EditableScoreInfo) async
}
```

`EditScoreInfoSheet` is rewritten to take `let model: any ScoreInfoEditing` (and
the `ScoreItem`) instead of the concrete `LibraryViewModel`. Signatures match the
existing methods exactly, so Library conforms with no behavior change.

> Note: `saveMetadata` stays non-throwing `async` (matching today's
> `LibraryViewModel`, which catches and routes errors to `currentError`). Each
> conforming view model owns its own error surfacing.

### Share state shared shape

`LibraryViewModel` owns a private `ShareTarget { id; urls: [URL] }` plus
`shareTarget` / `isPreparingShare` and `requestShare(_:format:)`. Promote the
target struct to a `public struct ScoreShareTarget: Identifiable, Equatable` in
`ScoreUI` so both view models present `ActivityViewControllerRepresentable` with
the same type, and the per-VM `requestShare` reads identically.

## Reader changes

`Packages/Features/Reader/`:

- **Package.swift:** add `.package(path: "../../ScoreUI")` and the `ScoreUI`
  product to the `Reader` target dependencies.
- **`ReaderViewModel`:**
  - Add `let shareService: any ScoreShareService` to stored props and `init`.
    (No other new injection needed — `repository: ScoreLibraryRepository` and
    `gateway: ScoreFileGateway` are already present, which is all the metadata
    load/save path requires.)
  - Add `shareTarget: ScoreShareTarget?`, `isPreparingShare`,
    `isScoreInfoPresented` (and reuse `requestShare(format:)` mirroring
    Library's implementation).
  - Conform to `ScoreInfoEditing`: implement `loadFileMetadata`/`saveMetadata`
    using `gateway` + `repository` exactly as `LibraryViewModel` does (extract
    the shared body if practical, but duplication here is acceptable and small).
- **`ReaderTopOverlay` (`ReaderToolbar.swift`):** replace the single inspector
  pill with two pills laid out right-aligned with a gap:
  - **"this score" pill (new, left):** info button (`info.circle`) →
    `isScoreInfoPresented` sheet hosting `EditScoreInfoSheet(model: viewModel,
    item: viewModel.scoreItem)`; share button (`square.and.arrow.up`) → `Menu`
    hosting `ShareSubmenu` (lazy `availableFormats(for:)`, `onShare` →
    `viewModel.requestShare`). Same `.glassEffect(.regular.interactive())` +
    shadow as the existing pill.
  - **"settings" pill (existing, right):** unchanged playback + display buttons.
  - Present the share sheet via `.sheet(item:)` on `shareTarget` with
    `ActivityViewControllerRepresentable(items:)`, mirroring `LibraryRootScreen`.
- Compact-width (iPhone) check: two 2-button pills plus a gap must fit the
  top-trailing safe area in portrait; verify in preview. The transport pill is
  at the bottom, so the top band has room.

## Library changes (migration, behavior-preserving)

- **Package.swift:** add the `ScoreUI` dependency.
- Replace local `ShareSubmenu`, `EditScoreInfoSheet`, `EditableScoreInfo` with
  imports from `ScoreUI`. Update `EditScoreInfoSheetModifier` /
  `ScoreListScreen` / `ScoreRowMenu` call sites to pass `model: library`
  (the `LibraryViewModel` now conforms to `ScoreInfoEditing`).
- `LibraryViewModel` adopts the promoted `ScoreShareTarget`.
- **Regression bar:** Library share + edit-info behavior must be visually and
  functionally unchanged. Existing Library tests/previews must still pass.

## App composition

`App/.../AppShellView` (the `ReadyShell` wiring): pass the already-bootstrapped
`ScoreShareService` into `ReaderRootScreen` / `ReaderViewModel` init, alongside
the existing `repository`, `gateway`, `scoresDirectory`. This is the same
service instance Library already receives.

## project.yml

- Register the package under `packages:`:
  ```yaml
    ScoreUI:
      path: Packages/ScoreUI
  ```
- No new `from:`/url dependency (local path only), so no version-bump dual-edit.
- Regenerate with `xcodegen generate` after editing.

## Localization

Follows the `module.feature.thing` key scheme. Strings moving out of Library's
`.xcstrings` into `ScoreUI`'s catalog get re-keyed to a `scoreUI.*` namespace
(e.g. `scoreUI.scoreInfo.title`, `scoreUI.shareFormat.museScoreV4`). Reader's
new toolbar labels (`reader.toolbar.showInfo`, `reader.toolbar.share`) live in
Reader's catalog.

**Stale-key pitfall:** `xcstringstool` does not auto-remove entries. When the
moved keys are deleted from Library's catalog and added to ScoreUI's, audit for
literal-`Text`/`LocalizedStringKey` call sites that could regenerate stale keys.
Verify with a clean build that no orphaned keys remain in Library's catalog.

## Testing

- **ScoreUI:** view-level preview snapshots for `EditScoreInfoSheet` and the
  share menu, driven by a hand-written `ScoreInfoEditing` fake + fake
  `availableFormats` closure. Pure-value tests for `EditableScoreInfo`
  baseline/diff if any logic moves with it.
- **Reader:** unit test `ReaderViewModel.requestShare` against a fake
  `ScoreShareService` (asserts `shareTarget.urls`); unit test the
  `ScoreInfoEditing` conformance against fake `repository`/`gateway`.
- **Library:** existing tests must remain green (regression guard for the
  migration).
- Build/test via `xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17'`
  (per project convention; `swift test` is broken by the SwiftLint plugin's
  macOS requirement).

## Risks & mitigations

- **Architecture change.** Adding a layer is normally stop-and-confirm; it was
  explicitly approved here. The arch-doc edit is part of this work, reviewed
  with the spec.
- **Migration regressions in Library.** Mitigated by keeping signatures
  identical and leaning on existing Library tests/previews.
- **Localization drift.** Mitigated by the stale-key audit above.
- **`ScoreUI` becoming a dumping ground.** Scope it narrowly to score-item
  presentation components reused across ≥2 features; do not add feature-specific
  UI.

## Open questions

None blocking. Naming `ScoreUI` (vs. `ScoreSharedUI` / `ScoreComponentsUI`) is
settled as `ScoreUI` unless review prefers otherwise.
