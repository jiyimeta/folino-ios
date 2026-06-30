import Foundation

/// How the Reader lays out the score in the viewport.
///
/// `.vertical` wraps systems to fit the view width and scrolls vertically; `.horizontal` lays the score out at its
/// natural width as one long row that scrolls horizontally; `.page` paginates wrapped systems by viewport height and
/// shows one page at a time.
public enum ReaderLayoutMode: String, CaseIterable, Sendable, Hashable {
    case vertical
    case horizontal
    case page
}

/// `@AppStorage` keys for Reader settings that persist across sessions and apply to every score. Co-located with
/// `ReaderLayoutMode` so the raw strings are not duplicated as literals across packages.
public enum ReaderGlobalSettingsKey {
    /// Bool. Preserved verbatim from the pre-refactor key so existing user state survives the refactor — do not rename.
    public static let metronomeEnabled = "readerMetronomeEnabled"

    /// `ReaderLayoutMode.rawValue` (String).
    public static let layoutMode = "readerLayoutMode"

    /// Bool. When true, the Reader auto-presents a Picture-in-Picture window of the score whenever the app backgrounds,
    /// and tears it down on return to the foreground. When false, PiP is never shown automatically.
    public static let pictureInPictureEnabled = "readerPictureInPictureEnabled"

    /// Bool. When true, runs of two or more consecutive empty-rest measures render as a single H-bar with a count,
    /// using `MultiMeasureRestPolicy.collapse`. When false, measures render individually.
    public static let collapseMultiMeasureRests = "readerCollapseMultiMeasureRests"

    /// Bool. When true, elements authored as invisible (`visible == false`) are still laid out and drawn greyed
    /// (~50% opacity) via `ScoreViewOptions.showsInvisibleElements`. When false (the default), they are dropped
    /// entirely — matching print behavior.
    public static let showInvisibleElements = "readerShowInvisibleElements"

    /// Bool. When true, the device's idle timer is disabled while the Reader is on screen so the display does not dim
    /// or lock during practice. The Reader restores the idle timer when it disappears. Defaults to true at the
    /// `@AppStorage` site for first-launch users.
    public static let keepScreenAwakeEnabled = "readerKeepScreenAwakeEnabled"

    /// Bool. `true` once the user has touched any page-mode tap-navigation zone for the first time. Drives the
    /// onboarding hint in `PagedScoreContainer.TapOverlay`. Defaults to `false`; once flipped, stays true for the
    /// install lifetime.
    public static let pageTapHintDismissed = "readerPageTapHintDismissed"

    /// Bool. When true, the Reader's bottom transport control shows a full-width time-based seek bar.
    /// Defaults to `true` at the `@AppStorage` site. When false, only the compact transport pill shows.
    public static let showSeekBarEnabled = "readerShowSeekBarEnabled"

    /// `PlaylistContinuationMode.rawValue` (String). Global, sticky. Governs whether finishing a score that was opened
    /// from a playlist advances to the next score. Defaults to `PlaylistContinuationMode.playThrough` at each
    /// `@AppStorage` site. Has no effect when the Reader was opened standalone or when a per-score repeat is active.
    public static let playlistContinuationMode = "readerPlaylistContinuationMode"

    /// `RepeatMode.rawValue` (String). Global, sticky — one repeat mode shared by every score (mirrors how
    /// `playlistContinuationMode` works). Defaults to `RepeatMode.off`. Only the *mode* is global; the A–B loop's
    /// actual measure endpoints stay per-score in `ReaderPreferences.abRepeat`. Edited from both the Reader playback
    /// inspector and Settings.
    public static let repeatMode = "readerRepeatMode"

    /// Double. Global A4 reference frequency in Hz, applied to all scores unless a per-score override is set in
    /// `ReaderPreferences.a4ReferenceHz`. Clamped to `[A4Reference.minHz, A4Reference.maxHz]`. Defaults to
    /// `A4Reference.standardHz` (440 Hz) when absent. Key used by both `@AppStorage` (Settings UI, future) and
    /// `UserDefaults.standard` (PlaybackPreferences builder, no-View context).
    public static let a4ReferenceHz = "reader.a4ReferenceHz"

    /// Bool. When true (the default at each `@AppStorage` site), the Reader follows the playhead during playback —
    /// auto-scroll in `.vertical` / `.horizontal`, auto-page-turn in `.page`. When false, continuous playback no
    /// longer moves the score; manual navigation (tap-seek, measure-step, scrub) still keeps its target in view.
    /// Applies to parsed PDFs too (auto-scroll / auto-page-turn over the original PDF) once OMR makes them playable.
    public static let autoFollowEnabled = "readerAutoFollowEnabled"

    /// Bool. `true` once the user chose "Don't show again" on the PDF-playback caveat dialog, suppressing its
    /// automatic presentation thereafter. Defaults to `false`; the caveat stays reachable any time via the PDF badge.
    public static let pdfPlaybackNoticeDismissed = "readerPdfPlaybackNoticeDismissed"

    /// Bool. When true (the default at each `@AppStorage` site), the `.page`-mode tap-zone navigation overlay
    /// (`TapOverlay`) is shown. When false it is hidden; swipe-to-turn and auto-page-turn still work. Read by the
    /// shared `PagedReaderSurface`, so it applies to both the score and PDF paged readers.
    public static let pageTurnButtonsVisible = "readerPageTurnButtonsVisible"
}
