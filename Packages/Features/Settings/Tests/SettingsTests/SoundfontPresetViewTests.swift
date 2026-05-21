import Domain
import Foundation
@testable import Settings
import Testing

struct SoundfontPresetSectionTests {
    @Test func `section instantiates with a stub provider`() {
        let section = SoundfontPresetSection(provider: StubProvider())
        _ = section.body
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
