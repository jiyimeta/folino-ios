import WireletProvided

/// Kotlin-implemented HTTP transport for the high-quality SF2. The Swift store calls `start`/`cancel`; the Kotlin
/// implementation reports progress and terminal events by calling back into the store's `@WireletExpose`
/// `ingestProgress` / `ingestFinished` / `ingestFailed` methods (no Swift closures cross the bridge).
@WireletProvided
public protocol SoundfontDownloader {
    /// Begin downloading `remoteURL` to `destinationPath`. `allowCellular` chooses the network policy
    /// (false = Wi-Fi only). Must be idempotent if a transfer is already running.
    func start(remoteURL: String, destinationPath: String, allowCellular: Bool)
    /// Cancel any in-flight transfer and remove partial output.
    func cancel()
}

/// Kotlin-implemented reachability. `isWiFi` is a synchronous snapshot; `startObserving` registers a callback that
/// invokes the store's `@WireletExpose onReachabilityChanged(_:)` on every Wi-Fi transition.
@WireletProvided
public protocol SoundfontReachability {
    func isWiFi() -> Bool
    func startObserving()
}

/// Kotlin-implemented persistence + storage location. `loadOptedIn` defaults to `true` on first launch (parity with
/// iOS UserDefaults default). `soundfontsDirectoryPath` is `filesDir/Soundfonts` (created by the Kotlin impl).
@WireletProvided
public protocol SoundfontPrefsStore {
    func loadOptedIn() -> Bool
    func saveOptedIn(value: Bool)
    func soundfontsDirectoryPath() -> String
}
