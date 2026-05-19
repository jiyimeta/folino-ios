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

    /// Bool. When true, the device's idle timer is disabled while the Reader is on screen so the display does not dim
    /// or lock during practice. The Reader restores the idle timer when it disappears. Defaults to true at the
    /// `@AppStorage` site for first-launch users.
    public static let keepScreenAwakeEnabled = "readerKeepScreenAwakeEnabled"
}
