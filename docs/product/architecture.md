# Architecture Overview

This document captures the high-level shape of the app: how users navigate it, what entities it stores, and what permissions it needs. Implementation detail is deferred to per-feature plans and to [`../engineering/module-architecture.md`](../engineering/module-architecture.md).

## Information Architecture

Two top-level surfaces (split-view on iPad, tabs on iPhone):

1. **Library** — sortable score list, playlists, tags, search.
2. **Reader** — full-screen view of the active score, with toolbar (mode, zoom, staves, mixer) and the playback transport.

A persistent compact transport is shown above the bottom edge whenever a score is open and audio is queued.

A **Settings** sheet (modal) covers SoundFont management, sync state, default reader preferences, license screens.

## Data Model (High-Level)

- **ScoreItem**: id, title, composer, addedAt, lastOpenedAt, format (mscx / mscz / xml / mxl / midi), localFileURL, sizeBytes, instrumentation summary, lengthBeats, tags[], primaryKey, defaultTempoBpm, isFavorite.
- **ScoreContent**: parsed `SheetMusicCore.Score`; not persisted (re-derived from `localFileURL`), but cached in memory while open.
- **AnnotationLayer**: id, scoreItemId, kind (drawing | text), strokes / textBoxes (each anchored to `(systemIndex, relativeRect)`), updatedAt.
- **Playlist**: id, name, items[(scoreItemId, position)], createdAt.
- **Tag**: id, name, color.
- **PlaybackPreferences**: id, scoreItemId, perStaff[ (staffIndex, volume, isMuted, isSolo, gmBank, gmProgram) ], tempoMultiplier, abRepeat?.
- **SoundfontPatch** (cache record): id (bank, program), localFileURL, sizeBytes, downloadedAt, lastUsedAt.

Scores live as their original files in `Documents/Scores/`. Annotations and prefs live in a SQLite database in `Application Support/`. Both are mirrored to CloudKit (see `privacy-and-accessibility.md`).

## Storage and Sync

- **v1: local-always.** Scores never leave the device's `Documents/Scores/`. CloudKit Private Database stores a `CKAsset` mirror plus metadata so other devices can pull. The local copy is the source of truth; CloudKit is additive.
- **Eviction:** disabled in v1. The app does not opt files into iCloud Drive's optimize-storage model. A future setting (post-v1) may allow opt-in eviction for users who explicitly want it.
- **SoundFont cache:** `Caches/Soundfonts/` — system-evictable directory. Re-downloaded on demand if the OS reclaims space.

## Permissions

Folino is intentionally permission-light:

- **No microphone** — Folino plays audio, it does not record.
- **No location.**
- **No background audio entitlement in v1** — playback stops when the app is backgrounded. (This is a deliberate cut to keep the security review surface small; opt-in background audio is on the roadmap.)
- **CloudKit private** — uses the user's existing Apple ID; no separate sign-in screen.
- **Files** — file picker is invoked on demand for import / export; no persistent file-system permissions are held.
- **Network** — used only to download SoundFont patches from the public release set.

## Localization

Folino ships with `en` and `ja` strings in v1. Development language is `en`. UI strings use Xcode 15+ string catalogs. The engraved score itself is locale-neutral; only chrome (toolbars, settings, library, error messages) is localized.

## Engine Boundary

Folino composes `swift-sheet-music` modules:

| Library | Folino's use |
| --- | --- |
| `SheetMusicCore` | The score data model, re-exported from Folino's Domain. |
| `SheetMusicMSCX` / `SheetMusicMusicXML` / `SheetMusicMIDI` | Format I/O behind a single Domain `ScoreFileGateway` protocol. |
| `SheetMusicLayout` | Layout calculation that drives Folino's Reader. |
| `SheetMusicAudio` | Wrapped by Folino's `PlaybackController` (handles cursor, A–B repeat, mixer state, persistence). |
| `SheetMusicPDF` | Used for the v1 PDF export path. |
| `SheetMusicUI` | Reference; the Folino reader has its own iPad / iPhone view code in `Packages/Features/Reader` because `SheetMusicUI` is currently macOS 15+. Some of the reader work may upstream into a new iOS-capable target inside `swift-sheet-music`. |

When Folino needs an engine capability that does not exist yet (mscz export, MusicXML export, interactive cursor API, free-text mutation API), the work goes upstream to `swift-sheet-music` first and Folino consumes the next tagged version.
