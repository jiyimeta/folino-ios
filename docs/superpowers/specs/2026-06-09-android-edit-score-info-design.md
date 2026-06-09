# Android Edit Score Info — Design

Date: 2026-06-09

## Summary

Bring the iOS "edit score info" feature to Android, reachable from both Library
and Reader, mirroring iOS *behavior* while adopting a Material-idiomatic
*presentation*. A full-screen edit screen (Material full-screen dialog) lets the
user edit a score's six credit fields and review read-only file info, with an
explicit Save and a discard-confirmation guard.

The editing/derivation logic is shared with iOS, not reimplemented in Kotlin: the
editable-fields value type, the file-metadata prefill rule, and the save
normalization are lifted into `Domain` (Foundation-only) so iOS and the
Android-gated Swift store call the same code.

## Goals

- Edit `title`, `subtitle`, `composer`, `arranger`, `lyricist`, `copyright` on a
  score from Android, with content parity to iOS.
- Reachable from Library (per-score `⋮` overflow, single score only) and Reader
  (top app bar info icon).
- Material full-screen-dialog presentation: `✕` / title / `SAVE` in the top app
  bar; explicit save; discard confirmation on unsaved exit.
- Persist all six fields to Room with parity semantics (trim, title required,
  empty string `""` is a meaningful "explicitly cleared" value).
- Share the edit logic with iOS via `Domain` — zero Kotlin reimplementation of
  business rules.

## Non-Goals

- No editing of fields iOS does not edit (no instrument/part metadata, no tags
  here — tags have their own sheet).
- No bulk metadata edit (CAB) — single score only, matching the iOS entry model.
- No change to the iOS UI itself beyond a behavior-preserving refactor that
  follows the shared types into `Domain`.

## Material recognition model

Decision (confirmed): **full-screen edit screen** (Material full-screen dialog),
the same mental model as editing a contact in Google Contacts.

Rationale: six editable fields plus a read-only info section is too much for an
`AlertDialog`, and a `ModalBottomSheet` collides with the soft keyboard once
multiple fields scroll. Material's full-screen dialog is the canonical pattern
for "edit a set of fields, then confirm with Save/Cancel in the top app bar,"
and its explicit-Save behavior coincides with iOS's existing Save + discard
semantics.

```
┌──────────────────────────────┐
│ ✕   Edit info          SAVE  │  ← top app bar; SAVE disabled when title blank
├──────────────────────────────┤
│ CREDITS                      │
│  Title       [ … ]           │
│  Subtitle    [ … ]           │
│  Composer    [ … ]           │
│  Arranger    [ … ]           │
│  Lyricist    [ … ]           │
│  Copyright   [ …            ]│  ← multi-line
│                              │
│ INFO (read-only)             │
│  Source         MuseScore 4  │
│  Date added     2026/06/01   │
└──────────────────────────────┘
```

## Shared logic (parity core)

iOS already keeps the edit logic SwiftUI-free, so the parity-correct move is to
lift it into `Domain` and have both platforms call it.

### Lift into `Packages/Domain`

- `EditableScoreInfo` (six `String` fields) moves from
  `Packages/ScoreUI/.../EditableScoreInfo.swift` to
  `Packages/Domain/Sources/Domain/Models/EditableScoreInfo.swift`. It is already
  `Foundation`+`Domain`-only with no SwiftUI coupling.
  - Its prefill initializer carries the rule unchanged: stored value wins; if the
    stored value is `nil`, fall back to the file metaTag; an empty string `""`
    counts as a stored value and suppresses the fallback; `subtitle` has no file
    fallback.
- The save normalization currently duplicated in `LibraryViewModel.saveMetadata`
  and `ReaderViewModel.saveMetadata` is consolidated into a single pure Domain
  function, e.g. `EditableScoreInfo.normalized(applyingTo:) -> ScoreItem?`:
  - Trim every field on `.whitespacesAndNewlines`.
  - Title required: return `nil` (no-op) when the trimmed title is empty.
  - Persist empties as `""` (so a cleared field stays cleared and is not
    re-prefilled from the file next time).
- The `ScoreInfoEditing` protocol stays where it is useful for iOS UI; only the
  value type + derivations move. (Confirm during planning whether the protocol
  should also move; not required for Android.)

### iOS follow-on (behavior-preserving)

- `EditScoreInfoSheet` stays in `ScoreUI`; it imports the type from `Domain`.
- `LibraryViewModel` / `ReaderViewModel` `saveMetadata` call the shared
  `normalized(applyingTo:)` instead of inlining trim/validation.
- Existing iOS behavior must be unchanged; covered by Domain unit tests that
  encode the current rules.

> Architecture note: moving a value type + adding pure helpers within `Domain`
> is behavior-preserving and is exactly what the iOS/Android parity rule
> mandates. It is surfaced here for the spec-review gate.

## Android UI

New Compose screen `EditScoreInfoScreen` (in the app module's
`ui/library` or a shared `ui/scoreinfo` package — decided in the plan):

