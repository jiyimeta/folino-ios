# Technical Feasibility & Open Questions

This is the living list of decisions where the cost / risk warrants written justification, and of items that still need empirical validation before locking in.

## Decided

### D1. Engine is `swift-sheet-music`, no third-party notation library

The notation engine, format I/O, layout, audio, and PDF export are all owned by `swift-sheet-music` (jiyimeta/swift-sheet-music). No web-based renderer, no C++ notation engine, no GPL dependency. This keeps folino fully native (Liquid Glass, Apple Pencil, Core Animation) and the licensing model simple.

The cost of this decision is that anything missing in `swift-sheet-music` becomes folino's responsibility too. See **D2**.

### D2. "Generic in `swift-sheet-music`, specific in folino"

The boundary rule for new work:

- **Upstream to `swift-sheet-music`** — anything any score app would want: format read / write, layout math, audio engine features, score model mutation primitives, an iOS-capable view target.
- **Inside folino** — anything bound to folino's UX, sync model, library, settings: page-turn gestures, PencilKit overlay, library DB, CloudKit sync, SoundFont cache UI, settings screen.

In practice that means the v1 implementation will likely require upstream PRs for at least: `.mscz` write, MusicXML write, an interactive cursor + A–B-repeat API on `PlaybackEngine`, and a `Score` mutation API for system-text / staff-text edits.

### D3. Annotations anchor to musical coordinates

PencilKit strokes and text boxes are stored as `(systemIndex, relativeRect)` in the score's layout space, not as absolute page coordinates. This is more engineering than the page-coordinate approach but makes the conflict between drawing and content zoom go away by design — strokes follow systems through reflow. Pinch zoom (viewport) is always free.

### D4. CloudKit Private Database, never iCloud Drive

Scores live in `Documents/Scores/`, never in `~/iCloud Drive/`. Sync is via CloudKit Private DB with `CKAsset` and a per-record metadata blob. The local copy is the source of truth and the OS cannot evict it.

The cost: folino does not appear in the Files app sidebar. Import / export is via the file picker and share sheet, which is acceptable for v1 and matches the "library lives inside folino" mental model.

A v2 setting may let users opt into iCloud Drive-style eviction for storage-constrained devices; that flow is not specified yet.

### D5. SoundFont strategy — bundled minimum + lazy split download

- Bundled in the app: Electric Piano 1 (`000_004.sf2`, ~1.6 MB) and a downsampled Standard Drum Kit derived from `128_000.sf2` (target ~1.5–2 MB). Combined ~3–4 MB.
- All other (bank, program) patches: downloaded on demand from the public release set at `jiyimeta/musescore-general-sf2-split` and cached in `Caches/Soundfonts/`.
- Cache management UI is part of v1 (see `features.md`).
- The downsampled drum kit `128_000_lite.sf2` is produced once in `musescore-general-sf2-split` (Polyphone: 22.05 kHz, fewer velocity layers) and shipped as a release asset alongside the full set. License chain stays MIT.

### D6. SoundFont licensing

`musescore-general-sf2-split` is MIT, derived from MuseScore_General which is also MIT (Frank Wen, Michael Cowgill, S. Christian Collins, et al.). No copyleft viral concern; folino must surface the MIT notice in the in-app license screen (`LicenseListView` from `LicenseList`, with a manually-added entry for the bundled and downloaded SoundFonts).

### D7. iPad and iPhone, iOS 26+

Universal app, `TARGETED_DEVICE_FAMILY: 1,2`. iOS 26+ deployment target unlocks Liquid Glass, current PencilKit, and the latest Swift Concurrency. Apple Pencil is iPad-only by hardware; the rest of the app is fully usable on iPhone. The Reader has size-class-aware layout (split toolbar on iPad, compact toolbar on iPhone).

## Open — to validate during implementation

### O1. `AVAudioUnitSampler` default behavior on iOS

If a score uses an instrument whose patch has not been downloaded and the bundled fallback path fails, folino currently shows silence + a notice. **To verify** whether `AVAudioUnitSampler` initialized without an explicit sound bank still emits audio on iOS 26 (legacy `DLSMusicDevice` fallback). If it does, we can soften the failure mode for missing patches; if not, the bundled Electric Piano fallback is the floor.

### O2. mscz round-trip fidelity

`SheetMusicMSCX` currently parses `.mscx` and reads `.mscz` (zipped). Round-tripping a `.mscz` (read → mutate text → write) must preserve all elements folino did not touch. The upstream PR for `.mscz` write needs a regression suite of round-trip tests on a corpus of public-domain scores.

### O3. PencilKit + score reflow performance

When a user changes content zoom on a score with hundreds of strokes, every stroke must be repositioned and redrawn. `PKDrawing` is lightweight per-stroke, but the worst case (full-orchestra rehearsal mark-up) needs to be measured on the lowest target hardware (iPad 10th gen baseline, iPhone 14). If unacceptable, the fallback is to defer reflow until the user finishes the gesture.

### O4. CloudKit asset size limits

`CKAsset` per-record size is generally large enough for any structured score, but a heavily-edited PDF (post-v1) can be >50 MB. The asset chunking strategy for v2 PDF support is not yet decided.

### O5. swift-sheet-music iOS view target

`SheetMusicUI` is currently macOS 15+. folino needs an iOS-capable equivalent. Two paths:

- **A.** folino implements its own reader views directly on `SheetMusicLayout`.
- **B.** folino contributes a new `SheetMusicUIiOS` (or platform-conditionalized `SheetMusicUI`) target upstream.

**A** is faster to ship. **B** is the long-term-correct shape. Plan to start with **A** and refactor to **B** once the reader's iPad behavior is stable.

## Rejected

- **Web-based renderer in `WKWebView`** — incompatible with native gestures, Liquid Glass, and PencilKit overlay.
- **GPL notation engines** — incompatible with App Store distribution as a paid / proprietary app, and would force the entire app to be GPL.
- **iCloud Drive (FileProvider) as the storage backend** — OS-controlled eviction violates the always-available principle.
- **Bundling the full MuseScore_General SoundFont** — IPA size cost is not justified given lazy-download is fast and the cache is user-managed.
