# Privacy & Accessibility

## Privacy Posture

Folino is built to be unremarkable from a privacy perspective: it does very little, so there is very little to leak.

### Data Folino holds

- The score files the user imports.
- Annotations (PencilKit drawings, text boxes), playlists, tags, per-score playback preferences.
- A cache of downloaded SoundFont patches.

### Data Folino does not hold

- No user account. No email, no name, no identifier collected by Folino.
- No microphone, location, contacts, photos, calendar.
- No analytics, no telemetry, no crash reporting beyond Apple's opt-in `MetricKit`.
- No third-party SDKs in the v1 binary.

### Network use

The only network traffic Folino originates is HTTPS GET requests to `github.com` and its release CDN to download SoundFont patches from the public release set at `jiyimeta/musescore-general-sf2-split`. CloudKit traffic flows through Apple's infrastructure under the user's Apple ID; Folino's developer never sees the data.

### Sync

CloudKit **Private** Database only. All synced records (score assets, annotations, playlists) live in the user's iCloud account. Folino's developer cannot read them. Disabling iCloud for Folino in Settings stops sync; the local copy is unaffected.

### Deletion

Deleting a score from the library removes:

- The local file in `Documents/Scores/`.
- The CloudKit `CKAsset` and metadata record.
- All annotations, prefs, and playlist entries that reference it.

Cached SoundFonts have an independent delete UI in Settings — they are not user data and are re-downloadable.

## Accessibility Commitments

### v1

- **VoiceOver labels** for every reader control and library row.
- **Dynamic Type** in all text outside the engraved score (library titles, settings, annotation text boxes).
- **Reduced Motion** respected: cursor and page-turn animations switch to crossfades.
- **Increased Contrast** respected: cursor highlight, A / B markers, and selection states use the high-contrast palette.
- **Hardware keyboard** focus chain through the library and reader; basic shortcuts for play / pause, prev / next system, prev / next score.

### Score-content accessibility (limits)

The engraved score itself is rendered as a vector view, not as accessible text. v1 ships with a single `accessibilityLabel` summarizing the score (title, composer, instrumentation, length) and per-system labels of "Measures N–M". Per-note accessibility (reading a chord aloud) is on the long-term roadmap and depends on `swift-sheet-music` exposing a structured accessibility tree.

## Telemetry & Updates

Folino does not phone home. The only signal a developer receives is App Store sales counts and any user-submitted crash reports via Apple's standard channel. Future analytics, if added, will be opt-in, on-device-only by default, and disclosed in this document.
