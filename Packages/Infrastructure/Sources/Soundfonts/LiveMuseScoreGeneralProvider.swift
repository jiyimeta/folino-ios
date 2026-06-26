import Domain
import Foundation
import Network
import Observation
import os

/// UserDefaults-backed opt-out toggle + foreground `URLSessionDownloadTask` lifecycle for the high-quality preset.
///
/// Network policy: `URLSessionConfiguration.allowsCellularAccess = false` for the auto-download session — that means
/// `startDownloadIfNeeded` is a no-op when Wi-Fi is unreachable, but a `URLSessionDownloadTask` already in flight on
/// Wi-Fi will not be killed if the user later steps onto cellular. `startDownloadAllowingCellular` uses a separate
/// session with `allowsCellularAccess = true` for the explicit "Download over cellular" button.
///
/// Observable: Settings reads `isOptedIn` and `downloadState` directly via `@Bindable`. Both are stored properties of
/// this `@Observable` class so the SwiftUI tracker picks up every transition.
///
/// Auto-retry: an `NWPathMonitor` watches for a Wi-Fi transition. When the last download failed and Wi-Fi becomes
/// reachable, the provider re-issues `startDownloadIfNeeded`.
@MainActor
@Observable
public final class LiveMuseScoreGeneralProvider: MuseScoreGeneralProvider {
    public private(set) var isOptedIn: Bool
    public private(set) var downloadState: SoundfontDownloadState

