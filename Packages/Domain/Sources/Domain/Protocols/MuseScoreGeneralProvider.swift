import Foundation
import Observation

/// Owns the high-quality preset opt-out toggle, file presence, and download lifecycle. The audio resolver and the
/// Settings row both consume this protocol; only the live infrastructure implementation mutates state.
///
/// `@MainActor` + `Observable` so the Settings row can drive its UI via `@Bindable` without a separate
/// `@State`-mirror layer — every property change emits an observation event and the view re-renders. The two accessors
/// reached from the audio thread are marked `nonisolated` so the engine never has to hop to the main actor.
@MainActor
public protocol MuseScoreGeneralProvider: AnyObject, Observable, Sendable {
    /// User toggle. Defaults to `true` on first launch (auto-download by default; opt-out via Settings). Flipping it
    /// via `setOptedIn(_:)`: cancels any in-flight download; if the file is on disk, deletes it.
    var isOptedIn: Bool { get }

    /// `true` iff the high-quality preset file is currently on disk and readable. Derived from `downloadState` so
    /// observers see the same transition the download state machine reports.
    var isDownloaded: Bool { get }

    /// File system URL of the downloaded preset, or `nil` if absent. `GMSoundfontResolver` consults this every time the
    /// engine asks for `defaultGMSoundfontURL` via the `nonisolated` sync variant; this main-actor accessor exists for
    /// UI / debugging surfaces that already run on the main actor.
    var museScoreGeneralFileURL: URL? { get }

    /// Currently-effective preset, derived from `(isOptedIn, isDownloaded)`: `highQuality` when both true,
    /// otherwise `lightweight`.
    var currentPreset: SoundfontPreset { get }

    /// Latest download state. Observable — Settings reads this directly via `@Bindable`.
    var downloadState: SoundfontDownloadState { get }

    /// Synchronous file-URL accessor used by the audio thread. `nonisolated` so it is callable without an actor hop;
    /// concrete providers override for real file-presence checks. Keeping this in the protocol makes it reachable via
    /// `any MuseScoreGeneralProvider` existentials.
    nonisolated var museScoreGeneralFileURLSync: URL? { get }

    /// Current network reachability snapshot used by the Settings UI to decide whether to prompt the user before
    /// kicking off a cellular download. Cheap synchronous read backed by the provider's internal `NWPathMonitor`.
    nonisolated var isCurrentlyWiFi: Bool { get }

    /// Apply the opt-in toggle. Side effects: if turning on, kick off `startDownloadIfNeeded`; if turning off, cancel
    /// any in-flight download and delete the downloaded file from disk.
    func setOptedIn(_ value: Bool)

    /// Kick off a download if the toggle is on, the file is absent, and the network policy allows it. Idempotent —
    /// safe to call on every app launch and every network-availability change.
    func startDownloadIfNeeded()

    /// Force a download attempt regardless of the network policy. Used when the user explicitly accepts cellular usage
    /// from the "no Wi-Fi" confirmation alert.
    func startDownloadAllowingCellular()

    /// Cancel an in-flight download. No-op if idle.
    func cancelDownload()

    /// Delete the downloaded preset file from disk if present. No-op if absent.
    func deleteDownloaded()
}

extension MuseScoreGeneralProvider {
    /// Default synchronous file-URL accessor. Returns `nil`. Override in concrete providers that can answer without an
    /// actor hop (e.g. `LiveMuseScoreGeneralProvider.museScoreGeneralFileURLSync`).
    public nonisolated var museScoreGeneralFileURLSync: URL? {
        nil
    }
}
