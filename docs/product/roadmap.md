# Roadmap

Phasing notes — not commitments. Each version cuts at a coherent feature boundary so a release can ship without half-built work in tree.

## v1.0 — "Read, hear, mark, save."

The minimum credible product for performing musicians. A scope that fits in a single, focused implementation effort.

- Reader: vertical scroll + page mode, page-turn taps and swipes, pinch viewport zoom, content zoom buttons, staff visibility, cursor highlight.
- Playback: per-staff volume / mute / solo / GM instrument, tap-to-cursor, A–B repeat, metronome, tempo 50–200 %.
- Annotations: PencilKit free-hand + system text boxes, both anchored to musical coordinates.
- Editing: System Text and Staff Text only.
- Library: list with sort orders, manual playlists, tags.
- Import: mscx, mscz, MusicXML, mxl, MIDI.
- Export: mscx, mscz, MIDI, PDF.
- SoundFonts: bundled Electric Piano 1 + downsampled Standard Drum Kit; on-demand download for everything else; full cache management UI.
- Sync: CloudKit Private Database. Local-always.

## v1.x — Quality and breadth, no new pillars

- Reader polish: cursor animation curves, system-relative annotation reflow under content zoom (if O3 in `feasibility.md` requires deferred-reflow).
- Library: smart playlists, folders.
- A–B repeat refinements: count-in, looped tempo ramping for practice mode.
- Background-audio entitlement (opt-in).

## v2.0 — Beyond structured scores

- **PDF import.** A second score type alongside structured (mscz / xml / midi) scores. PDFs render as PDF, drawn on top with the same annotation layer. No score → PDF conversion, no OMR.
- **MusicXML export.**
- **AirPlay / multi-screen** for mirroring the reader to a music stand display while keeping the transport on the iPad.
- **Storage optimization setting.** Opt-in iCloud-Drive-style eviction for users who want it.

## v2.x — Editing widens

- Lyrics editing.
- Chord-symbol editing.
- Dynamics, tempo markings, rehearsal marks.
- Note pitch transposition (one-note-at-a-time).

## v3+

- iPhone-only convenience features (lock-screen Now Playing, mini-player widget).
- Mac Catalyst.
- Cross-device session: live-share a reader view with another folino device for ensemble rehearsal.
- Note add / delete / duration changes — only after the underlying engine has a stable mutation API and undo model.