- `Scaffold` + `TopAppBar`:
  - Navigation icon `✕` → discard flow.
  - Title: localized "Edit info".
  - Action: `SAVE` text button, `enabled = title.trim().isNotEmpty()`.
- Scrolling content:
  - `CREDITS` section: six `OutlinedTextField`s. Title/Subtitle/Composer/
    Arranger/Lyricist single-line; Copyright multi-line.
  - `INFO` section (read-only rows): Source (MuseScore 4 / MusicXML / MIDI / PDF
    / Unknown) and Date added (locale-formatted). Source format brand literals
    are not localized; "Unknown" is.
- Unsaved-changes guard:
  - Baseline snapshot captured on load; `hasChanges = current != baseline`.
  - `✕` and system back (`BackHandler`) → when `hasChanges`, show an
    `AlertDialog` (Keep editing / Discard); otherwise pop immediately.
- Localization: English string resources; no internal feature names ("Reader"/
  "Editor") surfaced to the user.

## Persistence bridge (swift-wirelet)

`LibraryAndroidStore.swift`
(`Packages/Features/Library/Sources/FolinoLibraryJNI/`) is the single Room
source of truth. Add:

- `@WireletExpose func saveScoreInfo(_ id, _ title, _ subtitle, _ composer, _ arranger, _ lyricist, _ copyright)`
  — builds an `EditableScoreInfo`, calls the shared `normalized(applyingTo:)`,
  `store.upsert`, and reloads observables. No-op when normalization returns `nil`
  (blank title). Uses the existing multi-arg `@WireletExpose` support.
- `@WireletExpose func scoreInfoForEditing(_ id) -> EditScoreInfoWire` — returns
  the prefilled six fields plus read-only `source` and `dateAdded`. Built inside
  the store using the shared `EditableScoreInfo.init(item:fileMetadata:)`. Uses
  the synchronous-return wirelet capability (already added for export).

`EditScoreInfoWire` (`@WireFormat`): `title, subtitle, composer, arranger,
lyricist, copyright, source, addedAt`.

### Room migration

`ScoreRecordEntity` / `ScoreRecordWire` currently persist only `title`,
`subtitle`, `composer`. Add `arranger`, `lyricist`, `copyright` (nullable),
bumping the Room schema version by one with a migration that adds the columns.
`RoomLibraryStore.upsert`/projection updated to round-trip the new columns.

## Reader save path

The Android Reader is currently read-only and receives only `scoreId`. Wire a
narrow editing path mirroring iOS (where `ReaderViewModel` holds the repository):

- `MainActivity` already holds the Library store view model and hosts the
  NavHost that constructs `ReaderScreen`. Pass a narrow editing handle (or
  `onEdit`/`onSave` callbacks bound to `scoreInfoForEditing` / `saveScoreInfo`)
  into the Reader.
- Reader top app bar gains an info icon (next to the display-settings icon) that
  opens `EditScoreInfoScreen` for the current `scoreId`.
- After a successful save, refresh the Reader's displayed title via
  `scoreInfoForEditing` so the top bar reflects the edit.

## File metaTag prefill

Recommended for v1 with graceful degradation. iOS reads embedded `.mscz`
metaTags on demand (`LiveScoreMetadataReader`) to prefill never-edited credit
fields. The Android store is Swift and already has score-file access, so it can
share the same reading path to populate `scoreInfoForEditing`.

- During planning/implementation, verify `LiveScoreMetadataReader` (and its
  `ScoreFileGateway` parse path) builds for Android. If it does, reuse it.
- If the reader is unavailable on Android for any reason, degrade exactly as iOS
  does on a parse failure: prefill from stored fields only. The feature still
  works; only the convenience prefill is skipped.

## Validation rules (parity)

- Title required (non-empty after trim) — enforced by disabled `SAVE` and the
  `normalized(applyingTo:)` no-op guard.
- All fields trimmed on save.
- Empty string `""` is persisted and meaningful (explicitly cleared); it
  suppresses future file-metaTag prefill for that field.
- No length/format restrictions.

## Testing

- **Domain (Swift Testing):** prefill derivation (stored-wins / nil-fallback /
  empty-suppresses-fallback / subtitle-no-fallback) and normalization
  (trim / title-required / empty-as-`""`). These also lock current iOS behavior.
- **Android store:** `saveScoreInfo` and `scoreInfoForEditing` round-trip;
  Room migration adds the three columns and preserves existing rows.
- **Device (Pixel):** install + launch; exercise both entry points (Library `⋮`
  and Reader info icon), edit/save, discard confirmation, and title-required
  disabling.

## Open items to resolve in the plan

1. Exact Compose package home for `EditScoreInfoScreen` and navigation route
   wiring from both Library and Reader.
2. Whether `ScoreInfoEditing` (protocol) also moves to `Domain` or only the value
   type + functions.
3. Confirm `LiveScoreMetadataReader` Android buildability for the prefill path.
