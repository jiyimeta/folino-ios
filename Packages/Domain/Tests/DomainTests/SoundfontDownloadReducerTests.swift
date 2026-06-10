@testable import Domain
import Testing

struct SoundfontDownloadReducerTests {
    typealias R = SoundfontDownloadReducer

    @Test func `progress moves to downloading and clamps`() {
        #expect(R.nextState(.idle, on: .started) == .downloading(progress: 0))
        #expect(R.nextState(.downloading(progress: 0), on: .progress(fraction: 0.5)) == .downloading(progress: 0.5))
        #expect(R.nextState(.downloading(progress: 0.5), on: .progress(fraction: 1.4)) == .downloading(progress: 1))
        #expect(R.nextState(.downloading(progress: 0.5), on: .progress(fraction: -1)) == .downloading(progress: 0))
    }

    @Test func `finished and failed`() {
        #expect(R.nextState(.downloading(progress: 0.9), on: .finished) == .downloaded)
        #expect(R.nextState(.downloading(progress: 0.2), on: .failed(reason: "boom")) == .failed(reason: "boom"))
    }

    @Test func `cancelled and sync depend on file`() {
        #expect(R.nextState(.downloading(progress: 0.2), on: .cancelled(fileExists: false)) == .idle)
        #expect(R.nextState(.downloading(progress: 0.2), on: .cancelled(fileExists: true)) == .downloaded)
        #expect(R.nextState(.idle, on: .syncedFromDisk(fileExists: true)) == .downloaded)
        #expect(R.nextState(.downloaded, on: .syncedFromDisk(fileExists: false)) == .idle)
    }

    @Test func `auto start requires opt in wi fi absent file no inflight`() {
        #expect(R.shouldAutoStart(isOptedIn: true, fileExists: false, isDownloading: false, isWiFi: true))
        #expect(!R.shouldAutoStart(isOptedIn: false, fileExists: false, isDownloading: false, isWiFi: true))
        #expect(!R.shouldAutoStart(isOptedIn: true, fileExists: true, isDownloading: false, isWiFi: true))
        #expect(!R.shouldAutoStart(isOptedIn: true, fileExists: false, isDownloading: true, isWiFi: true))
        #expect(!R.shouldAutoStart(isOptedIn: true, fileExists: false, isDownloading: false, isWiFi: false))
    }

    @Test func `retries only after failure`() {
        #expect(R.shouldRetryOnWiFi(.failed(reason: "x")))
        #expect(!R.shouldRetryOnWiFi(.idle))
        #expect(!R.shouldRetryOnWiFi(.downloading(progress: 0.1)))
        #expect(!R.shouldRetryOnWiFi(.downloaded))
    }

    @Test func `preset selection`() {
        #expect(R.preset(isOptedIn: true, isDownloaded: true) == .highQuality)
        #expect(R.preset(isOptedIn: true, isDownloaded: false) == .lightweight)
        #expect(R.preset(isOptedIn: false, isDownloaded: true) == .lightweight)
    }
}
