import Domain
import Foundation
import Network
import os

/// UserDefaults-backed opt-out toggle + foreground `URLSessionDownloadTask` lifecycle for the high-quality preset.
///
/// Network policy: `URLSessionConfiguration.allowsCellularAccess = false` for the auto-download session — that means
/// `startDownloadIfNeeded` is a no-op when Wi-Fi is unreachable, but a `URLSessionDownloadTask` already in flight on
/// Wi-Fi will not be killed if the user later steps onto cellular. `startDownloadAllowingCellular` uses a separate
/// session with `allowsCellularAccess = true` for the explicit "Download over cellular" button.
///
/// State stream: `downloadStateStream()` returns a multicast `AsyncStream` so Settings + the resolver can both watch.
/// New subscribers receive the current state immediately.
///
/// Auto-retry: an `NWPathMonitor` watches for a Wi-Fi transition. When the last download failed and Wi-Fi becomes
/// reachable, the provider re-issues `startDownloadIfNeeded`.
public actor LiveMuseScoreGeneralProvider: MuseScoreGeneralProvider {
    private let targetDirectory: URL
    private let downloadURL: URL
    private let defaults: UserDefaults
    private let pathMonitor: any NetworkPathObserving
    private let wifiSession: URLSession
    private let cellularSession: URLSession
    private let logger = Logger(subsystem: "com.KeyNumber.Folino", category: "MuseScoreGeneralProvider")

    private var activeTask: URLSessionDownloadTask?
    /// Strongly held reference to the download delegate. `URLSessionTask.delegate` is `weak`, so without this the
    /// delegate would be deallocated before any callbacks fire.
    private var activeDelegate: DownloadDelegate?
    private var currentState: SoundfontDownloadState = .idle
    private var continuations: [UUID: AsyncStream<SoundfontDownloadState>.Continuation] = [:]

    public init(
        targetDirectory: URL,
        downloadURL: URL? = nil,
        defaults: UserDefaults = .standard,
        pathMonitor: any NetworkPathObserving = NWPathMonitorAdapter(),
        wifiSession: URLSession? = nil,
        cellularSession: URLSession? = nil,
    ) {
        self.targetDirectory = targetDirectory
        // swiftlint:disable:next force_unwrapping line_length
        self.downloadURL = downloadURL ?? URL(string: "https://github.com/jiyimeta/musescore-general-sf2-split/releases/download/unsplit/MuseScore_General.sf2")!
        self.defaults = defaults
        self.pathMonitor = pathMonitor
        self.wifiSession = wifiSession ?? Self.makeSession(allowsCellular: false)
        self.cellularSession = cellularSession ?? Self.makeSession(allowsCellular: true)
        // Compute the file URL directly here; `targetFileURL` is actor-isolated so cannot be accessed before init ends.
        let fileURL = targetDirectory.appending(path: SoundfontPreset.highQuality.fileName)
        currentState = FileManager.default.fileExists(atPath: fileURL.path) ? .downloaded : .idle
        pathMonitor.start { [weak self] isWiFi in
            Task { await self?.handlePathChange(isWiFi: isWiFi) }
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

    public var isOptedIn: Bool {
        defaults.object(forKey: Self.optInKey) as? Bool ?? true
    }

    public func setOptedIn(_ value: Bool) async {
        defaults.set(value, forKey: Self.optInKey)
        if value {
            await startDownloadIfNeeded()
        } else {
            await cancelDownload()
            await deleteDownloaded()
        }
    }

    public nonisolated var isCurrentlyWiFi: Bool {
        pathMonitor.isCurrentlyWiFi
    }

    public var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: targetFileURL.path)
    }

    public var museScoreGeneralFileURL: URL? {
        isDownloaded ? targetFileURL : nil
    }

    public nonisolated var museScoreGeneralFileURLSync: URL? {
        let url = targetDirectory.appending(path: SoundfontPreset.highQuality.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public var currentPreset: SoundfontPreset {
        (isOptedIn && isDownloaded) ? .highQuality : .lightweight
    }

    public nonisolated func downloadStateStream() -> AsyncStream<SoundfontDownloadState> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(id: id, continuation: continuation) }
            continuation.onTermination = { _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    private func register(id: UUID, continuation: AsyncStream<SoundfontDownloadState>.Continuation) {
        continuations[id] = continuation
        continuation.yield(currentState)
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func publish(_ state: SoundfontDownloadState) {
        currentState = state
        for continuation in continuations.values {
            continuation.yield(state)
        }
    }

    // swiftlint:disable:next async_without_await
    public func startDownloadIfNeeded() async {
        guard isOptedIn else { return }
        guard !isDownloaded else { publish(.downloaded); return }
        guard activeTask == nil else { return }
        guard pathMonitor.isCurrentlyWiFi else { return }
        startDownload(session: wifiSession)
    }

    // swiftlint:disable:next async_without_await
    public func startDownloadAllowingCellular() async {
        guard !isDownloaded else { publish(.downloaded); return }
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
        publish(.downloading(progress: 0))
        task.resume()
    }

    // swiftlint:disable:next async_without_await
    public func cancelDownload() async {
        activeTask?.cancel()
        activeTask = nil
        activeDelegate = nil
        // Keep state machine honest: if a file landed before cancel propagated, surface that.
        publish(isDownloaded ? .downloaded : .idle)
    }

    // swiftlint:disable:next async_without_await
    public func deleteDownloaded() async {
        try? FileManager.default.removeItem(at: targetFileURL)
        publish(.idle)
    }

    // MARK: - Internal — called by URLSessionDownloadDelegate

    fileprivate func updateProgress(bytesWritten: Int64, expected: Int64) {
        guard expected > 0 else { return }
        publish(.downloading(progress: Double(bytesWritten) / Double(expected)))
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
            publish(.downloaded)
        } catch {
            logger.error("Failed to install high-quality preset: \(String(describing: error), privacy: .public)")
            activeTask = nil
            activeDelegate = nil
            publish(.failed(reason: error.localizedDescription))
        }
    }

    fileprivate func handleDownloadFailed(error: Error) {
        activeTask = nil
        activeDelegate = nil
        // `URLError.cancelled` arrives when the user toggles off mid-download or app foregrounds with a stale handle —
        // do not surface a "failed" state in that case; cancellation already drove the state machine.
        if (error as? URLError)?.code == .cancelled { return }
        publish(.failed(reason: error.localizedDescription))
    }

    // MARK: - Reachability

    private func handlePathChange(isWiFi: Bool) async {
        guard isWiFi else { return }
        if case .failed = currentState {
            await startDownloadIfNeeded()
        }
    }
}

/// `URLSessionDownloadDelegate` lives outside the actor (URLSession's delegate callbacks are not isolated). It hops
/// back into the actor for every state mutation.
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
        Task { await owner.updateProgress(bytesWritten: written, expected: expected) }
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
            Task { await owner.handleDownloadFailed(error: error) }
            return
        }
        // Move synchronously off the delegate's tmp directory before returning; the file is deleted as soon as this
        // callback returns. Copy into our own scratch URL, then let the actor move it into place.
        let scratch = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        do {
            try FileManager.default.moveItem(at: location, to: scratch)
        } catch {
            Task { await owner.handleDownloadFailed(error: error) }
            return
        }
        Task { await owner.handleDownloadFinished(temporaryURL: scratch) }
    }

    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return } // Success path is handled by `didFinishDownloadingTo`.
        Task { await owner.handleDownloadFailed(error: error) }
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
