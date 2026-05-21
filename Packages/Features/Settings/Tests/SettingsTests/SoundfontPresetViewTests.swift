import Domain
import Foundation
@testable import Settings
import Testing

struct SoundfontPresetRowTests {
    @Test func `row instantiates with a stub provider`() {
        let row = SoundfontPresetRow(provider: StubProvider())
        _ = row.body
    }
}

private struct StubProvider: MuseScoreGeneralProvider {
    var isOptedIn: Bool {
        true
    }

    var isDownloaded: Bool {
        false
    }

    var museScoreGeneralFileURL: URL? {
        nil
    }

    var museScoreGeneralFileURLSync: URL? {
        nil
    }

    var isCurrentlyWiFi: Bool {
        true
    }

    var currentPreset: SoundfontPreset {
        .lightweight
    }

    func setOptedIn(_: Bool) {}
    func downloadStateStream() -> AsyncStream<SoundfontDownloadState> {
        AsyncStream { _ in }
    }

    func startDownloadIfNeeded() {}
    func startDownloadAllowingCellular() {}
    func cancelDownload() {}
    func deleteDownloaded() {}
}