    @ObservationIgnored private let targetDirectory: URL
    @ObservationIgnored private let downloadURL: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let pathMonitor: any NetworkPathObserving
    @ObservationIgnored private let wifiSession: URLSession
    @ObservationIgnored private let cellularSession: URLSession
    @ObservationIgnored private let reclaimer: SharedSoundfontReclaimer?
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.KeyNumber.Folino", category: "MuseScoreGeneralProvider",
    )

    @ObservationIgnored private var activeTask: URLSessionDownloadTask?
    /// Strongly held reference to the download delegate. `URLSessionTask.delegate` is `weak`, so without this the
    /// delegate would be deallocated before any callbacks fire.
    @ObservationIgnored private var activeDelegate: DownloadDelegate?

    public init(
        targetDirectory: URL,
        downloadURL: URL? = nil,
        defaults: UserDefaults = .standard,
        pathMonitor: any NetworkPathObserving = NWPathMonitorAdapter(),
        wifiSession: URLSession? = nil,
        cellularSession: URLSession? = nil,
        reclaimer: SharedSoundfontReclaimer? = nil,
    ) {
        self.targetDirectory = targetDirectory
        // swiftlint:disable:next force_unwrapping line_length
        self.downloadURL = downloadURL ?? URL(string: "https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/unsplit/MuseScore_General.sf2")!
        self.defaults = defaults
        self.pathMonitor = pathMonitor
        self.wifiSession = wifiSession ?? Self.makeSession(allowsCellular: false)
        self.cellularSession = cellularSession ?? Self.makeSession(allowsCellular: true)
        self.reclaimer = reclaimer
        isOptedIn = defaults.object(forKey: Self.optInKey) as? Bool ?? true
        let fileURL = targetDirectory.appending(path: SoundfontPreset.highQuality.fileName)
        downloadState = FileManager.default.fileExists(atPath: fileURL.path) ? .downloaded : .idle
        pathMonitor.start { [weak self] isWiFi in
            Task { @MainActor in self?.handlePathChange(isWiFi: isWiFi) }
        }
    }

    private static func makeSession(allowsCellular: Bool) -> URLSession {
        let config = URLSessionConfiguration.default
        config.allowsCellularAccess = allowsCellular
        config.waitsForConnectivity = true
        config.timeoutIntervalForResource = 60 * 30
        return URLSession(configuration: config)
    }

    private static let optInKey = "soundfont.museScoreGeneral.optedIn"

    private var targetFileURL: URL {
        targetDirectory.appending(path: SoundfontPreset.highQuality.fileName)
    }

    // MARK: - MuseScoreGeneralProvider

    public nonisolated var isCurrentlyWiFi: Bool {
        pathMonitor.isCurrentlyWiFi
    }

    /// Derived from `downloadState` so observers re-evaluate when the state machine transitions.
    public var isDownloaded: Bool {
        if case .downloaded = downloadState { return true }
        return false
    }

    public var museScoreGeneralFileURL: URL? {
        isDownloaded ? targetFileURL : nil
    }

    public nonisolated var museScoreGeneralFileURLSync: URL? {
        let url = targetDirectory.appending(path: SoundfontPreset.highQuality.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public var currentPreset: SoundfontPreset {
        SoundfontDownloadReducer.preset(isOptedIn: isOptedIn, isDownloaded: isDownloaded)
    }

    public func setOptedIn(_ value: Bool) {
        defaults.set(value, forKey: Self.optInKey)
        isOptedIn = value
        if value {
            reclaimer?.syncOwnMarker(isOptedIn: true)
            startDownloadIfNeeded()
        } else {
            cancelDownload()
            if let reclaimer {
                reclaimer.syncOwnMarker(isOptedIn: false)
                reclaimer.reclaimIfUnused(isOptedIn: false)
            } else {
                deleteDownloaded() // legacy single-app behavior when no shared reclaimer is wired (e.g. unit tests)
            }
        }
    }

    public func startDownloadIfNeeded() {
        let fileExists = FileManager.default.fileExists(atPath: targetFileURL.path)
        if fileExists {
            downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: true))
            return
        }
        guard SoundfontDownloadReducer.shouldAutoStart(
            isOptedIn: isOptedIn,
            fileExists: fileExists,
            isDownloading: activeTask != nil,
            isWiFi: pathMonitor.isCurrentlyWiFi,
        ) else { return }
        startDownload(session: wifiSession)
    }

    public func startDownloadAllowingCellular() {
        if FileManager.default.fileExists(atPath: targetFileURL.path) {
            downloadState = .downloaded
            return
        }
        guard activeTask == nil else { return }
        startDownload(session: cellularSession)
    }

    private func startDownload(session: URLSession) {
        try? FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)
        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 60
        let delegate = DownloadDelegate(owner: self)
        let task = session.downloadTask(with: request)
        task.delegate = delegate
        activeDelegate = delegate // keep strong ref alive for the lifetime of the task
        activeTask = task
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .started)
        let url = downloadURL.absoluteString
        logger.notice("MuseScore_General download starting from \(url, privacy: .public)")
        task.resume()
    }

    public func cancelDownload() {
        activeTask?.cancel()
        activeTask = nil
        activeDelegate = nil
        // Keep the state machine honest: if a file landed before cancel propagated, surface that.
        let exists = FileManager.default.fileExists(atPath: targetFileURL.path)
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .cancelled(fileExists: exists))
    }

    public func deleteDownloaded() {
        try? FileManager.default.removeItem(at: targetFileURL)
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: false))
    }

    // MARK: - Internal — called by URLSessionDownloadDelegate

    fileprivate func updateProgress(bytesWritten: Int64, expected: Int64) {
        guard expected > 0 else { return }
        downloadState = SoundfontDownloadReducer.nextState(
            downloadState, on: .progress(fraction: Double(bytesWritten) / Double(expected)),
        )
    }

    fileprivate func handleDownloadFinished(temporaryURL: URL) {
        do {
            if FileManager.default.fileExists(atPath: targetFileURL.path) {
                try FileManager.default.removeItem(at: targetFileURL)
            }
            try FileManager.default.moveItem(at: temporaryURL, to: targetFileURL)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var moved = targetFileURL
            try moved.setResourceValues(values)
            activeTask = nil
            activeDelegate = nil
            downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .finished)
            reclaimer?.syncOwnMarker(isOptedIn: true)
            let path = targetFileURL.path
            logger.notice("MuseScore_General download finished, installed at \(path, privacy: .public)")
        } catch {
            logger.error("Failed to install high-quality preset: \(String(describing: error), privacy: .public)")
            activeTask = nil
            activeDelegate = nil
            downloadState = .failed(reason: error.localizedDescription)
        }
    }

    fileprivate func handleDownloadFailed(error: Error) {
        activeTask = nil
        activeDelegate = nil
        // `URLError.cancelled` arrives when the user toggles off mid-download or app foregrounds with a stale handle —
        // do not surface a "failed" state in that case; cancellation already drove the state machine.
        if (error as? URLError)?.code == .cancelled { return }
        logger.notice("MuseScore_General download failed: \(error.localizedDescription, privacy: .public)")
        downloadState = .failed(reason: error.localizedDescription)
    }

    // MARK: - Reachability

    private func handlePathChange(isWiFi: Bool) {
        guard isWiFi else { return }
        if SoundfontDownloadReducer.shouldRetryOnWiFi(downloadState) {
            startDownloadIfNeeded()
        }
    }

    /// Called once at launch (after migration). Publishes the current opt-in as a marker and reclaims the shared file
    /// if this app is opted out and no installed sibling wants it.
    public func reconcileSharedSoundfontMarkersAtLaunch() {
        reclaimer?.syncOwnMarker(isOptedIn: isOptedIn)
        reclaimer?.reclaimIfUnused(isOptedIn: isOptedIn)
    }

    /// Called on scene-phase `.active`. Reflects a copy a sibling downloaded while we were backgrounded, and reclaims
    /// if a sibling opted out / was deleted while we were away and we are opted out.
    public func handleForeground() {
        refreshDownloadStateFromDisk()
        reclaimer?.reclaimIfUnused(isOptedIn: isOptedIn)
    }

    /// Re-derive `downloadState` from disk (App Groups give no cross-process change notification).
    public func refreshDownloadStateFromDisk() {
        let exists = FileManager.default.fileExists(atPath: targetFileURL.path)
        downloadState = SoundfontDownloadReducer.nextState(downloadState, on: .syncedFromDisk(fileExists: exists))
    }

    /// Sibling display name keeping the (opted-out) shared file on device, for the Settings "in use" note; nil unless
    /// this app is opted out, the shared file exists, and an installed sibling is opted in.
    public var soundfontKeptBySiblingDisplayName: String? {
        guard !isOptedIn, museScoreGeneralFileURLSync != nil else { return nil }
        return reclaimer?.siblingInUseDisplayName()
    }
}

