import Domain
import Foundation
@testable import Settings
import Testing

struct SoundfontPresetViewTests {
    @Test func `view instantiates with a stub provider`() {
        let view = SoundfontPresetView(provider: StubProvider())
        _ = view.body
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

    var currentPreset: SoundfontPreset {
        .generalUserGS
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
