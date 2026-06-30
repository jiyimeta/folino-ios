@testable import Domain
import Testing

struct SoundfontDownloadReducerTests {
    typealias R = SoundfontDownloadReducer

    @Test func `progress moves to downloading and clamps`() {
        #expect(R.nextState(.idle, on: .started) == .downloading(progress: 0))
        #expect(R.nextState(.downloading(progress: 0), on: .progress(fraction: 0.5)) == .downloading(progress: 0.5))
        #expect(R.nextState(.downloading(progress: 0.5), on: .progress(fraction: 1.4)) == .downloading(progress: 1))
        // Out-of-range fractions clamp to [0, 1]; a backward value is ignored (progress is monotonic).
        #expect(R.nextState(.downloading(progress: 0), on: .progress(fraction: -1)) == .downloading(progress: 0))
        #expect(R.nextState(.downloading(progress: 0.5), on: .progress(fraction: -1)) == .downloading(progress: 0.5))
    }

    // The background-download delegate hands every URLSession callback to the main actor through an independent
    // `Task { @MainActor in … }`, which carries no ordering guarantee. So `.progress` can land out of order — after
    // `.finished`, after a cancel, or behind a higher fraction. The reducer must absorb that.

    @Test func `progress never revives a terminal state`() {
        // A trailing progress that lands after `.finished` must not clobber `.downloaded` back to `.downloading`
        // (the "completed but still shows downloading" bug).
        #expect(R.nextState(.downloaded, on: .progress(fraction: 1.0)) == .downloaded)
        #expect(R.nextState(.downloaded, on: .progress(fraction: 0.4)) == .downloaded)
        // A stale progress must not revive a failed attempt, nor flip idle into downloading.
        #expect(R.nextState(.failed(reason: "x"), on: .progress(fraction: 0.5)) == .failed(reason: "x"))
        #expect(R.nextState(.idle, on: .progress(fraction: 0.5)) == .idle)
    }

    @Test func `progress is monotonic`() {
        // An out-of-order progress with a smaller fraction must not move the bar backward.
        #expect(R.nextState(.downloading(progress: 0.7), on: .progress(fraction: 0.3)) == .downloading(progress: 0.7))
        #expect(R.nextState(.downloading(progress: 0.7), on: .progress(fraction: 0.9)) == .downloading(progress: 0.9))
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
