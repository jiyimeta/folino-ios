# Android Share Import (iOS Share Extension parity) — Design

Date: 2026-06-09
Status: Approved (design)

## Goal

Bring the iOS Share Extension experience to Android: let a user share score files
into folino from another app (Android share sheet) or open them with folino from a
file manager ("Open with"), choose a destination (Library, an existing playlist, or
a new playlist), optionally open the imported score, and have duplicate detection
behave exactly as it does on iOS.

This is the Android counterpart of `App/ShareExtension/` plus the
`IncomingShareCoordinator` import drain on iOS.

## Parity rules applied

Per `CLAUDE.md`:

- **Logic / behavior → match iOS exactly, and share the code.** The import
  orchestration (accepted file types, playlist-target resolution, duplicate
  handling, open-after) is lifted into shared Domain code that both platforms call.
- **UI / UX placement → Android idioms.** The share target is a dedicated
  translucent activity presenting a Material bottom sheet (file summary +
  destination picker + Save / Save & Open), not a mirror of the iOS extension UI.
  The *content shown* stays at iOS parity; only placement adapts.

## Non-goals

- No App Group / URL-scheme transport (iOS-only mechanisms; Android receives an
  Intent directly in-process).
- No change to iOS share-extension UX or behavior — only an internal refactor to
  delegate its orchestration to the new shared coordinator.
- No new export functionality (this is import only).

## Current state (verified)

**iOS** (`Packages/Features/ImportExport/`):
- `ShareSession` (in `ImportExportShareUI`) stages files into the App Group and
  gates acceptance on a hardcoded extension allow-list: `mscz, mscx, musicxml,
  mxl, xml, midi, mid`.
- `ShareDecision` / `PlaylistChoice` (in `ImportExportShareUI`) model the user's
  destination + open-after choice.
- `IncomingShareCoordinator` (in `ImportExport`) drains staged tokens: resolves the
  playlist target, imports each file via `ScoreFileImporter.prepareImport` /
  `commitImport` (which does SHA-256 content hashing and duplicate detection via
  `ScoreLibraryRepository.scoreItems(matchingContentHash:)`), appends imported IDs
  to the target playlist, and reports an open-after item.

**Android** (`Android/` + `Packages/Features/Library/Sources/FolinoLibraryJNI/`):
- No share/import intent handling exists. `MainActivity` is MAIN/LAUNCHER only.
- Import entry point is `LibraryAndroidStore.importScore(_ path:)` (Swift JNI): it
  parses the `.mscz`, derives display fields via shared `ScorePresentation`, names
  the file `<id>.mscz`, and persists via the Kotlin/Room `LibraryStore`. **No
  duplicate detection** — every import becomes a new row.
- `ScoreRecordWire` / Room `ScoreRecordEntity` carry **no content hash**.
- Playlist operations already exist on the Swift store (`addToPlaylist`,
  `createPlaylistWithScores`, `bulkAddToPlaylist`, etc.) and `playlists` is an
  observable the Compose UI already consumes.

## Architecture

Three layers.

### Layer 1 — Shared import logic (Domain)

The iOS `IncomingShareCoordinator` is coupled to App Group paths, the
`IncomingShareIntent` JSON, and the iOS `ScoreFileImporter` (staging +
security-scoped resources). Those are genuinely platform-specific transports and
stay where they are. What is shared is the **decision algorithm**, extracted behind
small protocols so each platform supplies its own I/O.

New/moved Domain types:

- **`ShareImportPolicy`** — the accepted-extension allow-list and an
  `isAccepted(filename:)` predicate. iOS `ShareSession` and the Android transport
  both use it. (Replaces the hardcoded list in `ShareSession`.)
- **`PlaylistChoice`** and **`ShareDecision`** — moved from `ImportExportShareUI`
  to Domain so both platforms reference the same value types. (iOS call sites update
  their import; behavior unchanged.)
- **`SharedImportCoordinator`** — the platform-agnostic orchestration:
  1. Resolve the playlist target from a `PlaylistChoice` (existing lookup, or
     create-new; on create failure → import nothing and report the failed name,
     matching iOS).
  2. For each staged file: import it; on a detected duplicate, route through an
     optional resolver (confirm) or skip silently when none is wired (iOS parity).
  3. Append imported IDs to the resolved playlist.
  4. Report imported IDs, skipped reasons, the open-after item, and the resolved /
     created playlist info — the existing `DrainResult` shape.

  It depends on injected protocols, not concrete stacks:
  - a **file importer** abstraction (`prepare`/`commit` returning imported vs
    duplicate),
  - a **duplicate finder** (query existing scores by content hash),
  - a **playlist target** abstraction (lookup / create / append).

  iOS adapts its `ScoreFileImporter` + `ScoreLibraryRepository` to these; Android
  adapts its `LibraryStore`-backed store.

The iOS `IncomingShareCoordinator` keeps its public surface (token draining, App
Group I/O, `DrainResult`) but delegates the per-token orchestration to
`SharedImportCoordinator`. Existing `IncomingShareCoordinatorTests` must stay green.

### Layer 2 — Android transport (the "Share Extension equivalent")

- **`ShareTargetActivity`** (new, in the `app` module): a translucent activity that
  presents a Material bottom sheet. Hosted separately from `MainActivity` because
  shares arrive when the app may not be running and should not pollute the launcher
  task / back stack.
