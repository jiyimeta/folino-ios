# Library Android Recently Deleted — design

**Status**: Spec (brainstorming complete, awaiting plan)
**Date**: 2026-06-02
**Author**: Kiichi Ito (with Claude)
**Branch**: `android-library-recently-deleted` (cut from local `main`)
**Builds on**: [Library Android persistence](./2026-06-02-library-android-persistence-design.md), [Library Android pilot](./2026-06-01-library-android-pilot-design.md)

## Purpose

Give the Android Library a **Recently Deleted (Trash)** screen so a soft-deleted
score can be recovered after the Undo snackbar's window expires, and can be
**permanently** removed (record + file) when the user is sure. This completes the
delete loop the persistence slice started: soft-delete already stamps
`deletedAt` and **keeps the file** — but until now there was no surface that
showed deleted rows or removed them for good.

The persistence slice (merge `2156952`) deliberately left this for a follow-up:
the `deletedAt` timestamp and the backend `removeFile(localFileName:)` primitive
are **already in place** as deliberate groundwork, but the `LibraryStore`
backend has no way to delete a *record* and the Swift store exposes no deleted
list and no permanent-delete operation. This work fills exactly those gaps and
adds the Compose UI.

Scope **includes bulk selection** (multi-select restore / permanent-delete),
matching the iOS Recently Deleted screen.

## Guiding principle (from CLAUDE.md "iOS / Android parity")

- **Logic / behavior → match iOS exactly, and share the code.** The Trash rules
  — what counts as deleted (`deletedAt > 0`), the sort order
  (most-recently-trashed first), what "restore" and "permanent delete" do — live
  in the **shared Swift** `LibraryAndroidStore`, mirroring iOS
  `RecentlyDeletedViewModel` / `LibraryViewModel`. Kotlin gains only one new
  rule-free primitive (delete a record by id).
- **Android-only code is the minimum that can only be done on Android**: the Room
  DELETE query, the Compose Trash screen, the JNI wire methods.
- **UI/UX placement follows Android idioms.** Entry via an **overflow menu**, not
  an iOS-style in-list menu; permanent-delete confirmation via **AlertDialog**,
  not an iOS popover; bulk via the Material **Contextual Action Bar (CAB)**
  pattern (long-press to enter selection), not iOS `EditMode` + bottom bar. Only
  the *content* keeps iOS parity.

## How this maps to the iOS implementation (parity reference)

| iOS concern | iOS implementation | Android equivalent in this design |
|---|---|---|
| Deleted-list source | `repository.deletedScoreItems` | new Swift observable `deletedScores: [ScoreRowWire]` |
| Sort order | `RecentlyDeletedViewModel`: `deletedAt` **descending** | same — sorted **in Swift** before projecting to the wire type |
| Restore | `repository.restoreScoreItem(id:)` → clears `deletedAt` | existing `restore(_ id:)` (clears `deletedAt`); bulk = `restoreMany(_ ids:)` |
| Permanent delete | `repository.permanentlyDeleteScoreItem(id:)` → removes record + file | new `permanentlyDelete(_ id:)`: `removeFile` + `deleteRecord`; bulk = `permanentlyDeleteMany(_ ids:)` |
| Bulk = loop | `bulkRestore` / `bulkPermanentlyDelete` loop over single ops | same loop, **in Swift**, with a **single** reload at the end |
| Confirm before hard delete | popover confirm (`PermanentDeletePopover`) | Material **AlertDialog** |
| 30-day auto-purge | not implemented on iOS either ("purge/30日は未") | **out of scope** (parity: neither side has it) |

## Architecture

