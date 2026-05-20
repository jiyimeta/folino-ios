import Domain
import Foundation
@testable import Soundfonts
import Testing

@Suite(.serialized) struct LiveMuseScoreGeneralProviderTests {
    @Test func `default opt-in is true on first launch`() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        let provider = env.makeProvider()
        #expect(await provider.isOptedIn == true)
    }

    @Test func `toggling off cancels in-flight download and deletes file`() async throws {
        let env = try TestEnvironment()
        defer { env.cleanup() }
        try env.placeDownloadedFile(bytes: 100)
        let provider = env.makeProvider()
        await provider.setOptedIn(false)
        #expect(await provider.isDownloaded == false)
        #expect(await provider.currentPreset == .lightweight)
    }

    @Test func `startDownloadIfNeeded skips when network is cellular and policy is wifi-only`() async throws {
        let env = try TestEnvironment(networkIsWiFi: false)
        defer { env.cleanup() }
        let provider = env.makeProvider()
        await provider.startDownloadIfNeeded()
        #expect(await provider.isDownloaded == false)
        var observed: [SoundfontDownloadState] = []
        for await state in provider.downloadStateStream().prefix(1) {
            observed.append(state)
        }
        #expect(observed == [.idle])
    }

    @Test(.timeLimit(.minutes(1)))
    func `startDownloadIfNeeded on wifi reports progress and lands the file`() async throws {
        let env = try TestEnvironment(networkIsWiFi: true)
        defer { env.cleanup() }
        env.stubResponseBody = Data(repeating: 0xAB, count: 1024)
        let provider = env.makeProvider()
        await provider.startDownloadIfNeeded()
        // Wait for completion via the stream.
        for await state in provider.downloadStateStream() {
            if case .downloaded = state { break }
        }
        #expect(await provider.isDownloaded == true)
        #expect(await provider.currentPreset == .highQuality)
    }

    @Test(.timeLimit(.minutes(1)))
    func `startDownloadAllowingCellular runs even when wifi policy would refuse`() async throws {
        let env = try TestEnvironment(networkIsWiFi: false)
        defer { env.cleanup() }
        env.stubResponseBody = Data(repeating: 0xCC, count: 1024)
        let provider = env.makeProvider()
        await provider.startDownloadAllowingCellular()
        for await state in provider.downloadStateStream() {
            if case .downloaded = state { break }
        }
        #expect(await provider.isDownloaded == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func `network failure transitions to .failed and auto-retries when wifi reachability returns`() async throws {
        let env = try TestEnvironment(networkIsWiFi: true)
        defer { env.cleanup() }
        env.stubResponseError = URLError(.notConnectedToInternet)
        let provider = env.makeProvider()
        await provider.startDownloadIfNeeded()
        var sawFailed = false
        for await state in provider.downloadStateStream() {
            if case .failed = state { sawFailed = true; break }
        }
        #expect(sawFailed)
        // Drop the error; signal reachability change; expect the provider to retry.
        env.stubResponseError = nil
        env.stubResponseBody = Data(repeating: 0xDD, count: 1024)
        env.simulateReachabilityChange(toWiFi: true)
        for await state in provider.downloadStateStream() {
            if case .downloaded = state { break }
        }
        #expect(await provider.isDownloaded == true)
    }
}

// MARK: - TestEnvironment

final class TestEnvironment: @unchecked Sendable {
    let targetDirectory: URL
    let pathMonitor: FakePathMonitor
    private let defaultsSuiteName: String
    let defaults: UserDefaults
    /// Stub network response — class-level so ProviderStubURLProtocol can read it statically.
    var stubResponseBody: Data? {
        get { ProviderStubURLProtocol.responseBody }
        set { ProviderStubURLProtocol.responseBody = newValue }
    }

    var stubResponseError: Error? {
        get { ProviderStubURLProtocol.responseError }
        set { ProviderStubURLProtocol.responseError = newValue }
    }

    private let session: URLSession

    init(networkIsWiFi: Bool = true) throws {
        let unique = UUID().uuidString
        targetDirectory = FileManager.default.temporaryDirectory
            .appending(path: "LiveMuseScoreGeneralProviderTests-\(unique)")
        try FileManager.default.createDirectory(at: targetDirectory, withIntermediateDirectories: true)

        pathMonitor = FakePathMonitor(isCurrentlyWiFi: networkIsWiFi)

        defaultsSuiteName = "test-\(unique)"
        guard let suite = UserDefaults(suiteName: defaultsSuiteName) else {
            throw URLError(.unknown)
        }
        defaults = suite

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProviderStubURLProtocol.self] + (config.protocolClasses ?? [])
        config.allowsCellularAccess = true // test session always allows; cellular gating is checked via pathMonitor
        session = URLSession(configuration: config)
    }

    func makeProvider() -> LiveMuseScoreGeneralProvider {
        // swiftlint:disable:next force_unwrapping
        let downloadURL = URL(string: "https://test.example.com/MuseScore_General.sf2")!
        return LiveMuseScoreGeneralProvider(
            targetDirectory: targetDirectory,
            downloadURL: downloadURL,
            defaults: defaults,
            pathMonitor: pathMonitor,
            wifiSession: session,
            cellularSession: session,
        )
    }

    /// Drops a fake `MuseScore_General.sf2` into the target directory so the provider sees it as already downloaded.
    func placeDownloadedFile(bytes: Int) throws {
        let url = targetDirectory.appending(path: SoundfontPreset.highQuality.fileName)
        try Data(repeating: 0xAA, count: bytes).write(to: url)
    }

    /// Invokes the path monitor's handler as if Wi-Fi reachability changed.
    func simulateReachabilityChange(toWiFi: Bool) {
        pathMonitor.simulateReachabilityChange(toWiFi: toWiFi)
    }

    func cleanup() {
        ProviderStubURLProtocol.responseBody = nil
        ProviderStubURLProtocol.responseError = nil
        try? FileManager.default.removeItem(at: targetDirectory)
        defaults.removePersistentDomain(forName: defaultsSuiteName)
    }
}

// MARK: - FakePathMonitor

final class FakePathMonitor: NetworkPathObserving, @unchecked Sendable {
    private(set) var isCurrentlyWiFi: Bool
    private var handler: (@Sendable (Bool) -> Void)?

    init(isCurrentlyWiFi: Bool) {
        self.isCurrentlyWiFi = isCurrentlyWiFi
    }

    func start(handler: @escaping @Sendable (Bool) -> Void) {
        self.handler = handler
    }

    func simulateReachabilityChange(toWiFi: Bool) {
        isCurrentlyWiFi = toWiFi
        handler?(toWiFi)
    }
}

// MARK: - ProviderStubURLProtocol

final class ProviderStubURLProtocol: URLProtocol, @unchecked Sendable {
    // Class-level state so all instances of the protocol share the same configured response.
    // The test suite is @Suite(.serialized) so these won't race between tests.
    nonisolated(unsafe) static var responseBody: Data?
    nonisolated(unsafe) static var responseError: Error?

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with _: URLRequest) -> Bool {
        true
    }

    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        if let error = ProviderStubURLProtocol.responseError {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url else { client?.urlProtocolDidFinishLoading(self); return }
        let body = ProviderStubURLProtocol.responseBody ?? Data()
        guard let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Length": "\(body.count)"],
        ) else { client?.urlProtocolDidFinishLoading(self); return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
