import Foundation

/// How the Reader lays out the score in the viewport.
///
/// `.vertical` wraps systems to fit the view width and scrolls vertically;
/// `.horizontal` lays the score out at its natural width as one long row
/// that scrolls horizontally.
public enum ReaderLayoutMode: String, CaseIterable, Sendable, Hashable {
    case vertical
    case horizontal
}

/// `@AppStorage` keys for Reader settings that persist across sessions
/// and apply to every score. Co-located with `ReaderLayoutMode` so the
/// raw strings are not duplicated as literals across packages.
public enum ReaderGlobalSettingsKey {
    /// Bool. Preserved verbatim from the pre-refactor key so existing
    /// user state survives the refactor — do not rename.
    public static let metronomeEnabled = "readerMetronomeEnabled"

    /// `ReaderLayoutMode.rawValue` (String).
    public static let layoutMode = "readerLayoutMode"
}
