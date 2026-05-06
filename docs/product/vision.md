# Vision, Design Principles, and Target Users

## Vision

A score viewer and player for performing musicians: rich enough to replace dedicated notation apps for **reading and playback**, focused enough to feel as quick and obvious as a built-in iOS app. folino does not try to be a composition or engraving tool — it is the app you open on the music stand.

Product line: **"Open it on stage. Hear it. Mark it up. Move on."**

## Design Principles

1. **Reading first, everything else second.** The score must render fast, scroll smoothly, and turn pages with confidence. No modal in the path between launch and a playable score.
2. **Native iOS feel.** Stock gestures, stock text input, system canvas (PencilKit). No invented UI where an iOS-native equivalent exists. Liquid Glass, animation, and Apple Pencil behavior match the rest of the OS.
3. **No extra knobs.** folino refuses the engraving feature surface — no new-score wizards, no part extraction, no chord builders, no collaboration. Every feature must justify itself against "does this help a player read or rehearse?".
4. **Always available.** A score that has been opened once must open again with no network. The library lives on the device by default; cloud sync is additive, never a precondition.
5. **Annotations belong to music, not pages.** Pencil strokes and text boxes anchor to musical coordinates so they survive content reflow, staff visibility changes, and content zoom.

## Target Users

- **Performing musicians** carrying rehearsal scores on iPad, swapping between instruments and parts.
- **Ensemble players** who want per-staff mute / solo to practice their own line.
- **Students** working through études with section-loop and tempo control.
- **Hobbyists** ear-copying with MIDI files and listening back to their work.
- **Score readers on iPhone** who occasionally want to glance at a piece on the train rather than carry an iPad.

## Non-Users (Explicitly)

- People composing or engraving from scratch — folino does not write notes.
- Collaboration / sharing platforms — there is no folino account, no cloud library beyond the user's own iCloud.
- Sight-reading PDF-only users without any structured score files — supported in v2 via PDF, not v1.