- **AndroidManifest intent-filters** on `ShareTargetActivity`:
  - `ACTION_SEND` + `ACTION_SEND_MULTIPLE` (share sheet, single + multi),
  - `ACTION_VIEW` ("Open with", = iOS Document Types).
  - MIME types are broad (`application/octet-stream`, `application/*`,
    `audio/midi`, `text/xml`, `application/xml`) because Android cannot filter
    reliably by extension. **Real acceptance is decided after receipt** by
    `ShareImportPolicy` on the resolved display name — mirroring how iOS receives
    broadly by UTI then gates by extension.
- **Receive flow** in `ShareTargetActivity`:
  1. Collect `content://` URIs (`EXTRA_STREAM` for SEND/SEND_MULTIPLE, `data` for
     VIEW).
  2. Copy each via `ContentResolver` into `cacheDir/IncomingShare/<uuid>/`,
     recovering the original file name from `OpenableColumns.DISPLAY_NAME`.
  3. Classify with `ShareImportPolicy`; surface the unsupported count.
  4. Bottom sheet: file-count summary, destination picker (Library only / existing
     playlist list / new-playlist name field), and Save / Save & Open buttons.
     The existing-playlist list is read from the existing `LibraryAndroidStore`
     `playlists` observable.
  5. On confirm, call a new JNI method (Layer 3); on completion show a brief
     toast/snackbar, and for Save & Open launch `MainActivity` targeting the Reader
     for the last imported score; then `finish()`.

### Layer 3 — Android JNI entry point + duplicate detection

- **`LibraryAndroidStore.importShared(_ paths:[String], _ choice:…, _ openAfter:Bool)`**
  (new `@WireletExpose`): builds the Android adapters for the `SharedImportCoordinator`
  protocols against the Room-backed `LibraryStore`, runs the coordinator, refreshes
  observables, and returns a small result (imported count, last-opened id for
  open-after, created/target playlist info) as a wire type.
- **Content hashing for duplicate detection** (iOS parity):
  - Add `contentHash: String` to `ScoreRecordWire` and to the Room
    `ScoreRecordEntity` (new column), bumping the Room DB version with a migration
    (routine here — the schema has already gone through several). Existing rows get
    an empty hash → treated as "no match", a safe degrade.
  - Compute SHA-256 of file bytes in shared/Swift code. CryptoKit is unavailable on
    the Android Swift toolchain, so the hashing uses a Foundation- or
    swift-crypto-based implementation usable on both platforms (exact dependency
    decided in the plan). The hash is compared only within a single platform's
    library, so cross-platform digest equality is not required — but using the same
    algorithm keeps the code shared.
  - The Android `DuplicateFinder` adapter queries `store.loadAll()` by `contentHash`.
  - Duplicate behavior matches iOS with no resolver wired (MVP): skip the duplicate
    and include the existing item as the open-after candidate.

## Data flow (Android, end to end)

```
Other app / file manager
  → Intent (SEND / SEND_MULTIPLE / VIEW)
  → ShareTargetActivity
      → copy content:// → cacheDir/IncomingShare/<uuid>/<name>
      → ShareImportPolicy.isAccepted(name) classification
      → bottom sheet: pick destination + Save/Save&Open
  → JNI LibraryAndroidStore.importShared(paths, choice, openAfter)
      → SharedImportCoordinator
          → resolve playlist target (existing | create new)
          → per file: hash → DuplicateFinder → import-as-new | skip
          → append imported IDs to playlist
      → refresh observables; return result
  → toast; if Save&Open → launch MainActivity → Reader(lastImported)
  → finish()
```

## Error handling

- **Unreadable / non-score files**: classified unsupported by `ShareImportPolicy`;
  counted and reported, never crash (matches iOS ingest).
- **New-playlist creation fails**: import nothing, report the failed playlist name
  (iOS `IncomingShareCoordinator` parity).
- **Duplicate**: skip silently, surface existing item for open-after (iOS no-resolver
  path).
- **Per-file import failure**: skip that file with a reason; other files proceed.
- **cacheDir copies**: best-effort cleanup of `IncomingShare/<uuid>/` after the
  import returns.

## Testing

- **Domain `SharedImportCoordinator`** (Swift Testing): fake importer / duplicate
  finder / playlist target. Cover destination resolution (library / existing / new),
  open-after selection, duplicate skip, multi-file, and the "new-playlist create
  failure ⇒ import nothing, report name" rule. This is the shared source of truth
  for both platforms.
- **`ShareImportPolicy`** (Swift Testing): extension allow-list classification,
  case-insensitivity, unknown extensions rejected.
- **iOS regression**: `IncomingShareCoordinatorTests` green after the delegation
  refactor.
- **Android**: build, then **install + launch on Pixel** (per Android workflow) and
  manually verify: share single file, share multiple, "Open with", each destination
  option, Save & Open lands in the Reader, duplicate is skipped.

## Risks / call-outs

- **iOS refactor of a shipping feature**: `IncomingShareCoordinator` is delegated to
  the shared coordinator. Mitigated by keeping its public surface and its existing
  tests green.
- **Moving `ShareDecision` / `PlaylistChoice` into Domain** ripples to iOS
  `ImportExportShareUI` import sites (mechanical).
- **Room migration** for the `contentHash` column — verify on a Pixel with an
  existing DB (upgrade path), per the established migration-verification practice.
- **Cross-platform SHA-256**: confirm the chosen hashing dependency builds in the
  Android Swift cross-compile toolchain during the plan/implementation.
