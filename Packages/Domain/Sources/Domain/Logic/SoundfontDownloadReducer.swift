/// Pure decision logic for the high-quality SoundFont download — the single source of truth shared by the iOS
/// `LiveMuseScoreGeneralProvider` and the Android `MuseScoreGeneralAndroidStore`. No I/O, no Foundation networking;
/// callers supply the facts (file presence, reachability) and apply the verdicts.
public enum SoundfontDownloadReducer {
    /// Next state given the current state and an event.
    public static func nextState(
        _ current: SoundfontDownloadState,
        on event: SoundfontDownloadEvent,
    ) -> SoundfontDownloadState {
        _ = current // state is intentionally unused: every event fully determines the next state
        switch event {
        case .started:
            return .downloading(progress: 0)
        case let .progress(fraction):
            return .downloading(progress: min(1, max(0, fraction)))
        case .finished:
            return .downloaded
        case let .failed(reason):
            return .failed(reason: reason)
        case let .cancelled(fileExists):
            return fileExists ? .downloaded : .idle
        case let .syncedFromDisk(fileExists):
            return fileExists ? .downloaded : .idle
        }
    }

    /// Whether an automatic (Wi-Fi-only) download should begin now. Mirrors the iOS `startDownloadIfNeeded` guards:
    /// opted in, file absent, nothing already in flight, and currently on Wi-Fi.
    public static func shouldAutoStart(
        isOptedIn: Bool,
        fileExists: Bool,
        isDownloading: Bool,
        isWiFi: Bool,
    ) -> Bool {
        isOptedIn && !fileExists && !isDownloading && isWiFi
    }

    /// Whether to auto-retry when Wi-Fi becomes reachable — only when the last attempt failed.
    public static func shouldRetryOnWiFi(_ current: SoundfontDownloadState) -> Bool {
        if case .failed = current { return true }
        return false
    }

    /// Currently-effective preset: high quality only when opted in AND the file is downloaded.
    public static func preset(isOptedIn: Bool, isDownloaded: Bool) -> SoundfontPreset {
        (isOptedIn && isDownloaded) ? .highQuality : .lightweight
    }
}
