/// Inputs to `SoundfontDownloadReducer.nextState`. The reducer is the single place that maps a current
/// `SoundfontDownloadState` plus one of these events to the next state, so iOS (`LiveMuseScoreGeneralProvider`)
/// and Android (`MuseScoreGeneralAndroidStore`) share identical transition rules.
public enum SoundfontDownloadEvent: Sendable, Equatable {
    /// A download started (transport accepted the request).
    case started
    /// Progress update; `fraction` is bytes-written / expected, clamped to `[0, 1]`.
    case progress(fraction: Double)
    /// The file finished downloading and is installed on disk.
    case finished
    /// The download attempt failed. `reason` is a localized, displayable string.
    case failed(reason: String)
    /// A download was cancelled (user toggle-off or explicit stop). `fileExists` reflects whether a complete
    /// file nonetheless landed on disk before cancellation propagated.
    case cancelled(fileExists: Bool)
    /// Re-evaluate from disk (e.g. on launch): `fileExists` decides `downloaded` vs `idle`.
    case syncedFromDisk(fileExists: Bool)
}