```
 Compose LibraryScreen ──overflow menu──▶ RecentlyDeletedScreen
                                              │  vm.deletedScores (StateFlow)
                                              │  vm.restore(id) / vm.restoreMany(ids)
                                              │  vm.permanentlyDelete(id) / vm.permanentlyDeleteMany(ids)
                                              ▼
 LibraryAndroidStore  (Swift, @WireletObservable @Observable)   ← ALL business logic
   - scores: [ScoreRowWire]          (live; deletedAt <= 0)
   - deletedScores: [ScoreRowWire]   (deletedAt > 0, sorted desc)   ← NEW
   - permanentlyDelete / restoreMany / permanentlyDeleteMany        ← NEW @WireletExpose
        │  store.removeFile(localFileName) ; store.deleteRecord(id)
        ▼
 LibraryStore  (@WireletProvided protocol; Kotlin RoomLibraryStore)  ← rule-free backend
   - deleteRecord(id:)   ← NEW (Room DELETE)
   - removeFile(localFileName:)   (already present)
```

Same shape as the persistence slice: every decision stays in the Swift store; the
Kotlin backend only persists/removes what it is told to.

## Components

### 1. Backend protocol — `LibraryStore` (Swift declaration, Kotlin impl)

Add **one** method to the `@WireletProvided protocol LibraryStore`:

```swift
/// Permanently remove a persisted row by id. Pairs with `removeFile` for a
/// full purge; the Swift store calls both. Soft-delete does NOT call this.
func deleteRecord(id: String)
```

Kotlin `RoomLibraryStore` / `ScoreRecordDao`:

```kotlin
@Query("DELETE FROM score_records WHERE id = :id")
fun delete(id: String)
```

`removeFile(localFileName:)` already exists and already deletes the managed file.
This is an Android-only `@WireletProvided` protocol in `FolinoLibraryJNI` — it is
**not** the iOS-facing Domain `ScoreLibraryRepository`, so adding a method does
not ripple across iOS Features. Regenerating the wirelet bridge picks up the new
method (Kotlin `NativeAdapter` + Swift proxy).

### 2. Swift store — `LibraryAndroidStore`

- **New observable**: `public var deletedScores: [ScoreRowWire] = []` (second
  `StateFlow` on the Kotlin side — multiple observable props are already
  supported, as in the Settings spike).
- **`reload(using:)` updates both lists** from one `loadAll()` snapshot:
  - `scores` = records with `deletedAt <= 0`, projected (unchanged behavior).
  - `deletedScores` = records with `deletedAt > 0`, **sorted by `deletedAt`
    descending**, then projected. `ScoreRowWire` carries no `deletedAt`, but the
    sort happens in Swift *before* projection, so the wire type is unchanged and
    the Kotlin list arrives pre-sorted.
- **`@WireletExpose func permanentlyDelete(_ id: String)`**: find the record in
  `loadAll()`; if found, `store.removeFile(localFileName:)` then
  `store.deleteRecord(id:)`; reload. Missing id is a no-op (no crash).
- **`@WireletExpose func restoreMany(_ ids: [String])`** and
  **`@WireletExpose func permanentlyDeleteMany(_ ids: [String])`**: loop the
  single-item logic over `ids`, then reload **once** (avoids N `StateFlow`
  emissions and N `loadAll()` reads). `[String]` is a supported wire arg
  (Array of primitive). Existing single `restore(_ id:)` is reused for the
  single-row restore action.

### 3. Compose UI

**Entry point** — on the existing `LibraryScreen` top app bar, add an
**overflow (3-dot) menu** with a "Recently Deleted" item that navigates to the
Trash screen. (The gear Settings action stays as a direct app-bar icon.)

**`RecentlyDeletedScreen`** — consumes `vm.deletedScores` (already sorted).

*Normal mode:*
- Row tap → `ReaderStub` (same as the main list).
- **Leading swipe (start→end) = Restore** — safe/reversible, so swipe is
  appropriate here (Android idiom: swipe is for reversible actions).
- Row **overflow (3-dot) menu**: **Restore** and **Delete permanently**.
  - Permanent delete is **irreversible**, so it does **not** get a swipe (can't
    pair with Undo). It opens an **AlertDialog** confirm
    (`Permanently delete "<title>"?`).
