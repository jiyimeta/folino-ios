# Privacy & Accessibility

## Privacy Posture

folino is built to be unremarkable from a privacy perspective: it does very little, so there is very little to leak.

### Data folino holds

- The score files the user imports.
- Annotations (PencilKit drawings, text boxes), playlists, tags, per-score playback preferences.
- A cache of downloaded SoundFont patches.

### Data folino does not hold

- No user account. No email, no name, no identifier collected by folino.
- No microphone, location, contacts, photos, calendar.
- No analytics, no advertising, no behavioral telemetry.
- One third-party SDK: **Firebase Crashlytics**, for crash diagnostics only (see [Crash reporting](#crash-reporting)). No advertising, attribution, or analytics SDKs. Crash collection defaults on and is user-disablable.

### Network use

folino originates two kinds of network traffic. First, HTTPS GET requests to `github.com` and its release CDN to download SoundFont patches from the public release set at `jiyimeta/musescore-general-sf2-split`. Second, when crash reporting is enabled (the default; user-disablable), Firebase Crashlytics uploads crash diagnostics to Firebase (Google) servers over HTTPS — see [Crash reporting](#crash-reporting). CloudKit traffic flows through Apple's infrastructure under the user's Apple ID; folino's developer never sees the data.

### Sync

CloudKit **Private** Database only. All synced records (score assets, annotations, playlists) live in the user's iCloud account. folino's developer cannot read them. Disabling iCloud for folino in Settings stops sync; the local copy is unaffected.

### Deletion

Deleting a score from the library removes:

- The local file in `Documents/Scores/`.
- The CloudKit `CKAsset` and metadata record.
- All annotations, prefs, and playlist entries that reference it.

Cached SoundFonts have an independent delete UI in Settings — they are not user data and are re-downloadable.

### Crash reporting

folino uses **Firebase Crashlytics** to collect crash diagnostics so bugs can be found and fixed. Collection is **on by default** and can be turned off at any time in **Settings → Privacy → "Send crash reports"**; turning it off disables collection for that device.

- **What is collected:** crash stack traces and the standard device/OS diagnostic context Crashlytics captures (device model, OS version, app version, and similar).
- **What is not:** no user account, name, email, or folino-assigned identifier; folino attaches no custom user keys and never calls `setUserID`. Crash data is **not linked to the user's identity** and is **never used for tracking**.
- **Disclosure:** declared in the App Store privacy nutrition label as *Crash Data* (not linked, not tracking) and in the app's privacy manifest.

The `FolinoShareExtension` does not include crash reporting.

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

folino sends no behavioral analytics and runs no advertising or attribution tracking. The signals a developer receives are: App Store sales counts; crash diagnostics via Firebase Crashlytics while the user leaves crash reporting enabled (see [Crash reporting](#crash-reporting)); and any crash reports the user submits through Apple's standard channel. Future analytics, if added, will be opt-in and disclosed in this document.
