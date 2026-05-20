import Foundation

/// Owns the MuseScore_General opt-out toggle, file presence, and download lifecycle. The audio resolver and the
/// Settings row both consume this protocol; only the live infrastructure implementation mutates state.
public protocol MuseScoreGeneralProvider: Sendable {
    /// User toggle. Defaults to `true` on first launch (auto-download by default; opt-out via Settings). When the user
    /// flips this to `false`: cancel any in-flight download; if the file is on disk, delete it.
    var isOptedIn: Bool { get async }
    func setOptedIn(_ value: Bool) async

    /// `true` iff `MuseScore_General.sf2` is currently on disk and readable. Cached file system observation; safe to
    /// poll from the audio thread.
    var isDownloaded: Bool { get async }

    /// File system URL of the downloaded preset, or `nil` if absent. `GMSoundfontResolver` consults this every time the
    /// engine asks for `defaultGMSoundfontURL`.
    var museScoreGeneralFileURL: URL? { get async }

    /// Synchronous file-URL accessor used by the audio thread. Defaults to `nil`; concrete providers override for real
    /// file-presence checks. Keeping this in the protocol makes it reachable via `any MuseScoreGeneralProvider`
    /// existentials (protocol extension non-requirements are statically dispatched and cannot be overridden through
    /// existentials).
    var museScoreGeneralFileURLSync: URL? { get }

    /// Currently-effective preset, derived from `(isOptedIn, isDownloaded)`: `museScoreGeneral` when both true,
    /// otherwise `generalUserGS`.
    var currentPreset: SoundfontPreset { get async }

    /// Async stream of state changes for the Settings UI. New subscribers receive the current state immediately.
    func downloadStateStream() -> AsyncStream<SoundfontDownloadState>

    /// Kick off a download if the toggle is on, the file is absent, and the network policy allows it. Idempotent —
    /// safe to call on every app launch and every network-availability change.
    func startDownloadIfNeeded() async

    /// Force a download attempt regardless of the network policy. Used by the "Download over cellular" button.
    func startDownloadAllowingCellular() async

    /// Cancel an in-flight download. No-op if idle.
    func cancelDownload() async

    /// Delete `MuseScore_General.sf2` from disk if present. No-op if absent.
    func deleteDownloaded() async
}

extension MuseScoreGeneralProvider {
    /// Default synchronous file-URL accessor. Returns `nil`. Override in concrete providers that can answer without an
    /// actor hop (e.g. `LiveMuseScoreGeneralProvider.museScoreGeneralFileURLSync`).
    public var museScoreGeneralFileURLSync: URL? {
        nil
    }
}