- Empty state when `deletedScores` is empty.

*Selection mode (bulk)* — Material **CAB** pattern:
- **Long-press a row** enters selection mode; rows show a checkbox / selected
  highlight; tap toggles selection.
- The top app bar becomes a **contextual bar**: selected count + **Restore** +
  **Delete permanently** (→ `Permanently delete N scores?` AlertDialog) + an
  **✕** to exit selection mode.
- Restore → `vm.restoreMany(selectedIds)`; permanent → after confirm,
  `vm.permanentlyDeleteMany(selectedIds)`; both exit selection mode.

### 4. Localization

English-only for now (consistent with the rest of the Android port). New
`strings.xml` keys: recently-deleted title, restore, delete-permanently, the two
confirm-dialog titles/messages, empty-state.

## Data flow / edge cases

- **Restore from Trash**: `deletedAt` cleared → the row leaves `deletedScores`
  and reappears in `scores` (main list) on the next reload — both StateFlows
  update from the single reload.
- **Permanent delete**: file removed *then* record removed; row leaves
  `deletedScores`. If the file is already gone, `removeFile` is a no-op delete
  (Kotlin `File.delete()` returns false silently) — acceptable.
- **Empty selection**: bulk actions with an empty set are no-ops; the contextual
  bar's actions are disabled when count is 0 (or selection mode isn't entered).
- **No auto-purge**: deleted rows live indefinitely until the user restores or
  permanently deletes (iOS parity — neither platform purges yet).

## Testing

**Swift host tests** (`FolinoLibraryJNITests`, extend `LibraryAndroidStoreTests`
with the existing in-memory fake `LibraryStore`):
- `deletedScores` contains only `deletedAt > 0` rows, **sorted descending** by
  deletion time; `scores` contains only live rows (mutually exclusive).
- `delete(id)` then it appears in `deletedScores`, gone from `scores`.
- `restore(id)` moves it back; `restoreMany` restores all given ids in one pass.
- `permanentlyDelete(id)` calls `removeFile(localFileName)` **and**
  `deleteRecord(id)`, and the row leaves both lists; missing id is a no-op.
- `permanentlyDeleteMany` purges all given ids; the fake records both
  `removeFile` and `deleteRecord` calls.

The fake `LibraryStore` gains a `deleteRecord` impl (drop from its in-memory
array) and call-tracking for `deleteRecord` / `removeFile`.

**Kotlin / device**: build the two `.so`s (codegen → cross-compile, verify
`JNI_OnLoad`), `:app:installDebug`, launch on the Pixel 8a, and manually verify:
import → delete (snackbar) → open overflow → Recently Deleted → row present →
swipe-restore returns it to the main list → re-delete → permanent-delete via menu
→ confirm → gone → long-press → multi-select → bulk restore / bulk permanent
delete. Confirm survival across an app restart.

## Out of scope (future slices)

- **Empty Trash** (one-tap purge-all) and **30-day auto-purge** (neither exists
  on iOS yet).
- Search / sort / favorites / playlists / tags / share / Edit Info.
- Real Reader (rendering + audio).
- Localized strings beyond English.

## Risks / notes

- **Bridge regen ordering** (from the persistence slice): Gradle codegen → Swift
  cross-compile → assemble, or the `.so` lacks `JNI_OnLoad`
  (`UnsatisfiedLinkError`). Adding a `@WireletProvided` method and a second
  `@WireletObservable` prop both go through this path.
- **`allowMainThreadQueries()`** remains (pilot-accepted); the Trash list is tiny.
  Background write-through is still a separate follow-up.
- Adding a method to the `@WireletProvided` protocol exercises the bridge's
  Kotlin-supplied-method path again — already proven by `loadAll`/`upsert`/
  `copyImportedFile`/`removeFile`, so low risk.
