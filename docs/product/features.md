# Core Features

Each section calls out the **v1 cut** when relevant. Anything not marked is in v1.

## Reading

- **Two modes:** vertical scroll and page mode. Toggle from the reader toolbar.
- **Page turning** (page mode):
  - Tap the left / right ~25% of the screen to flip back / forward.
  - Edge-to-center swipe to flip back / forward.
  - Center tap toggles the reader chrome.
- **Pinch zoom** is a viewport zoom: it never reflows the score. Always available, no upper bound aside from rendering quality.
- **Content zoom** (toolbar buttons): changes engraved staff size and re-runs layout. Affects line breaks and page count. Independent of pinch.
- **Staff visibility:** per-staff toggle from the side panel. Hidden staves are dropped from layout for the current view; their playback is unaffected unless also muted (see Playback).
- **Cursor:** when playback is active, a highlight follows the current chord. Tap any chord to move the cursor without starting playback.

## Playback

Audio engine is `SheetMusicAudio` (`AVAudioEngine` + per-staff `AVAudioUnitSampler`). All playback features below operate at the staff level.

- **Per-staff volume** slider, **mute**, **solo**.
- **Per-staff instrument:** General MIDI (bank, program). Picker presents the standard GM list; selection persists per score.
- **Tap-to-play:** tap a chord to set the cursor, then tap play. Cursor is interactive whether playing or paused.
- **A–B repeat:** long-press on a chord to drop the **A** marker, long-press on a later chord to drop the **B** marker. Loop runs until canceled. Both markers are visible on the score and can be dragged to adjust.
- **Metronome:** on / off. Click sound is a separate sampler so it never competes with the score's own percussion.
- **Tempo:** 50 % – 200 % of the score's notated tempo. Pitch is preserved.

## Annotations

Two layers, both anchored to musical coordinates (system index + relative offset within the system) so they survive reflow, staff toggling, and content zoom.

- **Free-hand drawing** via `PKCanvasView`. Apple Pencil on iPad is the primary input; finger drawing is supported on both iPad and iPhone with reduced precision. Standard PencilKit tool palette — Folino does not skin or replace it.
- **Text boxes** using the system text input (software / hardware keyboard). Tap-and-hold to place, drag to move. Standard iOS text editing menu.

Annotations are erased / edited per stroke or per box. They are independent of the score data: deleting a score file deletes its annotations; opening a score on another device shows the same annotations in the same musical positions.

## Editing

The v1 edit surface is intentionally narrow: **System Text** and **Staff Text** only — the two free-text element types in the underlying score model. They have no fixed musical meaning, which makes them safe to edit without touching layout or playback math.

- Out of v1: lyrics, chord symbols, dynamics, tempo markings, notes (pitch / duration / addition / deletion), key / time signature, voicing.
- See [roadmap.md](./roadmap.md) for when other element types open up.

## Library

- **Sort orders:** name, date added, last opened, composer, key, time signature.
- **Manual playlists.** Smart playlists are post-v1.
- **Tags** for grouping when playlists are too heavyweight; folders are post-v1.
- Library entries show: title, composer, primary instrumentation, length, last opened, annotation indicator.

## Import / Export

| Format | v1 import | v1 export |
| --- | --- | --- |
| `.mscx` | ✓ | ✓ |
| `.mscz` | ✓ | ✓ |
| MusicXML / `.mxl` | ✓ | post-v1 |
| MIDI (SMF) | ✓ | ✓ |
| PDF | post-v1 | ✓ |

Import goes through the system file picker (`UIDocumentPickerViewController`) and the share-sheet "Open in Folino" handler. Export goes through the share sheet.

## SoundFont Management

Audio for any (bank, program) is supplied by SoundFont 2 files. Folino's `SoundfontResolver` looks up patches in this order:

1. **Bundled** — Electric Piano 1 (bank 0, program 4) and a downsampled Standard Drum Kit (bank 128, program 0). Combined size target ~3–4 MB. Used as the offline melodic / drum fallback.
2. **Cached download** — `.sf2` files previously downloaded into the app's `Caches/Soundfonts/`.
3. **Remote download** — fetched on demand from the public release set at `jiyimeta/musescore-general-sf2-split` and stored into the cache. Only the (bank, program) actually required by an open score are fetched.

If a download fails (offline, missing patch), Folino falls back to the bundled patch and shows a non-blocking notice — the score still plays.

A **SoundFont** screen in Settings shows:

- Bundled patches (cannot be deleted).
- Each cached patch with size and last-used date.
- Total cache size.
- Per-patch delete, "delete unused", and "delete all" actions.