/// `URLSessionDownloadDelegate` lives outside the class (URLSession's delegate callbacks are not isolated). It hops
/// back onto the main actor for every state mutation.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let owner: LiveMuseScoreGeneralProvider
    init(owner: LiveMuseScoreGeneralProvider) {
        self.owner = owner
    }

    func urlSession(
        _: URLSession, downloadTask _: URLSessionDownloadTask,
        didWriteData _: Int64, totalBytesWritten written: Int64,
        totalBytesExpectedToWrite expected: Int64,
    ) {
        Task { @MainActor in owner.updateProgress(bytesWritten: written, expected: expected) }
    }

    func urlSession(_: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `didFinishDownloadingTo` fires for *any* completed HTTP transaction including 4xx/5xx responses — the
        // server's error body would otherwise be saved as if it were a SoundFont. Check the status code before
        // accepting the file. Reject anything outside the 2xx range as a failed download.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200 ..< 300).contains(http.statusCode)
        {
            let urlString = downloadTask.originalRequest?.url?.absoluteString ?? "<unknown URL>"
            let error = URLError(.badServerResponse, userInfo: [
                NSLocalizedDescriptionKey: "HTTP \(http.statusCode) for \(urlString)",
            ])
            Task { @MainActor in owner.handleDownloadFailed(error: error) }
            return
        }
        // Move synchronously off the delegate's tmp directory before returning; the file is deleted as soon as this
        // callback returns. Copy into our own scratch URL, then let the main actor move it into place.
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: scratch)
        } catch {
            Task { @MainActor in owner.handleDownloadFailed(error: error) }
            return
        }
        Task { @MainActor in owner.handleDownloadFinished(temporaryURL: scratch) }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // Success path is handled by `didFinishDownloadingTo`.
        Task { @MainActor in owner.handleDownloadFailed(error: error) }
    }
}

/// Indirection over `NWPathMonitor` so tests can swap in a stub.
public protocol NetworkPathObserving: Sendable {
    var isCurrentlyWiFi: Bool { get }
    func start(handler: @escaping @Sendable (_ isWiFi: Bool) -> Void)
}

public final class NWPathMonitorAdapter: NetworkPathObserving, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "soundfont.network-path", qos: .utility)
    private let cachedIsWiFiLock = OSAllocatedUnfairLock<Bool>(initialState: false)

    public init() {}

    public var isCurrentlyWiFi: Bool {
        cachedIsWiFiLock.withLock { $0 }
    }

    public func start(handler: @escaping @Sendable (Bool) -> Void) {
        monitor.pathUpdateHandler = { [cachedIsWiFiLock] path in
            let isWiFi = path.status == .satisfied && path.usesInterfaceType(.wifi)
            cachedIsWiFiLock.withLock { $0 = isWiFi }
            handler(isWiFi)
        }
        monitor.start(queue: queue)
    }
}
