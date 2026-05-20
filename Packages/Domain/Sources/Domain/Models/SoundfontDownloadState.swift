import Foundation

/// Lifecycle of the MuseScore_General download. The Settings row reads this for its subtitle; `LiveMuseScoreGeneral-
/// Provider` is the sole writer.
public enum SoundfontDownloadState: Sendable, Equatable {
    /// File is not on disk and no download is in flight. The provider may transition to `downloading` automatically
    /// when the user's toggle is on and Wi-Fi becomes available.
    case idle

    /// A download is in flight. `progress` is in `[0, 1]`; bytes-written / expected-total.
    case downloading(progress: Double)

    /// File is on disk and ready for the audio engine to load.
    case downloaded

    /// The last download attempt failed. `reason` is a localized string suitable for display in Settings. The provider
    /// auto-retries when network becomes reachable again; the user can also tap "Retry".
    case failed(reason: String)
}
