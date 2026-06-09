import Domain
import Foundation
import Observation
import WireletObservable

/// Android-side high-quality SoundFont provider, mirroring iOS `LiveMuseScoreGeneralProvider` but with transport,
/// reachability, and persistence injected from Kotlin. State transitions, Wi-Fi gating, auto-retry, and preset
/// selection all run through the shared `SoundfontDownloadReducer`, so behavior matches iOS exactly.
///
/// Exposes flattened state to Compose (`stateWire`, `isOptedIn`, `presetRaw`) because Wirelet cannot bridge an
/// enum with associated values.
@WireletObservable
@Observable
public final class MuseScoreGeneralAndroidStore {
    @ObservationIgnored private let downloader: SoundfontDownloader
    @ObservationIgnored private let reachability: SoundfontReachability
    @ObservationIgnored private let prefs: SoundfontPrefsStore
    // swiftlint:disable:next line_length
    @ObservationIgnored private let remoteURL = "https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/unsplit/MuseScore_General.sf2"

    public var stateWire: SoundfontStateWire = .init(statusRaw: "idle", progress: 0, failureReason: "")
    public var isOptedIn = true
    public var presetRaw: String = SoundfontPreset.lightweight.rawValue

    @ObservationIgnored private var downloadState: SoundfontDownloadState = .idle {
        didSet { stateWire = Self.wire(downloadState); recomputePreset() }
    }

    public init(downloader: SoundfontDownloader, reachability: SoundfontReachability, prefs: SoundfontPrefsStore) {
        self.downloader = downloader
        self.reachability = reachability
        self.prefs = prefs
        isOptedIn = prefs.loadOptedIn()
        downloadState = FileManager.default.fileExists(atPath: targetFilePath) ? .downloaded : .idle
        recomputePreset()
        reachability.startObserving()
        startDownloadIfNeeded()
    }

    // MARK: - Derived

    private var soundfontsDir: String {
        prefs.soundfontsDirectoryPath()
    }

    private var targetFilePath: String {
        "\(soundfontsDir)/\(SoundfontPreset.highQuality.fileName)"
    }

    private var isDownloaded: Bool {
        if case .downloaded = downloadState { return true }
        return false
    }

    private func recomputePreset() {
        presetRaw = SoundfontDownloadReducer.preset(isOptedIn: isOptedIn, isDownloaded: isDownloaded).rawValue
    }

    private static func wire(_ state: SoundfontDownloadState) -> SoundfontStateWire {
        switch state {
        case .idle: .init(statusRaw: "idle", progress: 0, failureReason: "")
        case let .downloading(progress): .init(statusRaw: "downloading", progress: progress, failureReason: "")
        case .downloaded: .init(statusRaw: "downloaded", progress: 0, failureReason: "")
        case let .failed(reason): .init(statusRaw: "failed", progress: 0, failureReason: reason)
        }
    }

    // MARK: - Commands (Kotlin -> Swift)

    @WireletExpose
    public func setOptedIn(value: Bool) {
        prefs.saveOptedIn(value: value)
        isOptedIn = value
        recomputePreset()
        if value {
            startDownloadIfNeeded()
        } else {
            cancelDownload()
            deleteDownloaded()
        }
    }

    @WireletExpose
    public func startDownloadIfNeeded() {
        let exists = FileManager.default.fileExists(atPath: targetFilePath)
        if exists {
            downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: true))
            return
        }
        guard SoundfontDownloadReducer.shouldAutoStart(
            isOptedIn: isOptedIn,
            fileExists: exists,
            isDownloading: isDownloadingNow,
            isWiFi: reachability.isWiFi(),
        ) else { return }
        beginDownload(allowCellular: false)
    }

    @WireletExpose
    public func startDownloadAllowingCellular() {
        if FileManager.default.fileExists(atPath: targetFilePath) {
            downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: true))
            return
        }
        guard !isDownloadingNow else { return }
        beginDownload(allowCellular: true)
    }

    @WireletExpose
    public func cancelDownload() {
        downloader.cancel()
        let exists = FileManager.default.fileExists(atPath: targetFilePath)
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .cancelled(fileExists: exists))
    }

    @WireletExpose
    public func deleteDownloaded() {
        try? FileManager.default.removeItem(atPath: targetFilePath)
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: false))
    }

    /// Absolute path of the downloaded high-quality SF2 if present, else empty string. Read by the Kotlin resolver.
    @WireletExpose
    public func highQualityFilePath() -> String {
        FileManager.default.fileExists(atPath: targetFilePath) ? targetFilePath : ""
    }

    /// Synchronous Wi-Fi snapshot for the Settings UI's toggle-on gate.
    @WireletExpose
    public func isWiFiNow() -> Bool {
        reachability.isWiFi()
    }

    // MARK: - Ingest (Kotlin downloader / reachability -> Swift)

    @WireletExpose
    public func ingestProgress(fraction: Double) {
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .progress(fraction: fraction))
    }

    @WireletExpose
    public func ingestFinished() {
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .finished)
    }

    @WireletExpose
    public func ingestFailed(reason: String) {
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .failed(reason: reason))
    }

    @WireletExpose
    public func onReachabilityChanged(isWiFi: Bool) {
        guard isWiFi else { return }
        if SoundfontDownloadReducer.shouldRetryOnWiFi(downloadState) {
            startDownloadIfNeeded()
        }
    }

    // MARK: - Private

    private var isDownloadingNow: Bool {
        if case .downloading = downloadState { return true }
        return false
    }

    private func beginDownload(allowCellular: Bool) {
        try? FileManager.default.createDirectory(
            atPath: soundfontsDir, withIntermediateDirectories: true,
        )
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .started)
        downloader.start(remoteURL: remoteURL, destinationPath: targetFilePath, allowCellular: allowCellular)
    }
}
